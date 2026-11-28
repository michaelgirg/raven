#!/usr/bin/env python3
"""Preload and verify physical banks with the normal_8x16x8 fixture using Questa."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from questa_log import has_unexpected_diagnostics

ROOT = Path(__file__).resolve().parents[3]
TEST = ROOT / "tests" / "rtl" / "memory"
EXPORTER = ROOT / "tests" / "rtl" / "integration" / "export_fixtures.py"
RUN = ROOT / "build" / "tests" / "memory" / "bram_fixture"
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

    questa_bin = args.questa_bin
    if questa_bin is None and os.environ.get("QUESTA_BIN"):
        questa_bin = Path(os.environ["QUESTA_BIN"]).expanduser()
    tools = {}
    for name in ("vlib", "vlog", "vsim"):
        candidate = questa_bin / (name + (".exe" if os.name == "nt" else "")) if questa_bin else None
        executable = str(candidate.resolve()) if candidate and candidate.is_file() else (None if candidate else shutil.which(name))
        if not executable:
            parser.error(f"{name} not found; add Questa to PATH, set QUESTA_BIN, or use --questa-bin")
        tools[name] = executable

    RUN.mkdir(parents=True, exist_ok=True)
    fixtures = ROOT / "build" / "tests" / "integration" / "fixtures"

    def run(label, command):
        print(f"RUN {label}", flush=True)
        result = subprocess.run(
            command, cwd=RUN, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, timeout=args.timeout, check=False)
        print(result.stdout, end="")
        if result.returncode or has_unexpected_diagnostics(result.stdout):
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
