# RAVEN Design Draft - Revised Memory-System Sections

> Current Markdown revision of the memory/DMA draft sections. The shared memory
> proposal is [docs/RAVEN_Memory_System_Research.md](docs/RAVEN_Memory_System_Research.md).
> Copies under `Research- Memory/` and existing Word/PDF exports are earlier
> review snapshots; their capacities and interfaces may be superseded here.

*Status: proposed memory/DMA interface requirements for team review. Project-specific register semantics, tile packing, bank organization, and integration details remain proposed/TBD until agreed and validated.*

## A. Statement of Work - Initial Hardware Targets

Initial hardware targets (proposed). RAVEN will target INT8 activations and weights, INT32 accumulation, an 8×8 array containing 64 INT8 MAC units, and a minimum NPU clock frequency of 100 MHz. Assuming one MAC per unit per cycle, the theoretical arithmetic ceiling is 6.4 GMAC/s (12.8 GOPS when multiplication and addition are counted separately); these are analytical ceilings, not measured results. The memory subsystem will use the Ultra96-V2’s external LPDDR4 for model-scale tensors and programmable-logic BRAM for explicitly managed tiles and partial sums. The initial DMA target is a 128-bit AXI4 memory-mapped path and 128-bit AXI4-Stream path, with a 64-bit fallback if implementation timing or integration requires it. At 100 MHz, ideal one-beat-per-cycle ceilings are 1.6 GB/s for 128 bits and 0.8 GB/s for 64 bits; sustained DDR bandwidth must be measured on the implemented design. Scratchpad capacity, tile dimensions, DMA mode, and the PS–PL interface configuration remain provisional until synthesis and integration tests.

## B. Mockups - Interfaces, “DMA/Memory Interface”

DMA/memory interface (proposed). RAVEN separates control traffic from tensor data movement. The RISC-V runtime accesses project control/status registers through AXI4-Lite. Bulk tensor transfers use an AMD AXI DMA core, subject to confirmation of the selected Vivado IP version and block-design connectivity. The MM2S channel reads input and weight bytes from external DDR through a configured Zynq UltraScale+ PS–PL AXI path and presents them on AXI4-Stream. A RAVEN stream-to-scratchpad adapter writes the stream into the selected BRAM bank. For output transfers, a scratchpad reader presents bytes on AXI4-Stream to the S2MM channel, which writes them to DDR. The adapters and BRAM bank controller are RAVEN RTL responsibilities; AXI DMA does not itself implement the project’s scratchpad controller.

**Compute-side bandwidth requirement (proposed interface contract).** During each active 8×8-array compute cycle, the memory interface must deliver eight INT8 activations and eight INT8 weights: 8 bytes (64 bits) from the activation side and 8 bytes (64 bits) from the weight side per cycle. These are two simultaneous operand streams, or 16 bytes/cycle in aggregate before considering reuse, stalls, or additional operands. The 128-bit DMA width describes a transfer path into or out of local memory; it does not by itself guarantee the required BRAM-to-compute bandwidth. A candidate implementation is to bank activation and weight scratchpads separately, with at least eight byte-wide values available per operand side per cycle. One possible organization is eight banks per operand, arranged so each bank supplies one INT8 lane each cycle; alternatively, a suitably organized 64-bit-wide read word per operand side could supply all eight lanes if the BRAM primitive, addressing, and port arrangement support the required access pattern. Bank mapping, read latency, replication, and conflict handling are **TBD** and must be checked against the compute core’s exact access pattern and BRAM port limits. If simultaneous accesses cannot be served, the design must either change banking/replication or explicitly account for stalls; it must not assume the DMA width solves this issue.

For the first prototype, direct-register mode is proposed to simplify bring-up. Evaluate scatter-gather descriptors if queued transfers are needed to reduce CPU scheduling overhead. The proposed memory-mapped and stream widths are 128 bits, with 64 bits retained as a fallback. These widths are design targets and must be confirmed against the selected IP configuration, PS–PL port, clocks, timing closure, and resource utilization.

## C. Scratchpad Organization and Tiling

