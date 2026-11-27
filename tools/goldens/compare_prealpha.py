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
import hashlib
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
    p.add_argument('--max-print', type=int, default=None)
    p.add_argument('--log', type=Path, help='Save comparison output to this file')
    args = p.parse_args()
    if args.max_print is not None and args.max_print < 0:
        p.error('--max-print must be nonnegative')
    lines = []
    def report(message):
        lines.append(message)
        print(message)

    def finish(status):
        if args.log:
            args.log.parent.mkdir(parents=True, exist_ok=True)
            args.log.write_text('\n'.join(lines) + '\n', encoding='utf-8')
        return status

    try:
        metadata = json.loads((args.case / 'reference.json').read_text())
        if 'expected_error_code' in metadata:
            report('ERROR: This is an invalid-command case; check the RTL error code instead')
            return finish(2)
        m, n = metadata['M'], metadata['N']
        golden_bytes = (args.case / f'expected_{args.kind}.bin').read_bytes()
        actual_bytes = args.actual.read_bytes()
        golden = values(golden_bytes, args.kind)
        actual = values(actual_bytes, args.kind)
    except (ValueError, OSError, KeyError, struct.error, json.JSONDecodeError) as exc:
        report(f'ERROR: {exc}')
        return finish(2)
    report(f'case={metadata["name"]} kind={args.kind} shape={m}x{n}')
    report(f'golden_sha256={hashlib.sha256(golden_bytes).hexdigest()}')
    report(f'actual_sha256={hashlib.sha256(actual_bytes).hexdigest()}')
    if len(golden) != m * n:
        report(f'FAIL: golden has {len(golden)} values; expected {m*n}')
        return finish(1)
    if len(actual) != len(golden):
        report(f'FAIL {metadata["name"]} {args.kind}: expected {len(golden)} '
              f'values, got {len(actual)}')
        return finish(1)
    errors = [(idx, e, a) for idx, (e,a) in
              enumerate(zip(golden, actual)) if e != a]
    for idx, e, a in errors[:args.max_print]:
        offset = idx * (1 if args.kind == 'int8' else 4)
        report(f'  MISMATCH byte_offset=0x{offset:04x} [{idx//n}][{idx%n}] expected={e} actual={a}')
    if errors:
        report(f'FAIL {metadata["name"]}: {len(errors)}/{m*n} {args.kind} mismatches')
        return finish(1)
    report(f'PASS {metadata["name"]}: {m*n}/{m*n} {args.kind} values match, 0 mismatches')
    return finish(0)

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, OSError, KeyError, json.JSONDecodeError) as exc:
        print(f'ERROR: {exc}')
        raise SystemExit(2)
