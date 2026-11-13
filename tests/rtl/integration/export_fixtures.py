#!/usr/bin/env python3
"""Export RAVEN pre-alpha vectors as integration-test fixtures for tb_raven_npu_top.

Reads tests/vectors/prealpha/manifest.json and each case's reference.json, and writes one
directory per test case under the output directory:

  act.hex, wgt.hex, prm.hex  bank images, one 128-bit little-endian word per line
                             (16 KiB / 16 KiB / 4 KiB, same layout as export_compute_fixture.py)
  cmd.txt                    every staging register as "offset value" hex pairs, packed by the
                             same rules the firmware C helpers use (RISCV_Research.md §6.4)
  expected_int8.hex          expected M x N INT8 bytes, row-major, one byte per line
  meta.txt                   one line of decimal fields, see META_FIELDS
  golden.txt                 valid cases only: the tests/vectors/prealpha case whose
                             expected_int8.bin the result must match (for compare_prealpha.py)

and cases.txt listing "<case> <test>" in run order. Besides Jackie's fixtures it derives the
plan's variant and error cases (T3, T5-T7, T9-T11), so the testbench holds no command constants.
"""
import argparse
import json
import struct
from pathlib import Path

ACT_BYTES = 16384
WGT_BYTES = 16384
PRM_BYTES = 4096
OUT0_BYTES = 8192
A_PAD = 0x5A  # Visible padding in A rows, as in the golden generator.

# Register offsets (raven_ctrl_pkg.sv).
OPCODE, OP_FLAGS, SRC_A, SRC_B = 0x030, 0x034, 0x038, 0x03C
P0, P1, P2, P3, P4, P5 = 0x040, 0x044, 0x048, 0x04C, 0x050, 0x054
DST, PARAM, Q_ZP, Q_MULT, Q_SHIFT, Q_CLAMP = 0x058, 0x05C, 0x060, 0x064, 0x068, 0x06C
STAGING = [OPCODE, OP_FLAGS, SRC_A, SRC_B, P0, P1, P2, P3, P4, P5,
           DST, PARAM, Q_ZP, Q_MULT, Q_SHIFT, Q_CLAMP]

OP_NOP, OP_GEMM, OP_CONV2D = 0x00, 0x02, 0x03
FLAG_ACC_INIT, FLAG_ACC_LAST, FLAG_REQUANT_EN = 1 << 0, 1 << 1, 1 << 2
FLAG_RELU_EN, FLAG_PER_CHANNEL = 1 << 3, 1 << 6
GEMM_FLAGS = FLAG_ACC_INIT | FLAG_ACC_LAST | FLAG_REQUANT_EN

BANK_ACT0, BANK_ACT1, BANK_WGT0, BANK_WGT1 = 0, 1, 2, 3
BANK_OUT0, BANK_OUT1, BANK_PRM = 4, 5, 6

ERR_NONE, ERR_ILLEGAL_OP, ERR_BAD_DIM, ERR_BANK_RANGE = 0x00, 0x01, 0x02, 0x03
ERR_RSVD, ERR_ACC_RANGE, ERR_BAD_FLAGS = 0x07, 0x08, 0x0B

# meta.txt fields, in order. a_bank/b_bank say which bank models get act.hex/wgt.hex.
# expect_launch is 1 when the core must see exactly one command (0 for NOP and control errors).
META_FIELDS = ['M', 'N', 'P4', 'dst_offset', 'a_bank', 'b_bank', 'err_code', 'err_info',
               'stall', 'expect_launch']


def ref(bank, offset):
    """Scratchpad reference {BANK_ID[31:28], rsvd[27:24], BYTE_OFFSET[23:0]}."""
    return (bank << 28) | (offset & 0xFFFFFF)


def round_up(x, n):
    return (x + n - 1) // n * n


def gemm_regs(m, n, k, a_pitch, out_pitch, a_ref, b_ref, dst_ref, param_ref,
              flags, out_zp, clamp_min, clamp_max, q_mult=0, q_shift=0):
    """Staging values for one GEMM, packed per RISCV_Research.md §6.4."""
    return {
        OPCODE: OP_GEMM, OP_FLAGS: flags, SRC_A: a_ref, SRC_B: b_ref,
        P0: ((n & 0xFFFF) << 16) | (m & 0xFFFF), P1: k & 0xFFFF, P2: a_pitch & 0xFFFF,
        P3: 0, P4: out_pitch & 0xFFFF, P5: 0, DST: dst_ref, PARAM: param_ref,
        Q_ZP: (out_zp & 0xFF) << 16, Q_MULT: q_mult & 0xFFFFFFFF, Q_SHIFT: q_shift & 0xFF,
        Q_CLAMP: ((clamp_max & 0xFF) << 8) | (clamp_min & 0xFF),
    }


