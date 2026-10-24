# RAVEN shared interface contract

**Revision:** 0.3, October 23, 2026. **Status:** selected design proposal for implementation; no working RTL/firmware or measured FPGA result is implied. Michael owns compute, Taylor memory/adapter, Quan output arithmetic, Nahjay control/runtime, and Jackie export/reference data.

This document defines shared behavior used by the five research documents. The register tables in [RISC-V research](../RISCV_Research.md) provide the detailed proposed map. Change both together when revising an interface. Generated SystemRDL/RTL/C definitions remain future implementation work. [Project targets and dates](../PROJECT_PLAN.md) are separate from interface semantics.

## 1. Operand and result delivery

The baseline remains an 8×8 output-stationary array, signed INT8 raw multiplication, architectural INT32 sums, and a 100 MHz target. RESULT_LANES=1 is the bring-up configuration; four lanes remain an evaluation configuration.

### Logical memory ports and GEMM A

Each active ACT/WGT bank exposes a logical 128-bit synchronous read interface assembled from suitable BRAM primitives. Define byte address, request valid/ready, and response data/valid/ready. Addresses are 16-byte aligned. Responses preserve request order; the frontend tracks the destination row/block for each accepted request. Declare implemented read latency and maximum outstanding requests in the build manifest; the performance configuration must permit pipelined requests. A response and its metadata remain stable until accepted. Bank ownership prevents DMA from writing a bank being read by compute.

Keep GEMM A row-major with 16-byte-aligned base and row pitch `P2`. Michael's frontend uses two **8×16-byte local buffers, 256 bytes total**, excluding tags/control and other staging. For microtile origin `m0` and local K-block origin `k0=0,16,...`, request:

```text
row_address(r) = SRC_A.offset + (m0+r)*P2 + k0
cache[r][0..15] = the returned 16-byte row word
A_vector[r] = cache[r][j]           # one common j per accepted reduction step
```

Skip invalid M rows and mask their MACs. Stop at logical K, including a partial last block. Prefetch into the inactive buffer while the current buffer emits vectors. Eight sequential word reads provide sixteen full-block reduction steps; this makes overlap possible without eight simultaneous BRAM addresses. Initial fill, read latency, tails, and stalls remain measured overhead. Reset local K to zero for each resident K chunk and retain the chunk's global reduction position in the controller.

Validate both logical footprints and the rounded physical span of every wide read. The last row has owned padding through `round_up(K,16)`; padding bytes are ignored, never issued as real K terms. The exporter/runtime packs row padding into owned storage when canonical source rows are not aligned to the required pitch; it must not reinterpret an unpadded DDR tensor as padded A. Charge any runtime repacking to inference time and reject or use a supported CPU fallback if the required staging is unavailable. The tiler includes pitches/padding in bank-capacity checks. These local buffers are additional frontend storage, not a change to the 74–88 KiB base scratchpad payload budget. Synthesis determines their register/LUTRAM/BRAM cost.

### B panels and Conv windows

For an eight-column panel, lane `n` at reduction index `k` has byte address `SRC_B.offset + panel_index*panel_pitch + 8*k + n`. For GEMM, `panel_pitch=P3`, a 16-byte multiple at least `round_up(8*K,16)`; for Conv, use that minimum pitch for its resident flattened reduction. Mask/pad unused output columns with zero weights. For K=256 the minimum panel pitch is **2,048 bytes**, not 256. A 128-bit read supplies two 64-bit B vectors through a word register/unpacker. Pair A/B acceptance and preserve data, masks, channel tags, and K position on stalls.

Conv activations remain packed NHWC row bands. The compute-side window gatherer maps output position and `(kh,kw,ci)` to input addresses, supplies the input zero-point outside the valid input, and fills local A vectors. Start with a correct serialized gatherer with contiguous-word reuse. Its refill cost can exceed GEMM's eight word reads: filter/row crossings and small channel counts change locality. Hardware line buffers, packed A deployment formats, and extra banking remain later optimizations. Software-created patches are useful independent test fixtures. Do not infer one-cycle Conv gathering or model-level 6.4 GMAC/s from the array ceiling.

### Conv channel chunks

