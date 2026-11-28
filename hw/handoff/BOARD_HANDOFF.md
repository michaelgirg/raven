# Ultra96-V2 board handoff

For the live GEMM demo, use a fresh MEMORY build. Its handoff contains the
bitstream, matching PS initialization, preloaded fixture and one-command Tcl
runner. The runner programs the board, checks the JTAG AXI bridge and verifies
all 64 OUT0 bytes. [Build and run instructions](../README.md#run-the-full-board-test)

The earlier ZIP files and their checksums are indexed in the [archive README](README.md).
The [W14 record](../../evidence/vivado/board-prototype/live-gemm/results.json) links the
verified configuration to its transcript, raw OUT0 capture and golden comparison.