def nop_regs():
    regs = {r: 0 for r in STAGING}
    regs[Q_CLAMP] = 0x7F80
    return regs


def bank_images(ref_json):
    """ACT/WGT/PRM images for one case, in the compute fixture layout."""
    m, n, k, pitch = (int(ref_json[key]) for key in ('M', 'N', 'K', 'A_pitch_bytes'))
    a_base, b_base, p_base = (int(ref_json[key]) for key in ('A_base', 'B_base', 'PARAM_base'))
    act = bytearray([A_PAD] * ACT_BYTES)
    wgt = bytearray(WGT_BYTES)
    prm = bytearray(PRM_BYTES)
    for r in range(m):
        for t in range(k):
            act[a_base + r * pitch + t] = int(ref_json['A'][r][t]) & 0xFF
    for t in range(k):
        for c in range(n):
            wgt[b_base + 8 * t + c] = int(ref_json['B'][t][c]) & 0xFF
    for c in range(n):
        prm[p_base + 16 * c:p_base + 16 * (c + 1)] = struct.pack(
            '<iib7x', int(ref_json['corrected_bias'][c]),
            int(ref_json['multiplier_q31'][c]), int(ref_json['shift'][c]))
    return act, wgt, prm


def write_hex128(path, image):
    path.write_text(''.join(f'{int.from_bytes(image[i:i + 16], "little"):032x}\n'
                            for i in range(0, len(image), 16)), encoding='ascii')


class Case:
    def __init__(self, name, test, regs, images, expected=b'', dims=(0, 0), out_pitch=0,
                 dst_offset=0, a_bank=BANK_ACT0, b_bank=BANK_WGT0, err=(ERR_NONE, 0),
                 stall=False, expect_launch=True, golden=None):
        self.name, self.test, self.regs, self.images = name, test, regs, images
        self.expected, self.dims, self.out_pitch, self.dst_offset = expected, dims, out_pitch, dst_offset
        self.a_bank, self.b_bank, self.err, self.stall = a_bank, b_bank, err, stall
        self.expect_launch = expect_launch
        self.golden = golden

    def write(self, root):
        d = root / self.name
        d.mkdir(parents=True, exist_ok=True)
        for fname, image in zip(('act.hex', 'wgt.hex', 'prm.hex'), self.images):
            write_hex128(d / fname, image)
        (d / 'cmd.txt').write_text(''.join(f'{r:03x} {self.regs[r]:08x}\n' for r in STAGING),
                                   encoding='ascii')
        (d / 'expected_int8.hex').write_text(''.join(f'{b:02x}\n' for b in self.expected),
                                             encoding='ascii')
        meta = [self.dims[0], self.dims[1], self.out_pitch, self.dst_offset, self.a_bank,
                self.b_bank, self.err[0], self.err[1], int(self.stall), int(self.expect_launch)]
        (d / 'meta.txt').write_text(' '.join(str(v) for v in meta) + '\n', encoding='ascii')
        if self.golden and self.expected:
            (d / 'golden.txt').write_text(self.golden + '\n', encoding='ascii')


