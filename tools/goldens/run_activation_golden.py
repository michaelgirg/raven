#!/usr/bin/env python3
"""Test activationBuffer with the independently generated RAVEN A matrix.

Run at the repository root:
  python tools/goldens/run_activation_golden.py --case normal_8x16x8
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def run(cmd, cwd, label):
    print(f"RUN {label}", flush=True)
    result = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, errors="replace")
    (cwd / f"{label}.console.log").write_text(result.stdout, encoding="utf-8")
    if result.returncode:
        print(result.stdout[-5000:])
        raise RuntimeError(f"{label} failed (exit {result.returncode}); log: {cwd / (label + '.console.log')}")
    print(f"PASS {label}", flush=True)
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', default='normal_8x16x8')
    args = parser.parse_args()
    fixture = ROOT / 'tests' / 'vectors' / 'prealpha' / args.case
    info_path = fixture / 'reference.json'
    ahex = fixture / 'a.hex'
    abin = fixture / 'a.bin'
    if not all(p.is_file() for p in (info_path, ahex, abin)):
        parser.error(f"Missing fixture files in {fixture}")
    info = json.loads(info_path.read_text(encoding='utf-8'))
    m, k, pitch = info.get('M'), info.get('K'), info.get('A_pitch_bytes')
    if not (isinstance(m, int) and isinstance(k, int) and
            1 <= m <= 8 and 1 <= k <= 16 and pitch == 16):
        parser.error('Activation buffer supports M<=8, K<=16, and 16 bytes per stored row')
    data = abin.read_bytes()
    lines = ahex.read_text(encoding='utf-8').splitlines()
    if len(data) != m * 16 or len(lines) != m or any(
        line.lower() != f"{int.from_bytes(data[i*16:(i+1)*16], 'little'):032x}"
        for i, line in enumerate(lines)
    ):
        parser.error('a.hex and a.bin do not match the expected row-stride layout')

    workdir = ROOT / 'build' / 'tests' / 'memory' / 'golden' / args.case
    workdir.mkdir(parents=True, exist_ok=True)
    # The RTL has 8 physical banks and 16 positions per bank.
    # Keep the fixture's K-padding bytes, and fill unused rows with a
    # recognizable sentinel to verify full physical readback.
    physical = data + bytes([0xA5]) * ((8 - m) * 16)
    packed_hex = workdir / 'activation_padded.hex'
    packed_hex.write_text(''.join(
        f"{int.from_bytes(physical[i*16:(i+1)*16], 'little'):032x}\n"
        for i in range(8)
    ), encoding='utf-8')
    valid_count = m * k
    print(f"Prepared {m}x{k} activations: {valid_count} valid values, "
          f"{128-valid_count} padding bytes (8x16 physical buffer)", flush=True)
    rtl = ROOT / 'rtl' / 'memory' / 'activation_buffer.sv'
    tb = ROOT / 'tests' / 'rtl' / 'memory' / 'tb_activation_buffer_golden.sv'
    if not rtl.is_file() or not tb.is_file():
        parser.error('RTL or testbench file not found in the repository')

    try:
        run(['vlib', 'work'], workdir, 'vlib')
        run(['vlog', '-sv', str(rtl), str(tb)], workdir, 'compile')
        output = run([
            'vsim', '-c', '-onfinish', 'exit', '-t', '1ps',
            '-l', 'activation-golden.log', 'work.tb_activation_buffer_golden',
            '+AHEX=' + packed_hex.as_posix(), '+CASE=' + args.case,
            '+VALID_M=' + str(m), '+VALID_K=' + str(k),
            '-do', 'run -all; quit -f'
        ], workdir, 'activation-golden')
    except FileNotFoundError as exc:
        print(f"ERROR: Cannot locate {exc.filename}; ensure QuestaSim tools are in PATH")
        return 1
    except RuntimeError as exc:
        print('FAIL:', exc)
        return 1

    marker = f"PASS ACTIVATION GOLDEN: 128/128 INT8 values matched ({args.case})"
    if marker not in output or re.search(r'\*\*\s+(?:Error|Fatal)\b', output) or re.search(r'Errors:\s*[1-9]', output):
        print('FAIL: simulation did not print the expected PASS marker or reported an error')
        print(output[-5000:])
        return 1
    print(marker + f'; {valid_count}/{valid_count} valid values; output stalls verified')
    print('Evidence:', workdir / 'activation-golden.console.log')
    return 0


if __name__ == '__main__':
    sys.exit(main())
