#!/usr/bin/env python3
"""Run Michael's actual RTL in Questa; Python 3.9+, standard library only."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
TEST = ROOT / 'tests/rtl/compute'
SOURCES = [ROOT / p for p in (
    'rtl/compute/raven_mac_pe.sv', 'rtl/compute/raven_mac_array.sv',
    'rtl/compute/raven_gemm_frontend.sv', 'rtl/compute/raven_gemm_core.sv',
    'tests/rtl/compute/sim_read_memory.sv',
    'tests/rtl/compute/tb_raven_mac_pe.sv',
    'tests/rtl/compute/tb_raven_gemm_core.sv')]
ERROR = re.compile(r'\*\*\s+(?:Warning|Error|Fatal)\b|^\s*#?\s*Errors:\s*[1-9]', re.M)
BENIGN_WARNING = re.compile(
    r'^.*\*\*\s+Warning:\s+\(vopt-10587\).*$',
    re.M
)
PROBE = '''`timescale 1ns/1ps
module tb_assertion_probe;
  bit clk=0, sva_mode=0;
  always #5 clk=~clk;
  assert property (@(posedge clk) disable iff (!sva_mode) 1'b0)
    else $fatal(1,"ASSERT_PROBE_SVA_ACTIVE");
  initial begin
    sva_mode=$test$plusargs("SVA");
    if (!sva_mode) begin
      assert (1'b0) else $fatal(1,"ASSERT_PROBE_IMMEDIATE_ACTIVE");
    end
    #20; $display("ASSERTIONS_DISABLED"); $finish;
  end
endmodule
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--questa-bin', type=Path, help='Directory containing vsim/vlog/vlib/vmap; overrides QUESTA_BIN and PATH')
    parser.add_argument('--build', type=Path, default=ROOT / 'build/tests/compute/questa')
    parser.add_argument('--timeout', type=float, default=180, help='Wall-clock seconds per tool invocation')
    parser.add_argument('--demo-only', action='store_true', help='Run assertion guards and the 8x8 demo only')
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error('--timeout must be positive')
    # Resolve the project from this script, independently of the caller's cwd.
    # Simulator location is user configuration, never a checked-in machine path.
    questa_bin = args.questa_bin
    if questa_bin is None and os.environ.get('QUESTA_BIN'):
        questa_bin = Path(os.environ['QUESTA_BIN']).expanduser()
    tools = {}
    for name in ('vsim', 'vlog', 'vlib', 'vmap'):
        candidate = questa_bin / (name + ('.exe' if os.name == 'nt' else '')) if questa_bin else None
        executable = str(candidate.resolve()) if candidate and candidate.is_file() else (None if candidate else shutil.which(name))
        if not executable:
            parser.error(f'{name} not found; add Questa to PATH, set QUESTA_BIN, or use --questa-bin')
        tools[name] = executable
    base = args.build.resolve()
    run = base / datetime.now(timezone.utc).strftime('run_%Y%m%dT%H%M%S_%fZ')
    run.mkdir(parents=True)

    def run_path(path):
        # Windows permits a build directory on another drive; use a dynamically
        # resolved absolute path only when a relative path cannot represent it.
        try:
            return Path(os.path.relpath(path, run)).as_posix()
        except ValueError:
            return Path(path).as_posix()

    def report_command(argv):
        # Tool lookup is local to each machine. Record reusable executable names.
        return [next((name for name, exe in tools.items() if str(arg) == exe),
                     'python' if str(arg) == sys.executable else str(arg)) for arg in argv]

    for name in ('run_batch.do', 'view_demo.do'):
        shutil.copyfile(TEST / name, run / name)
    (run / 'assertion_probe.sv').write_text(PROBE, encoding='utf-8')
    report = {
        'started_utc': datetime.now(timezone.utc).isoformat(),
        'platform': platform.platform(), 'python': sys.version,
        'project_root_from_run': run_path(ROOT),
        'tools': {name: Path(exe).name for name, exe in tools.items()},
        'command_working_directory': 'generated run directory',
        'simulator_selection': 'configured directory' if questa_bin else 'PATH',
        'mode': 'demo' if args.demo_only else 'full',
        'source_sha256': {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in SOURCES + [TEST/'generate_vectors.py', TEST/'run_questa.py', TEST/'run_batch.do', TEST/'view_demo.do']},
        'steps': [], 'status': 'running'}

    def command(label, argv, *, marker=None, expected_failure=False):
        argv = [str(x) for x in argv]
        print(f'RUN {label}', flush=True)
        start = time.monotonic()
        proc = subprocess.Popen(argv, cwd=run, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == 'nt' else 0,
                                start_new_session=os.name != 'nt')
        timed_out = False
        try:
            output, _ = proc.communicate(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            if os.name == 'nt':
                subprocess.run(['taskkill', '/PID', str(proc.pid), '/T', '/F'], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, check=False)
            else:
                os.killpg(proc.pid, signal.SIGKILL)
            output, _ = proc.communicate()
        text = output.decode('utf-8', errors='replace').replace('\r\r\n','\n').replace('\r\n','\n')
        (run / f'{label}.console.log').write_text(text, encoding='utf-8')
        # Native transcripts are separate evidence; never append/read an old run.
        native = run / f'{label}.log'
        combined = text + ('\n' + native.read_text(encoding='utf-8', errors='replace') if native.exists() else '')
        step = {'name': label, 'argv': report_command(argv), 'returncode': proc.returncode,
                'seconds': round(time.monotonic()-start, 3), 'timed_out': timed_out,
                'expected_failure': expected_failure}
        report['steps'].append(step)
        if timed_out:
            raise RuntimeError(f'{label}: wall-clock timeout; see {label}.console.log')
        if expected_failure:
            # Seeing a marker in a printed command is not evidence of execution.
            active = re.search(r'^#\s*\*\* Fatal:.*' + re.escape(marker), combined, re.M)
            if not active or 'ASSERTIONS_DISABLED' in re.sub(r'^.*\$display.*$', '', combined, flags=re.M):
                raise RuntimeError(f'{label}: expected assertion rejection was not observed')
        elif proc.returncode or ERROR.search(BENIGN_WARNING.sub('', combined)) or (marker and marker not in combined):
            raise RuntimeError(f'{label}: tool/RTL/PASS check failed; see {label}.console.log')
        step['status'] = 'pass'
        print(f'PASS {label} ({step["seconds"]} s)', flush=True)
        return combined

    def simulate(label, top, plus=(), generics=(), *, marker=None, rejection=False, waves=False):
        cmd = [tools['vsim'], '-c', '-onfinish', 'exit', '-t', '1ps', '-sva', '-immedassert',
               '-l', f'{label}.log', '-wlf', f'{label}.wlf']
        if waves:
            cmd += ['-voptargs=+acc']
        cmd += list(generics) + ['work.' + top] + list(plus)
        cmd += ['-do', 'set raven_log_waves 1; do run_batch.do' if waves else 'run_batch.do']
        return command(label, cmd, marker=marker, expected_failure=rejection)

    try:
        command('vsim-version', [tools['vsim'], '-version'])
        command('vlog-version', [tools['vlog'], '-version'])
        command('vmap-local', [tools['vmap'], '-c'])
        command('vlib', [tools['vlib'], 'work'])
        command('vmap-work', [tools['vmap'], 'work', 'work'])
        command('compile', [tools['vlog'], '-sv', '-work', 'work', '-l', 'compile.log',
                            *[run_path(p) for p in SOURCES], 'assertion_probe.sv'])
        simulate('guard-immediate', 'tb_assertion_probe', marker='ASSERT_PROBE_IMMEDIATE_ACTIVE', rejection=True)
        simulate('guard-sva', 'tb_assertion_probe', ['+SVA'], marker='ASSERT_PROBE_SVA_ACTIVE', rejection=True)
        dimensions = [(8,8)] if args.demo_only else [(8,8),(4,4),(2,4),(1,1)]
        if not args.demo_only:
            simulate('pe', 'tb_raven_mac_pe', marker='PASS PE: 65536 signed products, bias/bubbles, both overflow directions, in-flight reset')
        for rows, cols in dimensions:
            dims = f'{rows}x{cols}'
            vectors = run / dims / 'vectors'
            command('vectors-'+dims, [sys.executable, run_path(TEST/'generate_vectors.py'), '--rows', rows,
                                      '--cols', cols, '--output', f'{dims}/vectors'])
            manifest = json.loads((vectors/'manifest.json').read_text())
            records = (vectors/'cases.txt').read_text().splitlines()
            if (manifest['rows'],manifest['cols']) != (rows,cols) or len(manifest['cases']) != 42 or len(records) != 42:
                raise RuntimeError('Incorrect fixture geometry/count: '+dims)
            for idx, (case, record) in enumerate(zip(manifest['cases'], records)):
                expected = [idx] + [case[key] for key in ('m','n','k','pitch','ab','bb','pb','error','stalls')]
                if case['id'] != idx or [int(v) for v in record.split()] != expected:
                    raise RuntimeError('Inconsistent fixture manifest: '+dims)
                for filename in ('a.hex','b.hex','param.hex','expected.hex','reference.json'):
                    if not (vectors/f'case_{idx:02d}'/filename).is_file():
                        raise RuntimeError('Missing fixture file: '+filename)
            if not args.demo_only:
                transcript = simulate('core-'+dims, 'tb_raven_gemm_core', [f'+FIXTURES={dims}/vectors'],
                                      [f'-gROWS={rows}',f'-gCOLS={cols}'],
                                      marker=f'PASS CORE {dims}: 42 fixtures and 3 in-flight reset/restart phases')
                # Each marker occurs in stdout and native log, so inspect stdout alone.
                console = (run/f'core-{dims}.console.log').read_text()
                ids = [int(v) for v in re.findall(r'PASS GEMM '+dims+r' case (\d+)\b',console)]
                if ids != list(range(42)):
                    raise RuntimeError('Missing/duplicate fixture PASS records: '+dims)
        if not args.demo_only:
            # Exercise the formerly silent manifest exit using the real core TB.
            for kind, data, fatal in [
                ('empty', '', 'Expected 42 fixtures, completed 0'),
                ('partial', '0 8 8\n', 'Malformed/truncated fixture manifest'),
                ('short', records_for_first(run), 'Expected 42 fixtures, completed 1')]:
                bad = run / ('invalid-manifest-'+kind)
                bad.mkdir()
                if kind == 'short':
                    shutil.copytree(run/'8x8/vectors/case_00',bad/'case_00')
                (bad/'cases.txt').write_text(data)
                simulate('guard-manifest-'+kind, 'tb_raven_gemm_core', ['+FIXTURES='+bad.name],
                         ['-gROWS=8','-gCOLS=8'], marker=fatal, rejection=True)
        simulate('demo', 'tb_raven_gemm_core', ['+FIXTURES=8x8/vectors',
                 '+DEMO_ONLY', '+WAVE=demo.vcd'], ['-gROWS=8','-gCOLS=8'],
                 marker='PASS CORE 8x8: 1 fixtures and 0 in-flight reset/restart phases', waves=True)
        if not (run/'demo.vcd').is_file() or not (run/'demo.wlf').is_file():
            raise RuntimeError('Demo waveform capture missing')
        report['status'] = 'pass'
        report['totals'] = {'signed_pe_products': 0 if args.demo_only else 65536,
                            'regression_fixtures': 0 if args.demo_only else 168,
                            'reset_restart_phases': 0 if args.demo_only else 12,
                            'assertion_guards': 2, 'manifest_rejection_guards': 0 if args.demo_only else 3,
                            'demo_outputs': 64}
    except Exception as exc:
        report['status'] = 'fail'
        report['failure'] = str(exc)
        print('FAIL: '+str(exc), file=sys.stderr, flush=True)
    finally:
        report['finished_utc'] = datetime.now(timezone.utc).isoformat()
        (run/'results.json').write_text(json.dumps(report,indent=2)+'\n', encoding='utf-8')
        (base/'latest.json').write_text(json.dumps({'status':report['status'],'results':(Path(run.name)/'results.json').as_posix()},indent=2)+'\n')
        print('Evidence: '+str(run), flush=True)
    return 0 if report['status'] == 'pass' else 1


def records_for_first(run):
    return (run/'8x8/vectors/cases.txt').read_text().splitlines()[0]+'\n'


if __name__ == '__main__':
    sys.exit(main())