def fixture_case(ref_json, expected, name=None, test='T4', **over):
    """A valid GEMM from a reference.json, with optional field overrides."""
    m, n, k = (int(ref_json[key]) for key in ('M', 'N', 'K'))
    p = dict(m=m, n=n, k=k, a_pitch=int(ref_json['A_pitch_bytes']), out_pitch=n,
             a_bank=BANK_ACT0, b_bank=BANK_WGT0, dst_offset=int(ref_json['OUTPUT_base']),
             flags=GEMM_FLAGS | FLAG_PER_CHANNEL, q_mult=0, q_shift=0,
             stall=bool(ref_json['backpressure_test']))
    # The clamp floor equals the output zero point in this case, so RELU_EN must not change it.
    if ref_json['name'] == 'channel_scales_relu_clamp':
        p['flags'] |= FLAG_RELU_EN
    p.update(over)
    regs = gemm_regs(p['m'], p['n'], p['k'], p['a_pitch'], p['out_pitch'],
                     ref(p['a_bank'], int(ref_json['A_base'])),
                     ref(p['b_bank'], int(ref_json['B_base'])),
                     ref(BANK_OUT0, p['dst_offset']),
                     ref(BANK_PRM, int(ref_json['PARAM_base'])),
                     p['flags'], int(ref_json['output_zero_point']),
                     int(ref_json['clamp_min']), int(ref_json['clamp_max']),
                     p['q_mult'], p['q_shift'])
    return Case(name or ref_json['name'], test, regs, bank_images(ref_json), expected,
                (m, n), p['out_pitch'], p['dst_offset'], p['a_bank'], p['b_bank'],
                stall=p['stall'], golden=ref_json['name'])


def error_case(base, name, test, err, expect_launch, edit, images=None):
    """A copy of a valid case's command with edit(regs) applied and an expected error."""
    regs = dict(base.regs)
    edit(regs)
    return Case(name, test, regs, images or base.images, err=err, expect_launch=expect_launch)


def overflow_case(base_ref):
    """Synthetic 0x08 case: 127 x 127 over K=16 on top of a bias near INT32_MAX."""
    r = dict(base_ref)
    m, n, k = 8, 8, 16
    r.update(M=m, N=n, K=k, A_pitch_bytes=16, A_base=0, B_base=0, PARAM_base=0,
             A=[[127] * k for _ in range(m)], B=[[127] * n for _ in range(k)],
             corrected_bias=[(1 << 31) - 1 - 1000] * n)
    assert (1 << 31) - 1 - 1000 + k * 127 * 127 > (1 << 31) - 1
    case = fixture_case(r, b'', name='t11_acc_overflow', test='T11', stall=False)
    case.err, case.dims = (ERR_ACC_RANGE, 0), (0, 0)
    return case


