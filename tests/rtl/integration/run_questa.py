#!/usr/bin/env python3
"""Run the control/integration pre-alpha testbench in Questa; Python 3.9+, standard library only.

Steps: assertion guards, compile (compute + control + operators + top + integration TB),
export fixtures, simulate tb_raven_npu_top, scan the transcript, then check every dumped
INT8 result with tools/goldens/compare_prealpha.py. The report goes to
build/tests/integration/questa/run_*/results.json and latest.json.

--no-sva-guard is for simulators that cannot run concurrent assertions (for example
ModelSim Intel FPGA Edition). Such a run is recorded as "sva_checked": false and is not
acceptance evidence.
"""
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
TEST = ROOT / 'tests/rtl/integration'
SOURCES = [ROOT / p for p in (
    'rtl/control/raven_ctrl_pkg.sv', 'rtl/control/raven_ctrl_regs.sv', 'rtl/control/raven_ctrl.sv',
    'rtl/compute/raven_mac_pe.sv', 'rtl/compute/raven_mac_array.sv',
    'rtl/compute/raven_gemm_frontend.sv', 'rtl/compute/raven_gemm_core.sv',
    'rtl/operators/raven_requantize_clamp.sv',
    'rtl/top/raven_requant.sv', 'rtl/top/raven_result_writer.sv', 'rtl/top/raven_npu_top.sv',
    'tests/rtl/compute/sim_read_memory.sv',
    'tests/rtl/integration/sim_write_memory.sv',
    'tests/rtl/integration/raven_tb_driver_pkg.sv',
    'tests/rtl/integration/tb_raven_npu_top.sv')]
SCRIPTS = [TEST / 'export_fixtures.py', TEST / 'run_questa.py', TEST / 'run_batch.do',
           ROOT / 'tools/goldens/compare_prealpha.py']
VECTORS = ROOT / 'tests/vectors/prealpha'
# Tests the testbench must report, each by at least one "PASS ..." line.
TESTS = [f'T{i}' for i in range(1, 16)]
ERROR = re.compile(r'\*\*\s+(?:Warning|Error|Fatal)\b|^\s*#?\s*Errors:\s*[1-9]', re.M)
BENIGN_WARNING = re.compile(r'^.*\*\*\s+Warning:\s+\(vopt-10587\).*$', re.M)
# ModelSim-only: SVA is parsed but not simulated. Allowed only with --no-sva-guard.
NO_SVA_WARNING = re.compile(r'^.*\*\*\s+Warning:.*\((?:vlog-2186|vsim-8311)\).*$', re.M)
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


