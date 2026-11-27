# RAVEN Ultra96-V2 board handoff

This page is for bringing up the RAVEN NPU on the Ultra96-V2 and running the GEMM demo.
It is written so a person or a coding agent can follow it step by step. Nothing here needs
a rebuild. Everything that runs on the board is in **`hw/handoff/raven_board_memory.zip`**.

Goal: one `M=8, K=16, N=8` INT8 GEMM runs on the board, started over JTAG, and its
64-byte result read back from OUT0 matches the golden reference.

## 1. What is in the zip

Unzipping gives one folder, `raven_handoff/`:

| File | Purpose |
|---|---|
| `raven_board.bit` | PL bitstream (MEMORY build: NPU + BRAM banks preloaded with the fixture) |
| `psu_init.tcl` | PS initialization for this exact build. Always use it with this `.bit` |
| `raven_board.ltx` | Debug probes file, only if Hardware Manager asks for one |
| `raven_board.xsa` | Hardware platform (includes the bitstream); not needed for these steps |
| `board_bringup_xsdb.tcl` | Step 3: reset, program the PL, run `psu_init`, release the PL reset |
| `run_fixture.tcl` | Steps 4 and 5: smoke test and GEMM run through Hardware Manager (JTAG-to-AXI) |
| `normal_8x16x8/` | The fixture: `cmd.txt` (registers to write), `expected_int8.hex` (golden result), and the `act/wgt/prm.hex` images already inside the bitstream |
| `build_info.txt` | Commit, Vivado version, part, clock, timing. Contains `out0_source: MEMORY` |
| `BOARD_HANDOFF.md` | This page |

`run_fixture.tcl` reads `build_info.txt` from its own folder to know this is the MEMORY
build, so keep the files together in `raven_handoff/`.

## 2. What you need

- An Ultra96-V2 and its 12 V supply.
- A JTAG pod on the **J3** header, for example Avnet `AES-ACC-U96-JTAG`, plus its micro-USB
  cable to the host.
- Vivado 2025.2 (or the Vivado Lab Edition 2025.2) on the host. It provides `vivado`,
  `xsdb` and `hw_server`, and installs the JTAG cable drivers. On Windows they are in
  `<install>\2025.2\Vivado\bin\`; use the `.bat` files or a Vivado command prompt.
- Python 3.9+ and a checkout of this repository, only for the optional independent check
  in step 6.

Board files and the source tree are **not** needed to run the demo.

## 3. Set up and program the board

1. Set boot mode switch **SW3 to JTAG**, or remove the SD card, so no SD image takes over
   the PS.
2. Connect the JTAG pod to J3 and to the host, then power on the board.
3. Unzip `raven_board_memory.zip` and open a terminal in the folder that contains
   `raven_handoff/`.
4. Program and initialize:

   ```sh
   xsdb raven_handoff/board_bringup_xsdb.tcl raven_handoff
   ```

   **Success:** the last line is `RAVEN_BRINGUP_COMPLETE`.

   This resets the system, programs the PL, runs `psu_init` (which starts the 50 MHz
   `pl_clk0`), and releases the PL reset. There is no boot loader, so repeat this step
   after **every** power cycle or board reset. Programming the bitstream again also
   restores the fixture data in the BRAMs.

## 4. Smoke test

```sh
vivado -mode batch -source raven_handoff/run_fixture.tcl -tclargs -smoke
```

**Success:** it prints `RAVEN: OUT0 source memory`, then a list of `ok` lines, and ends with
`RAVEN_SMOKE_PASS`.

It checks the `RAVN` ID (`0x5241564E`) and VERSION, a staging register write and readback,
OUT0 reads, AXI error responses for the unmapped hole, an OUT0 write and an address outside
the window (three lines ending in `AXI error as expected`), and a live NOP START → DONE.

## 5. Run the GEMM

```sh
vivado -mode batch -source raven_handoff/run_fixture.tcl -tclargs -fixture raven_handoff/normal_8x16x8 -out raven_handoff/out0.bin
```

**Success:** it ends with these lines:

```
  ok  OUT0 matches expected_int8.hex (64/64 bytes)
