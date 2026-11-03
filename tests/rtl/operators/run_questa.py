#!/usr/bin/env python3
"""Run the one-lane requantization test with Questa."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
SOURCES = [ROOT / 'rtl/operators/raven_requantize_clamp.sv',
           ROOT / 'tests/rtl/operators/tb_raven_requantize_clamp.sv']

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--questa-bin', type=Path)
    parser.add_argument('--build', type=Path, default=ROOT / 'build/tests/operators/questa')
    args = parser.parse_args()
    base = args.questa_bin or (Path(os.environ['QUESTA_BIN']) if 'QUESTA_BIN' in os.environ else None)
    tools = {}
    for name in ('vlib', 'vmap', 'vlog', 'vsim'):
        candidate = base / (name + ('.exe' if os.name == 'nt' else '')) if base else None
        tool = str(candidate) if candidate and candidate.is_file() else shutil.which(name)
        if not tool:
            parser.error(f'{name} not found; add Questa to PATH, set QUESTA_BIN, or use --questa-bin')
        tools[name] = tool
    build = args.build
    build.mkdir(parents=True, exist_ok=True)
    def run(command):
        print('RUN', ' '.join(map(str, command)), flush=True)
        subprocess.run(command, cwd=build, check=True)
    run([tools['vlib'], 'work'])
    run([tools['vmap'], 'work', 'work'])
    run([tools['vlog'], '-sv', '-work', 'work', *map(str, SOURCES)])
    run([tools['vsim'], '-c', '-onfinish', 'exit', '-sva', '-immedassert',
         'work.tb_raven_requantize_clamp', '-do', 'run -all; quit -f'])
    print('PASS operator Questa test')

if __name__ == '__main__':
    sys.exit(main())
