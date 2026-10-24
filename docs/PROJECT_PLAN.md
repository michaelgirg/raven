# RAVEN project targets and milestones

**Status:** engineering targets for planning, updated October 23, 2026. No performance, quality, resource, or implementation result is claimed. Official course deadlines take precedence over these internal dates. Shared behavior is defined in the [interface contract](interfaces/RAVEN_INTERFACE_CONTRACT.md).

## Functional and model acceptance

The proposed first three models are AD01, DS-CNN, and MobileNetV1 0.25× VWW. For designated supported fixtures/layers, require **zero mismatched INT8 elements** against TFLM commit `c051fea55c4a6b4464186e1bb126708bea50f32e` with `TFLITE_SINGLE_ROUNDING=1`, identical prepared parameters and identical input bytes. Preserve model hashes, preprocessing, dataset/split versions, build flags, and expected tensors together. An arbitrary optimized desktop TFLite build is not automatically that bit-exact reference. [Pinned arithmetic](https://github.com/tensorflow/tflite-micro/blob/c051fea55c4a6b4464186e1bb126708bea50f32e/tensorflow/lite/micro/kernels/internal/common.cc).

| Model | Application-quality goal | Mean inference latency | Sequential rate |
|---|---|---:|---:|
| AD01 | ROC-AUC ≥0.85 on the pinned ToyCar reference evaluation | ≤50 ms | ≥20/s |
| DS-CNN | 12-class top-1 accuracy ≥90% on the pinned Speech Commands reference split | ≤250 ms | ≥4/s |
| VWW | Binary person/no-person accuracy ≥80% on the pinned VWW evaluation | ≤1,000 ms | ≥1/s |

These are RAVEN goals, not upstream guarantees. First measure the pinned host baseline on the exact evaluation pipeline. If it misses a quality goal, investigate model/preprocessing/split compatibility and document any revised goal; do not attribute that failure to hardware without evidence. Numerical conformance and application quality are separate checks. ResNet-8 and Streaming DS-CNN remain secondary candidates with model-specific targets deferred until selected.

AD01 reconstructs 640 features: compare all reconstructed outputs, then reference anomaly scoring/window aggregation and ROC-AUC. Its input/output scales differ, so raw integer reconstruction MSE is not a substitute for the reference score. Evaluate quality on the host if needed. Classifier top-1 is not AD01's metric.

Measure inference from ready INT8 input in DDR to final output committed in DDR, including runtime scheduling, DMA, repacking, CPU fallback, and output operators. Report loading, host preprocessing, bank/arena cleanup, and observed mailbox RUN-to-DONE separately. For warm measurements use at least 100 runs and report mean/p95, batch size, clock, configuration, and CPU-fallback share. Disable oracle/debug execution when measuring throughput. Sequential rate assumes one outstanding inference, as in the mailbox contract.

Hardware goals: 8×8 INT8 MAC array, architectural INT32 accumulation, at least 100 MHz with nonnegative routed setup slack, and ≤80% of each FPGA resource family. The 6.4 GMAC/s / 12.8 GOPS arithmetic ceiling requires full occupancy and one valid MAC per PE per cycle; it is not model throughput. Publish actual DSP/LUT/FF/BRAM use and timing. Logical scratchpad totals are 74–88 KiB base, 78–92 KiB with PRM, or 86–108 KiB with PRM and OUT1; local memory/frontend storage is accounted separately.

## Master internal schedule

| Milestone | Target | Accountable lead | Acceptance |
|---|---|---|---|
| M1: configuration and interface definition | November 6, 2026 | Nahjay | Core/tool configuration and tested-version status documented; block design recreated from Tcl on a second machine; shared fields reviewed for implementation |
| M2: RISC-V alive on board | November 20, 2026 | Nahjay | Build hash/console and arena pattern test pass |
| Fall checkpoint | December 2, 2026 | Michael | Current subsystem work and shared interfaces documented; build/test evidence and spring integration risks recorded |
| Spring restart | January 15, 2027 | Nahjay | Board/tool environment reproduced; subsystem work resumed |
| M3: CSR/queue verification | January 22, 2027 | Nahjay | Defined register/error/queue and abort behavior passes simulation |
| M4: host drivers and traces | January 29, 2027 | Nahjay | Host driver traces replay against RTL; blob byte schema and CPU/NPU constant round-trips defined/tested with Jackie |
| M5: DMA/control self-test | February 5, 2027 | Taylor | Bank-aware packet/tail/commit/guard tests and control-only round trips pass |
| M6: synthetic compute integration | February 12, 2027 | Michael | RISC-V-launched GEMM/Conv matches pinned integer goldens; bank/PSUM ownership correct |
| M7: AD01 end-to-end | February 26, 2027 | Jackie | All ten layers match; reconstruction/scoring pipeline and measured latency/quality reported |
| M8: interrupt pipeline | March 5, 2027 | Nahjay | Overlap and T2–T5 measurements reported; timer-driven waits verified |
| M9: three-model beta | March 12, 2027 | Michael | One bitstream/firmware runs all three blobs; numerical and application checks reported against targets |
| M10: robustness | April 2, 2027 | Nahjay | Recoverable fault fixtures meet declared reporting bounds and restart; terminal fault path documented |
| M11: handoff reproduction | April 9, 2027 | Taylor | A non-author reproduces build and known tests from documentation; friction corrected |
| Final package ready | April 16, 2027 | Michael | Tagged source/build instructions, tested versions, results, diagrams, and limitations ready |

Leads coordinate shared milestones; subsystem ownership remains Michael/compute, Quan/operators, Taylor/memory, Nahjay/control, Jackie/models. Naming a milestone lead does not designate a post-graduation maintainer. The stakeholder handoff recipient and maintenance commitment still require a real agreement.

No required implementation work is scheduled over Thanksgiving, fall exams/winter interval, or spring break. Leave April 19–21 as contingency. UF lists Thanksgiving November 23–28, fall classes ending December 2 with exams December 5–11, spring classes starting January 11, spring break March 13–20, and spring classes ending April 21. [UF 2026–2027 calendar](https://catalog.ufl.edu/UGRD/dates-deadlines/2026-2027/).

## Shared risk priorities

Severity/likelihood use 1–5 engineering ratings, not probabilities. Keep subsystem-specific risks in their research documents.

| Risk | Severity | Likelihood | Mitigation / warning |
|---|---:|---:|---|
| Timing closure | 5 | 3 | Early frontend/array synthesis and routed checks; warning: negative slack at 100 MHz |
| Resource overrun | 4 | 3 | Track physical BRAM, queues, CPU memory and lane count; warning: >80% of a resource family or failed bank fit |
| Model quality/preprocessing mismatch | 4 | 3 | Establish pinned host baseline before hardware comparison; warning: baseline below the stated floor or mismatched feature tensors |
| Operand/DDR stalls | 4 | 3 | Verify row-block delivery, Conv gather and DMA overlap; warning: input/dependency stalls dominate measured time |
| Ownership/cleanup/recovery fault | 5 | 3 | Commit-gated banks, explicit RECLAIM and recovery-generation tickets; warning: stale completion, altered guard bytes, or failed second run |
| Integration slips | 4 | 3 | M5 control-only tests and synthetic M6 before full models; warning: missing interface/fixture blocks the next owner |

Revisit ratings and targets using implementation evidence. None of these planning ratings establishes a measured failure rate.