...
RAVEN_FIXTURE_DONE (<n> checks)
```

The script writes the 16 command registers from `cmd.txt`, starts the command, polls
`STATUS` and `IRQ_STATUS` until DONE, checks that `DONE_SEQ` matches, reads 64 bytes from
OUT0 into `out0.bin`, and compares them byte by byte with `expected_int8.hex`. Any
difference stops it with `CHECK FAILED` and lists up to 8 mismatched bytes.

The run can be repeated without reprogramming. If a previous run left the NPU busy or
halted, add `-soft_reset`.

## 6. Optional: independent golden check

From the repository root, with the `out0.bin` from step 5:

```sh
python tools/goldens/compare_prealpha.py --case tests/vectors/prealpha/normal_8x16x8 --kind int8 --actual <path>/raven_handoff/out0.bin
```

**Success:** `PASS normal_8x16x8: 8x8 int8, 0 mismatches`.

## 7. Report back

Send back:

1. The full console output of steps 3, 4 and 5.
2. `raven_handoff/out0.bin`.
3. The step 6 output, if you ran it.

These go into `evidence/` as the board result (W14 in the plan).

## 8. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `No PSU target found` in step 3 | The JTAG chain is not visible. Check the pod is on J3 and powered, the board is on, and the cable driver is installed. Run `xsdb` then `connect; targets` to see the chain. |
| `No JTAG-to-AXI core found` in step 4 or 5 | The PL clock is not running. Rerun step 3, then retry. |
| `No Zynq UltraScale+ device on the JTAG chain` | Another program holds the cable, or hw_server is on another port. Close other Vivado/Vitis sessions, or pass `-url <host:port>`. |
| Hardware Manager asks for a probes file | Add `-probes raven_handoff/raven_board.ltx`. |
| `NPU not idle ... rerun with -soft_reset` | A previous command did not finish. Add `-soft_reset`. |
| `No DONE within 2000 ms` | The PATTERN bitstream is loaded, or `RAVEN: OUT0 source pattern` was printed. Run step 3 with the files from this zip. Do not mix the `.bit` and `psu_init.tcl` of different zips. |
| `NPU reported an error` | The output includes `ERR_CODE` and `ERR_INFO`. Send them back; the command in `cmd.txt` should never be rejected. |
| `CHECK FAILED: n/64 OUT0 bytes differ` | Send the full output and `out0.bin`. Run step 5 once more after step 3 to rule out a stale state. |

Already in the Hardware Manager GUI with the target open? In its Tcl console run
`set argv {-smoke -no_connect}` (or `{-fixture raven_handoff/normal_8x16x8 -no_connect}`),
then `source raven_handoff/run_fixture.tcl`.

## 9. Reference

| Item | Value |
|---|---|
| Part / board | `xczu3eg-sbva484-1-i` / `avnet.com:ultra96v2:part0:1.2` |
| Clock | `pl_clk0` 50 MHz (IOPLL 1500 MHz / 30), the only PL clock |
| RAVEN window | `0xA4000000`, 16 KiB, in the JTAG-to-AXI address space |
| CSR block | `0xA4000000` (ID `+0x000`, CTRL `+0x010`, STATUS `+0x014`, IRQ_STATUS `+0x01C`, NEXT_SEQ `+0x020`, DONE_SEQ `+0x024`, ERR_CODE `+0x028`, ERR_INFO `+0x02C`, staging `+0x030`–`+0x06C`) |
| Unmapped hole | `0xA4001000`–`0xA4001FFF` (DECERR) |
| OUT0 readback | `0xA4002000`–`0xA4003FFF`, read-only (writes give SLVERR) |
| CTRL bits | bit 0 START, bit 1 SOFT_RESET |
| STATUS bits | bit 0 busy, bit 1 halted, bit 2 error |
| Data in BRAM | ACT0/ACT1 = `act.hex`, WGT0/WGT1 = `wgt.hex`, PRM = `prm.hex`, loaded by the bitstream. SOFT_RESET keeps it; only OUT0 is written at run time |

More detail: [hw/README.md](../README.md#bring-up-the-board) (build and bring-up),
[the board prototype interface](../../docs/interfaces/RAVEN_BOARD_PROTOTYPE_INTERFACE.md)
(register procedure), and [the plan](../../docs/plans/nahjay_board_prototype.md) §13.

## 10. Build record

| Item | Value |
|---|---|
| Built from | `d567757` with Vivado 2025.2 (`hw/build.tcl -tclargs -out0_memory 1`); the packaged `run_fixture.tcl` is the version committed with this zip |
| Timing | WNS +7.026 ns, WHS +0.010 ns, 0 failing endpoints, 0 critical warnings |
| Simulation | W1–W13 pass in ModelSim ASE 18.1 (immediate checks only; licensed Questa SVA run pending) |
| `raven_board.bit` SHA-256 | `a4015788444c577b48903f9d67ba89d2546ac107533cb4a032cd02c2348be69a` |
| `psu_init.tcl` SHA-256 | `34015b22fdc4138f17cab44a6502668bd1120694e0cddf378d3a2bf96945af0f` |
| Zip SHA-256 | in [SHA256SUMS](SHA256SUMS) |
