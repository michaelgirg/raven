#!/usr/bin/env python3
"""Run the one-lane requantization test with Questa; Python 3.9+ stdlib only."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
SOURCES = [ROOT / 'rtl/operators/raven_requantize_clamp.sv',
           ROOT / 'tests/rtl/operators/tb_raven_requantize_clamp.sv']
PASS = 'PASS REQUANT: rounding, clamps, tags, stalls, reset, and consecutive inputs'
ERROR = re.compile(r'\*\*\s+(?:Error|Fatal)\b|^\s*#?\s*Errors:\s*[1-9]', re.M)
PROBE = '''`timescale 1ns/1ps
module tb_operator_assertion_probe;
  bit clk=0, sva_mode=0;
  always #5 clk=~clk;
  assert property (@(posedge clk) disable iff (!sva_mode) 1'b0)
    else $fatal(1,"OPERATOR_SVA_ACTIVE");
  initial begin
    sva_mode=$test$plusargs("SVA");
    if (!sva_mode) begin
      assert (1'b0) else $fatal(1,"OPERATOR_IMMEDIATE_ACTIVE");
    end
    #20; $display("OPERATOR_ASSERTIONS_DISABLED"); $finish;
  end
endmodule
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--questa-bin', type=Path)
    parser.add_argument('--build', type=Path, default=ROOT / 'build/tests/operators/questa')
    parser.add_argument('--timeout', type=float, default=180,
                        help='Wall-clock seconds per tool invocation')
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error('--timeout must be positive')
    base = args.questa_bin
    if base is None and os.environ.get('QUESTA_BIN'):
        base = Path(os.environ['QUESTA_BIN']).expanduser()
    tools = {}
    for name in ('vlib', 'vmap', 'vlog', 'vsim'):
        candidate = base / (name + ('.exe' if os.name == 'nt' else '')) if base else None
        tool = str(candidate.resolve()) if candidate and candidate.is_file() else (None if candidate else shutil.which(name))
        if not tool:
            parser.error(f'{name} not found; add Questa to PATH, set QUESTA_BIN, or use --questa-bin')
        tools[name] = tool
    build = args.build.resolve()
    run = build / datetime.now(timezone.utc).strftime('run_%Y%m%dT%H%M%S_%fZ')
    run.mkdir(parents=True)
    (run / 'assertion_probe.sv').write_text(PROBE, encoding='utf-8')
    (run / 'run_batch.do').write_text(
        'onerror {quit -force -code 1}\nonbreak {quit -force -code 1}\n'
        'run -all\nquit -force -code 1\n', encoding='utf-8')
    report = {'status': 'running', 'source_sha256': {
        p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in SOURCES + [Path(__file__).resolve()]}, 'steps': []}

    def run_path(path):
        try:
            return Path(os.path.relpath(path, run)).as_posix()
        except ValueError:
            return Path(path).as_posix()

    def command(label, argv, *, marker=None, rejection=False):
        argv = [str(a) for a in argv]
        print('RUN ' + label, flush=True)
        proc = subprocess.Popen(argv, cwd=run, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == 'nt' else 0,
                                start_new_session=os.name != 'nt')
        timed_out = False
        try:
            output, _ = proc.communicate(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            if os.name == 'nt':
                subprocess.run(['taskkill', '/PID', str(proc.pid), '/T', '/F'],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            else:
                os.killpg(proc.pid, signal.SIGKILL)
            output, _ = proc.communicate()
        text = output.decode('utf-8', errors='replace').replace('\r\r\n', '\n').replace('\r\n', '\n')
        (run / (label + '.console.log')).write_text(text, encoding='utf-8')
        native = run / (label + '.log')
        combined = text + ('\n' + native.read_text(encoding='utf-8', errors='replace') if native.exists() else '')
        step = {'name': label, 'returncode': proc.returncode, 'timed_out': timed_out,
                'expected_failure': rejection}
        report['steps'].append(step)
        if timed_out:
            raise RuntimeError(label + ': wall-clock timeout')
        if rejection:
            if not re.search(r'^#\s*\*\* Fatal:.*' + re.escape(marker), combined, re.M):
                raise RuntimeError(label + ': expected assertion did not execute')
        elif proc.returncode or ERROR.search(combined):
            raise RuntimeError(label + ': tool or RTL error')
        elif marker and not re.search(r'^#\s*' + re.escape(marker) + r'\s*$', combined, re.M):
            raise RuntimeError(label + ': completion marker missing')
        step['status'] = 'pass'
        print('PASS ' + label, flush=True)

    def simulate(label, top, marker, rejection=False, plus=()):
        command(label, [tools['vsim'], '-c', '-onfinish', 'exit', '-sva', '-immedassert',
                        '-l', label + '.log', '-wlf', label + '.wlf', 'work.' + top,
                        *plus, '-do', 'run_batch.do'], marker=marker, rejection=rejection)

    try:
        command('vmap-local', [tools['vmap'], '-c'])
        command('vlib', [tools['vlib'], 'work'])
        command('vmap-work', [tools['vmap'], 'work', 'work'])
        command('compile', [tools['vlog'], '-sv', '-work', 'work', '-l', 'compile.log',
                            *[run_path(p) for p in SOURCES], 'assertion_probe.sv'])
        simulate('guard-immediate', 'tb_operator_assertion_probe',
                 'OPERATOR_IMMEDIATE_ACTIVE', rejection=True)
        simulate('guard-sva', 'tb_operator_assertion_probe',
                 'OPERATOR_SVA_ACTIVE', rejection=True, plus=('+SVA',))
        simulate('requant', 'tb_raven_requantize_clamp', PASS)
        report['status'] = 'pass'
        print('PASS operator Questa test', flush=True)
    except (OSError, RuntimeError) as exc:
        report['status'] = 'fail'
        report['failure'] = str(exc)
        print('FAIL: ' + str(exc), file=sys.stderr, flush=True)
    finally:
        (run / 'results.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        (build / 'latest.json').write_text(json.dumps({
            'status': report['status'], 'results': (Path(run.name) / 'results.json').as_posix()
        }, indent=2) + '\n', encoding='utf-8')
        print('Evidence: ' + str(run), flush=True)
    return 0 if report['status'] == 'pass' else 1

if __name__ == '__main__':
    sys.exit(main())
