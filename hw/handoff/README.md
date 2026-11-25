# RAVEN board handoff packages

Ready-to-use Ultra96-V2 packages, so the board can be brought up without rebuilding.
Each zip comes from one `hw/build.tcl` run. Always use the `.bit` and `psu_init.tcl` from
the same zip.

| Package | OUT0 source | Use |
|---|---|---|
| `raven_board_pattern.zip` | PATTERN | Bring-up: JTAG, PS initialization, 50 MHz clock, address map, bridge, live NOP START → DONE. GEMM does not complete. |
| `raven_board_memory.zip` | MEMORY | GEMM demo with the 64-byte readback. Not built yet; waits on the memory adapter (plan §13). |

Contents of each zip:

| File | Purpose |
|---|---|
| `raven_board.bit` | PL bitstream |
| `raven_board.ltx` | Debug probes file, if Hardware Manager asks for one |
| `raven_board.xsa` | Hardware platform, including the bitstream |
| `psu_init.tcl` | PS initialization for this exact build |
| `board_bringup_xsdb.tcl` | Step 1: reset, program the PL, run `psu_init`, release the PL reset |
| `run_fixture.tcl` | Step 2 `-smoke`, step 3 `-fixture` (Hardware Manager, JTAG-to-AXI) |
| `build_info.txt` | Commit, Vivado version, part, clock and timing for this build |
| `BRINGUP.md` | This page's quick steps |

## Quick steps (PATTERN package)

Full details, including the fixture step and troubleshooting, are in
[hw/README.md](../README.md#bring-up-the-board).

1. Ultra96-V2 with the JTAG pod on J3, and SW3 set to JTAG boot (or no SD card). Power on.
2. Unzip to a folder, for example `raven_handoff/`.
3. Program and initialize. This must print `RAVEN_BRINGUP_COMPLETE`:

   ```sh
   xsdb raven_handoff/board_bringup_xsdb.tcl raven_handoff
   ```

4. Smoke test. This must print `RAVEN_SMOKE_PASS`:

   ```sh
   vivado -mode batch -source raven_handoff/run_fixture.tcl -tclargs -smoke
   ```

   If the NPU was left busy or halted, add `-soft_reset`.

Report back the console output of both steps, especially any failure in the three
"AXI error as expected" checks or in the xsdb target selection. Those are the parts
that could not be tested without the board.

## Integrity

SHA-256 of each package, from the commit that added it:

| Package | Built from | SHA-256 |
|---|---|---|
| `raven_board_pattern.zip` | `3cba04a` | `ce7f2ff95be47675749d31335c7dd61716298126953c2c2a38efd5c6175b0838` |
