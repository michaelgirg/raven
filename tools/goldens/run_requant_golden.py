#!/usr/bin/env python3
"""Test Quan's requantization RTL against saved Python-generated INT8 goldens.

From repository root:
    python tools/goldens/run_requant_golden.py --case rounding_ties
    python tools/goldens/run_requant_golden.py --case positive_negative_saturation
    python tools/goldens/run_requant_golden.py --case channel_scales_relu_clamp --stall

Requires Questa commands (vmap, vlib, vlog, vsim) on PATH.
Outputs are generated under build/tests/operators/golden/<case>/.
"""
import argparse
import json
import os
import re
import shutil
import struct
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VALID_CASES = (
    "rounding_ties",
    "positive_negative_saturation",
    "channel_scales_relu_clamp",
    "normal_8x16x8",
    "signed_nonzero_zp_stalled",
    "partial_tile_7x13x5",
)


def write_hex(path, values, bits, count):
    values = list(values)
    values += [0] * (count - len(values))
    if len(values) != count:
        raise ValueError(f"Incorrect vector length for {path.name}")
    mask = (1 << bits) - 1
    path.write_text("".join(f"{v & mask:0{bits//4}x}\n" for v in values), encoding="ascii")


def execute(label, command, cwd):
    print(f"RUN {label}", flush=True)
    try:
        proc = subprocess.run(command, cwd=cwd, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=120)
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"{label} timed out") from exc
    output = proc.stdout.decode("utf-8", errors="replace")
    (cwd / f"{label}.console.log").write_text(output, encoding="utf-8")
    if proc.returncode:
        print("\n".join(output.splitlines()[-25:]))
        raise RuntimeError(f"{label} failed (exit {proc.returncode})")
    print(f"PASS {label}")
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", required=True, choices=VALID_CASES)
    parser.add_argument("--stall", action="store_true", help="Exercise output backpressure")
    args = parser.parse_args()

    case_dir = ROOT / "tests/vectors/prealpha" / args.case
    d = json.loads((case_dir / "reference.json").read_text(encoding="utf-8"))
    m, n = d["M"], d["N"]
    if not (1 <= m <= 8 and 1 <= n <= 8 and m*n <= 64):
        raise ValueError("Unsupported M/N")

    accum = [value for row in d["expected_int32"] for value in row]
    expected = [value for row in d["expected_int8"] for value in row]
    multipliers = d["multiplier_q31"]
    shifts = d["shift"]
    if len(accum) != m*n or len(expected) != m*n or len(multipliers) != n or len(shifts) != n:
        raise ValueError("Unexpected fixture vector lengths")

    # Verify JSON agrees with committed reference binaries, including byte order.
    expected_int32_bytes = b"".join(struct.pack("<i", v) for v in accum)
    expected_int8_bytes = bytes(v & 255 for v in expected)
    if (case_dir / "expected_int32.bin").read_bytes() != expected_int32_bytes:
        raise RuntimeError("INT32 fixture binary disagrees with reference.json")
    if (case_dir / "expected_int8.bin").read_bytes() != expected_int8_bytes:
        raise RuntimeError("INT8 fixture binary disagrees with reference.json")

    work = ROOT / "build/tests/operators/golden" / args.case
    work.mkdir(parents=True, exist_ok=True)
    write_hex(work / "input_int32.hex", accum, 32, 64)
    write_hex(work / "expected_int8.hex", expected, 8, 64)
    write_hex(work / "multipliers.hex", multipliers, 32, 8)
    write_hex(work / "shifts.hex", shifts, 8, 8)
    (work / "run_batch.do").write_text(
        "onerror {quit -force -code 1}\n"
        "onbreak {quit -force -code 1}\n"
        "run -all\n"
        "quit -force -code 1\n", encoding="ascii")

    tools = {name: shutil.which(name) for name in ("vmap", "vlib", "vlog", "vsim")}
    if not all(tools.values()):
        raise RuntimeError("Questa tools not found on PATH; run from your Questa-enabled terminal")

    execute("vmap-local", [tools["vmap"], "-c"], work)
    execute("vlib", [tools["vlib"], "work"], work)
    execute("vmap-work", [tools["vmap"], "work", "work"], work)
    sources = [ROOT / "rtl/operators/raven_requantize_clamp.sv",
               ROOT / "tests/rtl/operators/tb_raven_requant_golden.sv"]
    execute("compile", [tools["vlog"], "-sv", "-work", "work", "-l", "compile.log",
                        *[p.as_posix() for p in sources]], work)
    args_vs = [tools["vsim"], "-c", "-onfinish", "exit", "-sva", "-immedassert",
               "-l", "golden.log", "work.tb_raven_requant_golden",
               f"+M={m}", f"+N={n}", f"+ZP={d['output_zero_point']}",
               f"+LO={d['clamp_min']}", f"+HI={d['clamp_max']}"]
    if args.stall:
        args_vs.append("+STALL")
    args_vs += ["-do", "do run_batch.do"]
    output = execute("requant-golden", args_vs, work)
    marker = f"PASS REQUANT GOLDEN: {m*n}/{m*n} INT8 outputs matched"
    if marker not in output or re.search(r"\bErrors:\s*[1-9]", output):
        raise RuntimeError("No valid golden-result PASS marker; see requant-golden.console.log")
    print(f"{marker} ({args.case})")
    print(f"Evidence: {work / 'requant-golden.console.log'}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"FAIL: {exc}")
        raise SystemExit(1)
