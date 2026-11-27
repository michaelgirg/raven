#!/usr/bin/env python3
"""Preload and verify physical banks with the normal_8x16x8 fixture using Questa."""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
TEST = ROOT / "tests" / "rtl" / "memory"
EXPORTER = ROOT / "tests" / "rtl" / "integration" / "export_fixtures.py"
RUN = ROOT / "build" / "tests" / "memory" / "bram_fixture"
ERROR = re.compile(r"\*\*\s+(?:Warning|Error|Fatal)\b|^\s*#?\s*Errors:\s*[1-9]", re.M)
PASS = "PASS BRAM FIXTURE PRELOAD:"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--questa-bin", type=Path,
                        help="Directory containing vsim, vlog, and vlib")
    parser.add_argument("--timeout", type=int, default=120,
                        help="Maximum seconds per command")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")

    tools = {}
    for name in ("vlib", "vlog", "vsim"):
        candidate = args.questa_bin / (name + ".exe") if args.questa_bin else None
        executable = str(candidate) if candidate and candidate.is_file() else shutil.which(name)
        if not executable:
            parser.error(f"{name} not found; add Questa to PATH or use --questa-bin")
        tools[name] = executable

    RUN.mkdir(parents=True, exist_ok=True)
    fixtures = ROOT / "build" / "tests" / "integration" / "fixtures"

    def run(label, command):
        print(f"RUN {label}", flush=True)
        result = subprocess.run(
            command, cwd=RUN, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, timeout=args.timeout, check=False)
        print(result.stdout, end="")
        filtered = re.sub(
            r"^.*\*\* Warning: \((?:vlog|vsim|vopt)-223\) The environment variable MGC_HOME.*\n?",
            "",
            result.stdout,
            flags=re.M
        )
        if result.returncode or ERROR.search(filtered):
            raise RuntimeError(f"{label} failed (exit {result.returncode})")
        return result.stdout

    run("fixture export", [
        sys.executable, str(EXPORTER),
        "--vectors", str(ROOT / "tests" / "vectors" / "prealpha"),
        "--output", str(fixtures)])
    if not (RUN / "work").is_dir():
        run("library creation", [tools["vlib"], "work"])
    run("compile", [
        tools["vlog"], "-sv", "-work", "work",
        str(ROOT / "rtl" / "memory" / "raven_bram_bank.sv"),
        str(ROOT / "rtl" / "memory" / "raven_memory_banks.sv"),
        str(TEST / "tb_raven_memory_banks_fixture.sv")])
    transcript = run("fixture preload simulation", [
        tools["vsim"], "-c", "-onfinish", "exit", "-sva", "-immedassert",
        "work.tb_raven_memory_banks_fixture",
        "-do", "run -all; quit -f"])
    if PASS not in transcript:
        raise RuntimeError("Simulation did not report the fixture preload PASS marker")
    print("BRAM fixture preload checks passed.")


if __name__ == "__main__":
    main()