For CONV2D, P1[15:0] is **C_in_full**, the channel stride of each stored NHWC input pixel; it is not the chunk count. P5[15:0] is **cin_start** and P5[31:16] stays zero. Add the RW staging register **CONV_CHUNK at NPU offset 0x0B4**: [15:0] is **cin_count**, [31:16] reserved zero. Require cin_count>0 and cin_count<=C_in_full-cin_start after checking cin_start<C_in_full. For other opcodes CONV_CHUNK is unused/reserved zero. Include it in queue snapshots and saved software commands.

The local reduction has K_chunk=Kh*Kw*cin_count. For a local channel index ci, gather `(ih*W_in+iw)*C_in_full + cin_start + ci`; virtual padding supplies z_a. Pack only those selected channels into B, using its padded eight-column panels. ACT residency still covers full-channel row bands, so channel splitting does not reduce the stored activation stride or automatically shrink ACT capacity.

ACC_INIT starts at channel zero and applies the full-layer corrected bias once. Continuations keep the same full input stride, window geometry, output tile and bias/PSUM context, and start at the saved next channel. ACC_LAST ends exactly at C_in_full; a nonfinal chunk must end earlier. Validate nonoverlapping complete coverage in the exporter/runtime and expected next channel/full stride in PSUM metadata. Reject zero/out-of-range counts with ERR_BAD_DIM, reserved bits with ERR_RSVD, and inconsistent first/last/context flags with ERR_BAD_FLAGS. A single-chunk Conv explicitly uses cin_start=0 and cin_count=C_in_full.

### Result destinations

One-lane output writes use a byte address and byte write enable on the logical memory word. The baseline proposal includes an ACT-bank destination route, advertised by HW_FEATURES[2]; DMA and the result writer are mutually exclusive bank owners. Without OUT1, reserve a FREE ACT destination before prefetching into it. This reduces overlap but permits distinct INT32 PSUM and final INT8 storage. If the advertised route/capacity is absent, reschedule or reject; a FREE bank alone is insufficient. ACT output becomes FULL and follows the existing typed-source/drain rules, not automatic Conv→Conv chaining. Four result lanes require verified write combining/ports before adoption.

The existing explicit PSUM_SRC/PSUM_PITCH and bias-once rules remain. Final INT8 writes use a distinct bank while the old context stays owned until retirement. Abort/recovery invalidates local buffers as well as PSUM metadata.

