# RAVEN Memory-System Research

**Status:** Initial research and proposed architecture; RTL implementation has not started.  
**Owner:** Taylor — BRAM organization, memory interfaces, DMA, and memory verification.  
**Target:** AMD/Avnet Ultra96-V2 (Zynq UltraScale+ MPSoC ZU3EG).  

Ultra96-V2 memory resources, DDR/AXI paths, DMA, tiling, and double buffering

*Much information in this doc was used to refine the Design Draft*

*Also important distinction after updating: the new BRAM bandwidth figures are theoretical compute-facing requirements, not measured DDR bandwidth. Likewise, the proposed banking arrangement and memory totals still need synthesis and team review before they can be treated as final*

**Shared definitions:** the [interface contract](interfaces/RAVEN_INTERFACE_CONTRACT.md) selects the baseline ports, DMA packets/commit, ACT destination capability, and recovery. The [project plan](PROJECT_PLAN.md) holds master dates and model targets. The definitions below are proposed behavior, not implemented hardware.

## Summary

RAVEN is a RISC-V-controlled programmable FPGA NPU intended to execute multiple quantized neural-network models on the Ultra96-V2. The feedback document makes the memory subsystem more concrete: it calls for measurable acceptance criteria for DMA, explicit DMA control/interface documentation, defined register fields and completion behavior, and subsystem ownership. It also proposes an 8×8 array of 64 INT8 MAC units with INT32 accumulation and a minimum 100 MHz target. These are design targets, not verified implementation results.

Recommended baseline: keep model tensors in the board’s external LPDDR4; stage active tiles in BRAM; use AMD AXI DMA for DDR-to-stream and stream-to-DDR transfers; begin with 128-bit memory-mapped and stream paths at a nominal 100 MHz where the implemented PS–PL path supports them; use separate activation and weight ping-pong buffers; and retain partial sums on-chip until an output tile is complete. Start in direct-register DMA mode for bring-up, then evaluate scatter-gather if descriptor overhead or queued transfers become important.

## 1. Scope and evidence labels

This report distinguishes (A) board/vendor facts, (B) requirements or proposals already present in the RAVEN draft/feedback, and (C) engineering recommendations that require team approval and implementation testing. No sustained bandwidth, final buffer fit, or inference performance is claimed without measurement.

## 2. Ultra96-V2 memory resources