Scratchpad organization (initial proposal). The base logical allocation is two 16 KiB activation buffers, two 16 KiB weight buffers, 8–16 KiB for output/partial-sum storage, and 2–8 KiB for FIFOs and control state: **74–88 KiB total**. This corrects the earlier 58–72 KiB estimate. Nahjay's proposed parameter bank (`PRM`, 4 KiB) is accounted for separately, bringing the total to **78–92 KiB** with `PRM` and without an optional second output bank. If `OUT1` is added for output double buffering, budget a further 8–16 KiB, for **86–108 KiB** including `PRM` and `OUT1`. These are logical capacity estimates, not physical BRAM utilization guarantees. Actual BRAM use depends on primitive configurations, width/depth choices, banking, port requirements, and any replication inferred by synthesis; report the synthesized BRAM use and timing.

For consistency with the proposed bank identifiers in Nahjay's `RISCV_Research.md` §6.4, the draft uses `ACT0` (ID 0), `ACT1` (1), `WGT0` (2), `WGT1` (3), `OUT0` (4), optional `OUT1` (5), and `PRM` (6). These IDs and sizes remain subject to team agreement and integration validation. Logical buffers may map to multiple physical BRAM primitives.

Why 16 KiB per operand buffer? The candidate 32×32×64 GEMM tile described below needs only 2 KiB for each INT8 operand tile. The 16 KiB buffer size is therefore a larger **allocation to evaluate during synthesis**, not a requirement implied by that example. It could accommodate multiple tiles, different tile shapes, or prefetching, but that benefit has not yet been demonstrated. Compare a smaller tile-sized allocation (at least 2 KiB per operand buffer for that specific example, plus any alignment/packing margin) with the 16 KiB option, and select the smallest organization that supports the agreed workload, required banking/bandwidth, and desired overlap. Buffer capacity must be evaluated together with ports and bank conflicts, not capacity alone.

Tiling (initial proposal). A candidate GEMM test uses Mₜ=32, Nₜ=32 and Kₜ=64: the INT8 A tile is 32×64 bytes = 2 KiB; the INT8 B tile is 64×32 bytes = 2 KiB; and the INT32 accumulator tile is 32×32×4 bytes = 4 KiB, excluding metadata, bias, output staging and alignment. These dimensions are a test point, not a finalized hardware requirement. Tile sizes will be tuned against the 8×8 MAC array, local-memory port bandwidth and selected models. The packed operand layout and which component prepares convolution tiles are shared decisions: the memory interface needs an agreed byte order, row/stride rules, padding representation, alignment, and transfer length; convolution-to-GEMM lowering/tile generation ownership is **TBD with the compute/software team**.

## D. Partial Sums, Double Buffering and Ownership

Partial-sum workspace (proposed). INT32 partial sums must persist across K-dimension chunks until the full reduction for an output tile is complete. For the example 32×32 output tile, one INT32 accumulator workspace is 4 KiB. The compute core may keep these values in local registers while processing a chunk, then write them to a designated accumulator BRAM region before the next chunk; on the next chunk it restores or reloads those values, adds the new products, and writes back as needed. The exact save/restore cadence, whether partial sums stay in registers for some or all K chunks, accumulator banking/ports, and when operand buffers can be reused are **shared compute/memory decisions and TBD**. Ownership rules must ensure the DMA or adapter cannot overwrite an operand buffer still in use, and compute cannot read a buffer before it is marked READY. An accumulator workspace must not be reassigned until the associated output tile is complete and safely handed off.

Double buffering and ownership (initial proposal). Activation and weight scratchpads use ping-pong buffering if resource and port budgets permit. While the NPU computes from one buffer, DMA may fill the alternate buffer. A filled input/weight buffer is marked `READY` only after the expected valid-byte count and configured packet-end condition are validated. After compute finishes its final read, the input/weight bank may return to `READY` for reuse if its contents are intentionally retained, or transition through the agreed release policy before reuse; it should not be automatically treated as `FREE` in every case. Nahjay's proposed `RELEASE_A`, `RELEASE_B`, and `RELEASE_PARAM` controls (§6.7 of `RISCV_Research.md`) should govern when retained activation, weight, and parameter banks are released or reused.