Research: [AMD BRAM data flow](https://docs.amd.com/r/en-US/ug573-ultrascale-memory-resources/Data-Flow), [primitive widths](https://docs.amd.com/r/en-US/ug573-ultrascale-memory-resources/Block-RAM-Library-Primitives), [implicit-GEMM tile construction](https://docs.nvidia.com/cutlass/4.5.0/media/docs/cpp/implicit_gemm_convolution.html). The particular row-block buffer is RAVEN's proposal, not a vendor implementation or timing result.

## 2. DMA packets and bank commit

Baseline: normal AMD AXI DMA, direct-register mode, Micro DMA disabled, 128-bit memory/stream widths, DRE disabled, 23-bit length field explicitly set. Require 16-byte-aligned DDR addresses and scratchpad starts, but support arbitrary positive byte lengths within the bank and DMA limits.

Distinguish logical tensor bytes, allocated storage bytes, and exact transfer bytes. A GEMM tile with padded row pitch can transfer more bytes than its logical M×K count. Own storage through `round_up(transfer_bytes,16)` without silently increasing the packet length. An API request for zero bytes is a no-op: no DMA register writes and no ownership change.

For nonzero packet length `n`, the RAVEN stream subset is:

```text
beats = ceil(n/16)
valid_final_bytes = ((n-1) % 16) + 1
final_TKEEP = (1 << valid_final_bytes) - 1
```

All nonfinal beats have TKEEP=0xFFFF; the last accepted beat alone has TLAST=1 and contiguous low valid lanes. For 2/12/490 bytes, final masks are 0x0003/0x0FFF/0x03FF and beat counts are 1/1/31. Count bytes only on valid/ready handshakes, write only valid lanes, and reject sparse/zero masks, overrun, and early/late packet ends. Hold payload and sidebands stable under backpressure. Allocation padding is ignored; virtual Conv padding uses the activation zero-point, whereas cleanup writes raw zero bytes.

MM2S_LENGTH is the exact packet length. Baseline S2MM_LENGTH equals that length; successful completion must report the same actual bytes. Reject undersized receive buffers before starting hardware. Successful tests are bounded by each bank's capacity minus offset; PRM is 4 KiB and OUT0 may be 8 KiB.

### Fill commit sequence

1. Before changing active configuration, require MM2S and adapter fill slots available, bank FREE, and checked address/length/physical storage bounds.
2. Program FILL_DST/FILL_BYTES; ARM_FILL claims DMA_FILLING. Fence, read/check FILL_BUSY with a bounded wait, and program MM2S source then LENGTH last.
3. The adapter receives/validates the packet and sets FILL_DONE plus AWAIT_COMMIT. **FILL_DONE means packet received, not bank READY.** Keep FILL_BUSY and DMA_FILLING until commit/recovery.
4. Firmware checks both adapter success and successful MM2S completion. An error quarantines the bank. Only then write **ADP_CTRL[4]=COMMIT_FILL**, making the latched bank READY and clearing the fill slot.

ADP_STATUS[3] is AWAIT_COMMIT; its other existing fields retain their meanings. COMMIT_FILL is legal only when AWAIT_COMMIT is set and no adapter error exists. The latched reference stays stable, and writes to active fill configuration are rejected. Firmware must not arm a new fill until commit is visible. This gates already-queued consumers on genuine transfer success. The baseline fixes FILL_SEGS=1; segmented fills and NHWC_CB are rejected until a separate revision defines their commit/capability protocol.

For drains, require S2MM/adapter availability and a FULL bank first. Arm S2MM before emitting the adapter stream. Keep DRAINING until successful S2MM byte-count completion and adapter stream completion, then BANK_RELEASE. Neither adapter completion alone nor an error frees a bank.

The commit adds one ordered write per fill: **six fill writes**, before polling/IRQ acknowledgments. Revise traces and MMIO estimates accordingly. A documented build must not mix old automatic-READY semantics with this revision.

Research: [PG021 programming/alignment](https://docs.amd.com/r/en-US/pg021_axi_dma/Direct-Register-Mode-Simple-DMA), [MM2S_LENGTH](https://docs.amd.com/r/en-US/pg021_axi_dma/MM2S_LENGTH-MM2S-DMA-Transfer-Length-Register-Offset-28h), [S2MM_LENGTH](https://docs.amd.com/r/en-US/pg021_axi_dma/S2MM_LENGTH-S2MM-DMA-Buffer-Length-Register-Offset-58h), [AXI stream byte qualifiers](https://docs.amd.com/r/en-US/pg085-axi4stream-infrastructure/Master-Interface-Signals).

## 3. Capability and reset fields

Proposed additions occupy unused fields of the reviewed map:

| Register/bit | Meaning |
|---|---|
| NPU HW_FEATURES, offset 0x0B0, bit 0 | T_LOOPBACK (0x80) present |
| HW_FEATURES bit 1 | T_FILL (0x81) present |
| HW_FEATURES bit 2 | Operator/final-result writes to ACT banks supported |
| HW_FEATURES bit 3 | OUT1 physically present |
| HW_FEATURES bits 4–31 | Reserved zero; no channel-blocked capability in this revision |
| NPU STATUS[12] | QUIESCENT: no active local memory requests/writes or pending responses; does not imply queue empty |
| NPU CTRL[5] / STATUS[13] | ZERO_LOCAL / LOCAL_ZERO_BUSY: explicit erasure of local operand/product/accumulator/result storage |
| ADP_CTRL[4] / ADP_STATUS[3] | COMMIT_FILL / AWAIT_COMMIT (§2) |
| NPU CONV_CHUNK, offset 0x0B4 | RW staging: [15:0] cin_count; [31:16] reserved zero; non-Conv value zero |

Validate bank IDs against the versioned bank/presence table, not BANK_ID < bank_count: PRM remains ID 6 when optional OUT1/ID 5 is absent. Include full padded B-panel spans (ceil(N/8) panels), A pitches, PARAM records, PSUM and destination storage in capacity checks.

Validate normal opcodes 0x00–0x0F with HW_LIMITS[31:16], test opcodes 0x80/0x81 with HW_FEATURES, and reject all other opcodes. CPU fallback kernel availability is checked against the compiled CPU registry, not the NPU bitmap. Disabled capabilities must fail explicitly. Cleanup-enabled builds retain T_FILL, even when labeled demo/release.

SOFT_RESET cancels/quiesces local execution before returning IDLE, flushes the NPU queue, clears pending IRQ/error/counters and staging fields, sets NEXT_SEQ=0 and DONE_SEQ=0xFFFF, and invalidates local execution context. CLEAR_ERR clears diagnostics only and does not resume the halted queue. Reset does not erase BRAM or replace the coordinated DMA/adapter recovery procedure.

ZERO_LOCAL is a separate W1S action legal only with QUIESCENT and Q_EMPTY; otherwise reject it with AXI SLVERR. It asserts LOCAL_ZERO_BUSY, blocks START, clears local operand/product/accumulator/result storage to raw zero, invalidates cached valid/context bits, and deasserts busy only when erasure completes. Preserve performance counters. Bound completion and verify internal storage clearing in RTL; invalidating a valid bit alone is not erasure. Add these fields to the future generated header/RDL together and enforce VERSION compatibility; legacy blobs/firmware must not silently reinterpret them.

## 4. Mailbox ownership and cleanup

The mailbox remains 64 bytes and uncached. Keep its existing eleven words through profile_addr; replace the five reserved words with request_id, completed_request_id, response_code, and two reserved words. All are 32-bit; preserve the existing field offsets preceding them. Update the mailbox ABI version.

Commands: IDLE=0, RUN_MODEL=1, SELF_TEST=2, SHUTDOWN=3, **RECLAIM=4**. Lifecycle: READY=0, BUSY=1, DONE=2, CLEARING=3, STOPPED=4, INIT=5; terminal faults use `0x80000000 | error_code`. Invalid-state requests return response_code without changing the lifecycle or buffer ownership.

```text
INIT -> initialization and required cleanup -> READY
READY -> host stages/cleans input -> RUN_MODEL -> BUSY
BUSY -> output committed to DDR, banks/local buffers cleared -> DONE
DONE -> host invalidates/reads output -> RECLAIM -> CLEARING -> READY
DONE -> host has read output -> SHUTDOWN -> CLEARING -> STOPPED
```

SELF_TEST is accepted only in READY and returns to READY after its cleanup. SHUTDOWN in READY can clear owned allocations and enter STOPPED. RUN_MODEL is rejected while DONE; it never triggers cleanup. The host waits for READY before staging another input.

Permit one outstanding request. Host writes payload/command, completes A53 ordering/cache maintenance, then publishes a new request_id last. Runtime writes response/status/output fields, then completed_request_id last. Read a response only for the matching ID; repeats do not re-execute a request. A runtime boot initializes INIT and invalidates the previous session/IDs before publishing READY; a restarting loader resynchronizes instead of replaying an old request.

For noncoherent DDR, clean host-written inputs before ownership transfer and invalidate completed outputs before reading. Before RECLAIM, relinquish old allocations and complete maintenance so no stale dirty cache line can undo cleanup. Do not access runtime-owned allocations during BUSY/CLEARING. RISC-V fences do not substitute for A53 maintenance/barriers.

With RAVEN_CFG_ZEROIZE enabled (required for demonstrations), after final output reaches DDR capture inference counters, quiesce all owners, release retained banks, then T_FILL each scratchpad bank with raw zero and release it. Invoke ZERO_LOCAL and await its completion before publishing DONE. Preserve DDR output until RECLAIM/SHUTDOWN. Clear every used activation/workspace allocation and owned padding before reuse; track these ranges in the arena plan. A measured CPU-store clear is the initial implementation, rather than an unspecified DMA zero generator. This is a used-allocation policy, not a promise to wipe untouched parts of the entire 64 MiB arena. Report bank cleanup, arena cleanup, inference time, and RUN-to-DONE latency separately.

Research: [AMD PS/PL coherency example](https://xilinx-wiki.atlassian.net/wiki/spaces/A/pages/18842098/Zynq%2BUltraScale%2BMPSoC%2BCache%2BCoherency). The lifecycle and ownership protocol are RAVEN design choices.

## 5. CPU/NPU constants and numeric metadata

Retain original TFLite-order weights and original INT32 bias for every weighted layer in the blob. NPU-executed layers additionally reference derived packed B and corrected-bias records. Keep distinct references and explicit layout IDs; a CPU kernel never interprets packed B as raw weights or corrected bias as original bias.

```text
CPU: acc = original_bias + sum((a_q - z_a)*w_q)
NPU: corrected_bias = original_bias - z_a*sum(full_layer_weights)
     acc = corrected_bias + sum(a_q*w_q)
```

Validate symmetric weights (weight zero-point zero), INT32 seeds, and raw intermediate ranges using wide host calculations. Apply full-layer correction/bias once at ACC_INIT, not per K chunk. Virtual Conv padding supplies a_q=z_a. PER_CHANNEL still selects only requant scale granularity, not whether per-output bias exists.

PARAM records retain 16 bytes/channel: little-endian int32 corrected_bias at byte 0, int32 multiplier at 4, signed int8 shift at 8, and seven zero padding bytes. Record indices are logical output channels. CPU references use original constants and the same pinned prepared multiplier/shift and activation parameters; softmax/depthwise preparation is exported explicitly for the chosen kernel. Quantization preparation runs on the host.

Replace scale_q31 with **uint32 scale_f32_bits**, preserving the original IEEE-754 binary32 scale bit pattern; 1.0 is 0x3F800000. Per-axis scale arrays retain binary32 bits and quantized-axis metadata. Execution multipliers remain signed INT32 Q31 values with separate signed shifts. Scale storage does not require an inference FPU. Reject zero, negative, or nonfinite scales.

Blob metadata must distinguish raw_weight_ref, original_bias_ref, packed_weight_ref, npu_param_ref, CPU kernel/preparation reference, exec mode, dtype/layout, logical dimensions, byte strides, logical/storage lengths, and per-axis quantization. Offsets are uint32 relative to the declared blob/arena, sizes/counts uint32, and signed quantities explicitly int32/int8 as above. Sections are little-endian and 16-byte aligned. A generated C table and binary decoder populate the same logical executor records; never serialize native C struct padding. Before exporter/runtime implementation, commit the versioned byte-offset/record-size schema and round-trip fixtures at M4. No working codec is claimed by this semantic contract.

Validate version, section/count arithmetic, offsets, layouts, quantization, CPU kernel support, and NPU capabilities before DMA. CRC32 is corruption detection, not authentication. Original+derived copies cost DDR storage rather than another scratchpad bank; publish actual packed sizes. [LiteRT quantization](https://developers.google.com/edge/litert/conversion/tensorflow/quantization/quantization_spec), [pinned TFLM Conv](https://github.com/tensorflow/tflite-micro/blob/c051fea55c4a6b4464186e1bb126708bea50f32e/tensorflow/lite/micro/kernels/internal/reference/integer_ops/conv.h).

## 6. Timed waits, recovery, and completion tickets

Route an AXI Timer interrupt into INTC; a proposed 1 ms tick remains enabled during NPU/DMA waits. Every wait checks status and a deadline in an event loop, including when an IRQ is lost. WFI is only its idle step. Compute/drain deadlines cover normal work and allowed stalls; derive them per operation rather than imposing a universal 10 ms duration limit.

Recover by canceling the failed execution:

1. Stop submissions, cancel software-pending work/tickets, preserve diagnostics, and quarantine banks.
2. ABORT from any active state, including ISSUE/DRAIN; await bounded QUIESCENT, accounting for pipeline and memory responses.
3. Reset AXI DMA and await reset completion for both channels. Keep the adapter servicing old transfers until DMA quiesces; do not free storage or remove its endpoint prematurely.
4. Reset the adapter, SOFT_RESET/flush NPU queues, clear IRQs, and invalidate PSUM/local cached context.
5. Reclaim bank metadata only after all owners quiesce, perform required cleanup, and reinitialize DMA/IRQs. Invalidate the MMIO write-elision shadow.
6. Resynchronize NEXT_SEQ, increment a software recovery generation, and return to usable state only after success.

Software tickets contain `{uint32 generation, uint64 command_id}`. Assign monotonically increasing command IDs from zero within a generation; hardware receives the low 16 bits. Increment generation on every sequencer reset/recovery, cancel old-generation tickets, and reject counter exhaustion instead of reusing an ID. Hardware sequence wrap alone does not reuse a software ticket.

Keep a FIFO of issued but not yet reaped IDs, plus the last observed 16-bit DONE_SEQ (initially 0xFFFF). On a status sample, delta=(DONE_SEQ-last_seen_done)&0xFFFF; advance only when delta is within the known issued-not-reaped count, otherwise report a hardware-state error. Reap that many entries and retain their highest 64-bit ID as a completed watermark with an explicit initially-false valid flag. Bound issued-not-reaped work below 32,768 and sample/reap before that bound, including with lost interrupts. A wait checks generation, assigned-ID validity, then the full-width completed watermark; it never compares an arbitrarily old ticket directly with 16-bit DONE_SEQ. Specify logical ticket fields rather than assuming a packed wire struct.

If quiescence/reset fails, remain in terminal fault and use documented board/system recovery; never mark a bank FREE while a writer might remain active. Timer-driven recovery assumes an operational CPU/MMIO/timer path. It does not guarantee recovery from a completely blocked interconnect. T10's ≤20 ms reporting target applies to listed recoverable fixtures configured with 10 ms deadlines; successful restart is checked separately. Other operations use their declared deadline plus timer/handler overhead.

Research: [AXI Timer interval interrupts](https://docs.amd.com/r/en-US/pg079-axi-timer/Functional-Description), [RISC-V WFI](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html), [DMA reset affects both channels](https://docs.amd.com/r/en-US/pg021_axi_dma/MM2S_DMACR-MM2S-DMA-Control-Register-Offset-00h).

## 7. Measurements and required integration evidence

Measure T5 with same-clock ILA probes on npu_irq and a dedicated ISR-entry GPIO marker. The assembly entry stub makes the marker write its first instrumented action; begin with marker low and only DONE enabled for an isolated NOP. Target ≤2 µs IRQ-to-observed-marker, including marker/MMIO overhead. A passing bound bounds actual entry; a slow marker does not alone identify entry latency. A running CYC_TOTAL is not a latched event timestamp. [AMD ILA guide](https://docs.amd.com/api/khub/documents/aDiRFjuULD9RnRTU0Olwig/content).

Required acceptance evidence:

- Operand delivery: M/N/K edges, aligned pitches, K chunks, delayed read responses, stalls, and Conv padding/stride/dilation; post-route timing and measured refill/input stalls.
- DMA: 1/2/3/10/12/15/16/17/490-byte packets and bank boundaries; guard bytes, final-beat stalls, adapter-before-DMA completion, error-before-commit, and rejected oversized requests.
- Ownership: retained READY/FULL sources, typed PSUM continuation, ACT destination reservations, and rejection of unsupported routes/segmented layouts.
- Mailbox: two distinct consecutive inputs, delayed output acknowledgment, duplicate IDs, invalid-state requests, shutdown, cache-enabled host staging, and cleanup readback.
- Recovery: lost IRQ, never-done compute, stuck output, malformed packet, DMA fault, abort in every active phase, late completion, sequence wraparound, old completed tickets across 32,768/65,536 subsequent commands, stale reset-generation tickets, and a fresh successful operation afterward.
- Export/numerics: raw/derived constant round-trip, scale 1.0/per-axis scales, zero-point correction and bias applied once, and zero element mismatches against the pinned reference on designated supported fixtures.

Host feasibility work on October 23 passed 60 GEMM layout cases, 28 accumulation cases using all 14 committed FC operators, four Conv-window cases, and eleven packet-length expectations. These were arithmetic/address checks, not RTL, DMA-IP, timing, full-inference, or quality results. The host FC chunk choices did not establish bank fit; the deployed tiler must validate all padded operand, PARAM, PSUM, and destination footprints.
