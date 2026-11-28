#!/usr/bin/env python3
"""Run the board-prototype AXI bridge testbench in Questa; Python 3.9+, standard library only.

Steps: assertion guards, compile (NPU RTL + board RTL + bridge TB), simulate
tb_raven_axil_bridge with the default OUT0 latency, again with zero latency and a
different seed, and once against raven_board_top_v in PATTERN mode with the board's
default latency; then W13, tb_raven_board_top against raven_board_top_v in MEMORY mode
with the hw/fixtures BRAM images (checked against a fresh export_fixtures.py run), with
every OUT0 dump checked by tools/goldens/compare_prealpha.py; scan each transcript, then
compile the board RTL with SYNTHESIS defined.
The report goes to build/tests/board/questa/run_*/results.json and latest.json.

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

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from questa_log import has_unexpected_diagnostics

ROOT = Path(__file__).resolve().parents[3]
TEST = ROOT / 'tests/rtl/board'
BOARD_RTL = [ROOT / p for p in ('rtl/memory/raven_bram_bank.sv', 'rtl/memory/raven_memory_banks.sv',
                                 'rtl/board/raven_axil_bridge.sv', 'rtl/board/raven_out0_pattern.sv',
                                 'rtl/board/raven_board_top.sv', 'rtl/board/raven_board_top_v.v')]
SOURCES = [ROOT / p for p in (
    'rtl/control/raven_ctrl_pkg.sv', 'rtl/control/raven_ctrl_regs.sv', 'rtl/control/raven_ctrl.sv',
    'rtl/compute/raven_mac_pe.sv', 'rtl/compute/raven_mac_array.sv',
    'rtl/compute/raven_gemm_frontend.sv', 'rtl/compute/raven_gemm_core.sv',
    'rtl/operators/raven_requantize_clamp.sv',
    'rtl/memory/activation_buffer.sv', 'rtl/memory/weight_buffer.sv',
    'rtl/memory/parameter_buffer.sv', 'rtl/memory/output_buffer.sv',
    'rtl/memory/raven_integrity_pkg.sv',
    'rtl/memory/raven_read_buffer_adapter.sv', 'rtl/memory/raven_output_buffer_adapter.sv',
    'rtl/top/raven_requant.sv', 'rtl/top/raven_result_writer.sv', 'rtl/top/raven_npu_top.sv')] + BOARD_RTL + [
    ROOT / p for p in (
    'tests/rtl/compute/sim_read_memory.sv',
    'tests/rtl/integration/sim_write_memory.sv',
    'tests/rtl/board/axil_master_pkg.sv',
    'tests/rtl/board/tb_raven_axil_bridge.sv',
    'tests/rtl/board/tb_raven_board_top.sv')]
SCRIPTS = [ROOT / 'tests/rtl/questa_log.py', TEST / 'run_questa.py', TEST / 'run_batch.do',
           ROOT / 'tests/rtl/integration/export_fixtures.py', ROOT / 'tools/goldens/compare_prealpha.py']
# W13: the fixture preloaded into the MEMORY build, and the ACT1/WGT1 variant of its command.
FIXTURE = 'normal_8x16x8'
FIXTURE_DIR = ROOT / 'hw/fixtures' / FIXTURE
FIXTURE_IMAGES = ('act.hex', 'wgt.hex', 'prm.hex')
FIXTURE_ALT = 't7_normal_act1_wgt1'
# Tests the testbench must report, each by a "TEST Wn PASS" line.
BRIDGE_TESTS = [f'W{i}' for i in range(1, 13)]
TESTS = BRIDGE_TESTS + ['W13']
# Simulation configurations: (label, OUT0 latency, seed, test the board wrapper).
CONFIGS = [('bridge', 4, 1, 0), ('bridge-latency0', 0, 2, 0), ('board-top', 1, 3, 1)]
SUMMARY = re.compile(r'SUMMARY: (\d+) passed, (\d+) failed, (\d+) checks, (\d+) writes, (\d+) reads')
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
        if candidate and not candidate.is_file() and candidate.with_suffix('.exe').is_file():
            candidate = candidate.with_suffix('.exe')  # Windows tools driven from WSL.
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
    parser.add_argument('--build', type=Path, default=ROOT / 'build/tests/board/questa')
    parser.add_argument('--timeout', type=float, default=600, help='Wall-clock seconds per tool invocation')
    parser.add_argument('--tests', default='', help='Comma-separated subset, e.g. W1,W4 (default: all)')
    parser.add_argument('--no-sva-guard', action='store_true',
                        help='Skip the concurrent-assertion guard (simulators without SVA); not acceptance evidence')
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error('--timeout must be positive')
    wanted = [t for t in args.tests.split(',') if t] or TESTS
    if any(t not in TESTS for t in wanted):
        parser.error('--tests takes names from W1..W13')
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
        if expected_failure:
            active = re.search(r'^#\s*\*\* Fatal:.*' + re.escape(marker), combined, re.M)
            if not active or 'ASSERTIONS_DISABLED' in re.sub(r'^.*\$display.*$', '', combined, flags=re.M):
                raise RuntimeError(f'{label}: expected failure signature was not observed')
        elif (proc.returncode
              or has_unexpected_diagnostics(combined, allow_no_sva=args.no_sva_guard)
              or (marker and marker not in combined)):
            raise RuntimeError(f'{label}: tool/RTL/PASS check failed; see {label}.console.log')
        step['status'] = 'pass'
        print(f'PASS {label} ({step["seconds"]} s)', flush=True)
        return combined

    def simulate(label, top, plus=(), *, marker=None, rejection=False, generics=(), library='work'):
        cmd = [tools['vsim'], '-c', '-onfinish', 'exit', '-t', '1ps', '-voptargs=+acc']
        if not args.no_sva_guard:
            cmd += ['-sva', '-immedassert']
        cmd += ['-l', f'{label}.log', '-wlf', f'{label}.wlf', *generics,
                library + '.' + top, *plus, '-do', 'run_batch.do']
        return command(label, cmd, marker=marker, expected_failure=rejection)

    try:
        command('vsim-version', [tools['vsim'], '-version'])
        command('vlog-version', [tools['vlog'], '-version'])
        command('vlib', [tools['vlib'], 'work'])
        command('compile', [tools['vlog'], '-sv', '-timescale', '1ns/1ps', '-work', 'work', '-l', 'compile.log',
                            *[run_path(p) for p in SOURCES], 'assertion_probe.sv'])
        simulate('guard-immediate', 'tb_assertion_probe', marker='ASSERT_PROBE_IMMEDIATE_ACTIVE', rejection=True)
        if not args.no_sva_guard:
            simulate('guard-sva', 'tb_assertion_probe', ['+SVA'], marker='ASSERT_PROBE_SVA_ACTIVE', rejection=True)

        configurations = {}
        bridge_wanted = [t for t in wanted if t in BRIDGE_TESTS]
        for label, latency, seed, board_top in (CONFIGS if bridge_wanted else ()):
            transcript = simulate(label, 'tb_raven_axil_bridge',
                                  ['+TESTS=' + ','.join(bridge_wanted), f'+SEED={seed}'],
                                  generics=[f'-gOUT0_LATENCY={latency}', f'-gBOARD_TOP={board_top}'],
                                  marker='ALL TESTS PASSED')
            seen = set(re.findall(r'^#\s*TEST (W\d+) PASS\s*$', transcript, re.M))
            missing = [t for t in bridge_wanted if t not in seen]
            summary = SUMMARY.search(transcript)
            if missing or not summary or int(summary.group(2)) != 0:
                raise RuntimeError(f'{label}: missing PASS records {missing} or bad summary')
            configurations[label] = {
                'out0_latency': latency, 'seed': seed, 'board_top': bool(board_top),
                'tests': sorted(seen, key=lambda t: int(t[1:])),
                'pass_records': int(summary.group(1)), 'checks': int(summary.group(3)),
                'axi_writes': int(summary.group(4)), 'axi_reads': int(summary.group(5))}
        report['configurations'] = configurations

        if 'W13' in wanted:
            # The committed board fixture must match what export_fixtures.py writes today.
            command('export-fixtures', [sys.executable, ROOT / 'tests/rtl/integration/export_fixtures.py',
                                        '--vectors', ROOT / 'tests/vectors/prealpha', '--output', run / 'fixtures'])
            fresh = run / 'fixtures' / FIXTURE
            for f in sorted(p.name for p in FIXTURE_DIR.iterdir()):
                if (FIXTURE_DIR / f).read_bytes() != (fresh / f).read_bytes():
                    raise RuntimeError(f'hw/fixtures/{FIXTURE}/{f} is stale; regenerate it with export_fixtures.py')
            # raven_board_top_v loads the images by bare name, as in the Vivado project.
            for f in FIXTURE_IMAGES:
                shutil.copyfile(FIXTURE_DIR / f, run / f)
            (run / 'out-w13').mkdir()
            transcript = simulate('board-memory', 'tb_raven_board_top',
                                  [f'+FIXTURE=fixtures/{FIXTURE}', f'+CMD_ALT=fixtures/{FIXTURE_ALT}/cmd.txt',
                                   '+OUT=out-w13'], marker='TEST W13 PASS')
            summary = SUMMARY.search(transcript)
            dumps = sorted((run / 'out-w13').glob('out0_*.bin'))
            if not summary or int(summary.group(2)) != 0 or len(dumps) != 3:
                raise RuntimeError('board-memory: bad summary or missing OUT0 dumps')
            for dump in dumps:
                command('compare-' + dump.stem, [sys.executable, run_path(ROOT / 'tools/goldens/compare_prealpha.py'),
                                                 '--case', run_path(ROOT / 'tests/vectors/prealpha' / FIXTURE),
                                                 '--kind', 'int8', '--actual', run_path(dump)],
                        marker='0 mismatches')
            configurations['board-memory'] = {
                'fixture': FIXTURE, 'runs': [d.stem for d in dumps], 'tests': ['W13'],
                'pass_records': int(summary.group(1)), 'checks': int(summary.group(3)),
                'axi_writes': int(summary.group(4)), 'axi_reads': int(summary.group(5))}

        # The board RTL must compile with simulation-only code removed.
        command('synthesis-define-vlib', [tools['vlib'], 'rtl_synthesis'])
        command('synthesis-define-compile', [tools['vlog'], '-sv', '+define+SYNTHESIS',
                '-timescale', '1ns/1ps', '-work', 'rtl_synthesis', '-l', 'synthesis-define-compile.log',
                *[run_path(p) for p in BOARD_RTL]])

        report['status'] = 'pass'
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