def find_tools(parser, questa_bin):
    tools = {}
    for name in ('vsim', 'vlog', 'vlib', 'vmap'):
        candidate = questa_bin / (name + ('.exe' if os.name == 'nt' else '')) if questa_bin else None
        executable = (str(candidate.resolve()) if candidate and candidate.is_file()
                      else (None if candidate else shutil.which(name)))
        if not executable:
            parser.error(f'{name} not found; add Questa to PATH, set QUESTA_BIN, or use --questa-bin')
        tools[name] = executable
    return tools


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--questa-bin', type=Path,
                        help='Directory containing vsim/vlog/vlib/vmap; overrides QUESTA_BIN and PATH')
    parser.add_argument('--build', type=Path, default=ROOT / 'build/tests/integration/questa')
    parser.add_argument('--timeout', type=float, default=600, help='Wall-clock seconds per tool invocation')
    parser.add_argument('--tests', default='', help='Comma-separated subset, e.g. T1,T4 (default: all)')
    parser.add_argument('--no-sva-guard', action='store_true',
                        help='Skip the concurrent-assertion guard (simulators without SVA); not acceptance evidence')
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error('--timeout must be positive')
    wanted = [t for t in args.tests.split(',') if t] or TESTS
    if any(t not in TESTS for t in wanted):
        parser.error('--tests takes names from T1..T15')
    questa_bin = args.questa_bin
    if questa_bin is None and os.environ.get('QUESTA_BIN'):
        questa_bin = Path(os.environ['QUESTA_BIN']).expanduser()
    tools = find_tools(parser, questa_bin)

    base = args.build.resolve()
    run = base / datetime.now(timezone.utc).strftime('run_%Y%m%dT%H%M%S_%fZ')
    run.mkdir(parents=True)

    def run_path(path):
        try:
            return Path(os.path.relpath(path, run)).as_posix()
        except ValueError:
            return Path(path).as_posix()

    def report_command(argv):
        return [next((name for name, exe in tools.items() if str(arg) == exe),
                     'python' if str(arg) == sys.executable else str(arg)) for arg in argv]

    shutil.copyfile(TEST / 'run_batch.do', run / 'run_batch.do')
    (run / 'assertion_probe.sv').write_text(PROBE, encoding='utf-8')
    report = {
        'started_utc': datetime.now(timezone.utc).isoformat(),
        'platform': platform.platform(), 'python': sys.version,
        'tools': {name: Path(exe).name for name, exe in tools.items()},
        'simulator_selection': 'configured directory' if questa_bin else 'PATH',
        'sva_checked': not args.no_sva_guard,
        'tests_requested': wanted,
        'source_sha256': {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in SOURCES + SCRIPTS},
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
                subprocess.run(['taskkill', '/PID', str(proc.pid), '/T', '/F'],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            else:
                os.killpg(proc.pid, signal.SIGKILL)
            output, _ = proc.communicate()
        text = output.decode('utf-8', errors='replace').replace('\r\r\n', '\n').replace('\r\n', '\n')
        (run / f'{label}.console.log').write_text(text, encoding='utf-8')
        native = run / f'{label}.log'
        combined = text + ('\n' + native.read_text(encoding='utf-8', errors='replace') if native.exists() else '')
        step = {'name': label, 'argv': report_command(argv), 'returncode': proc.returncode,
                'seconds': round(time.monotonic() - start, 3), 'timed_out': timed_out,
                'expected_failure': expected_failure}
        report['steps'].append(step)
        if timed_out:
            raise RuntimeError(f'{label}: wall-clock timeout; see {label}.console.log')
        scanned = BENIGN_WARNING.sub('', combined)
        if args.no_sva_guard:
            scanned = NO_SVA_WARNING.sub('', scanned)
        if expected_failure:
            active = re.search(r'^#\s*\*\* Fatal:.*' + re.escape(marker), combined, re.M)
            if not active or 'ASSERTIONS_DISABLED' in re.sub(r'^.*\$display.*$', '', combined, flags=re.M):
                raise RuntimeError(f'{label}: expected assertion rejection was not observed')
        elif proc.returncode or ERROR.search(scanned) or (marker and marker not in combined):
            raise RuntimeError(f'{label}: tool/RTL/PASS check failed; see {label}.console.log')
        step['status'] = 'pass'
        print(f'PASS {label} ({step["seconds"]} s)', flush=True)
        return text

    def simulate(label, top, plus=(), *, marker=None, rejection=False, generics=()):
        cmd = [tools['vsim'], '-c', '-onfinish', 'exit', '-t', '1ps']
        if not args.no_sva_guard:
            cmd += ['-sva', '-immedassert']
        cmd += ['-l', f'{label}.log', '-wlf', f'{label}.wlf', *generics,
                'work.' + top, *plus, '-do', 'run_batch.do']
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
        if not args.no_sva_guard:
            simulate('guard-sva', 'tb_assertion_probe', ['+SVA'], marker='ASSERT_PROBE_SVA_ACTIVE', rejection=True)

        command('fixtures', [sys.executable, run_path(TEST / 'export_fixtures.py'),
                             '--vectors', run_path(VECTORS), '--output', 'fixtures'])
        cases = [line.split() for line in (run / 'fixtures/cases.txt').read_text().splitlines()]
        (run / 'out').mkdir()
        transcript = simulate('integration', 'tb_raven_npu_top',
                              ['+FIXTURES=fixtures', '+OUT=out', '+TESTS=' + ','.join(wanted)],
                              marker='ALL TESTS PASSED')

        # Every requested test and every fixture case of those tests must report PASS.
        passes = re.findall(r'^#\s*PASS (\S+)', transcript, re.M)
        tests_seen = sorted(set(re.findall(r'^#\s*TEST (T\d+) PASS', transcript, re.M)),
                            key=lambda t: int(t[1:]))
        missing_tests = [t for t in wanted if t not in tests_seen]
        missing_cases = [name for name, test in cases if test in wanted and name not in passes]
        if missing_tests or missing_cases:
            raise RuntimeError(f'Missing PASS records: tests {missing_tests}, cases {missing_cases}')
        summary = re.search(r'SUMMARY: (\d+) passed, (\d+) failed, (\d+) checks', transcript)
        if not summary or int(summary.group(2)) != 0:
            raise RuntimeError('Testbench summary missing or reports failures')

        # Independent INT8 check of every dumped result against Jackie's goldens.
        # dumps.txt lists "<tag> <fixture>"; golden.txt names the vectors case to compare with.
        dumps_file = run / 'out/dumps.txt'
        # A fixture rerun later (T13, T14) rewrites its dump, so keep one entry per tag.
        dumps = dict(line.split() for line in dumps_file.read_text().splitlines()) if dumps_file.exists() else {}
        files = sorted(p.stem[len('actual_int8_'):] for p in (run / 'out').glob('actual_int8_*.bin'))
        if sorted(dumps) != files:
            raise RuntimeError('dumps.txt does not match the actual_int8_*.bin files')
        compared = []
        for tag, fixture in sorted(dumps.items()):
            golden = (run / 'fixtures' / fixture / 'golden.txt').read_text().strip()
            command('compare-' + tag, [sys.executable, run_path(ROOT / 'tools/goldens/compare_prealpha.py'),
                                       '--case', run_path(VECTORS / golden), '--kind', 'int8',
                                       '--actual', f'out/actual_int8_{tag}.bin'], marker='0 mismatches')
            compared.append(tag)
        if not compared and any(t in wanted for t in ('T4', 'T5', 'T6', 'T7', 'T8')):
            raise RuntimeError('No INT8 results were dumped')

        configuration_checks = {}
        if set(wanted) == set(TESTS):
            (run / 'out-cols1').mkdir()
            config_text = simulate('single-column', 'tb_raven_npu_top',
                                   ['+FIXTURES=fixtures', '+OUT=out-cols1', '+TESTS=T1,T3'],
                                   generics=['-gCOLS=1'], marker='ALL TESTS PASSED')
            config_summary = re.search(r'SUMMARY: (\d+) passed, (\d+) failed, (\d+) checks', config_text)
            if (not config_summary or int(config_summary.group(2)) != 0
                    or any(not re.search(r'^#\s*TEST ' + test + r' PASS\s*$', config_text, re.M)
                           for test in ('T1', 'T3'))):
                raise RuntimeError('Single-column reset/NOP checks did not complete')
            configuration_checks['COLS=1'] = {
                'tests': ['T1', 'T3'], 'pass_records': int(config_summary.group(1)),
                'checks': int(config_summary.group(3))}

        report['status'] = 'pass'
        report['configuration_checks'] = configuration_checks
        report['totals'] = {'tests': tests_seen, 'pass_records': len(passes),
                            'checks': int(summary.group(3)), 'int8_comparisons': compared}
        for name in ('vsim-version', 'vlog-version'):
            report[name.replace('-', '_')] = (run / f'{name}.console.log').read_text().strip()
    except Exception as exc:
        report['status'] = 'fail'
        report['failure'] = str(exc)
        print('FAIL: ' + str(exc), file=sys.stderr, flush=True)
    finally:
        report['finished_utc'] = datetime.now(timezone.utc).isoformat()
        (run / 'results.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        (base / 'latest.json').write_text(json.dumps(
            {'status': report['status'], 'sva_checked': report['sva_checked'],
             'results': (Path(run.name) / 'results.json').as_posix()}, indent=2) + '\n')
        print('Evidence: ' + str(run), flush=True)
    return 0 if report['status'] == 'pass' else 1


if __name__ == '__main__':
    sys.exit(main())
