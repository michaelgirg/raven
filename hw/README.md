# FPGA project and board setup

Reproducible Ultra96-V2 hardware setup. `build.tcl` builds the board prototype from a
clean checkout: one JTAG-to-AXI master reaching the NPU registers at `0xA4000000` and
OUT0 readback at `0xA4002000`, on a 50 MHz PL clock. The design and its decisions are in
the [board prototype plan](../docs/plans/nahjay_board_prototype.md); the register and
host procedure are in the [board prototype interface](../docs/interfaces/RAVEN_BOARD_PROTOTYPE_INTERFACE.md).

There are two builds. The **PATTERN** bring-up build (`-out0_memory 0`, the default)
returns a fixed test pattern on OUT0 readback and the NPU has no backing memory, so a NOP
START completes but a GEMM does not. The **MEMORY** GEMM demo build (`-out0_memory 1`)
connects `rtl/memory/raven_memory_banks` to every NPU bank port and to OUT0 readback. Its
ACT/WGT/PRM BRAMs are preloaded at configuration from `hw/fixtures/normal_8x16x8`
(`act.hex`, `wgt.hex`, `prm.hex`, loaded into ACT0/ACT1 and WGT0/WGT1 alike). Nothing
writes those banks on the board, so the preload survives SOFT_RESET; reprogramming the
bitstream restores it. To change the fixture, regenerate that directory with
`export_fixtures.py`; `tests/rtl/board/run_questa.py` fails if it is stale.

## Build the board prototype

Prerequisites:

- Vivado 2025.2 with Zynq UltraScale+ device support.
- Ultra96-V2 board files. Install once from the Vivado Tcl console:

  ```tcl
  xhub::refresh_catalog [xhub::get_xstores xilinx_board_store]
  xhub::install [xhub::get_xitems avnet.com:xilinx_board_store:Ultra96v2:1.2]
  ```

  The scripts find boards installed this way even in batch mode.
- On Windows, a short enough checkout path. Vivado's debug-core step fails when its temp
  path exceeds 146 characters. `create_project.tcl` checks this first and suggests a
  shorter `-out` directory if needed.

From the repository root:

```sh
vivado -mode batch -source hw/build.tcl -tclargs -jobs 8
```

This takes about 25 minutes. Options (`-out <dir>`, `-jobs <n>`, `-out0_memory 0|1`,
`-board_part <name>`) are described in [board_settings.tcl](board_settings.tcl).
`create_project.tcl` alone creates the project and block design without building, for
inspection in the GUI.

The build fails unless synthesis and implementation succeed, `clk_pl_0` is 50 MHz, and
setup and hold slack are non-negative. Output goes to `build/hw/board/`:

| Path | Contents |
|---|---|
| `handoff/raven_board.bit` | PL bitstream |
| `handoff/raven_board.ltx` | Debug probes file |
| `handoff/raven_board.xsa` | Hardware platform, including the bitstream |
| `handoff/psu_init.tcl` | PS initialization generated for this exact configuration |
| `handoff/board_bringup_xsdb.tcl`, `handoff/run_fixture.tcl` | Board-side scripts |
| `handoff/build_info.txt` | Revision, options, clock and timing summary |
| `reports/` | Utilization, timing, clocks, DRC and methodology reports |
| `prj/raven.xpr` | The generated Vivado project |

Always use the `.bit` and `psu_init.tcl` from the same build.

## Bring up the board

A prebuilt package is committed in [handoff/](handoff/README.md):
`raven_board_pattern.zip` holds the PATTERN build's files and short bring-up steps, so
the board can be brought up without rebuilding. The commands below use a local build;
with the zip, use the folder you unzipped it to instead of `build/hw/board/handoff`.

Hardware: Ultra96-V2 with a JTAG pod on the J3 header (for example Avnet
`AES-ACC-U96-JTAG`). Set boot mode switch SW3 to JTAG, or power up with no SD card, so
no SD image takes over the PS.