Output and partial-sum banks have a separate lifecycle. An output/partial-sum bank is marked `NPU_WRITING` while compute writes it. An incomplete INT32 partial-sum tile can return to `READY` with a partial-sum tag and be restored for the next K chunk; it must not be treated as a completed output. A completed output tile is marked `FULL` and can transition to `DRAINING` while the output reader/DMA transfers it to DDR. Optional `OUT1` can allow output draining to overlap later computation. DMA completion and NPU completion are separate events. The implementation must prevent DMA writes to a buffer currently owned by compute and prevent compute from reading a buffer before it is `READY`; backpressure, reset, transfer errors, and partial tiles must be handled explicitly.

Proposed state vocabulary for the draft: `FREE`, `DMA_FILLING`, `READY`, `COMPUTING`, `NPU_WRITING`, `FULL`, `DRAINING`, and `ERROR`. Not every bank type needs every state; the bank controller must define legal transitions for input, weight, parameter, partial-sum, and completed-output banks.

## E. DMA Adapter Behavior and Register Interface

**Stream adapter behavior (proposed; details TBD with selected AXI DMA configuration).** The stream-to-scratchpad adapter accepts a beat only when `TVALID` and `TREADY` are both asserted; when the destination bank/FIFO cannot accept data, it deasserts `TREADY` and must preserve any pending beat without dropping or duplicating bytes. The final beat’s valid-byte count is determined from the configured byte count and the AXI4-Stream `TKEEP` mask; the adapter must write only lanes marked valid and must not treat padding bytes as tensor data. Whether the selected AXI DMA configuration emits `TLAST` and how packet boundaries are used must be verified. Proposed rule: the adapter counts accepted valid bytes and marks the transfer complete only when the expected byte count has been received and the configured end-of-packet condition is consistent. Early/late `TLAST`, too few or too many valid bytes, unsupported alignment, or an unexpected transfer length set an error status and prevent the destination buffer from becoming READY. Exact recovery/abort behavior, maximum length, and whether malformed streams can be drained or require channel reset are **TBD**. For scratchpad-to-stream, the reader must hold data and `TVALID` stable while `TREADY` is low and assert the configured packet-end signal on the final beat.

**Register-map integration (proposed; align with the existing RISC-V/control proposal).** Do not create a competing second register map in this memory draft. Nahjay's `RISCV_Research.md` is the current reference for (1) the AMD AXI DMA native register map and version-specific PG021 details (§7.1) and (2) the proposed RAVEN adapter/bank control and status CSRs (§7.2), which currently proposes `ADP_BASE = 0xA002_0000`. Treat that base and the adapter fields as proposed until the team confirms address allocation and the implemented block design. The RAVEN adapter CSR map is distinct from the AMD AXI DMA native AXI4-Lite map; the two must not be conflated.

Before integration, the team must confirm the native AXI DMA IP/version, direct-register versus scatter-gather mode, address width, source/destination and byte-count handling, selected bank ID, status/error/clear behavior, interrupt or polling policy, and reset/abort semantics. Use the version-matched AMD PG021 register definitions for the IP itself, and document how the adapter CSRs trigger/observe adapter and bank behavior. This memory draft specifies the required memory-side behavior, not a duplicate software register specification.

For DDR buffers used by a processor runtime, cache maintenance or coherent-access configuration must be defined. The selected PS–PL AXI interface and memory attributes must be recorded, and DMA addresses must be validated against permitted buffer regions. Descriptor and address validation are required to prevent erroneous commands from accessing unrelated memory.

## F. Risks and Mitigation - Memory/DMA

Initial ratings below are qualitative engineering judgments for review, not measured probabilities or team-approved ratings.

