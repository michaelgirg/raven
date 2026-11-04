# RAVEN

**RISC-V-Controlled Programmable FPGA Neural Processing Unit**

RAVEN is a senior capstone project developing a programmable INT8 neural processing unit for the AMD/Avnet Ultra96-V2. A RISC-V soft processor will schedule neural-network operations on a shared compute engine, with DMA moving tensors between external LPDDR4 and on-chip BRAM.

The goal is to execute multiple supported model graphs using one FPGA bitstream and one runtime binary. Intended applications include audio anomaly detection, keyword spotting, and visual wake-word person detection, with inference performed locally on the board.

**Current status: standalone compute, memory-buffer and requantization/clamp RTL, plus a pre-alpha control block and a simulation top that connects control, compute, requantization and INT8 result storage.** One register-bus command runs one resident INT8 GEMM tile through to stored INT8 bytes, checked against the golden fixtures. In that integration test the command driver (standing in for the RISC-V) and the bank memories are simulation models. Physical memories, DMA, the RISC-V, full-system integration and FPGA measurements remain future work; the broader architecture below is a proposal. See [Control pre-alpha and integration](#control-pre-alpha-and-integration).


## Documentation and ownership

| Area | Owner | Research document |
|---|---|---|
| Compute architecture, MAC datapath, pipeline, and compute verification | Michael | [NPU compute architecture](docs/NPU_ARCHITECTURE.md) |
| Requantization, activation, pooling, element-wise Add, and operator verification | Quan | [NPU operators and datapath support](docs/NPU_Operators_Research.md); [requantization implementation](rtl/operators/README.md) |
| BRAM organization, memory interfaces, DMA, and memory verification | Taylor | [Memory-system research](docs/RAVEN_Memory_System_Research.md); [memory buffers](rtl/memory/README.md) |
| RISC-V integration, MMIO, control, and runtime | Nahjay | [RISC-V integration and runtime](docs/RISCV_Research.md) |
| Model analysis/export, tensor extraction, and golden-reference generation | Jackie | [Quantized-model research](docs/Quantized_Models.md); [golden fixtures and GEMM verification](evidence/prealpha/compute/README.md) |

The research documents describe broader proposed behavior and identify implemented subsets. The [shared interface contract](docs/interfaces/RAVEN_INTERFACE_CONTRACT.md) defines the operand, DMA, mailbox, constant-format, and recovery baseline. The [project plan](docs/PROJECT_PLAN.md) holds shared acceptance goals and milestones. Full-system implementation, FPGA timing, and model-quality evidence remain to be collected; standalone simulation instructions are linked below.

Use [docs/RAVEN_Memory_System_Research.md](docs/RAVEN_Memory_System_Research.md)
for the current memory proposal and [the revised draft sections](docs/drafts/RAVEN_Design_Draft_Revised_Memory_DMA_Sections.md)
for memory/DMA draft wording. Other research copies and existing Word/PDF exports
are review snapshots; their interface and capacity descriptions may be superseded.

## Current subsystem status and integration

| Area | Implemented and tested | Connection still needed |
|---|---|---|
| Compute — Michael | Resident INT8 GEMM microtile, INT32 output, reset/backpressure/error tests | Production operand responders, command control and output storage |
| Memory — Taylor | 128-byte activation buffer, eight-lane reads, standalone bench | Adapter/frontend agreement, weight/parameter storage, DMA and bank ownership |
| Operators — Quan | One-lane INT32-to-INT8 requantization/clamp, tags and elastic output, standalone bench | Channel mapping, per-channel parameter delivery and destination storage |
| Goldens — Jackie | Reproducible fixtures, byte comparator and three extra INT32 GEMM cases | Fixtures for overflow/bad-pitch errors (currently derived in the integration exporter) |
| Control — Nahjay | Register block, single-command FSM, NPU simulation top (control → compute → requant → INT8 writer), command driver and T1–T15 integration tests | AXI4-Lite/generated CSR, command queue, bank-state interlock, physical banks, RISC-V firmware |

Compute's operand frontend requests 128-bit words with bank-local byte offsets
and gathers lanes internally. The activation buffer instead returns eight bytes
for a four-bit K selector. These interfaces need an agreed adapter or frontend
change. Its active-high asynchronous reset must be coordinated with compute's
synchronous active-low reset; responders must flush stale replies on restart.

The compute result lane supplies data, row, column, index and last. The operator
tail also needs a channel tag and that channel's multiplier, shift, output
zero-point and clamp range. Channel/base mapping and parameter delivery remain
integration work. Backpressure must propagate through the tail, and system
completion must follow final output acceptance/storage. The pre-alpha
[integration top](#control-pre-alpha-and-integration) does this with simulation
bank models; no result through physical memories is claimed yet.

## Proposed system architecture

```mermaid
flowchart TB
    RV["RISC-V runtime"] -->|"AXI4-Lite"| CTRL["Command staging and queue"]
    CTRL --> MAC["INT8 Conv/GEMM MAC core"]
    CTRL --> OPS["Requantization and output operators"]
    RV -->|"Transfer control"| DMA["AXI DMA and stream adapter"]
    DDR["External LPDDR4"] <--> DMA
    DMA <--> SPAD["Banked BRAM scratchpad"]
    SPAD -->|"Activations and weights"| MAC
    MAC -->|"Completed INT32 results"| OPS
    MAC -->|"Non-final INT32 partial sums"| SPAD
    SPAD -->|"Standalone operator inputs"| OPS
    OPS -->|"INT8 results"| SPAD
```

The proposed compute core is a parameterized output-stationary array. Dense Conv2D maps onto the GEMM datapath through a window frontend; firmware schedules bank-fitting tiles and K-dimension chunks. Partial sums remain INT32 until the reduction finishes, with bias applied once. The proposed final K-chunk path reads an explicitly identified partial-sum context and writes INT8 results to a separate destination bank.

The RISC-V runs the layer schedule, programs transfers, and executes software fallback kernels. The ARM Cortex-A53 is assigned board boot and file staging in the baseline. Depthwise hardware remains an open decision; fallback time and transfers must be included in end-to-end results.

### Control and memory interfaces

The current register and command proposal is in [RISC-V research §§6–7](docs/RISCV_Research.md). It replaces the original `PARAM_DIM` and `ADDR_IN`/`ADDR_WEIGHT`/`ADDR_OUT` sketch. NPU commands use scratchpad bank/offset references; DDR addresses belong to the DMA interface.

Three blocks have separate responsibilities:

- **NPU control:** staging registers, a proposed four-entry command queue, operation fields, completion/error status, and performance counters.
- **AMD AXI DMA:** vendor MM2S/S2MM registers for DDR-to-stream and stream-to-DDR transfers.
- **RAVEN stream adapter:** proposed fill/drain registers, scratchpad selection, byte counts, and bank ownership.

GEMM A stays row-major: two local 8×16-byte buffers turn sequential 128-bit row reads into eight activation lanes. The proposed Conv path adds a bounds-checked window gatherer; it is not part of the current compute RTL.

Input ping-pong banks allow filling a FREE bank while another is in use. A received DMA packet stays DMA_FILLING until firmware checks successful MM2S completion and explicitly commits the bank to READY. Exact byte lengths and final byte masks support short model tensors. Typed READY/FULL rules govern source consumption; retained tensors and unfinished partial sums cannot be overwritten. A drained output bank is released after successful DMA and adapter completion. See the [memory proposal](docs/RAVEN_Memory_System_Research.md) for capacity, bandwidth, and ownership details.

## Compute implementation and tests

The demonstrated use case is **8×16 signed INT8 activations × 16×8 signed INT8
weights + bias → 8×8 signed INT32 results**. The implementation includes the MAC
datapath/array, pipeline, operand frontend, controller and compute verification.

| Design file | What it does |
|---|---|
| [raven_mac_pe.sv](rtl/compute/raven_mac_pe.sv) | Saves a signed INT8 product, adds it to an INT32 seeded sum, handles valid bubbles and detects signed overflow |
| [raven_mac_array.sv](rtl/compute/raven_mac_array.sv) | Connects the PEs into an output-stationary array with row/column broadcasts and masks |
| [raven_gemm_frontend.sv](rtl/compute/raven_gemm_frontend.sv) | Reads row-major A and packed B, buffers their words and pairs operands at the same K position |
| [raven_gemm_core.sv](rtl/compute/raven_gemm_core.sv) | Checks and saves a command, reads corrected bias, sequences the reduction and drains tagged INT32 outputs |

```mermaid
flowchart LR
    DRIVER["TB command driver"] --> CORE["GEMM controller"]
    MEMORY["TB A / B memories"] --> FRONT["Operand frontend"]
    PARAM["TB PARAM memory"] --> CORE
    CORE --> FRONT
    FRONT --> ARRAY["MAC array and pipelined PEs"]
    ARRAY --> CORE
    CORE --> CHECK["TB result consumer / independent scoreboard"]
```

The design top is `raven_gemm_core`. Default ROWS=COLS=8; each physical dimension
supports 1..8. A command is accepted on `cmd_valid_i && cmd_ready_o` and saves M,
N, K, A row pitch and A/B/PARAM starting offsets. M and N must fit the physical
array. There is one command in flight and one complete resident K reduction.

Three separate 128-bit memory request/response interfaces use valid/ready,
16-byte-aligned bank-local byte offsets (24 bits by default) and one outstanding
request per port. Hold a request address stable until it is accepted. The
responder must hold response valid/data until response-ready is asserted;
an early response cannot be a one-clock pulse that disappears before acceptance.
Transfers occur on a rising clock edge with both valid and ready high.
Responses are ordered, with no transaction IDs or memory-error sideband.
Default ACT/WGT/PARAM capacities are 16 KiB / 16 KiB / 4 KiB. A rows have a
16-byte-aligned pitch at least round_up(K,16). B always has eight physical
column lanes per K position. Each PARAM channel record is 16 bytes; compute
reads its signed corrected bias from bytes 0..3. All rounded physical reads
must fit their selected bank. Logical K padding is not accumulated.

The output is one signed INT32 valid/ready lane with row, column, logical
index `row*N+column` and last marker. Data and tags stay fixed during a stall.
Corrected bias is applied once:
`original_bias[j] - input_zero_point * sum(B[k,j])`. The Python reference
independently computes `original_bias[j] + sum((A[i,k]-input_zero_point)*B[k,j])`
with wide integers.

### Run the compute tests

Requires Python 3.9+ and a working Questa installation/license. Add your
simulator's executable directory to PATH, set QUESTA_BIN locally, or use
`--questa-bin "<your-questa-bin-directory>"`. No script assumes a personal
checkout or installation path. TensorFlow, NumPy, Make and a C++ toolchain are
not needed for these synthetic Questa tests.

```sh
python tests/rtl/compute/run_questa.py
python tests/rtl/compute/run_questa.py --demo-only
```

The runner finds the checkout from its own location. Generated fixtures,
libraries, transcripts and waveforms go into a fresh directory under
`build/tests/compute/questa/`; `latest.json` points to the report using a path
relative to its directory. A relative `--build` override is resolved from the
caller's working directory.

For the GUI, change to the generated run directory printed by the runner and
enter `do view_demo.do`. The demo prints the checked matrix and captures VCD/WLF
waveforms. The two testbenches and `sim_read_memory.sv` are under
`tests/rtl/compute/`; `generate_vectors.py` creates the independent fixtures,
and `run_questa.py` / `run_batch.do` enforce the run and failure checks.

Validation used **Questa Intel Starter FPGA Edition-64 2021.2**
with immediate and concurrent assertions enabled. The PE passed 65,536 signed
operand products plus seeded bubbles, both overflow directions, sticky overflow,
reinitialization and in-flight reset checks.
Each of 8×8, 4×4, 2×4 and 1×1 passed 42 fixtures and three reset/restart phases:
**168 fixtures and 12 reset/restart scenarios total**. The short demo checked
all 64 outputs. Separate intentional-failure checks confirmed assertion
execution and rejection of incomplete fixture manifests.

See the [combined execution log](evidence/questa/verification.log),
[source-hash/result report](evidence/questa/results.json),
[waveform preview](evidence/questa/demo_waveform.svg) and
[experiments, failures and difficulties](evidence/questa/experiments/README.md).
The experiment record links the actual failed attempts and their fixes.

### Known bugs, limitations and integration boundaries

No failing case remains in the executed supported suite. The testbench's
Questa declaration-initialization, fixture-name and incomplete-manifest issues
were fixed and are documented in the experiment record. The suite is not an
exhaustive proof of every possible sequence.

- One physical microtile per command, full resident K only and one result lane.
  Conv gathering, larger-tile traversal, saved-PSUM/K-chunk continuation,
  transpose/BLAS modes and four-lane output remain future work.
- The arithmetic uses raw signed INT8 operands, symmetric weights and corrected
  INT32 seeds. Any intermediate signed INT32 overflow rejects the tile after its
  reduction, without successful result beats. Export must validate seed/range
  compatibility. Codes: 0x00 success, 0x02 dimension/pitch, 0x03 alignment/span,
  0x08 accumulation overflow.
- Reset is synchronous active-low. Compute and memory responders must reset/flush
  together. Stale replies after an independent reset are unsupported.
- The core has no autonomous timeout/abort recovery. Missing memory responses or
  a permanently blocked consumer can stall it indefinitely. Simulation watchdogs
  do not implement an on-chip supervisor.
- `compute_done` follows the last product's commitment, including a reduction
  rejected for overflow. `result_done` follows INT32 acceptance or rejection.
  System retirement still requires actual downstream storage and successful
  bank transitions.
- The command driver, memory responders and scoreboard are simulation stand-ins.
  Teammates retain production responsibility for RISC-V/CSR, physical BRAM/DMA,
  requantization/INT8 storage and model export.
- No synthesis, DSP inference/resource measurement, routed timing, board test or
  full-model inference is claimed. The 10 ns simulation clock is stimulus.

## Control pre-alpha and integration

The pre-alpha control block accepts one command at a time over a small register bus,
validates it, launches it on the compute core and reports completion only after the INT8
results are stored. A simulation top connects control, Michael's unmodified GEMM core,
Quan's requantization/clamp block and an INT8 result writer. A testbench command driver
stands in for the RISC-V. The design decisions are in the
[control plan](docs/plans/nahjay_control_integration_prealpha.md).

| Design file | What it does |
|---|---|
| [raven_ctrl_pkg.sv](rtl/control/raven_ctrl_pkg.sv) | Register offsets, opcodes, flags, bank IDs, error codes and FSM state codes |
| [raven_ctrl_regs.sv](rtl/control/raven_ctrl_regs.sv) | Register bus with the [§6.2](docs/RISCV_Research.md) offsets: staging, RO/W1S/W1C behavior and the IRQ line |
| [raven_ctrl.sv](rtl/control/raven_ctrl.sv) | Snapshots staging on START, validates, issues one core command, retires, and keeps errors, sequence numbers and counters |
| [raven_requant.sv](rtl/top/raven_requant.sv) | Loads per-channel multiplier/shift PARAM records through a second PRM read port and feeds [raven_requantize_clamp](rtl/operators/raven_requantize_clamp.sv) |
| [raven_result_writer.sv](rtl/top/raven_result_writer.sv) | Turns INT8 results into byte-strobed OUT0 writes at `dst + row*pitch + col`, and reports when the last byte is stored |
| [raven_npu_top.sv](rtl/top/raven_npu_top.sv) | Connects the blocks and routes A to ACT0/ACT1 and B to WGT0/WGT1; every bank is a top-level port |

```mermaid
flowchart LR
    DRV["TB command driver (RISC-V stand-in)"] -->|"register bus"| REGS["Register block"]
    REGS <--> CTRL["Control FSM"]
    CTRL -->|"one command"| CORE["GEMM core"]
    ACT["TB ACT0 / ACT1"] --> CORE
    WGT["TB WGT0 / WGT1"] --> CORE
    PRM["TB PRM (two read ports)"] --> CORE
    PRM --> RQ
    CORE -->|"INT32"| RQ["PARAM loader + requant/clamp"]
    RQ -->|"INT8"| WR["Result writer"]
    WR --> OUT["TB OUT0"]
    WR -->|"last byte stored"| CTRL
```

Implemented behavior:

- Opcodes `0x00 NOP` and `0x02 GEMM` (one resident tile, M and N ≤ 8, full K, flags
  `ACC_INIT|ACC_LAST|REQUANT_EN`, optional `RELU_EN` and `PER_CHANNEL`). Any other opcode
  is `ERR_ILLEGAL_OP`.
- Before launch, control checks reserved bits, flags, bank IDs and types, dimensions and the
  destination span, and reports the first failure with ERR_INFO set to the offending
  register's offset. A rejected command never reaches the core. The core's own pitch, span
  and overflow errors (0x02, 0x03, 0x08) pass through with ERR_INFO 0.
- The independent requant PARAM loader waits until the core begins its first validated
  bias read. Commands rejected during validation issue no operand or parameter reads.
- A command retires only after the core has finished without error **and** the last INT8
  byte has been accepted by OUT0. DONE_SEQ, CMD_COUNT and IRQ DONE update then.
- Any error halts the FSM. CLEAR_ERR clears the diagnostics; only SOFT_RESET returns to
  IDLE. SOFT_RESET also resets the datapath and the bank ports through `local_rst_no`.

Differences from the full [§5–§6 control design](docs/RISCV_Research.md):

- A plain register bus instead of AXI4-Lite and the generated CSR. The offsets and field
  layouts are the same.
- Queue depth 1, so `STATUS.Q_FULL` is set while a command is active. FETCH and WAIT_DEP
  are never entered.
- No bank states. RELEASE flags are accepted and ignored. OUT1 is absent.
- ABORT and ZERO_LOCAL are ignored, and QUIESCENT reads as `!BUSY`.
- START while busy latches ERR_Q_OVERFLOW at once. The in-flight command still finishes
  and retires, and the FSM then halts.
- OUT0 is taken as 8 KiB, the contract's lower bound.

### Run the integration tests

```sh
python tests/rtl/integration/run_questa.py
python tests/rtl/integration/run_questa.py --tests T1,T4
```

Questa is located the same way as for the compute runner (`--questa-bin`, QUESTA_BIN or
PATH). The runner checks that immediate and concurrent assertions execute, compiles the
compute, control, operator and top RTL with the integration testbench, exports fixtures
from `tests/vectors/prealpha/`, and runs T1–T15. It then checks every dumped INT8 result
again with `tools/goldens/compare_prealpha.py`. Output goes to a fresh directory under
`build/tests/integration/questa/`. `--no-sva-guard` runs on a simulator without
concurrent assertions (for example ModelSim Intel FPGA Edition) and marks the report
`"sva_checked": false`. Such a run is not acceptance evidence.

The tests are T1 reset values, T2 register access, T3 NOP, T4 the six valid fixtures back
to back, T5 shared multiplier/shift, T6 padded output pitch, T7 bank routing, T8 random
memory and write stalls on every valid case, T9 zero K, T10 ten control-detected errors,
T11 core-detected errors including PARAM alignment/span, T12 START while busy,
T13 halted behavior, T14 hardware and soft reset during RUN and DRAIN, and T15 staging
rewrites during a run. Every valid result is
compared byte for byte, and every other OUT0 byte must still hold its 0xA5 guard value.

**Verification status:** all 15 tests pass with Questa Intel Starter FPGA Edition-64
2021.2 and both assertion guards enabled: **49 PASS records, 698 checks and 20 independent
INT8 comparisons**. The full runner also checks `COLS=1` reset/NOP operation (43 checks).
See the [source-hash/result report](evidence/questa/integration/results.json),
[combined execution log](evidence/questa/integration/verification.log) and
[validation fixes](docs/plans/nahjay_control_integration_prealpha.md#licensed-questa-validation).

### Control limitations

- Everything listed as out of scope in the [plan](docs/plans/nahjay_control_integration_prealpha.md#9-out-of-scope-document-as-known-limitations):
  the command queue, the bank-state interlock, ABORT/ZERO_LOCAL, AXI4-Lite, multi-tile and
  K-chunk commands, DMA, the RISC-V and firmware, synthesis and timing.
- The bank models are testbench stand-ins. Taylor's buffers use asynchronous active-high
  reset and smaller row-based ports, so they are not connected yet.
- The core has no timeout, so a memory that never responds hangs the command until
  SOFT_RESET.
- Control does not range-check Q_SHIFT or Q_MULT. Values outside the TFLM range
  (`-31 ≤ shift ≤ 30`, multiplier ≥ 0) are caught only by a simulation assertion in
  `raven_requant`.

## Initial design targets

| Parameter | Proposed target |
|---|---|
| FPGA platform | Ultra96-V2, Zynq UltraScale+ MPSoC ZU3EG |
| Control processor | RISC-V soft processor; MicroBlaze V proposed, pending integration review |
| Initial compute array | 8×8, or 64 scalar MACs; larger configurations evaluated later |
| Numerical formats | Signed INT8 activations/weights; architectural INT32 accumulation with validated ranges |
| Clock and timing | At least 100 MHz; non-negative routed timing slack |
| Result interface | One lane for functional bring-up; four lanes as an evaluation configuration; target II=1 |
| Control interface | 32-bit MMIO over AXI4-Lite |
| DMA path | Proposed 128-bit memory-mapped and stream paths at nominal 100 MHz, subject to connectivity and timing |
| Base logical scratchpad allocation | 74–88 KiB |
| Additional parameter/output storage | +4 KiB PRM; optional +8–16 KiB OUT1; total 86–108 KiB with both |
| FPGA resource use | Original planning target below approximately 80%; verify each resource in synthesis/implementation |
| Operator/model goals | Six NPU operators and three selected models, subject to team acceptance decisions |

At 100 MHz and full occupancy, 64 MACs yield a theoretical ceiling of **6.4 GMAC/s**, or **12.8 GOPS** when multiplication and addition count separately. A 128-bit interface at that clock has an ideal payload ceiling of **1.6 GB/s per direction**. Neither figure establishes achieved performance. Utilization, pipeline/drain overhead, local-memory ports, DMA, and fallback work all affect results.

Scratchpad figures are logical allocations, not measured physical BRAM use; the parameter bank and OUT1 are additions to the base budget. See [compute estimates](docs/NPU_ARCHITECTURE.md) and [memory estimates](docs/RAVEN_Memory_System_Research.md) for assumptions.

## Proposed operator set

| Opcode | Operation | Planned role |
|---|---|---|
| `0x01` | Conv2D | Dense and pointwise convolution using the shared compute core |
| `0x02` | GEMM | Matrix multiplication and fully connected layers |
| `0x03` | ReLU | Standalone activation; also fused after final requantization |
| `0x04` | Pooling | Average pool first; max pool as an extension |
| `0x05` | Requantization | INT32-to-INT8 scaling/clamping, standalone or fused after a completed reduction |
| `0x06` | Element-wise Add (EWADD) | Quantized residual addition with input/output rescaling |
| `0x07` | Depthwise Conv | Reserved; hardware mapping undecided, initial RISC-V fallback |

The six-operator goal covers `0x01`–`0x06`; the reserved depthwise opcode does not count as implemented support. Pooling and EWADD follow the initial FC/Conv bring-up. Softmax and metadata operations such as reshape belong to the runtime plan.

Exact arithmetic and field definitions are in the [operator proposal](docs/NPU_Operators_Research.md) and [control proposal](docs/RISCV_Research.md), including the proposed pinned TFLM integer reference, EWADD pre-shift, and widened POOL stride fields.

## Candidate models

| Model | Application | Proposed use |
|---|---|---|
| Deep Autoencoder (AD01) | Audio anomaly detection | First integration candidate: fully connected layers, requantization, and fused ReLU |
| DS-CNN | Keyword spotting | Candidate after AD01; requires depthwise execution and average pooling |
| MobileNetV1 0.25x | Visual wake-word person detection | Third candidate; depthwise fallback and feature-map tiling need measurement |
| ResNet-8 | Image classification | Alternative/extension requiring residual Add |
| Streaming DS-CNN | Streaming wake-word detection | Alternative/extension requiring depthwise execution |

Model files are present under [models/](models/). The [model inventory](docs/Quantized_Models.md) records source provenance, tensor shapes, operator counts, quantization, and parameter storage. The proposed first three are AD01, DS-CNN, and MobileNetV1; their inclusion here does not indicate working FPGA inference.

## Planned deployment and verification

The deployment toolchain will inspect supported graphs, retain original CPU/reference weights and bias, add separately referenced packed NPU weights/corrected-bias records, prepare integer quantization parameters, plan storage/tiling, and generate golden tensors. Tensor scale bits are preserved separately from execution multipliers. The runtime proposal starts with generated C layer tables and progresses to a validated data-driven model blob, allowing model changes without rebuilding the runtime.

Proposed driver entry points include `raven_dma_transfer()`, `raven_set_op()`, and `raven_start()`; these APIs are documented plans, not available code in this checkout.

Verification will compare integer outputs against the agreed reference at PE, tile, operator, layer, and model levels. Tests must cover edge tiles, K-chunk continuation, bias applied once, zero-points, rounding/clamping, backpressure, bank ownership, DMA integrity, and error recovery. Proposed numerical, model-quality and latency targets are in the [shared acceptance table](docs/PROJECT_PLAN.md#functional-and-model-acceptance); they still require measurement against pinned evaluation pipelines.

Benchmarks will report inference latency, useful MAC activity, input/output stalls, transfer bandwidth, FPGA resources, timing, and power where measured. Reports must include CPU fallback and data movement, and distinguish analytical ceilings from measured results.

## Development roadmap

| Phase | Intended outcome |
|---|---|
| Architecture and requirements | Review subsystem contracts, core/tool choices, operator scope, model candidates, and acceptance criteria |
| Independent subsystem development | Implement and verify compute, output operators, memory/DMA, control/runtime, and model tooling |
| First integration | Run synthetic GEMM/Conv workloads across the integrated control, compute, and memory paths |
| Real-model execution | Bring up AD01, then evaluate additional models and fallback costs against golden references |
| Beta | Demonstrate the agreed core features and selected models; collect baseline measurements |
| Optimization and handoff | Improve bottlenecks, complete verification, document limits, and test reproducible setup |

Use the [project milestones and acceptance table](docs/PROJECT_PLAN.md) for shared planning and acceptance criteria.

## Planned deliverables and limitations

Planned deliverables are an Ultra96-V2 prototype, SystemVerilog RTL, RISC-V firmware/drivers, model deployment tools, verification assets, benchmark reports, and architecture/interface/build documentation. The handoff proposal includes a tagged release, tested dependency versions, known-input examples, troubleshooting notes, and reproduction by someone other than the author.

FPGA resources, memory ports/bandwidth, timing closure, unsupported operators, quantization behavior, and integration complexity constrain the design. RISC-V fallbacks prioritize correctness and can dominate latency. Final model support, accuracy, throughput, power, and maintainability must be demonstrated through implementation and documented acceptance checks.

## Repository structure

```text
raven/
├── .github/            # Future CI workflow definitions
├── configs/            # Future design, model-export, and simulation presets
├── data/               # Local raw/processed datasets; contents ignored by Git
├── docs/               # Research, decisions, interface contracts, diagrams, and guides
├── evidence/           # Simulation results, verification notes and screenshots
├── rtl/                # Compute, memory buffers, INT8 tail, pre-alpha control and NPU top
├── hw/                 # Future Vivado Tcl, constraints, and IP configuration
├── software/           # Future firmware, runtime, drivers, HAL, and host tests
├── tools/              # Golden-fixture tools; future model export and register generation
├── tests/              # Standalone RTL tests, goldens and the pre-alpha integration test
├── benchmarks/         # Future workload definitions and measured result summaries
├── models/             # Five original candidate quantized TFLite models
├── third_party/        # Future explicitly vendored upstream dependencies
├── .gitignore
└── README.md
```

See the [full directory map and ownership guide](docs/REPOSITORY_STRUCTURE.md) for where each teammate's work belongs. Area READMEs describe current implementations and planned work; [automation notes](.github/AUTOMATION.md) cover future CI. `.gitkeep` files retain empty implementation folders in Git. The command queue, runtime, physical memory/DMA and full-system integration remain future work.

Generated products belong under the Git-ignored `build/` directory. See the compute run instructions in this README; additional build instructions will accompany their corresponding implementations.
