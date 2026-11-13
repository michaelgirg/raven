#!/usr/bin/env python3
"""Measure PR #4's buffered/direct GEMM cycles in isolated copies; Python 3.9+."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[2],
                        help='Checkout containing PR #4 or the reviewed revision')
    parser.add_argument('--build', type=Path, help='Writable output root; default: <repo>/build/board-review')
    parser.add_argument('--questa-bin', type=Path, help='Forwarded to the integration runner; otherwise use QUESTA_BIN/PATH')
    parser.add_argument('--timeout', type=float, default=180, help='Wall-clock seconds per simulator invocation')
    args = parser.parse_args()
    repo = args.repo.resolve()
    if args.timeout <= 0:
        parser.error('--timeout must be positive')
    if not (repo / 'rtl/memory/raven_read_buffer_adapter.sv').is_file():
        parser.error('--repo must contain PR #4; use its branch or revision bf944c1749310a615bb6b7924edeb3b453fc21f9')
    spec = importlib.util.spec_from_file_location('integration_runner', repo / 'tests/rtl/integration/run_questa.py')
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    build = (args.build or repo / 'build/board-review').resolve()
    build.mkdir(parents=True, exist_ok=True)
    target = Path(tempfile.mkdtemp(prefix='r', dir=build))
    print('Measurement output: ' + str(target), flush=True)
    for source in runner.SOURCES + runner.SCRIPTS:
        dest = target / source.relative_to(repo)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, dest)
    shutil.copytree(repo / 'tests/vectors/prealpha', target / 'tests/vectors/prealpha')

    # This shape is relevant to AD01's first FC layer. Zero-extend a single
    # independently checked row; zero weights preserve its eight expected bytes.
    vectors = target / 'tests/vectors/prealpha'
    normal = vectors / 'normal_8x16x8'
    reference = json.loads((normal / 'reference.json').read_text())
    if (reference['M'], reference['N'], reference['K']) != (8, 8, 16):
        raise RuntimeError('The normal fixture changed; review the zero-extension before measuring')
    name = 'board_perf_1x640x8'
    reference.update(name=name, M=1, K=640, A_pitch_bytes=640, A_base=0, B_base=0,
                     PARAM_base=0, OUTPUT_base=0, backpressure_test=False,
                     A=[reference['A'][0] + [0]*624],
                     B=reference['B'] + [[0]*8 for _ in range(624)])
    case = vectors / name
    case.mkdir()
    (case / 'reference.json').write_text(json.dumps(reference), encoding='utf-8')
    (case / 'expected_int8.bin').write_bytes((normal / 'expected_int8.bin').read_bytes()[:8])
    manifest = json.loads((vectors / 'manifest.json').read_text())
    manifest['cases'].append(dict(name=name, M=1, N=8, K=640, expected_elements=8, fixture_dir=name))
    (vectors / 'manifest.json').write_text(json.dumps(manifest), encoding='utf-8')

    bench = target / 'tests/rtl/integration/tb_raven_npu_top.sv'
    text = bench.read_text()
    old = '        raven_close_trace();\n        stalls = 0;'
    if old not in text or 'parameter bit USE_TILE_BUFFERS = 1' not in text:
        raise RuntimeError('Integration bench changed; review the measurement instrumentation')
    text = text.replace(old, '''        $display("BOARD_PERF %s buffered=%0d busy=%0d stall_in=%0d stall_out=%0d",
                 tag, USE_TILE_BUFFERS, dut.status.cyc_busy,
                 dut.status.cyc_stall_in, dut.status.cyc_stall_out);
''' + old, 1)
    bench.write_text(text, encoding='utf-8')
    records, suites = {}, {}
    for mode in (1, 0):
        text = re.sub(r'parameter bit USE_TILE_BUFFERS = [01]',
                      'parameter bit USE_TILE_BUFFERS = ' + str(mode), bench.read_text())
        bench.write_text(text, encoding='utf-8')
        run_base = target / ('b' + str(mode))
        command = [sys.executable, str(target / 'tests/rtl/integration/run_questa.py'),
                   '--tests', 'T4', '--build', str(run_base), '--timeout', str(args.timeout)]
        if args.questa_bin:
            command += ['--questa-bin', str(args.questa_bin.resolve())]
        print('RUN pipeline mode ' + str(mode), flush=True)
        proc = subprocess.run(command, cwd=target, capture_output=True, text=True,
                              encoding='utf-8', errors='replace', timeout=args.timeout*6)
        (target / ('runner-' + str(mode) + '.log')).write_text(proc.stdout + proc.stderr, encoding='utf-8')
        if proc.returncode:
            raise RuntimeError('Integration run failed; see ' + str(target / ('runner-' + str(mode) + '.log')))
        run = (run_base / json.loads((run_base / 'latest.json').read_text())['results']).parent
        result = json.loads((run / 'results.json').read_text())
        if result['status'] != 'pass' or not result['sva_checked']:
            raise RuntimeError('A successful assertion-enabled run is required')
        suites[str(mode)] = result['totals']
        transcript = (run / 'integration.console.log').read_text(encoding='utf-8')
        shutil.copyfile(run / 'integration.console.log', target / ('pipeline-' + str(mode) + '.log'))
        previous = (0, 0, 0)
        records[str(mode)] = []
        for name, buffered, busy, si, so in re.findall(
                r'BOARD_PERF (\S+) buffered=(\d+) busy=(\d+) stall_in=(\d+) stall_out=(\d+)', transcript):
            values = tuple(map(int, (busy, si, so)))
            delta = tuple(a-b for a, b in zip(values, previous))
            if int(buffered) != mode or min(delta) < 0 or delta[0] <= 0:
                raise RuntimeError('Unexpected counter sequence')
            previous = values
            records[str(mode)].append(dict(case=name, busy_cycles=delta[0],
                                           input_stall_cycles=delta[1], output_stall_cycles=delta[2]))
        if sorted(row['case'] for row in records[str(mode)]) != sorted(result['totals']['int8_comparisons']):
            raise RuntimeError('Measured cases must exactly match independently compared outputs')
        print('PASS measured pipeline mode ' + str(mode), flush=True)
    if [row['case'] for row in records['1']] != [row['case'] for row in records['0']]:
        raise RuntimeError('Buffered/direct case lists differ')
    (target / 'pipeline_cycles.json').write_text(json.dumps(records, indent=2) + '\n', encoding='utf-8')
    measurement = {'status': 'pass', 'scope': 'simulation tile cycles, not board or model latency',
                   'sva_checked': True, 'totals': suites,
                   'source_sha256': {p.relative_to(repo).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                                     for p in runner.SOURCES + runner.SCRIPTS},
                   'pipeline_cycles': records}
    (target / 'measurement_results.json').write_text(json.dumps(measurement, indent=2) + '\n', encoding='utf-8')
    (build / 'latest.json').write_text(json.dumps({'status': 'pass',
        'results': (Path(target.name) / 'measurement_results.json').as_posix()}, indent=2) + '\n', encoding='utf-8')
    print('PASS measurement: ' + str(target / 'measurement_results.json'), flush=True)


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired, ValueError, KeyError) as exc:
        sys.exit('FAIL: ' + str(exc))