The Ultra96-V2 uses the Zynq UltraScale+ MPSoC ZU3EG and has 2 GB of LPDDR4 RAM. The ZU3EG programmable logic is listed with 216 36-Kibit block-RAM primitives: 972 KiB of raw bit capacity including parity positions, or 864 KiB of ordinary data capacity when mapped as 1,024×32 data bits per primitive, 1.8 Mbit of distributed RAM, and no UltraRAM blocks. Primitive configuration affects usable payload; see [AMD UG573](https://docs.amd.com/r/en-US/ug573-ultrascale-memory-resources/Read-Width-READ_WIDTH_-A-B). These are device-level totals; they are not all available to RAVEN because the design also consumes LUTs, registers, BRAMs, and ports for compute, FIFOs, control, and integration. [1, 2]

| Resource | Use in RAVEN | Caveat |
| --- | --- | --- |
| 2 GB LPDDR4 (external DDR) | Full model weights, full feature maps, large intermediate tensors, input/output tensors | Capacity is large relative to scratchpad; sustained throughput depends on PS–PL path and arbitration. |
| Block RAM (BRAM) | Explicit local activation, weight, output and partial-sum buffers | Finite physical blocks/ports; measure actual inferred BRAM and port conflicts after synthesis. |
| Distributed RAM (LUTRAM) | Small FIFOs, lookup tables, flags and small tables | Consumes LUT resources that may otherwise support logic. |
| UltraRAM | Do not budget for it | ZU3EG listing reports zero UltraRAM blocks. |

## 3. DDR and AXI path proposal

Use three logically separate interfaces. AXI4-Lite carries low-bandwidth control and status; AXI4 memory-mapped carries DDR bursts; AXI4-Stream carries payloads between DMA and the NPU-side stream adapter. AMD AXI DMA provides MM2S (memory-mapped to stream) and S2MM (stream to memory-mapped) channels that operate independently, and its control/status registers are accessed through AXI4-Lite. [3]

1. RISC-V runtime writes NPU configuration and DMA control/status registers through AXI4-Lite.

1. AXI DMA MM2S reads model/input bytes from DDR through a configured Zynq PS–PL AXI path and streams them to a stream-to-scratchpad adapter.

1. The adapter writes the tile into a selected BRAM bank and keeps that bank DMA_FILLING after packet validation; firmware marks it READY with COMMIT_FILL only after successful MM2S completion as well.

1. The NPU consumes READY activation/weight tiles and writes results into output/accumulator storage.

1. When output data must leave the FPGA, a scratchpad reader feeds an AXI4-Stream sink connected to S2MM, which writes the results back to DDR.

Important integration point: AXI DMA stream ports do not by themselves define a BRAM address/write controller. RAVEN must implement and verify the stream-to-BRAM writer and BRAM-to-stream reader, or choose an equivalent adapter. The selected PS–PL route (for example, an HP port for noncoherent PL access) must be recorded in the Vivado block design. Zynq UltraScale+ offers HP and HPC interfaces with 32-, 64-, or 128-bit widths; HP is noncoherent and HPC supports I/O coherency features. The right choice depends on whether the RISC-V software runs bare-metal or under an OS and how DDR buffers are cached. [4]

## 4. DMA options and tentative configuration

| Setting | Initial proposal | Reason / validation |
| --- | --- | --- |
| DMA IP | AMD AXI DMA | Matches DDR ↔ AXI4-Stream dataflow; standard IP reduces custom-engine scope. [3] |
| Memory-mapped width | 128 bits preferred; 64-bit fallback | At 100 MHz, theoretical one-beat-per-cycle payload ceiling is 1.6 GB/s at 128 bits and 0.8 GB/s at 64 bits. |
| Stream width | 128 bits initially, if adapter/NPU supports it | 16 INT8 values per full beat; add unpacking/lane distribution if compute interface differs. |
| Control | AXI4-Lite, 32-bit register accesses | Keep register access out of the high-volume tensor path. |
| Mode | Direct-register mode; Micro DMA disabled; DRE disabled; length width explicitly 23 | Direct mode is simpler and lower resource; scatter-gather queues descriptors and offloads CPU work. [3] |
| Burst | Start with up to 16 beats, then measure | Candidate setting only; validate IP limits, 4 KiB boundaries, timing, and PS–PL path. |
| Alignment | 16-byte-aligned addresses/starts; exact nonmultiple byte lengths supported | Final TKEEP/TLAST and valid-byte writes follow the shared packet contract; storage padding is separate from transfer length. |

Bandwidth arithmetic: bytes/cycle = width/8. At 100 MHz, 64 bits gives 8 × 100 million = 0.8 GB/s; 128 bits gives 16 × 100 million = 1.6 GB/s. These are theoretical interface ceilings, not measured DDR throughput. Read and write channels may be independent, but they still contend for DDR and interconnect resources.

See the [DMA packet contract](interfaces/RAVEN_INTERFACE_CONTRACT.md#2-dma-packets-and-bank-commit): 2/12/490-byte packets use final TKEEP 0x0003/0x0FFF/0x03FF. Invalid lanes are not written. COMMIT_FILL is ADP_CTRL[4], AWAIT_COMMIT is ADP_STATUS[3], and FILL_BUSY remains asserted through commit. Check availability before modifying active configuration. Baseline FILL_SEGS=1; segmented fills remain disabled.

## 5. Scratchpad organization

The current logical scratchpad allocation from the four original rows is **74–88 KiB**, not 58–72 KiB. Keep Nahjay’s proposed parameter bank and the optional second output bank separate in the budget rather than silently folding them into the base total. These are logical capacities; physical BRAM use must be checked after synthesis because width, depth, banking, and port requirements affect primitive packing.

### 5.1 Base allocation and additions

| Logical buffer | Proposed capacity | Role / status |
| --- | ---: | --- |
| Activation banks `ACT0` / `ACT1` | 2 × 16 KiB = 32 KiB | Current activation tile and next tile; ping-pong input banks |
| Weight banks `WGT0` / `WGT1` | 2 × 16 KiB = 32 KiB | Current weight tile and next tile; may retain weights across multiple commands |
| Output / partial-sum bank `OUT0` | 8–16 KiB | INT8 output or INT32 partial sums; dimensions and coexistence requirements need agreement |
| FIFO / control allowance | 2–8 KiB | Stream elasticity, metadata, state and small queues; validate what must actually use BRAM |
| **Base logical total** | **74–88 KiB** | Sum of the four rows above |
| Nahjay-proposed parameter bank `PRM` | **+4 KiB** | Proposed additional bank for per-output bias and optional per-channel requantization records; bias is required even with a shared requant scale. Not included in the base total; pending team/Quan review |
| Optional second output bank `OUT1` | **+8–16 KiB** | Optional output ping-pong bank, if synthesis and the final output/partial-sum lifecycle permit it |
| **Total with `PRM`, without `OUT1`** | **78–92 KiB** | Base + proposed parameter bank |
| **Total with `PRM` and `OUT1`** | **86–108 KiB** | Base + parameter bank + optional second output bank |

Nahjay’s RISC-V/control proposal assigns bank IDs `ACT0=0`, `ACT1=1`, `WGT0=2`, `WGT1=3`, `OUT0=4`, optional `OUT1=5`, and proposed `PRM=6`; see `RISCV_Research.md` §6.4. The PRM record layout and exact output-bank configuration remain proposed and require review by the compute/output owners. Do not treat these estimates as a synthesis result.

### 5.2 Compute-facing BRAM bandwidth (separate from DMA bandwidth)

The proposed 8×8 MAC array needs **eight INT8 activation bytes and eight INT8 weight bytes simultaneously on every active compute cycle**: 8 bytes/cycle from the activation operand path and 8 bytes/cycle from the weight operand path. At 100 MHz, that is 0.8 GB/s of activation data plus 0.8 GB/s of weight data at the compute-facing interface, or 1.6 GB/s combined when both streams are active. This is a local BRAM-to-compute requirement, not the same thing as the AXI DMA’s DDR-to-stream width or bandwidth.

**Selected logical port/frontend proposal:** provide a 128-bit synchronous ACT read port with explicit request/response valid/ready, ordered responses, documented latency, and pipelined-request capacity. Michael uses two local 8×16-byte buffers (256 bytes excluding metadata) to fetch one word from each valid row of a row-major GEMM tile and emit eight row values at one K index per accepted compute cycle. A double-buffered block can overlap eight row-word reads with sixteen full-block issue steps. This is an analytical opportunity, not a timing result. WGT exposes a logical 128-bit read port feeding two packed 64-bit B vectors per word. Physical BRAM primitives and inferred ports must be checked by synthesis.

The [shared port/address contract](interfaces/RAVEN_INTERFACE_CONTRACT.md#1-operand-and-result-delivery) defines padded read bounds, lane masks, and ownership. Conv retains NHWC with Michael's bounds-checked window gatherer; its fragmented accesses can refill more slowly. The DMA beat width does not establish Conv gathering bandwidth. Account for the compute-local buffers separately from the scratchpad allocation.

The one-lane result writer is proposed to use byte enables for OUT or ACT destinations under exclusive ownership. Advertise ACT writes with HW_FEATURES[2], reserve the destination before prefetch, and reject unsupported plans. RESULT_LANES=4 needs its own verified port/write-combining arrangement.

Use INT8 storage for quantized activations and weights, but wider accumulators. INT32 is the proposed accumulation format. Keep partial sums on-chip across reduction-dimension chunks when possible; repeatedly writing partial sums to DDR wastes bandwidth. Separate logical buffers even if synthesis packs them into fewer physical memories.

## 6. Tiling proposal

For a first GEMM validation, use C[M×N] = A[M×K] × B[K×N] with candidate tile sizes Mₜ=32, Nₜ=32, Kₜ=64. This is a memory/dataflow test point, not a claim that the proposed 8×8 MAC array computes a 32×32 tile in one cycle.

| Tile object | Calculation | Storage |
| --- | --- | --- |
| A tile | 32 × 64 INT8 | 2,048 bytes |
| B tile | 64 × 32 INT8 | 2,048 bytes |
| C accumulator tile | 32 × 32 × INT32 | 4,096 bytes |
| Total active tile set | 2,048 + 2,048 + 4,096 | 8 KiB, excluding bias, output staging and metadata |

Tiling rules: reuse each weight tile across multiple output positions; reuse activation tiles across output channels; keep accumulators local across K chunks; write quantized outputs only when needed; and support partial edge tiles. For convolution, consider line/window buffering to reuse overlapping activation windows. Tune tile dimensions against the actual MAC-array shape, local-memory ports, and selected models.

## 7. Double buffering and control protocol

Use ping-pong activation and weight banks. While the NPU computes from one bank, DMA may fill a different bank that is `FREE`. Input/weight banks that are retained after a command may return to `READY` for reuse; they do **not** automatically become `FREE` merely because a compute command finished. The command’s `RELEASE_A`, `RELEASE_B`, or `RELEASE_PARAM` policy (proposed in Nahjay’s `RISCV_Research.md` §6.7) determines when a retained source bank can be released for a new DMA fill. A fill must never overwrite a bank in `READY`, `COMPUTING`, `FULL`, or another owned state.

Output and partial-sum banks have a distinct lifecycle from input banks. A destination being written by compute is `NPU_WRITING`; a completed INT8 output becomes `FULL` and can be drained or consumed by an allowed output operator. A non-final K chunk may leave INT32 partial sums in `READY` with a PSUM tag, where the next chunk continues accumulation.

A continuation explicitly names PSUM_SRC and PSUM_PITCH, validated against saved offset/shape/pitch/bias-applied metadata. Middle chunks update that INT32 context in place. The final chunk holds the context while writing INT8 to a distinct FREE destination bank; after all output writes finish, the old context is invalidated/released to FREE and the new destination becomes FULL. A separate region in the same bank is not the baseline because ownership is bank-level. Without OUT1, a reserved FREE ACT bank is usable only if the implemented compute write path supports it; otherwise reject the plan. Final in-place narrowing remains deferred.

Optional `OUT1` can enable output double buffering but increases the capacity budget by 8–16 KiB. See Nahjay’s proposed partial-sum and bank protocol in `RISCV_Research.md` §§6.6–6.7; final ownership and state transitions need team agreement.

| State / event | Meaning | Proposed transition / rule |
| --- | --- | --- |
| `FREE` | Bank available for a new transfer or initial output | A DMA fill may move it to `DMA_FILLING`; a compute destination may be claimed under the agreed output protocol |
| `DMA_FILLING` | Adapter/DMA owns the fill bank, including its awaiting-commit phase | Packet-valid FILL_DONE alone does not release it; successful MM2S plus COMMIT_FILL makes READY. Any error quarantines it as ERROR. |
| `READY` | Complete input/weight tile, retained bank, or tagged INT32 partial sum | Can be consumed by compute; retained inputs may return to `READY` after use, and PSUM remains `READY` between K chunks |
| `COMPUTING` | NPU is consuming a source bank | Retained READY inputs return to READY; retained FULL INT8 outputs return to FULL. Explicit release frees a source; final PSUM consumption releases it only after destination writes finish (§6.6 of the control document). |
| `NPU_WRITING` | Compute/operator is writing a destination | INT32 intermediate partial sum returns to `READY` + PSUM tag; completed INT8 output becomes `FULL` |
| `FULL` | Completed INT8 output tile | May be drained or consumed by an allowed output operator; becomes `FREE` only after drain/release or explicit ownership release |
| `DRAINING` | Adapter owns output while supplying S2MM | Conservative proposal: hold ownership until expected bytes/TLAST are valid and AXI DMA reports successful S2MM completion; firmware then uses BANK_RELEASE to return FREE |
| `ERROR` | Transfer, length, range, or protocol fault | Recover/reset and release only through the agreed error-recovery path |

DMA completion and compute completion are separate events. For a fill, FILL_DONE means the expected valid bytes and final TLAST were received; the bank stays DMA_FILLING/AWAIT_COMMIT until firmware checks successful MM2S completion and writes COMMIT_FILL. This prevents a queued consumer from reading a packet whose DMA later reports failure. For a drain, adapter stream completion means the requested bytes were emitted with valid TLAST; it does not establish DDR completion. Keep the bank DRAINING until both completions are checked; firmware then writes BANK_RELEASE, as in Nahjay's §7.3. An error follows recovery rather than silently freeing the bank.

**Register-map source of truth:** use Nahjay’s proposed driver-side register reference in `RISCV_Research.md` §7.1 (AMD AXI DMA PG021 direct-register registers) and §7.2 (RAVEN adapter/bank CSR, proposed base `ADP_BASE = 0xA002_0000`) rather than inventing a second adapter map in this document. Treat adapter offsets/fields as proposals until Taylor and Nahjay agree and the RTL/driver definitions are generated or verified together. AMD AXI DMA’s vendor register map is separate from the RAVEN adapter CSR.

**Result write path (proposed).** Share RESULT_LANES with Michael and Quan: one lane for functional bring-up, four for evaluation, target II=1. This implies up to 1 or 4 INT8 result bytes/cycle, while non-final INT32 context writes require 4 or 16 bytes/cycle. Validate actual BRAM packing, port conflicts, parameter reads, lane masks/tags, and backpressure before selecting four lanes; the capacity totals above do not prove that bandwidth. Both configurations must preserve data and metadata on stalls.

## 8. Rough bandwidth and performance model

The feedback document proposes 64 INT8 MAC units (8×8), INT32 accumulation and a minimum 100 MHz clock. If each unit completes one MAC per cycle, the arithmetic ceiling is 64 × 100 MHz = 6.4 GMAC/s (12.8 GOPS if multiply and add count as two operations). This is a theoretical ceiling, not expected sustained throughput.

A deliberately pessimistic no-reuse case that fetches a new INT8 activation and a new INT8 weight for every MAC would demand about 12.8 GB/s at 6.4 GMAC/s—well above the 128-bit/100 MHz interface ceiling. This illustrates why tiling and operand reuse are essential; it is not a prediction of actual DDR traffic.

Measure required bandwidth from real transfers: (DDR bytes read + DDR bytes written) / inference time. Count input activations, weights, intermediate writes, and output writes separately. Benchmark sequential DMA transfers at multiple sizes, then benchmark full layers and models. Record achieved throughput, average/maximum transfer latency, NPU stall cycles, BRAM usage, timing slack, and inference latency. Avoid asserting a sustained-bandwidth percentage before measurement.

## 9. Verification and acceptance criteria

- DMA integrity: exact round trips for lengths 1/2/3/10/12/15/16/17/490 and each bank's supported boundaries, with final masks, byte counts, guard bytes, and backpressure. Successful lengths cannot exceed capacity minus offset; PRM is 4 KiB. Zero length is a no-op. Reject oversized/unaligned requests before programming DMA. Test adapter completion before MM2S success/error and require commit before READY.

- Boundary safety: test normal AXI DMA transfers crossing 4 KiB boundaries with the chosen configuration, and validate wide-read/padded storage bounds. Micro DMA is disabled; do not apply its limitations to the baseline.

- Buffer protocol: assertions/testbench prove DMA fills claim only FREE banks and NPU reads obey the opcode-specific READY/FULL tensor-type rules. Test retained FULL sources returning to FULL, unfinished PSUM rejection by standalone operators, explicit continuation source/pitch validation, distinct final-output ownership, and DRAINING retention until successful S2MM completion.

- Functional correctness: tiled GEMM/Conv output matches an integer golden reference across full and edge tiles.

- Overlap: test demonstrates DMA transfer of tile n+1 overlaps compute of tile n without corrupting data; report measured overlap rather than claiming it.

- Performance: publish measured DDR read/write throughput, transfer sizes, clock rates, DMA mode, PS–PL port configuration and competing traffic.

- Implementation: record BRAM/LUT/DSP usage and timing slack from Vivado reports; ensure the agreed clock target is met.

## 10. Risks and decisions still open

Severity and likelihood use a proposed 1–5 scale (5 = highest severity / most likely). These are initial engineering judgments for prioritization, not measured probabilities; revise them after the first synthesis and integration tests.

| Risk | Severity (1–5) | Likelihood (1–5) | Mitigation / evidence to collect |
| --- | ---: | ---: | --- |
| Compute-facing bandwidth stalls: BRAM cannot deliver 8 activation bytes + 8 weight bytes each active cycle | 5 | 3 | Agree the compute-facing word/lane contract with Michael; evaluate banking/wide-word/replication options; measure operand-stall cycles and post-route timing. |
| BRAM port conflicts or bank mapping cannot sustain simultaneous reads/writes | 4 | 3 | Specify per-bank read/write ownership and ports; test representative access patterns; inspect inferred RAM and utilization reports; add assertions for conflicting owners. |
| Scratchpad capacity underestimated, especially with the 4 KiB `PRM` bank and optional 8–16 KiB `OUT1` | 4 | 3 | Track base 74–88 KiB, +4 KiB PRM, and optional +8–16 KiB OUT1 separately; synthesize candidate layouts and record physical BRAM usage. |
| DMA/adapter transfer length, final-beat, or `TLAST` mismatch | 4 | 3 | Reference Nahjay’s adapter proposal (§7.2 in `RISCV_Research.md`); verify exact byte count, `TLAST`, backpressure, and error status with aligned, tail, and malformed-length tests. |
| Buffer ownership/state error: DMA overwrites an input still retained by compute, or output/PSUM bank is reused too early | 5 | 3 | Align with Nahjay’s `READY` retention, explicit release, `FULL` output and PSUM lifecycle; add assertions and stress tests with overlapped transfers/compute/drains. |
| Packed operand layout or convolution tile preparation is ambiguous across owners | 4 | 4 | Record the agreed layout, pitches, alignment, and responsible frontend/tool owner before freezing adapter interfaces; keep unresolved choices explicitly proposed/TBD. |
| PS–PL connectivity/cache policy causes stale or contended DDR data | 4 | 2 | Select the HP/HPC route and document cache/coherency handling; benchmark concurrent read/write traffic. |
| DMA mode/register configuration differs from software assumptions | 3 | 3 | Pin the AXI DMA IP version/configuration; use PG021 for vendor registers and Nahjay’s §7.2 only for RAVEN adapter CSRs; test direct-register completion and errors. |

### Implementation evidence still needed

- Synthesize the selected logical 128-bit read ports and row-block frontend; record latency, request capacity, physical primitive use, and routed timing.
- Verify Conv window gathering, B-panel pitch, tails, and one-lane byte-masked writes to advertised destinations.
- Verify commit-gated READY, retained typed sources, PSUM continuation, and quiescence before recovery releases banks.
- Generate/verify the adapter map with Nahjay, including COMMIT_FILL/AWAIT_COMMIT and the disabled segmented-fill extension.
- Measure overlap and stalls; use the [project dates and targets](PROJECT_PLAN.md) rather than a second memory-subsystem calendar.

## References

1. [1] 96Boards, “Getting Started with the Ultra96-V2” (board specifies ZU3EG and 2 GB LPDDR4). https://www.96boards.org/documentation/consumer/ultra96/ultra96-v2/getting-started/

1. [2] 96Boards, “Ultra96-V2 Hardware Documentation” and board hardware user guide. https://www.96boards.org/documentation/consumer/ultra96/ultra96-v2/hardware-docs/

1. [3] AMD, AXI DMA LogiCORE IP Product Guide PG021, Core Overview / Feature Summary (MM2S, S2MM, AXI4-Lite, widths, direct and scatter-gather modes). https://docs.amd.com/r/en-US/pg021_axi_dma/Core-Overview

1. [4] AMD, Zynq UltraScale+ MPSoC Processing System Product Guide PG201, “Slave Interface” (PS–PL HP/HPC interface roles and widths). https://docs.amd.com/r/en-US/pg201-zynq-ultrascale-plus-processing-system/Slave-Interface

1. [5] RAVEN Design Draft, supplied project document, especially initial hardware targets and Interfaces/DMA section.

1. [6] RAVEN Design Draft — Comments and Draft Responses, supplied feedback document, especially performance targets, accountability, acceptance criteria and mockup content.

Status note: this document is an initial research/proposal artifact. Confirm current board documentation, exact ZU3EG resource figures, selected Vivado version/IP configuration, and actual block-design connectivity before treating any proposed setting as final.
