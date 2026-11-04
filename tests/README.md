# Hardware and system verification

The compute suite is runnable from the repository root:

```sh
python tests/rtl/compute/run_questa.py
```

It compiles the actual compute RTL, checks it with PE/core testbenches and an
independent fixture generator, and captures transcripts and demo waveforms.
It requires Python 3.9+ and a working Questa installation. See the
[run instructions and coverage](../README.md#run-the-compute-tests).
The [operator suite](../rtl/operators/README.md#verification) runs with
`python tests/rtl/operators/run_questa.py`; the
[activation-buffer bench](rtl/memory/README.md) has standalone simulation
instructions. [Golden fixtures and extra GEMM checks](../evidence/prealpha/compute/README.md)
provide additional compute coverage. The control/integration suite runs control,
compute, all four native memory buffers, requantization and INT8 storage together
on the golden fixtures:

```sh
python tests/rtl/integration/run_questa.py
```

See [Control pre-alpha and integration](../README.md#control-pre-alpha-and-integration)
for T1–T15 and its verification status. A full run also checks the original direct-bank
configuration against the buffered outputs and runs dedicated adapter stall, address,
byte-strobe and reset tests. Integration through physical backing banks and the
RISC-V remains future work. See the [current subsystem boundaries](../README.md#current-subsystem-status-and-integration).

| Directory | Intended contents | Lead |
|---|---|---|
| `rtl/compute/` | PE/core GEMM, partial tiles, K tails, backpressure and coordinated reset/restart tests; saved-PSUM/K-chunk continuation remains future work | Michael |
| `rtl/operators/` | Implemented requantization/clamp bench; broader activation, pool and EWADD tests remain planned | Quan |
| `rtl/memory/` | Standalone activation, weight, parameter and output benches; scratchpad/DMA/ownership tests remain planned | Taylor |
| `rtl/control/` | CSR, queue/dispatch, IRQ, interlock, and recovery tests (pre-alpha control is covered by `rtl/integration/`) | Nahjay |
| `rtl/integration/` | Buffered/direct NPU top, memory-adapter benches, command driver, bank models, fixture exporter and T1–T15 | Shared |
| `integration/` | Cross-subsystem simulation and on-board hardware/software checks | Shared; assign a lead per milestone |
| `formal/` | Optional future assertion/property harnesses and formal-run configuration | Scope and owner TBD; no formal flow implemented |
| `vectors/` | Small, reproducible fixtures with documented dtype, shape, layout, quantization, and provenance | Jackie with test owner |
| `traces/` | Curated golden register transactions for driver checks and RTL replay | Nahjay with subsystem owners |

Firmware-only host tests live in [software/tests/](../software/tests/). Host-tool tests can live alongside their model/register tools as those are added.

Write simulator products, waveforms, logs, and large generated tensors under `build/tests/`. Keep small reviewed fixtures in source control and document how to reproduce them. Register traces are expected transaction fixtures; waveforms belong in generated output.

Acceptance criteria are proposed in the [compute](../docs/NPU_ARCHITECTURE.md), [operator](../docs/NPU_Operators_Research.md), [memory](../docs/RAVEN_Memory_System_Research.md), and [control](../docs/RISCV_Research.md) documents.
