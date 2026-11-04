# Hardware and system verification

## Verified pre-alpha results

All executed RTL suites passed on merged revision
`3577d48d063182e0e2e9560623f58cf0804621ae`. The
[result record](../evidence/questa/final-prealpha/results.json) contains suite
reports, source hashes, outcomes and the resolved host launch issue; the
[execution log](../evidence/questa/final-prealpha/verification.log) retains the runs.

| Suite | Passing coverage |
|---|---|
| PE/compute | 65,536 signed INT8 products; 168 fixtures across 8×8, 4×4, 2×4 and 1×1; 12 reset/restart phases; all 64 demo outputs. |
| Operator | Rounding, saturation/clamp, tags, consecutive inputs, output stalls and reset. |
| Native buffers | Activation, weight, parameter and output standalone benches; eight deliberate reset/validity/mode faults rejected. |
| Buffer/operator goldens | Four buffer types on six fixtures, plus requantization with and without stalls on all six: 36 successful runs. |
| Supplemental compute goldens | Normal, signed/nonzero-zero-point and partial-tile INT32 fixtures passed using the Python exporter and Questa directly. |
| Control/integration | T1–T15 in buffered and direct configurations: 51 PASS records, 721 checks and 22 independently compared INT8 dumps per configuration. All output bytes agreed. |
| Adapter/configuration | 1,536 adapter checks; COLS=1 reset/NOP operation passed 43 checks. |
| Rejection/reproducibility | Active assertion guards, incomplete manifests, invalid commands, wrong comparison data and four native-buffer read corruptions rejected; regenerated fixtures matched. |
| Cycle reproduction | Eight cases per configuration matched the recorded counters, including bank-end K=33 and synthetic 1×640×8. |

Intentional-failure sections contain expected assertion or scoreboard rejections.
They verify that broken behavior is detected in simulation. They do not establish
hardware ECC, CRC or intrusion protection. No failing RTL case remains in the
executed suites; this is not exhaustive proof of every input or sequence.

The six golden cases are `normal_8x16x8`, `signed_nonzero_zp_stalled`,
`partial_tile_7x13x5`, `positive_negative_saturation`, `rounding_ties` and
`channel_scales_relu_clamp`. To reproduce the standalone matrix, run each command
below once per case, replacing the example case name:

```sh
python tools/goldens/run_activation_golden.py --case normal_8x16x8
python tools/goldens/run_weight_golden.py --case normal_8x16x8
python tools/goldens/run_parameter_golden.py --case normal_8x16x8
python tools/goldens/run_output_golden.py --case normal_8x16x8
python tools/goldens/run_requant_golden.py --case normal_8x16x8
python tools/goldens/run_requant_golden.py --case normal_8x16x8 --stall
```

Fresh [out-of-context synthesis](../hw/README.md#verified-block-synthesis) reproduced
the FPGA review's resource and preliminary timing estimates. Physical backing
banks, processor/DMA, complete routed timing, board operation and full-model
accuracy/latency remain unverified. The synthetic FC-shaped test is not execution
of the actual AD01 model.

## Run the main suites

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