1. **Program and initialize** with xsdb (from Vivado or Vitis), passing the handoff folder:

   ```sh
   xsdb build/hw/board/handoff/board_bringup_xsdb.tcl build/hw/board/handoff
   ```

   This resets the system, programs the PL, runs `psu_init` (starting `pl_clk0`), and
   releases the PL reset. It must end with `RAVEN_BRINGUP_COMPLETE`. Repeat after any
   power cycle or board reset. There is no boot loader, so nothing else starts the PL clock.
2. **Smoke test** from Vivado Hardware Manager, using the same hw_server:

   ```sh
   vivado -mode batch -source build/hw/board/handoff/run_fixture.tcl -tclargs -smoke
   ```

   It checks the `RAVN` ID and VERSION, a staging register write and readback, the OUT0
   pattern (all 16 fixture words plus the last word), AXI error responses for the
   unmapped hole, an OUT0 write and an address outside the window, and a live NOP
   START → DONE. It must end with `RAVEN_SMOKE_PASS`. From the Hardware Manager Tcl
   console with the target already open, use `set argv {-smoke -no_connect}` and then
   `source run_fixture.tcl`. Add `-soft_reset` if the NPU was left busy or halted.
3. **GEMM fixture** (MEMORY build only). The handoff includes the preloaded fixture
   directory; run it and compare:

   ```sh
   vivado -mode batch -source build/hw/board/handoff/run_fixture.tcl -tclargs -fixture build/hw/board/handoff/normal_8x16x8 -out build/prototype/out0.bin
   python tools/goldens/compare_prealpha.py --case tests/vectors/prealpha/normal_8x16x8 --kind int8 --actual build/prototype/out0.bin
   ```

   On the PATTERN build this step times out by design, and `-soft_reset` recovers the NPU.

If Hardware Manager reports no JTAG-to-AXI core, the PL clock is not running: rerun step 1,
then refresh the device.

## Verified board build

Vivado 2025.2 builds the PATTERN bitstream for `xczu3eg-sbva484-1-i` (board part
`avnet.com:ultra96v2:part0:1.2`). Measured results:

| Metric | Result |
|---|---:|
| `pl_clk0` | 50.000 MHz (IOPLL 1500 MHz / 30) |
| Worst setup slack (WNS) | +7.667 ns, 0 failing endpoints |
| Worst hold slack (WHS) | +0.012 ns, 0 failing endpoints |
| Errors / critical warnings | 0 / 0 |
| LUTs / flip-flops | 8,067 (11.4%) / 8,163 |
| Block RAM tiles / DSPs | 2.5 (debug hub) / 14 |
| RAVEN address window | `0xA4000000`, 16 KiB, in the JTAG-to-AXI address space |

DRC and methodology findings are advisories only: DSP pipelining hints, and reset
warnings inside the Vivado debug hub. The NPU's bank ports are tied idle in this build,
so its utilization is below the full NPU estimate in the next section. The out-of-context
check of the wrapper alone (`check_board_synthesis.tcl`, 20 ns) also passes with 0
critical warnings and +11.2 ns internal slack.

The [results record](../evidence/vivado/board-prototype/results.json) lists the source
revision, file hashes and what is not yet covered. The curated
[implementation](../evidence/vivado/board-prototype/implementation/) and
[wrapper synthesis](../evidence/vivado/board-prototype/wrapper-synthesis/) reports have
host/date lines removed and workspace paths normalized. The board bring-up and smoke
test above have not yet been run on hardware.

## NPU block synthesis

