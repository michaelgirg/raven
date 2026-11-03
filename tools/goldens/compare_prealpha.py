#!/usr/bin/env python3
"""Compare raw RTL/destination bytes to the independent pre-alpha golden files.

Usage:
  python tools/goldens/compare_prealpha.py --case tests/vectors/prealpha/normal_8x16x8 \
      --kind int8 --actual actual_output.bin
  python tools/goldens/compare_prealpha.py --case tests/vectors/prealpha/normal_8x16x8 \
      --kind int32 --actual actual_accumulations.bin
Exit status: 0 match, 1 mismatch, 2 invalid args/file/format.
"""
import argparse
import json
import struct
from pathlib import Path


def values(data, kind):
    if kind == 'int8':
        return [x if x < 128 else x - 256 for x in data]
    if len(data) % 4:
        raise ValueError('INT32 byte length is not divisible by four')
    return list(struct.unpack(f'<{len(data)//4}i', data))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--case', type=Path, required=True)
    p.add_argument('--kind', choices=['int32', 'int8'], required=True)
    p.add_argument('--actual', type=Path, required=True)
    p.add_argument('--max-print', type=int, default=12)
    args = p.parse_args()
    metadata = json.loads((args.case / 'reference.json').read_text())
    if 'expected_error_code' in metadata:
        p.error('This is an invalid-command case; check the RTL error code instead')
    m, n = metadata['M'], metadata['N']
    golden = values((args.case / f'expected_{args.kind}.bin').read_bytes(), args.kind)
    actual = values(args.actual.read_bytes(), args.kind)
    if len(actual) != len(golden):
        print(f'FAIL {metadata["name"]} {args.kind}: expected {len(golden)} '
              f'values, got {len(actual)}')
        return 1
    errors = [(idx//n, idx % n, e, a) for idx, (e,a) in
              enumerate(zip(golden, actual)) if e != a]
    for r,c,e,a in errors[:args.max_print]:
        print(f'  MISMATCH [{r}][{c}] expected={e} actual={a}')
    if errors:
        print(f'FAIL {metadata["name"]}: {len(errors)}/{m*n} {args.kind} mismatches')
        return 1
    print(f'PASS {metadata["name"]}: {m}x{n} {args.kind}, 0 mismatches')
    return 0

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, OSError, KeyError, json.JSONDecodeError) as exc:
        print(f'ERROR: {exc}')
        raise SystemExit(2)
