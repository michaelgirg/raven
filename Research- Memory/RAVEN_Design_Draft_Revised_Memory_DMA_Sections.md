# RAVEN Design Draft - Revised Memory-System Sections

*Items that require implementation or team approval are explicitly labeled proposed/TBD. *

## A. Statement of Work - Initial Hardware Targets

Initial Hardware Targets (proposed). RAVEN will target INT8 activations and weights, INT32 accumulation, an 8×8 array containing 64 INT8 MAC units, and a minimum NPU clock frequency of 100 MHz. Assuming one MAC per unit per cycle, the theoretical arithmetic ceiling is 6.4 GMAC/s (12.8 GOPS when multiplication and addition are counted separately); these are analytical ceilings, not measured results. The memory subsystem will use the Ultra96-V2’s external LPDDR4 for model-scale tensors and programmable-logic BRAM for explicitly managed tiles and partial sums. The initial DMA target is a 128-bit AXI4 memory-mapped path and 128-bit AXI4-Stream path, with a 64-bit fallback if implementation timing or integration requires it. At 100 MHz, the ideal one-beat-per-cycle ceilings are 1.6 GB/s for 128 bits and 0.8 GB/s for 64 bits; sustained DDR bandwidth will be measured on the implemented design. Scratchpad capacity, tile dimensions, DMA mode, and the PS–PL interface configuration remain provisional until synthesis and integration tests.

## B. Mockups - Interfaces, “DMA/Memory Interface”

DMA/Memory Interface (proposed). RAVEN separates control traffic from tensor data movement. The RISC-V runtime accesses NPU and DMA control/status registers through AXI4-Lite. Bulk tensor transfers use an AMD AXI DMA core, subject to confirmation of the selected Vivado IP version and block-design connectivity. The MM2S channel reads input and weight bytes from external DDR through a configured Zynq UltraScale+ PS–PL AXI path and presents them on AXI4-Stream. A RAVEN stream-to-scratchpad adapter writes the stream into the selected BRAM bank. For output transfers, a scratchpad reader presents output bytes on AXI4-Stream to the S2MM channel, which writes them to DDR. The stream adapters, BRAM bank selection, byte-count checks, backpressure behavior, and buffer ownership protocol are RAVEN RTL responsibilities; AXI DMA does not itself define the project’s BRAM controller.

For the first prototype, use direct-register DMA mode to simplify bring-up. Evaluate scatter-gather descriptors if queued transfers are needed to reduce CPU scheduling overhead. The proposed memory-mapped and stream widths are 128 bits, with 64 bits retained as a fallback. These widths are design targets and must be confirmed against the selected IP configuration, PS–PL port, clocks, timing closure, and resource utilization.

## C. Adding: Scratchpad Organization and Tiling

Scratchpad Organization (initial proposal). The first synthesis experiment will target two 16 KiB activation buffers, two 16 KiB weight buffers, 8–16 KiB for output/partial-sum storage, and 2–8 KiB for FIFOs and control state (approximately 58–72 KiB total logical storage). The actual implementation may differ because BRAM primitives have fixed configurations and port constraints; resource use will be reported from Vivado synthesis and implementation. Activations and weights are stored as INT8. Partial sums use the proposed INT32 format until requantization produces the output representation. Logical buffers will be separately named and documented even if synthesis maps them into shared physical RAM resources.

Tiling (initial proposal). The runtime divides operators into tiles sized to fit local memory and the compute datapath. A candidate GEMM test uses Mₜ=32, Nₜ=32 and Kₜ=64: the INT8 A tile is 2 KiB, the INT8 B tile is 2 KiB, and the INT32 accumulator tile is 4 KiB, excluding metadata, bias and output staging. These dimensions are a test point, not a finalized hardware requirement. Tile sizes will be tuned against the 8×8 MAC array, local-memory port bandwidth and the selected models. The implementation should retain partial sums on-chip across K-dimension chunks where possible and support edge tiles.

## D. Adding: Double Buffering and Ownership

Double Buffering (initial proposal). Activation and weight scratchpads will use ping-pong buffering. While the NPU computes from one buffer, DMA may fill the alternate buffer. Buffer ownership will be tracked using explicit states: FREE, DMA_FILLING, READY, COMPUTING and ERROR. A buffer may transition to READY only after the expected transfer length is received and validated; it may return to FREE only after the NPU signals completion. DMA completion and NPU completion are separate events. The implementation must prevent DMA writes to a buffer currently owned by compute and must safely handle backpressure, reset, transfer errors and partial tiles. Output double buffering may be added to overlap result writes with later computation.

