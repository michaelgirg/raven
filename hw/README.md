# FPGA project and board setup

This directory is reserved for reproducible Ultra96-V2 hardware setup. It does not contain a working Vivado project or bitstream yet.

`check_npu_synthesis.tcl` runs the NPU block out of context for the ZU3EG. It is a
feasibility check, not a board build. See the [review and reproduction commands](../docs/reviews/RAVEN_BOARD_READINESS_REVIEW.md#reproduce-the-checks)
for the pinned source revision, reproduction commands and limitations. The buffer
integration is merged; the current repository contains the required adapter RTL.

## Verified block synthesis

Vivado 2025.2 out-of-context synthesis was repeated on merged revision
`3577d48d063182e0e2e9560623f58cf0804621ae` with `USE_TILE_BUFFERS=1` for
`xczu3eg-sbva484-1-e`. It reproduced the reviewed result:

| Metric | Result |
|---|---:|
| LUTs | 15,346 |
| Flip-flops | 14,839 |
| DSP blocks | 16 |
| RAMB36 / RAMB18 | 0 / 0; backing banks are outside this block |
| Clock constraint | 10 ns |
| Estimated internal worst setup slack | +1.169 ns |
| Synthesis errors / critical warnings | 0 / 0 |

There are 207 synthesis warnings, including the memory-inference/reset warnings
described in the [review](../docs/reviews/RAVEN_BOARD_READINESS_REVIEW.md).
The clock-source and external interface timing assumptions are incomplete.
These are synthesis estimates, not complete-system resource use or routed timing
closure. Physical backing BRAM, processor/DMA, a loading/readback path, the board
wrapper and on-board tests remain future work. See the
[merged-build validation record](../evidence/questa/final-prealpha/results.json) and
the retained [resource](../evidence/vivado/board-readiness/utilization_synth.rpt) /
[timing](../evidence/vivado/board-readiness/timing_synth.rpt) reports.

## Board project layout

- `constraints/`: reviewed board pin, clock, timing, and physical constraints.
- `ip/`: vendor-IP configuration sources, such as reviewed Tcl or XCI files.
- `debug/`: future ILA/JTAG setup, debug Tcl, and capture configuration; generated captures belong under `build/hw/`.
- Root of `hw/`: planned project/block-design scripts such as `create_project.tcl` and `bd.tcl`, plus programming/export scripts when implemented.

Taylor leads memory/DMA configuration; Nahjay leads processor/control integration. Board-level integration is shared and needs an accountable lead before implementation.

Use [rtl/](../rtl/) for custom logic. Direct generated Vivado projects, IP output products, checkpoints, bitstreams, and hardware exports to `build/hw/` at the repository root. Commit reproducible source/configuration; the root `.gitignore` excludes local XPR state and common generated files.

The proposed tool pin and board/control configuration are in [RISC-V research](../docs/RISCV_Research.md). Record tested versions in `tools/VERSIONS.md` when the team validates them.