def build_cases(vectors):
    manifest = json.loads((vectors / 'manifest.json').read_text(encoding='utf-8'))
    refs, cases = {}, []
    for entry in manifest['cases']:
        d = vectors / entry['fixture_dir']
        r = json.loads((d / 'reference.json').read_text(encoding='utf-8'))
        refs[entry['name']] = r
        if 'expected_error_code' in entry:
            continue
        expected = (d / 'expected_int8.bin').read_bytes()
        assert len(expected) == int(r['M']) * int(r['N']), entry['name']
        cases.append(fixture_case(r, expected))

    normal = refs['normal_8x16x8']
    normal_case = next(c for c in cases if c.name == 'normal_8x16x8')
    normal_out = normal_case.expected
    partial = refs['partial_tile_7x13x5']
    partial_out = next(c for c in cases if c.name == 'partial_tile_7x13x5').expected

    # Zero-extension preserves the independent normal-case golden, while K=33
    # crosses three 16-byte chunks and repeatedly reuses the small staging slots.
    # Place every allocation at its bank's end to exercise the full address path.
    extended = dict(normal)
    extended.update(K=33, A_pitch_bytes=48, A_base=ACT_BYTES - 8*48,
                    B_base=WGT_BYTES - round_up(33*8, 16), PARAM_base=PRM_BYTES - 8*16,
                    OUTPUT_base=OUT0_BYTES - 8*8,
                    A=[row + [0]*17 for row in normal['A']],
                    B=normal['B'] + [[0]*8 for _ in range(17)])
    cases.append(fixture_case(extended, normal_out, name='t4_bank_edges_k33', stall=False))

    # T3: NOP launches nothing and writes nothing.
    cases.insert(0, Case('t3_nop', 'T3', nop_regs(), normal_case.images, expect_launch=False))

    # T5: shared multiplier/shift from the (uniform) record values.
    assert len(set(normal['multiplier_q31'])) == 1 and len(set(normal['shift'])) == 1
    cases.append(fixture_case(normal, normal_out, name='t5_normal_shared_scale', test='T5',
                              flags=GEMM_FLAGS, q_mult=int(normal['multiplier_q31'][0]),
                              q_shift=int(normal['shift'][0])))
    # T6: padded output pitch at a nonzero destination.
    cases.append(fixture_case(partial, partial_out, name='t6_partial_pitch16_dst100', test='T6',
                              out_pitch=16, dst_offset=0x100))
    # T7: A from ACT1 and B from WGT1.
    cases.append(fixture_case(normal, normal_out, name='t7_normal_act1_wgt1', test='T7',
                              a_bank=BANK_ACT1, b_bank=BANK_WGT1))

    # T9: Jackie's zero-K case, rejected by control before the core sees it.
    zk = refs['invalid_zero_k']
    cases.append(error_case(normal_case, 'invalid_zero_k', 'T9', (int(zk['expected_error_code']), P1),
                            False, lambda g: g.update({
                                P0: (int(zk['N']) << 16) | int(zk['M']), P1: int(zk['K'])})))

    # T10: one case per control-detected rule (plan §7 Phase 2 CHECK order, D9 ERR_INFO).
    n, m = int(normal['N']), int(normal['M'])
    t10 = [
        ('t10_illegal_opcode', (ERR_ILLEGAL_OP, OPCODE), {OPCODE: OP_CONV2D}),
        ('t10_reserved_src_a', (ERR_RSVD, SRC_A), {SRC_A: ref(BANK_ACT0, 0) | (1 << 24)}),
        ('t10_reserved_p5', (ERR_RSVD, P5), {P5: 1}),
        ('t10_missing_acc_last', (ERR_BAD_FLAGS, OP_FLAGS),
         {OP_FLAGS: (GEMM_FLAGS | FLAG_PER_CHANNEL) & ~FLAG_ACC_LAST}),
        ('t10_src_a_prm_bank', (ERR_BANK_RANGE, SRC_A), {SRC_A: ref(BANK_PRM, 0)}),
        ('t10_dst_out1_bank', (ERR_BANK_RANGE, DST), {DST: ref(BANK_OUT1, 0)}),
        ('t10_m9', (ERR_BAD_DIM, P0), {P0: (n << 16) | 9}),
        ('t10_p4_below_n', (ERR_BAD_DIM, P4), {P4: n - 1}),
        ('t10_dst_misaligned', (ERR_BANK_RANGE, DST), {DST: ref(BANK_OUT0, 0x008)}),
        ('t10_dst_span_overflow', (ERR_BANK_RANGE, DST),
         {DST: ref(BANK_OUT0, OUT0_BYTES - 16)}),
    ]
    assert OUT0_BYTES - 16 + (m - 1) * n + n > OUT0_BYTES
    for name, err, fields in t10:
        cases.append(error_case(normal_case, name, 'T10', err, False,
                                lambda g, f=fields: g.update(f)))

    # T11: rules only the core checks; its code passes through and ERR_INFO is 0 (D9, D12).
    k = int(normal['K'])
    cases.append(error_case(normal_case, 't11_a_pitch_short', 'T11', (ERR_BAD_DIM, 0), True,
                            lambda g: g.update({P2: round_up(k, 16) - 16})))
    cases.append(error_case(normal_case, 't11_a_base_misaligned', 'T11', (ERR_BANK_RANGE, 0), True,
                            lambda g: g.update({SRC_A: ref(BANK_ACT0, 0x008)})))
    cases.append(error_case(normal_case, 't11_param_base_misaligned', 'T11', (ERR_BANK_RANGE, 0), True,
                            lambda g: g.update({PARAM: ref(BANK_PRM, 0x008)})))
    cases.append(error_case(normal_case, 't11_param_span_overflow', 'T11', (ERR_BANK_RANGE, 0), True,
                            lambda g: g.update({PARAM: ref(BANK_PRM, PRM_BYTES - 16)})))
    cases.append(overflow_case(normal))
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--vectors', type=Path, default=Path('tests/vectors/prealpha'))
    parser.add_argument('--output', type=Path, default=Path('build/tests/integration/fixtures'))
    args = parser.parse_args()
    cases = build_cases(args.vectors)
    names = [c.name for c in cases]
    assert len(names) == len(set(names)), 'duplicate case names'
    args.output.mkdir(parents=True, exist_ok=True)
    for case in cases:
        case.write(args.output)
    (args.output / 'cases.txt').write_text(''.join(f'{c.name} {c.test}\n' for c in cases),
                                           encoding='ascii')
    print(f'Wrote {len(cases)} integration fixtures to {args.output}')


if __name__ == '__main__':
    main()
