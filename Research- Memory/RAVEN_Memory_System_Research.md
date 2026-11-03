# RAVEN Memory-System Research

**Status:** Initial research and proposed architecture; RTL implementation has not started.  
**Owner:** Taylor - BRAM organization, memory interfaces, DMA, and memory verification.  
**Target:** AMD/Avnet Ultra96-V2 (Zynq UltraScale+ MPSoC ZU3EG).  
**Document purpose:** Research baseline and initial proposal; all widths, capacities, tile sizes, and interface details remain subject to team approval, synthesis, and hardware validation.

Ultra96-V2 memory resources, DDR/AXI paths, DMA, tiling, and double buffering
*Much information in this doc was used to refine the Design Draft*

## Summary

RAVEN is a RISC-V-controlled programmable FPGA NPU intended to execute multiple quantized neural-network models on the Ultra96-V2. The feedback document makes the memory subsystem more concrete: it calls for measurable acceptance criteria for DMA, explicit DMA control/interface documentation, defined register fields and completion behavior, and subsystem ownership. It also proposes an 8×8 array of 64 INT8 MAC units with INT32 accumulation and a minimum 100 MHz target. These are design targets, not verified implementation results.

Recommended baseline: keep model tensors in the board’s external LPDDR4; stage active tiles in BRAM; use AMD AXI DMA for DDR-to-stream and stream-to-DDR transfers; begin with 128-bit memory-mapped and stream paths at a nominal 100 MHz where the implemented PS–PL path supports them; use separate activation and weight ping-pong buffers; and retain partial sums on-chip until an output tile is complete. Start in direct-register DMA mode for bring-up, then evaluate scatter-gather if descriptor overhead or queued transfers become important.

## 1. Scope and evidence labels

T	his report distinguishes (A) board/vendor facts, (B) requirements or proposals already present in the RAVEN draft/feedback, and (C) engineering recommendations that require team approval and implementation testing. No sustained bandwidth, final buffer fit, or inference performance is claimed without measurement.

## 2. Ultra96-V2 memory resources

The Ultra96-V2 uses the Zynq UltraScale+ MPSoC ZU3EG and has 2 GB of LPDDR4 RAM. The ZU3EG programmable logic is listed with 216 block-RAM blocks totaling about 7.6 Mbit (approximately 0.95 MB decimal), 1.8 Mbit of distributed RAM, and no UltraRAM blocks. These are device-level totals; they are not all available to RAVEN because the design also consumes LUTs, registers, BRAMs, and ports for compute, FIFOs, control, and integration. [1, 2]

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

1. The adapter writes the tile into a selected BRAM bank and marks that bank READY only after the complete expected byte count is received.

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
| Mode | Direct-register mode for bring-up; evaluate scatter-gather later | Direct mode is simpler and lower resource; scatter-gather queues descriptors and offloads CPU work. [3] |
| Burst | Start with up to 16 beats, then measure | Candidate setting only; validate IP limits, 4 KiB boundaries, timing, and PS–PL path. |
| Alignment | Prefer 16-byte-aligned buffers/sizes for 128-bit transfers | Simplifies packing and burst behavior; define tail handling for nonmultiples. |

Bandwidth arithmetic: bytes/cycle = width/8. At 100 MHz, 64 bits gives 8 × 100 million = 0.8 GB/s; 128 bits gives 16 × 100 million = 1.6 GB/s. These are theoretical interface ceilings, not measured DDR throughput. Read and write channels may be independent, but they still contend for DDR and interconnect resources.

## 5. Scratchpad organization

A reasonable first synthesis experiment is a 58–72 KiB logical scratchpad allocation. Treat these as capacity targets, not a guarantee of physical BRAM fit: inferred memory width/depth, port count, banking, and primitive packing affect resource use.

| Logical buffer | Proposed capacity | Role |
| --- | --- | --- |
| Activation A/B | 2 × 16 KiB | Current input tile and next tile |
| Weight A/B | 2 × 16 KiB | Current weight tile and next tile |
| Output / partial sums | 8–16 KiB | INT32 accumulation and/or output staging; confirm dimensions |
| FIFO/control allowance | 2–8 KiB | Stream elasticity, metadata, state and small queues |

Use INT8 storage for quantized activations and weights, but wider accumulators. INT32 is the draft’s proposed accumulation format. Keep partial sums on-chip across reduction-dimension chunks when possible; repeatedly writing partial sums to DDR wastes bandwidth. Separate logical buffers even if synthesis packs them into fewer physical memories. Define bank ownership, addresses, byte counts, and arbitration explicitly.

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

Use ping-pong activation and weight buffers. While the NPU computes from bank A, DMA may fill bank B. Once compute has finished using A and B is fully loaded, the roles swap. Apply the same concept to output draining if it helps overlap writes with computation.

