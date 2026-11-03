#!/usr/bin/env python3
"""Adapt one RAVEN pre-alpha golden case to Michael's existing GEMM RTL testbench.

Compute-only bridge: INT32 GEMM, NOT integrated quantization/memory/command RTL.
Does not modify Michael's files; emits a case_00 fixture for +DEMO_ONLY.
"""
import argparse
import json
from pathlib import Path

BANK_BYTES = 16384
PARAM_BYTES = 4096


def write_hex128(path, bank):
    path.write_text(''.join(f'{int.from_bytes(bank[i:i+16], "little"):032x}\n'
                            for i in range(0, len(bank), 16)), encoding='ascii')


def export(case_dir, output):
    d = json.loads((case_dir / 'reference.json').read_text(encoding='utf-8'))
    m, n, k, pitch = (int(d[key]) for key in ('M','N','K','A_pitch_bytes'))
    if not (1 <= m <= 8 and 1 <= n <= 8 and k > 0 and pitch % 16 == 0):
        raise ValueError('Expected a valid 1..8 by 1..8 GEMM tile with padded A pitch')
    if m * pitch > BANK_BYTES or k * 8 > BANK_BYTES:
        raise ValueError('Fixture too large for current simulation memory banks')

    # Match sim_read_memory widths, physical layout and the existing compute fixture ABI.
    a_mem = bytearray([0x5A] * BANK_BYTES)
    b_mem = bytearray(BANK_BYTES)
    p_mem = bytearray(PARAM_BYTES)
    for r in range(m):
        for t in range(k):
            a_mem[r * pitch + t] = int(d['A'][r][t]) & 255
    for t in range(k):
        for c in range(n):
            b_mem[8 * t + c] = int(d['B'][t][c]) & 255
    for c in range(n):
        p_mem[16 * c:16 * c + 4] = int(d['corrected_bias'][c]).to_bytes(4, 'little', signed=True)

    expected = [int(v) for row in d['expected_int32'] for v in row]
    if len(expected) != m*n:
        raise ValueError('Expected INT32 shape does not match M*N')
    case0 = output / 'case_00'
    case0.mkdir(parents=True, exist_ok=True)
    write_hex128(case0 / 'a.hex', a_mem)
    write_hex128(case0 / 'b.hex', b_mem)
    write_hex128(case0 / 'param.hex', p_mem)
    (case0 / 'expected.hex').write_text(''.join(f'{v & 0xffffffff:08x}\n' for v in expected + [0]*(64-len(expected))), encoding='ascii')
    (case0 / 'reference.json').write_text(json.dumps(d, indent=2) + '\n', encoding='utf-8')
    # Index M N K A_pitch A_base B_base PARAM_base expected_error stall_mode.
    (output / 'cases.txt').write_text(f'0 {m} {n} {k} {pitch} 0 0 0 0 1\n', encoding='ascii')
    print(f'Prepared Michael-compatible INT32 fixture: {output} (M={m}, N={n}, K={k})')
    print('Only the compute stage is tested; INT8 requantization is not involved.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', type=Path, default=Path('tests/vectors/prealpha/normal_8x16x8'))
    parser.add_argument('--output', type=Path, default=Path('build/tests/prealpha/jackie_compute'))
    args = parser.parse_args()
    export(args.case, args.output)

if __name__ == '__main__':
    main()