`check_npu_synthesis.tcl` runs the NPU block out of context for the ZU3EG. It is a
feasibility check, not a board build. See the [review and reproduction commands](../docs/reviews/RAVEN_BOARD_READINESS_REVIEW.md#reproduce-the-checks)
for the pinned source revision, reproduction commands and limitations. The buffer
integration is merged; the current repository contains the required adapter RTL.

Vivado 2025.2 out-of-context synthesis passes on the runtime-integrity build with
`USE_TILE_BUFFERS=1` for `xczu3eg-sbva484-1-e`:

| Metric | Result |
|---|---:|
| LUTs | 15,981 |
| Flip-flops | 15,322 |
| DSP blocks | 16 |
| RAMB36 / RAMB18 | 0 / 0; backing banks are outside this block |
| Clock constraint | 10 ns |
| Estimated internal worst setup slack | +1.243 ns |
| Synthesis errors / critical warnings | 0 / 0 |

There are 210 synthesis warnings, including the memory-inference/reset warnings
described in the [review](../docs/reviews/RAVEN_BOARD_READINESS_REVIEW.md).
The clock-source and external interface timing assumptions are incomplete.
These are synthesis estimates, not complete-system resource use or routed timing
closure. The synthesizable backing-bank RTL is checked separately by the
[physical memory bank synthesis target](#physical-memory-bank-synthesis); production
bank integration, processor/DMA and the bank loading path remain future work. The
board wrapper and readback path are described above. See the
[runtime-integrity validation record](../evidence/questa/integrity/results.json) and
the retained [resource](../evidence/vivado/staging-integrity/utilization_synth.rpt) /
[timing](../evidence/vivado/staging-integrity/timing_synth.rpt) reports.

The [netlist check](../evidence/vivado/staging-integrity/netlist_protection.rpt)
confirms that parity and error state remain in every staging adapter: 97 parity
registers and seven integrity-error registers in this build. After synthesis, run:

```sh
vivado -mode batch -source hw/check_staging_integrity_netlist.tcl -tclargs "<output-directory>/synthesis.dcp" "<output-directory>/netlist_protection.rpt"
```

## Physical memory bank synthesis

From the repository root, run the bank aggregate independently to verify that
Vivado maps its full-capacity ACT, WGT, mirrored PARAM, and OUT0 arrays to block
RAM:

```sh
vivado -mode batch -source hw/check_memory_banks_synthesis.tcl -tclargs . build/hw/memory-banks
```

The out-of-context target uses the ZU3EG speed-grade part and a 10 ns clock
constraint. It checks that inferred RAMB36/RAMB18 capacity covers all 80 KiB
of logical storage, and writes utilization, timing, and checkpoint outputs under
`build/hw/memory-banks/`. This validates bank-memory inference only; it does not
integrate the banks into `raven_npu_top`, validate the NPU memory adapters, or
establish board timing. The target has been added, but its result must not be
reported as validated until run with Vivado.

## Board project layout

- `board_settings.tcl`: shared options, paths, address map and source list for the board scripts.
- `create_project.tcl`, `bd.tcl`, `build.tcl`: project, block design, and the full build and handoff.
- `check_board_synthesis.tcl`, `check_npu_synthesis.tcl`, `check_memory_banks_synthesis.tcl`, `check_staging_integrity_netlist.tcl`: out-of-context checks.
- `constraints/raven_board.xdc`: board constraints. There are no package pins, and the PS IP constrains `pl_clk0`.
- `debug/`: board-side scripts (`board_bringup_xsdb.tcl`, `run_fixture.tcl`); generated captures belong under `build/hw/`.
- `ip/`: vendor-IP configuration sources, such as reviewed Tcl or XCI files.

Taylor leads memory/DMA configuration; Nahjay leads processor/control integration and the board build scripts.

Use [rtl/](../rtl/) for custom logic. Direct generated Vivado projects, IP output products, checkpoints, bitstreams, and hardware exports to `build/hw/` at the repository root. Commit reproducible source/configuration; the root `.gitignore` excludes local XPR state and common generated files.

The proposed tool pin and board/control configuration are in [RISC-V research](../docs/RISCV_Research.md). Record tested versions in `tools/VERSIONS.md` when the team validates them.