| State | Meaning | Allowed next state |
| --- | --- | --- |
| FREE | Buffer available for a new tile | DMA_FILLING |
| DMA_FILLING | DMA/adapter owns buffer; writes are in progress | READY or ERROR |
| READY | Full tile validated; safe for NPU to consume | COMPUTING |
| COMPUTING | NPU owns tile; DMA must not overwrite it | FREE after completion |
| ERROR | Transfer/length/protocol fault | FREE after reset/recovery |

Completion is split across DMA and compute. DMA completion means the expected bytes reached the adapter or DDR endpoint; NPU completion means the compute operation has finished. Do not reuse a buffer until the owner releases it. Verify backpressure, delayed DMA completion, reset during transfer, partial tiles, and mismatched byte counts.

## 8. Rough bandwidth and performance model

T	he feedback document proposes 64 INT8 MAC units (8×8), INT32 accumulation and a minimum 100 MHz clock. If each unit completes one MAC per cycle, the arithmetic ceiling is 64 × 100 MHz = 6.4 GMAC/s (12.8 GOPS if multiply and add count as two operations). This is a theoretical ceiling, not expected sustained throughput.

A deliberately pessimistic no-reuse case that fetches a new INT8 activation and a new INT8 weight for every MAC would demand about 12.8 GB/s at 6.4 GMAC/s-well above the 128-bit/100 MHz interface ceiling. This illustrates why tiling and operand reuse are essential; it is not a prediction of actual DDR traffic.

Measure required bandwidth from real transfers: (DDR bytes read + DDR bytes written) / inference time. Count input activations, weights, intermediate writes, and output writes separately. Benchmark sequential DMA transfers at multiple sizes, then benchmark full layers and models. Record achieved throughput, average/maximum transfer latency, NPU stall cycles, BRAM usage, timing slack, and inference latency. Avoid asserting a sustained-bandwidth percentage before measurement.

## 9. Verification and acceptance criteria

- DMA integrity: known byte patterns match exactly for aligned and unaligned lengths supported by the chosen configuration, including final partial beats.

- Boundary safety: no transfer crosses an unsupported 4 KiB boundary behavior; confirm AXI DMA configuration and descriptors.

- Buffer protocol: assertions/testbench prove a DMA writer never overwrites a COMPUTING buffer and the NPU never reads a buffer before READY.

- Functional correctness: tiled GEMM/Conv output matches an integer golden reference across full and edge tiles.

- Overlap: test demonstrates DMA transfer of tile n+1 overlaps compute of tile n without corrupting data; report measured overlap rather than claiming it.

- Performance: publish measured DDR read/write throughput, transfer sizes, clock rates, DMA mode, PS–PL port configuration and competing traffic.

- Implementation: record BRAM/LUT/DSP usage and timing slack from Vivado reports; ensure the agreed clock target is met.

## 10. Risks and decisions still open

| Issue | Risk / decision needed |
| --- | --- |
| PS–PL connectivity and cache policy | Select actual AXI port and document whether DDR buffers are coherent or require cache clean/invalidate operations. |
| DMA mode | Confirm AXI DMA direct-register vs scatter-gather; pin Vivado/IP version. |
| Scratchpad implementation | Choose RAM banking/ports and adapter protocol; confirm capacity in synthesis. |
| Tile sizes | Tune against supported models and compute-array shape. |
| Register map | Define DMA base address, control/status bits, byte count, error semantics and interrupt behavior; do not conflate proposed NPU registers with AMD IP’s own register map. |
| Ownership | Feedback names Taylor for BRAM organization, memory interfaces, DMA and memory verification; name a separate integration lead for shared integration. |
| Ethical/security controls | DMA address validation and memory-region limits are relevant because programmable DMA can access sensitive data if software or descriptors are incorrect. |

## References

1. [1] 96Boards, “Getting Started with the Ultra96-V2” (board specifies ZU3EG and 2 GB LPDDR4). https://www.96boards.org/documentation/consumer/ultra96/ultra96-v2/getting-started/

1. [2] 96Boards, “Ultra96-V2 Hardware Documentation” and board hardware user guide. https://www.96boards.org/documentation/consumer/ultra96/ultra96-v2/hardware-docs/

1. [3] AMD, AXI DMA LogiCORE IP Product Guide PG021, Core Overview / Feature Summary (MM2S, S2MM, AXI4-Lite, widths, direct and scatter-gather modes). https://docs.amd.com/r/en-US/pg021_axi_dma/Core-Overview

1. [4] AMD, Zynq UltraScale+ MPSoC Processing System Product Guide PG201, “Slave Interface” (PS–PL HP/HPC interface roles and widths). https://docs.amd.com/r/en-US/pg201-zynq-ultrascale-plus-processing-system/Slave-Interface

1. [5] RAVEN Design Draft, supplied project document, especially initial hardware targets and Interfaces/DMA section.

1. [6] RAVEN Design Draft - Comments and Draft Responses, supplied feedback document, especially performance targets, accountability, acceptance criteria and mockup content.

Status note: this document is an initial research/proposal artifact. Confirm current board documentation, exact ZU3EG resource figures, selected Vivado version/IP configuration, and actual block-design connectivity before treating any proposed setting as final.
