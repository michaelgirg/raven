#!/usr/bin/env python3
"""Generate deterministic GEMM -> requant fixtures for RAVEN pre-alpha.

Uses the current RAVEN proposed pre-alpha numeric contract, not a TFLite model:
  acc = original_bias[c] + sum((A[r][k]-z_a)*B[k][c])
  multiplier is nonnegative signed INT32 Q0.31, -31 <= shift <= 30
  scaled = (acc * multiplier + (1 << (30 - shift))) >> (31 - shift)
  int8 = clamp(scaled + z_out, clamp_min, clamp_max)

The single-rounding arithmetic follows the documented proposed TFLM convention.
The Python implementation should still be cross-checked against the compiled,
pinned C++ TFLM reference before claiming full bit-exact TFLM conformance.

Only Python 3.9+ standard library is used. The source code is in tools/goldens/;
fixtures live in tests/vectors/prealpha/ and are safe to check into Git.
"""
import argparse
import hashlib
import json
import random
import struct
from pathlib import Path

DEFAULT_OUTPUT = Path(__file__).resolve().parents[2] / "tests/vectors/prealpha"
SEED = 20261102
CONTRACT = "raven-prealpha-gemm-v1-proposed-tflm-single-rounding"


def round_up(n, align):
    return (n + align - 1) // align * align


def check_int32(n, what):
    if not -(1 << 31) <= n <= (1 << 31) - 1:
        raise ValueError(f"{what}: signed INT32 overflow ({n})")
    return n


def quantized_multiplier(x, mul, shift):
    if not (0 <= mul <= 0x7fffffff and -31 <= shift <= 30):
        raise ValueError("Unsupported Q31 multiplier/shift")
    shifted = (x * mul + (1 << (30 - shift))) >> (31 - shift)
    return check_int32(shifted, "requant product")


def make_case(name, m, n, k, a, b, bias, input_zp, output_zp, mul, shifts,
              clamp_min=-128, clamp_max=127, stall=False):
    assert 1 <= m <= 8 and 1 <= n <= 8 and k > 0
    assert len(a) == m and all(len(row) == k for row in a)
    assert len(b) == k and all(len(row) == n for row in b)
    assert len(bias) == n and len(mul) == n and len(shifts) == n
    assert -128 <= input_zp <= 127 and -128 <= output_zp <= 127
    assert -128 <= clamp_min <= clamp_max <= 127
    assert all(-128 <= v <= 127 for row in a for v in row)
    assert all(-128 <= v <= 127 for row in b for v in row)
    assert all(-(1<<31) <= v <= (1<<31)-1 for v in bias)
    pitch = round_up(k, 16)

    # Physical A layout: M rows, each padded to a 16-byte read boundary.
    # Use 0x5a in padding so a bad read is visible in tests.
    a_buf = bytearray([0x5a] * (m * pitch))
    for r, row in enumerate(a):
        for t, v in enumerate(row):
            a_buf[r * pitch + t] = v & 0xff

    # Physical B layout: 8 lanes per K, inactive columns are zero.
    b_buf = bytearray(round_up(k * 8, 16))
    for t, row in enumerate(b):
        for c, v in enumerate(row):
            b_buf[8 * t + c] = v & 0xff

    # Corrected bias is a compute-only seed. Original bias is reference truth.
    corrected = [check_int32(bias[c] - input_zp * sum(b[t][c] for t in range(k)),
                             f"corrected_bias[{c}]") for c in range(n)]
    # 16-byte parameter records, 8 physical channels (extra records zero-filled).
    param_buf = bytearray(8 * 16)
    for c in range(n):
        param_buf[16*c:16*(c+1)] = struct.pack('<iib7x', corrected[c], mul[c], shifts[c])

    # Independently compute centered arithmetic, never read corrected bias.
    int32 = [[check_int32(bias[c] + sum((a[r][t] - input_zp) * b[t][c]
                                         for t in range(k)), f"acc[{r}][{c}]")
              for c in range(n)] for r in range(m)]
    # Cross-check physical compute seed formula, to flag preparation mistakes.
    for r in range(m):
        for c in range(n):
            assert int32[r][c] == corrected[c] + sum(a[r][t] * b[t][c] for t in range(k))
    int8 = []
    for r in range(m):
        row = []
        for c in range(n):
            scaled = quantized_multiplier(int32[r][c], mul[c], shifts[c])
            row.append(max(clamp_min, min(clamp_max, scaled + output_zp)))
        int8.append(row)

    info = dict(name=name, operation="GEMM_REQUANT", M=m, N=n, K=k,
                A_pitch_bytes=pitch, B_physical_cols=8,
                A_base=0, B_base=0, PARAM_base=0, OUTPUT_base=0,
                input_zero_point=input_zp, output_zero_point=output_zp,
                clamp_min=clamp_min, clamp_max=clamp_max,
                original_bias=bias, corrected_bias=corrected,
                multiplier_q31=mul, shift=shifts, backpressure_test=stall,
                A=a, B=b, expected_int32=int32, expected_int8=int8)
    return info, dict(a=a_buf, b=b_buf, param=param_buf,
                      expected_int32=b''.join(struct.pack('<i', x) for row in int32 for x in row),
                      expected_int8=bytes(x & 0xff for row in int8 for x in row))


