#!/usr/bin/env python3
"""Verify Taylor's outputBuffer against saved INT8 Python golden outputs.

From the RAVEN repository root:
    python tools/goldens/run_output_golden.py --case normal_8x16x8
    python tools/goldens/run_output_golden.py --case signed_nonzero_zp_stalled
    python tools/goldens/run_output_golden.py --case partial_tile_7x13x5

This tests buffer write/readback only. The bytes are driven by the testbench,
not by Quan's RTL; it is not a connected GEMM-to-output test.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def run_step(label: str, command: list[str], directory: Path) -> str:
    print(f"RUN {label}", flush=True)
    try:
        result = subprocess.run(command, cwd=directory, capture_output=True, text=True, errors="replace")
    except FileNotFoundError as exc:
        raise RuntimeError(f"{command[0]} not found. Add QuestaSim to PATH.") from exc
    combined = result.stdout + "\n" + result.stderr
    (directory / f"{label}.console.log").write_text(combined, encoding="utf-8")
    if result.returncode != 0 or re.search(r"\*\*\s+(Error|Fatal)\b|\bErrors:\s*[1-9]", combined):
        raise RuntimeError(f"{label} failed; see {directory / (label + '.console.log')}\n{combined[-1500:]}")
    print(f"PASS {label}", flush=True)
    return combined


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", default="normal_8x16x8", help="Name of a tests/vectors/prealpha case folder")
    args = parser.parse_args()
    if not args.case or args.case in (".", "..") or "/" in args.case or "\\" in args.case:
        parser.error("Use a case folder name, not a path")

    fixture = ROOT / "tests" / "vectors" / "prealpha" / args.case
    json_path = fixture / "reference.json"
    binary_path = fixture / "expected_int8.bin"
    if not json_path.is_file() or not binary_path.is_file():
        parser.error(f"Missing reference.json or expected_int8.bin in {fixture}")
    info = json.loads(json_path.read_text(encoding="utf-8"))
    m, n = int(info["M"]), int(info["N"])
    if not (1 <= m <= 8 and 1 <= n <= 8):
        parser.error(f"outputBuffer supports 1<=M<=8 and 1<=N<=8; got {m}x{n}")
    packed = binary_path.read_bytes()
    if len(packed) != m * n:
        parser.error(f"Expected {m*n} bytes for {m}x{n}, got {len(packed)}")
    reference = info.get("expected_int8")
    if not isinstance(reference, list) or len(reference) != m or any(len(row) != n for row in reference):
        parser.error("reference.json expected_int8 shape doesn't match M x N")
    flattened = bytes(int(value) & 0xFF for row in reference for value in row)
    if flattened != packed:
        parser.error("expected_int8.bin and reference.json disagree")

    padded = bytearray(64)
    for row in range(m):
        padded[row * 8 : row * 8 + n] = packed[row * n : (row + 1) * n]

    build = ROOT / "build" / "tests" / "memory" / "golden_output" / args.case
    build.mkdir(parents=True, exist_ok=True)
    hex_path = build / "output_expected.hex"
    hex_path.write_text("".join(f"{byte:02X}\n" for byte in padded), encoding="ascii")
    print(f"Prepared {args.case}: {m}x{n} INT8 outputs, {m*n} valid values, {64-m*n} padding bytes (8x8 output buffer)", flush=True)

    run_step("vlib", ["vlib", "work"], build)
    run_step("compile", [
        "vlog", "-sv", "-work", "work",
        str(ROOT / "rtl" / "memory" / "output_buffer.sv"),
        str(ROOT / "tests" / "rtl" / "memory" / "tb_output_buffer_golden.sv"),
    ], build)
    result = run_step("output-golden", [
        "vsim", "-c", "-onfinish", "exit", "-t", "1ps", "-l", "output-golden.log",
        "work.tb_output_buffer_golden",
        "+OUTPUT_HEX=" + hex_path.as_posix(), "+CASE=" + args.case,
        "+VALID_COUNT=" + str(m * n),
        "-do", "run -all; quit -f",
    ], build)
    marker = f"PASS OUTPUT GOLDEN: 64/64 INT8 positions matched ({args.case}); {m*n}/{m*n} valid values; output stalls verified"
    if marker not in result or not re.search(r"Errors:\s*0", result):
        raise RuntimeError(f"Questa did not report the expected passing result. Inspect {build / 'output-golden.console.log'}")
    print(marker)
    print("Evidence: " + str(build / "output-golden.console.log"))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, RuntimeError, KeyError, TypeError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
