#!/usr/bin/env python3
"""Verify Taylor's weightBuffer against RAVEN's Python-generated B matrices.

Run from the RAVEN repo root:
  python tools/goldens/run_weight_golden.py --case normal_8x16x8
  python tools/goldens/run_weight_golden.py --case signed_nonzero_zp_stalled
  python tools/goldens/run_weight_golden.py --case partial_tile_7x13x5
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def run(command, cwd, label):
    print(f"RUN {label}", flush=True)
    proc = subprocess.run(
        command, cwd=cwd, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, text=True, errors='replace'
    )
    (cwd / f"{label}.console.log").write_text(proc.stdout, encoding='utf-8')
    if proc.returncode:
        print(proc.stdout[-5000:])
        raise RuntimeError(f"{label} failed (exit {proc.returncode}); see {cwd / (label+'.console.log')}")
    print(f"PASS {label}", flush=True)
    return proc.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', default='normal_8x16x8')
    args = parser.parse_args()
    if '/' in args.case or '\\' in args.case or args.case in ('.', '..'):
        parser.error('Provide a case folder name, not a path')
    fixture = ROOT / 'tests' / 'vectors' / 'prealpha' / args.case
    p_json, p_bin, p_hex = (fixture / n for n in ('reference.json', 'b.bin', 'b.hex'))
    if not all(p.is_file() for p in (p_json, p_bin, p_hex)):
        parser.error(f"Missing fixture files in {fixture}")

    info = json.loads(p_json.read_text(encoding='utf-8'))
    k, n = info.get('K'), info.get('N')
    if (not isinstance(k, int) or not isinstance(n, int) or
            not 1 <= k <= 16 or not 1 <= n <= 8 or info.get('B_physical_cols') != 8):
        parser.error('weightBuffer supports 1<=K<=16, 1<=N<=8, eight physical columns')

    b = p_bin.read_bytes()
    expected_stored_bytes = ((k + 1) // 2) * 16  # generator pads paired K rows to 16-byte beats
    if len(b) != expected_stored_bytes:
        parser.error(f"Expected {expected_stored_bytes} weight bytes, got {len(b)}")

    # The original B hex stores two 8-byte K rows per 128-bit line, little-endian.
    golden_hex_lines = p_hex.read_text(encoding='utf-8').splitlines()
    expected_hex = [
        f"{int.from_bytes(b[i:i+16], 'little'):032x}"
        for i in range(0, len(b), 16)
    ]
    if [line.strip().lower() for line in golden_hex_lines] != expected_hex:
        parser.error('b.hex does not agree with b.bin (128-bit paired-row layout)')

    # Check that the valid KxN elements match the independent JSON reference.
    golden = info.get('B')
    if not isinstance(golden, list) or len(golden) != k or any(len(row) != n for row in golden):
        parser.error('Invalid B matrix shape in reference.json')
    for row in range(k):
        for channel in range(n):
            if b[8*row + channel] != golden[row][channel] & 0xFF:
                parser.error(f"Inconsistent B at k={row}, channel={channel}")

    # Convert bytes to 16 x 64-bit weight banks, filling any unused physical K rows
    # with a sentinel. Keep the generator's existing padding bytes unchanged.
    physical = b + bytes([0xA5]) * (128 - len(b))
    workdir = ROOT / 'build' / 'tests' / 'memory' / 'golden_weight' / args.case
    workdir.mkdir(parents=True, exist_ok=True)
    weight_hex = workdir / 'weight_banks.hex'
    weight_hex.write_text(''.join(
        f"{int.from_bytes(physical[i*8:(i+1)*8], 'little'):016x}\n"
        for i in range(16)
    ), encoding='utf-8')

    valid = k * n
    print(f"Prepared K={k}, N={n} weights: {valid} valid values, "
          f"{128-valid} padding positions (16x8 physical buffer)", flush=True)

    rtl = ROOT / 'rtl' / 'memory' / 'weight_buffer.sv'
    tb = ROOT / 'tests' / 'rtl' / 'memory' / 'tb_weight_buffer_golden.sv'
    if not rtl.is_file() or not tb.is_file():
        parser.error('Weight buffer RTL or golden testbench not found')

    try:
        run(['vlib', 'work'], workdir, 'vlib')
        run(['vlog', '-sv', str(rtl), str(tb)], workdir, 'compile')
        output = run([
            'vsim', '-c', '-onfinish', 'exit', '-t', '1ps', '-l', 'weight-golden.log',
            'work.tb_weight_buffer_golden',
            '+BHEX=' + weight_hex.as_posix(), '+CASE=' + args.case,
            '+VALID_K=' + str(k), '+VALID_N=' + str(n),
            '-do', 'run -all; quit -f'
        ], workdir, 'weight-golden')
    except FileNotFoundError as exc:
        print(f"ERROR: Could not find {exc.filename}; check your QuestaSim PATH")
        return 1
    except RuntimeError as exc:
        print('FAIL:', exc)
        return 1

    marker = f"PASS WEIGHT GOLDEN: 128/128 INT8 values matched ({args.case})"
    if (marker not in output or
        re.search(r'\*\*\s+(?:Error|Fatal)\b', output) or
        re.search(r'Errors:\s*[1-9]', output)):
        print('FAIL: missing PASS marker or simulator reported an error')
        print(output[-5000:])
        return 1
    print(marker + f'; {valid}/{valid} valid values; output stalls verified')
    print('Evidence:', workdir / 'weight-golden.console.log')
    return 0


if __name__ == '__main__':
    sys.exit(main())
