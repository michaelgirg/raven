#!/usr/bin/env python3
"""Verify Taylor's parameterBuffer with saved RAVEN Python goldens.

Run from anywhere inside the repository, e.g.:
    python tools/goldens/run_parameter_golden.py --case normal_8x16x8
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VALID_CASES = (
    "normal_8x16x8", "signed_nonzero_zp_stalled", "partial_tile_7x13x5",
    "rounding_ties", "positive_negative_saturation", "channel_scales_relu_clamp",
)


def pack_i32(value: int) -> int:
    if not -(1 << 31) <= value < (1 << 31):
        raise ValueError(f"Value out of signed INT32 range: {value}")
    return value & 0xFFFFFFFF


def pack_i8(value: int) -> int:
    if not -128 <= value <= 127:
        raise ValueError(f"Value out of signed INT8 range: {value}")
    return value & 0xFF


def create_words(case: dict) -> list[int]:
    n = int(case["N"])
    if not 1 <= n <= 8:
        raise ValueError(f"Expected 1 to 8 channels; got N={n}")
    fields = ("corrected_bias", "multiplier_q31", "shift")
    for field in fields:
        if len(case[field]) != n:
            raise ValueError(f"{field} length {len(case[field])} differs from N={n}")
    words = [0] * 29
    for channel in range(n):
        words[channel] = pack_i32(int(case["corrected_bias"][channel]))
        words[8 + channel] = pack_i32(int(case["multiplier_q31"][channel]))
        words[16 + channel] = pack_i8(int(case["shift"][channel]))
    words[24] = pack_i8(int(case["output_zero_point"]))
    words[25] = pack_i8(int(case["clamp_min"]))
    words[26] = pack_i8(int(case["clamp_max"]))
    # Verify both modes: per-channel, then shared using channel-0 multiplier/shift.
    words[27] = 1
    words[28] = 1
    return words


def run_step(label: str, command: list[str], directory: Path) -> str:
    print(f"RUN {label}", flush=True)
    try:
        result = subprocess.run(command, cwd=directory, capture_output=True, text=True)
    except FileNotFoundError as exc:
        raise RuntimeError(f"{command[0]} not found. Install QuestaSim and add it to PATH.") from exc
    combined = result.stdout + "\n" + result.stderr
    (directory / f"{label}.console.log").write_text(combined, encoding="utf-8")
    if result.returncode != 0:
        raise RuntimeError(f"{label} exited with code {result.returncode}:\n{combined[-2500:]}")
    print(f"PASS {label}", flush=True)
    return combined


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", default="normal_8x16x8", choices=VALID_CASES)
    args = parser.parse_args()

    case_dir = ROOT / "tests" / "vectors" / "prealpha" / args.case
    source = case_dir / "reference.json"
    if not source.is_file():
        parser.error(f"Missing fixture: {source}")
    case = json.loads(source.read_text(encoding="utf-8"))
    words = create_words(case)
    build = ROOT / "build" / "tests" / "memory" / "golden_parameter" / args.case
    build.mkdir(parents=True, exist_ok=True)
    params_path = build / "parameter_words.hex"
    params_path.write_text("".join(f"{word:08X}\n" for word in words), encoding="ascii")
    print(f"Prepared {args.case}: {case['N']} valid channels, 8 physical channels; 29 write registers", flush=True)
    run_step("vlib", ["vlib", "work"], build)
    run_step("compile", [
        "vlog", "-sv", "-work", "work",
        str(ROOT / "rtl/memory/parameter_buffer.sv"),
        str(ROOT / "tests/rtl/memory/tb_parameter_buffer_golden.sv"),
    ], build)
    result = run_step("parameter-golden", [
        "vsim", "-c", "-onfinish", "exit", "-t", "1ps",
        "-l", "parameter-golden.log", "work.tb_parameter_buffer_golden",
        "+PARAM_HEX=" + params_path.as_posix(),
        "+CASE=" + args.case,
        "-do", "run -all; quit -f",
    ], build)
    marker = f"PASS PARAMETER GOLDEN: 8/8 channels matched ({args.case})"
    if marker not in result or "Errors: 0" not in result:
        raise RuntimeError("Questa did not report the expected passing summary. See " + str(build / "parameter-golden.console.log"))
    print(marker + "; per-channel and shared modes; output stalls verified")
    print("Evidence: " + str(build / "parameter-golden.console.log"))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, ValueError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