def cases():
    rng = random.Random(SEED)
    # Normal small values: easy to debug by hand, intentionally avoids saturation.
    a = [[rng.randint(-4, 4) for _ in range(16)] for _ in range(8)]
    b = [[rng.randint(-4, 4) for _ in range(8)] for _ in range(16)]
    yield make_case('normal_8x16x8', 8, 8, 16, a, b,
                    [rng.randint(-15, 15) for _ in range(8)], 0, -4,
                    [1 << 30]*8, [0]*8)

    a = [[rng.randint(-128, 127) for _ in range(16)] for _ in range(8)]
    b = [[rng.randint(-128, 127) for _ in range(8)] for _ in range(16)]
    yield make_case('signed_nonzero_zp_stalled', 8, 8, 16, a, b,
                    [rng.randint(-100, 100) for _ in range(8)], -17, 11,
                    [1 << 30]*8, [-5, -5, -5, -5, -5, -5, -5, -5], stall=True)

    a = [[rng.randint(-5, 5) for _ in range(13)] for _ in range(7)]
    b = [[rng.randint(-5, 5) for _ in range(5)] for _ in range(13)]
    yield make_case('partial_tile_7x13x5', 7, 5, 13, a, b,
                    [7, -9, 31, 0, -17], 4, 6,
                    [1 << 30, 1 << 29, 1 << 30, 1 << 30, 1 << 29],
                    [0, 0, -1, 0, 1])

    a = [[127 for _ in range(16)] for _ in range(8)]
    b = [[127 if c % 2 == 0 else -128 for c in range(8)] for _ in range(16)]
    yield make_case('positive_negative_saturation', 8, 8, 16, a, b,
                    [4096 if c % 2 == 0 else -4096 for c in range(8)], 0, 0,
                    [1 << 30]*8, [1]*8)

    # Ties: 3 * 0.5 => +2; -3 * 0.5 => -1 (round half toward +infinity).
    yield make_case('rounding_ties', 2, 4, 1, [[3], [-3]],
                    [[1, 1, 1, 1]], [0]*4, 0, 0,
                    [1 << 30]*4, [0]*4)

    a = [[rng.randint(-15, 15) for _ in range(16)] for _ in range(8)]
    b = [[rng.randint(-8, 8) for _ in range(8)] for _ in range(16)]
    yield make_case('channel_scales_relu_clamp', 8, 8, 16, a, b,
                    [rng.randint(-30, 30) for _ in range(8)], 9, -6,
                    [1 << 30, 1 << 29, 1 << 28, 1 << 30,
                     1 << 30, 1 << 29, 1 << 28, 1 << 30],
                    [0, 1, -1, 0, -2, 1, 0, -1], -6, 100)


def write_hex_words(path, data):
    # Each line is a 128-bit little-endian memory word (Michael's existing convention).
    assert len(data) % 16 == 0
    path.write_text(''.join(f'{int.from_bytes(data[t:t+16], "little"):032x}\n'
                            for t in range(0, len(data), 16)))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', type=Path, default=DEFAULT_OUTPUT)
    args = ap.parse_args()
    out = args.output
    out.mkdir(parents=True, exist_ok=True)
    summary = []
    for info, files in cases():
        directory = out / info['name']
        directory.mkdir(exist_ok=True)
        hashes = {}
        for key, data in files.items():
            filename = f'{key}.bin'
            (directory / filename).write_bytes(data)
            hashes[filename] = hashlib.sha256(data).hexdigest()
            if key in ('a', 'b', 'param'):
                write_hex_words(directory / f'{key}.hex', data)
        info['hashes_sha256'] = hashes
        (directory / 'reference.json').write_text(json.dumps(info, indent=2) + '\n')
        summary.append(dict(name=info['name'], M=info['M'], N=info['N'], K=info['K'],
                            expected_elements=info['M'] * info['N'],
                            fixture_dir=info['name']))
    # Invalid commands are expected to fail before reading any operands.
    invalid = dict(name='invalid_zero_k', operation='GEMM_REQUANT', M=8, N=8, K=0,
                   expected_error_code=2, expected_output_elements=0,
                   note='Command rejection belongs to Nahjay; no output data is expected.')
    directory = out / invalid['name']
    directory.mkdir(exist_ok=True)
    (directory / 'reference.json').write_text(json.dumps(invalid, indent=2) + '\n')
    summary.append(dict(name=invalid['name'], expected_error_code=2,
                        fixture_dir=invalid['name']))
    manifest = dict(seed=SEED, contract=CONTRACT, int8_order='row major M x N',
                    int32_file='little-endian signed INT32 row-major',
                    int8_file='raw twos-complement bytes row-major',
                    memory_word_hex='one 128-bit little-endian word per line',
                    cases=summary)
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Generated {len(summary)} pre-alpha cases in {out}')

if __name__ == '__main__':
    main()
