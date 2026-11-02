# Compute pre-alpha — experiments, failures and difficulties

This record covers the compute design and its Questa validation. Tests used
Questa Intel Starter FPGA Edition-64 2021.2 and Python 3.12.10 on Windows x64.
The computational logic was preserved during validation.

## What was tested

The main use case is 8×16 INT8 activations × 16×8 INT8 weights + bias, producing
64 INT32 results. The command driver, operand memories and output consumer are
testbench stand-ins. The tests exercise the real compute modules and compare
results with an independent Python wide-integer reference.

## Failures and difficulties

| Issue | What happened | Fix / follow-up |
|---|---|---|
| Original Questa compilation | `vlog-2244` rejected an implicitly static `int timeout_cycles=0` declaration inside the reset-phase block. | Separated declaration from assignment so the watchdog starts from zero for every phase. [Original compile failure](01-original-compile.log). |
| First GEMM fixture load | Questa formatted `%02d` as `case_ 0`; memory initialization could not find `case_00`, and the result assertion failed on unknown data. | Built the two decimal digits explicitly with `%0d%0d`. Input values, expected results and assertions were preserved. [Original simulation failure](02-fixture-path-padding.log). |
| Incomplete fixture manifest | Review found that the old bench stopped on a short `$fscanf` record without enforcing 42 completed fixtures. | Added partial-record, sequential-ID and exact-total checks. Intentional empty, partial-record and short-manifest runs now fail as expected. |
| Native exit status | This Questa configuration returned status zero even after `$fatal`. | The runner also checks transcript diagnostics and exact PASS totals. It separately proves that immediate and concurrent assertions execute, and returns nonzero on an unexpected test failure. |
| Group portability | A teammate's checkout and simulator installation can be in different directories. | The runner locates the project from its script location, uses relative fixture/source paths where possible, and discovers tools through PATH, QUESTA_BIN or --questa-bin. A relocated checkout passed when launched from another directory with spaces in the checkout/build paths. |

The [combined execution log](../verification.log) contains named sections for
the normal regressions, the two assertion probes and the three manifest-rejection
probes. Fatal messages inside those five intentional-failure sections are
expected; they are not failures of the normal design regression.

## Results after the fixes

| Check | Result |
|---|---|
| Compile the design and benches | Passed with zero warnings/errors. |
| PE testbench | 65,536 signed INT8 operand products passed, plus bias/bubbles, both overflow directions and in-flight reset. |
| Core configurations | 8×8, 4×4, 2×4 and 1×1 each passed 42 fixtures and three reset/restart phases: **168 fixtures and 12 phases total**. |
| Short demonstration | All 64 INT32 outputs matched the independent reference, with correct row/column/index/last tags. |
| Demo counters | 151 busy cycles, 16 K issues, 37 input-stall clocks, six output-stall clocks and error code zero. |
| Waveform | The captured trace shows the result held during backpressure, followed by 64 accepted outputs; compute completion precedes final result completion. |

The [result report](../results.json) records source hashes, versions, portable
command argument lists, durations and outcomes. The [waveform preview](../demo_waveform.svg)
shows selected public signals from the saved VCD. Run the scripts again to
regenerate the full VCD/WLF waveforms and fixtures under the ignored build folder.

## Remaining limitations

There is no failing case in the executed supported suite. The core handles one
physical GEMM microtile, one full resident K reduction and one INT32 output lane.
It does not implement Conv gathering, saved partial-sum continuation or final
INT8 conversion. Compute and memory responders must reset together; missing
replies or a permanently blocked consumer can stall the core indefinitely.

Physical BRAM/DMA, RISC-V control, output operators and full-model execution
remain integration work for the team. Synthesis, board operation, FPGA resource
use and routed timing were not measured. A 10 ns test clock does not prove
100 MHz timing closure. The project README also lists the known limitations.