## E. Adding: DMA Register/Software Interface

DMA control interface (to be finalized). The software interface will expose a project-level function such as raven_dma_transfer(src_ddr_addr, dst_buffer_id, byte_count, direction) and return or report completion/error status. The precise function signature is illustrative and remains TBD. The design documentation must distinguish RAVEN’s proposed MMIO register map from the AMD AXI DMA IP’s own register map. Before integration, the team will specify the DMA base address, control/status fields, source/destination address handling, byte count, interrupt or polling behavior, error flags, alignment rules, reset behavior, and whether scatter-gather descriptors are enabled. Register offsets and bit definitions will not be considered final until agreed and verified in the block design.

For DDR buffers used by a processor runtime, cache maintenance or coherent-access configuration must be defined. The selected PS–PL AXI interface and memory attributes must be recorded, and DMA addresses must be validated against permitted buffer regions. Descriptor and address validation are required to prevent erroneous or untrusted commands from accessing unrelated memory.

## F. Replacing/expanding: Risks and Mitigation - memory-system entries

| Risk | Severity / likelihood (initial qualitative assessment) | Mitigation and observable warning |
| --- | --- | --- |
| DDR bandwidth bottleneck | High severity / medium likelihood; validate experimentally | Measure read/write throughput and NPU stall cycles; warning: DMA cannot supply tiles before compute exhausts the active tile. |
| BRAM capacity/port conflict | High / medium | Track synthesis BRAM and port use; warning: inferred RAM exceeds budget or synthesis duplicates RAM to satisfy ports. |
| DMA/adapter protocol mismatch | High / medium | Known-pattern tests, byte counters and assertions; warning: byte-count mismatch, stream stall or corrupted tile. |
| Double-buffer ownership race | High / medium | State machine and assertions; warning: DMA writes while buffer is COMPUTING or NPU reads before READY. |
| Cache/coherency error | High / medium if software caching is used | Document HP/HPC path and cache policy; warning: stale or inconsistent DDR data. |
| Timing closure at target clock | Medium-high / medium | Run timing analysis and test DMA/compute clock-domain crossings; warning: negative slack or CDC violations. |

*Severity and likelihood are preliminary engineering judgments, not team-approved ratings. These will need to be reviewed after initial implementation and update with measured evidence.*

## G. Adding: Memory/DMA acceptance criteria

- Known-pattern DDR↔scratchpad tests reproduce expected bytes for all supported transfer sizes, alignments and tail cases.

- Transfer completion, error reporting and reset behavior are documented and pass testbench/hardware tests.

- Assertions verify that a DMA-owned buffer is not read by compute and a COMPUTING buffer is not overwritten.

- A tiled GEMM or convolution test matches the software integer golden reference, including edge tiles and requantization.

- At least one test demonstrates correct DMA/compute overlap; the measured overlap and any stalls are reported.

- Benchmark reports include DMA width, clock, burst settings, selected PS–PL port, transfer sizes, sustained read/write bandwidth, BRAM/LUT/DSP utilization, timing slack and inference latency.

## H. Update ownership and unresolved decisions

I (Taylor) am responsible for BRAM organization, memory interfaces, DMA and memory verification.

***Open decisions: selected AXI DMA IP/version and mode; actual PS–PL port and cache policy; final memory widths and clocks; scratchpad RAM banking/port architecture; final tile dimensions; DMA register base/offsets and completion semantics; supported transfer alignments and maximum lengths; and target model shapes used for performance acceptance.

## References to add to the draft

1. [1] 96Boards, “Getting Started with the Ultra96-V2” (board specifies ZU3EG and 2 GB LPDDR4). https://www.96boards.org/documentation/consumer/ultra96/ultra96-v2/getting-started/

1. [2] 96Boards, “Ultra96-V2 Hardware Documentation” and board hardware user guide. https://www.96boards.org/documentation/consumer/ultra96/ultra96-v2/hardware-docs/

1. [3] AMD, AXI DMA LogiCORE IP Product Guide PG021, Core Overview / Feature Summary (MM2S, S2MM, AXI4-Lite, widths, direct and scatter-gather modes). https://docs.amd.com/r/en-US/pg021_axi_dma/Core-Overview

1. [4] AMD, Zynq UltraScale+ MPSoC Processing System Product Guide PG201, “Slave Interface” (PS–PL HP/HPC interface roles and widths). https://docs.amd.com/r/en-US/pg201-zynq-ultrascale-plus-processing-system/Slave-Interface
