# FPGA project and board setup

This directory is reserved for reproducible Ultra96-V2 hardware setup. It does not contain a working Vivado project or bitstream yet.

- `constraints/`: reviewed board pin, clock, timing, and physical constraints.
- `ip/`: vendor-IP configuration sources, such as reviewed Tcl or XCI files.
- `debug/`: future ILA/JTAG setup, debug Tcl, and capture configuration; generated captures belong under `build/hw/`.
- Root of `hw/`: planned project/block-design scripts such as `create_project.tcl` and `bd.tcl`, plus programming/export scripts when implemented.

Taylor leads memory/DMA configuration; Nahjay leads processor/control integration. Board-level integration is shared and needs an accountable lead before implementation.

Use [rtl/](../rtl/) for custom logic. Direct generated Vivado projects, IP output products, checkpoints, bitstreams, and hardware exports to `build/hw/` at the repository root. Commit reproducible source/configuration; the root `.gitignore` excludes local XPR state and common generated files.

The proposed tool pin and board/control configuration are in [RISC-V research](../docs/RISCV_Research.md). Record tested versions in `tools/VERSIONS.md` when the team validates them.
