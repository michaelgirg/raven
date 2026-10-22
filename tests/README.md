# Hardware and system verification

These folders reserve space for future verification assets. No test suite is implemented or runnable yet.

| Directory | Intended contents | Lead |
|---|---|---|
| `rtl/compute/` | PE/array, edge-tile, K-chunk, and backpressure tests | Michael |
| `rtl/operators/` | Integer-reference, activation, pool, and EWADD tests | Quan |
| `rtl/memory/` | Scratchpad/adapter, DMA-stream, byte-count, and ownership tests | Taylor |
| `rtl/control/` | CSR, queue/dispatch, IRQ, interlock, and recovery tests | Nahjay |
| `integration/` | Cross-subsystem simulation and on-board hardware/software checks | Shared; assign a lead per milestone |
| `formal/` | Optional future assertion/property harnesses and formal-run configuration | Scope and owner TBD; no formal flow implemented |
| `vectors/` | Small, reproducible fixtures with documented dtype, shape, layout, quantization, and provenance | Jackie with test owner |
| `traces/` | Curated golden register transactions for driver checks and RTL replay | Nahjay with subsystem owners |

Firmware-only host tests live in [software/tests/](../software/tests/). Host-tool tests can live alongside their model/register tools as those are added.

Write simulator products, waveforms, logs, and large generated tensors under `build/tests/`. Keep small reviewed fixtures in source control and document how to reproduce them. Register traces are expected transaction fixtures; waveforms belong in generated output.

Acceptance criteria are proposed in the [compute](../docs/NPU_ARCHITECTURE.md), [operator](../docs/NPU_Operators_Research.md), [memory](../docs/RAVEN_Memory_System_Research.md), and [control](../docs/RISCV_Research.md) documents.
