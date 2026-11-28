# Archived Ultra96-V2 board packages

The ZIP files here preserve earlier board builds and their provenance. Their
bitstreams predate the corrected address decode and GEMM data path. For a live
demo, build a fresh MEMORY handoff and run the current Tcl test. [Current board instructions](../README.md#run-the-full-board-test)

| Archived package | Build revision | Purpose at that revision |
|---|---|---|
| `raven_board_pattern.zip` | `3cba04a` | JTAG and patterned OUT0 bring-up |
| `raven_board_memory.zip` | `d567757` | Preloaded GEMM prototype before the hardware fixes |

The archived checksums remain available in [SHA256SUMS](SHA256SUMS). Keep each
bitstream paired with the PS initialization from its own build.