| Risk | Severity (1–5) | Likelihood (1–5) | Mitigation and observable warning |
|---|---:|---:|---|
| Compute-facing bandwidth stalls: DDR/DMA cannot refill tiles, or BRAM cannot supply eight activation and eight weight bytes each active cycle | 5 | 3 | Measure sustained DDR/BRAM throughput and compute stall cycles; warning: compute is ready but an operand tile is exhausted. |
| BRAM port/bank conflicts or synthesis replication | 4 | 3 | Define lane-to-bank mapping and ownership; test simultaneous accesses and inspect inferred RAM/replication; warning: serialized reads, stalls, or unexpected BRAM growth. |
| Scratchpad capacity underestimation when `PRM` and optional `OUT1` are included | 4 | 3 | Track base (74–88 KiB), `PRM` (+4 KiB), and optional `OUT1` (+8–16 KiB) separately; compare logical capacity with post-synthesis utilization. |
| DMA/adapter final-beat, byte-count, or `TLAST` mismatch | 4 | 3 | Test `TKEEP`/`TLAST`, byte counters, backpressure, and malformed packets; warning: mismatches, corrupted tiles, or false completion. |
| Buffer ownership/state error, including premature input reuse or partial-sum/output confusion | 5 | 3 | Assert legal state transitions and inject completion/reset errors; warning: DMA writes during compute, reads before `READY`, or wrong K-chunk results. |
| Packed layout or convolution tile-preparation ambiguity | 4 | 4 | Agree lane order, strides, padding, alignment and the component responsible for convolution tile preparation before end-to-end tests. |
| PS–PL cache/coherency error | 4 | 2 | Document selected HP/HPC path and cache policy; warning: stale or inconsistent DDR data. |
| DMA mode/register mapping mismatch | 3 | 3 | Validate direct-register/scatter-gather choice and keep adapter CSRs separate from the AMD native register map. |

## G. Memory/DMA Acceptance Criteria

- Known-pattern DDR↔scratchpad tests reproduce expected bytes for supported transfer sizes, alignments and final-beat masks.
- Backpressure tests demonstrate no lost/duplicated bytes and stable stream payload while stalled.
- Correct-length transfers complete; early/late packet end and incorrect lengths set an error and do not mark a buffer READY.
- Register read/write, status clearing, completion/error behavior and reset behavior are documented and tested.
- Banked BRAM test demonstrates eight INT8 activation values and eight INT8 weight values available per active compute cycle under the agreed access pattern, or reports the resulting stall rate if the target cannot be sustained.
- Assertions verify that a DMA-owned buffer is not read by compute and a COMPUTING buffer is not overwritten.
- A tiled GEMM or convolution test matches the software integer golden reference, including edge tiles, K-chunk partial sums and requantization. Test-vector layout and convolution tile preparation owner are agreed with the compute/software team.
- At least one test demonstrates correct DMA/compute overlap; measured overlap and stalls are reported.
- Benchmark reports include DMA width, clock, burst settings, selected PS–PL port, transfer sizes, sustained read/write bandwidth, BRAM/LUT/DSP utilization, timing slack and inference latency.

## H. Ownership and Shared Decisions

Taylor owns BRAM organization, memory interfaces, DMA integration and memory verification. This section does not assign ownership of compute-core design or software implementation.

Shared decisions to resolve with the compute/software team:

1. Packed activation/weight layout: lane order, row/column-major convention, strides, padding, alignment, tail handling and byte order.
2. Convolution tile preparation: which component converts convolution tensors into the packed tiles expected by the memory interface, and how that handoff is represented.
3. Partial-sum save/restore cadence across K chunks and the point at which input buffers are safe to reuse.
4. Scratchpad bank mapping/replication, final operand buffer size, and whether the array can sustain 8 activation bytes plus 8 weight bytes per cycle.
5. Confirm the bank IDs and ownership/release semantics in `RISCV_Research.md` §§6.4 and 6.7, including retained input-bank reuse and the separate output/partial-sum lifecycle.
6. DMA IP/version/mode, native register-map mapping, adapter CSR base/fields, PS–PL port/cache policy, address width, maximum transfer length, alignment rules and error/reset semantics.
7. Whether the proposed `PRM` and optional `OUT1` banks are included in the first implementation; account for their capacities explicitly.

## References

1. 96Boards, “Getting Started with the Ultra96-V2” (board specification and memory). https://www.96boards.org/documentation/consumer/ultra96/ultra96-v2/getting-started/
2. 96Boards, “Ultra96-V2 Hardware Documentation” and board hardware user guide. https://www.96boards.org/documentation/consumer/ultra96/ultra96-v2/hardware-docs/
3. AMD, *AXI DMA LogiCORE IP Product Guide PG021*, including the version-matched native register map, MM2S/S2MM, AXI4-Lite, AXI4-Stream, direct-register and scatter-gather modes. https://docs.amd.com/r/en-US/pg021_axi_dma/Core-Overview
4. AMD, *Zynq UltraScale+ MPSoC Processing System Product Guide PG201*, PS–PL interface options. https://docs.amd.com/r/en-US/pg201-zynq-ultrascale-plus-processing-system/Slave-Interface
