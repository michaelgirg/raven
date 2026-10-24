# RAVEN NPU Operators and Datapath Support

**Status:** Initial research and proposed operator architecture; implementation has not started.

**Owner:** Quan — NPU Operators + Datapath Support.

**Target:** AMD/Avnet Ultra96-V2 (Zynq UltraScale+ MPSoC ZU3EG).

**Shared baseline:** the [interface contract](interfaces/RAVEN_INTERFACE_CONTRACT.md) defines one-lane destination routing, per-output records, canonical CPU constants, and recovery. [Project acceptance](PROJECT_PLAN.md) specifies numerical and application checks. These are design requirements pending implementation verification.

## 1. Summary

RAVEN's proposed compute core produces signed INT32 completed dot-product results from signed INT8 operands. This document plans the supporting operators that turn those results into usable INT8 feature maps and handle model operations outside dense Conv2D/GEMM: requantization, ReLU/clamps, pooling, element-wise addition, and depthwise convolution.

The first compatibility path should be Deep Autoencoder (AD01): GEMM plus completed-output requantization and fused ReLU. DS-CNN and MobileNetV1 then make depthwise convolution and average pooling important. ResNet-8 adds element-wise ADD, but it is not in Jackie's recommended first three models. Max pooling is retained as an extension because it is not reported in the current five-model inventories.

This is a design proposal, not an RTL, performance, resource, or model-verification result. The shared command fields and scratchpad interfaces cited below require team sign-off.

## 2. Scope and Architecture Context

Michael's proposal is an 8×8 output-stationary INT8 MAC array (64 scalar MACs) with an INT32 architectural accumulation result and a 100 MHz minimum design target. Completed results leave the array through a result interface; they must not be requantized while a K-dimension reduction is incomplete. Taylor's proposal uses BRAM-resident activation, weight, output, and partial-sum buffers with bank ownership. Nahjay's proposal dispatches bank-resident commands and has `valid/ready` behavior and a command-complete boundary after all output data is written.

The appropriate initial organization is therefore:

```text
MAC result (INT32, complete reduction)
  → per-output bias/correction already represented in accumulator seed
  → requantize (INT32 → INT8) → optional activation clamp → output staging/scratchpad

Scratchpad INT8 tensor → standalone pool / standalone ReLU / EWADD → scratchpad INT8 tensor
```

The result path needs `valid`, `ready`, data, output-channel/element tag, lane mask, and end-of-tile indication. It must retain a valid datum unchanged until accepted. A small FIFO or result snapshot may absorb short stalls, but it is not a substitute for a backpressure contract. Output order may be microtile order rather than global tensor order, so the write side needs the address/tag supplied by the compute controller; this document does not define that mapping.

## 3. Candidate Model Operator Requirements

The matrix below reports Jackie's `Quantized_Models.md` findings. The local MLCommons Tiny `.tflite` files were not present for independent inspection during this research; consequently no operator list below is independently verified.

| Model | Reported operators relevant here | Relevance |
|---|---|---|
| Deep Autoencoder (AD01) | Fused ReLU; FULLY_CONNECTED | First bring-up candidate; requires final INT32-to-INT8 conversion even when ReLU is fused. |
| DS-CNN | DEPTHWISE_CONV_2D, AVERAGE_POOL_2D, fused ReLU | Recommended model; reported per-channel weights. |
| MobileNetV1 0.25x | DEPTHWISE_CONV_2D, AVERAGE_POOL_2D, fused ReLU | Recommended model; depthwise-heavy and reported per-channel weights. |
| ResNet-8 | ADD, AVERAGE_POOL_2D, fused ReLU | ADD is required for residual paths, but this model is not in the proposed first three. |
| Streaming DS-CNN | DEPTHWISE_CONV_2D, fused ReLU | A later extension; no pooling is reported. |

`RESHAPE` is reported by several models but preserves tensor elements and quantization parameters; it should normally be metadata/layout handling rather than an arithmetic FPGA unit. `SOFTMAX` is reported by four models but is outside this assignment and should remain a runtime/model-selection decision. Dense Conv2D and FULLY_CONNECTED are Michael's compute scope.

## 4. Quantized Numeric Contract

LiteRT describes an INT8 value as `real = (q - z) × scale`. Activations may use any signed INT8 zero-point; INT8 Conv2D/DepthwiseConv2D weights are symmetric (`z = 0`) and can be per-axis. Bias is INT32 with scale `input_scale × weight_scale[channel]`. [LiteRT INT8 specification](https://developers.google.com/edge/litert/conversion/tensorflow/quantization/quantization_spec)

For a completed accumulator `a` and output channel `c`, a useful formulation is:

```text
y_q = clamp(qmin, qmax,
            rounded(a × (s_in × s_weight[c] / s_out)) + z_out)
```

`a` includes the INT32 bias and any agreed activation-zero-point correction. The mathematical equation above is useful for scale selection, but it is not a bit-exact arithmetic definition.

**Proposal for review — pinned integer reference.** Use TensorFlow Lite Micro (TFLM) commit [`c051fea55c4a6b4464186e1bb126708bea50f32e`](https://github.com/tensorflow/tflite-micro/tree/c051fea55c4a6b4464186e1bb126708bea50f32e), with `TFLITE_SINGLE_ROUNDING=1`, as RAVEN's initial golden integer convention. The selected helper is [`MultiplyByQuantizedMultiplier`](https://github.com/tensorflow/tflite-micro/blob/c051fea55c4a6b4464186e1bb126708bea50f32e/tensorflow/lite/micro/kernels/internal/common.cc); the reference requantization call sequence is in [`requantize.h`](https://github.com/tensorflow/tflite-micro/blob/c051fea55c4a6b4464186e1bb126708bea50f32e/tensorflow/lite/micro/kernels/internal/reference/requantize.h). This configuration choice is important: TFLM also has a different, double-rounding path when that build macro is absent. They must not be treated as bit-exact alternatives.

For the selected helper, `M` is a nonnegative signed `int32` significand with its binary point at bit 31 (Q0.31), and `s` is signed. It computes, in signed 64-bit arithmetic, `p = x × M`, then `r = arithmetic_right_shift(p + 2^(30-s), 31-s)`. Thus a positive `s` reduces the final right-shift count and scales up by a power of two; a negative `s` increases it and scales down. The supported reference range is `-31 ≤ s ≤ 30`. Adding the positive half-ULP before the arithmetic right shift gives round-to-nearest with halfway cases toward positive infinity: for an exact `+1.5` it returns `+2`, while an exact `-1.5` returns `-1`. This behavior, including negative ties, is the proposed hardware behavior; it is not generic “round to nearest.”

For a completed INT32 MAC result, use a signed 64-bit product and rounding-addend path, check that the shifted result fits signed INT32, add `Q_ZP.output` in a widened signed value, then apply the activation clamp (`Q_CLAMP`) and finally the INT8 storage range. The final clamp bounds must themselves be within `[-128, 127]`. There is no intermediate wraparound in the reference contract; an out-of-range product/result is an error condition to detect or preclude through model validation, not a value to silently wrap. Map `Q_MULT` to `M` and `Q_SHIFT[7:0]` to `s`, treating both as signed fields. This keeps Nahjay's proposed fields but requires the signed interpretation to be ratified.

Per-tensor parameters are sufficient for activations and pool outputs in the LiteRT scheme. For Conv2D and DepthwiseConv2D, index the weight/bias/multiplier/shift record by logical output channel, including channel multiplier in depthwise convolution. Nahjay's proposed 16-byte parameter record (`bias_corrected`, multiplier, shift, padding) is a reasonable placeholder, but its layout, corrected-bias range, and channel indexing remain proposals for team review.

**Bias is independent of scale granularity.** Under the shared proposal, PARAM supplies per-output corrected bias on every GEMM/Conv ACC_INIT, including AD01 with per-tensor scales. PER_CHANNEL=0 selects Q_MULT/Q_SHIFT for the tail but does not disable bias-vector access. Continuations and standalone REQUANT do not add bias again; bias-free layers use zero seeds. This matches the proposed PARAM contract in RISCV_Research.md §6.4.

## 5. Operator Research

### ReLU and activation clamps

ReLU implements `max(real_x, 0)`. In quantized storage, real zero is represented by `z_out`, not necessarily integer zero, so a standard ReLU after requantization is `max(q, z_out)`, followed by the normal INT8 upper bound. ReLU6 or a model-specific fused activation additionally uses a quantized upper clamp derived from the output scale and zero-point. The clamp must be applied in output quantization before values are committed to the INT8 tensor.

Fusing ReLU with final requantization avoids writing and rereading an intermediate INT8 tensor. `RELU_EN` should mean that output clamp policy is applied only on the final result of a GEMM/Conv command (`ACC_LAST`), not to intermediate INT32 partial sums. For final or standalone writes, reserve a distinct FREE destination and check OUT1/ACT-route capabilities. The selected one-lane ACT write proposal uses byte enables and exclusive bank ownership; four lanes need verified write combining/ports. A standalone `RELU` command remains useful for a graph boundary or an externally produced tensor; it is a comparator/mux per lane and needs no DSP. ReLU compatibility is high; a standalone dedicated unit is low priority because the requantizer can perform the fused form.

### Max and average pooling

Pooling reduces a window in an INT8 NHWC feature map, commonly using `Kh×Kw`, stride, and explicit/SAME/VALID padding metadata. Output dimensions and padding must be supplied by the command/layout contract; boundary windows must never read unowned scratchpad bytes. Reject an average-pool configuration that produces a window with no valid elements, matching the reference's zero-count failure instead of dividing by zero.

Max pool selects the largest *quantized integer* in a window. LiteRT requires input and output scale/zero-point to match, so no requantization is needed. For padding, the reference operator's padding semantics must be reproduced; a practical hardware rule is to compare only valid input elements, rather than inserting an arbitrary INT8 value. A line/window reader and comparator tree give one result per accepted window after fill. It consumes LUTs/registers primarily, and its size grows with window area and lane count.

Average pool requires a signed widened sum of the **raw quantized INT8 values** and a correctly rounded division by the count of valid input elements. LiteRT requires matching input/output scale and zero-point for AVERAGE_POOL_2D. The selected TFLM reference, [`integer_ops/pooling.h`](https://github.com/tensorflow/tflite-micro/blob/c051fea55c4a6b4464186e1bb126708bea50f32e/tensorflow/lite/micro/kernels/internal/reference/integer_ops/pooling.h), derives each window's start/end bounds by clipping the filter window to the input; its divisor is the resulting valid `filter_count`, not necessarily `Kh × Kw` at a padded edge. It accumulates raw values in a widened signed accumulator, then uses `(sum + n/2) / n` for positive sums and `(sum - n/2) / n` for nonpositive sums, with integer division truncating toward zero. This rounds a half away from zero: `3/2 → 2` and `-3/2 → -2`.

Centering each value, dividing, and adding the zero-point back is not a safe replacement for that integer sequence because rounding is applied at a different point. For example, with `z = 1`, `n = 2`, and raw values `[0, 1]`, the reference's raw sum is `1`, so it outputs `(1 + 1)/2 = 1`. Centering first gives `[-1, 0]`, whose rounded mean is `(-1 - 1)/2 = -1`; adding `z` produces `0`. Both expressions describe the same real average before rounding, but differ at a tie. Hardware should follow the raw-sum sequence above. Global average pooling is the same reduction with a window equal to the spatial input; it needs a wider counter/sum and is a common classification-head case.

The reported models require average, not max, pooling. Start with a standalone scratchpad-to-scratchpad pooling engine, sharing address generation/window buffering between modes. It should use backpressure at input and output and only declare command completion after the final output write. Do not assume a dedicated line buffer is justified before actual layer shapes and BRAM ports are agreed with Taylor.

### Element-wise Addition

Residual ADD combines two equal-shaped tensors. If their scales/zero-points differ, raw INT8 addition is incorrect. The scale equation is:

```text
t = round((a_q - z_a) × r_a) + round((b_q - z_b) × r_b)
y_q = clamp(round(t × r_out) + z_out)
```

For exact integer behavior, use the selected TFLM [`reference ADD`](https://github.com/tensorflow/tflite-micro/blob/c051fea55c4a6b4464186e1bb126708bea50f32e/tensorflow/lite/micro/kernels/internal/reference/integer_ops/add.h) path and the same [`common.cc`](https://github.com/tensorflow/tflite-micro/blob/c051fea55c4a6b4464186e1bb126708bea50f32e/tensorflow/lite/micro/kernels/internal/common.cc) helper. It subtracts each input zero-point; left-shifts both centered inputs by one shared `left_shift`; applies input A/B Q0.31 multiplier/shift pairs; adds the two INT32 scaled values; applies an output Q0.31 multiplier/shift; adds the output zero-point; then clamps to the activation bounds. Every multiplier call uses the single-rounding rule defined in Section 4. This staged integer process is the proposed golden behavior, whereas the equation above is only an approximation of its real-number intent.

Use signed 64-bit multiply/round intermediates within each multiplier; retain each scaled input, their sum, the output-scaled value, and zero-point addition in at least signed INT32 with range checks before narrowing. Bias-style per-channel parameters are not implied by LiteRT ADD, which specifies per-tensor inputs and output. The pinned ADD code calls SmallerThanOneExp at all three scaling stages: require nonnegative multipliers and signed shifts in [-31, 0], rather than the general requant helper's wider shift range. Map `Q_MULT_A`, `Q_MULT_B`, and their signed `Q_SHIFT` input fields to the two input multiplier/shift pairs; map `Q_MULT` and `Q_SHIFT[7:0]` to the output pair; and use the existing `Q_ZP` bytes for input A, input B, and output zero-points.

An EWADD engine needs two scratchpad read streams, address/shape checking, two multiplier/shift paths (which may be time-multiplexed if throughput permits), an adder, and a final clamp. It is a medium compatibility priority because it enables reported ResNet-8, and a medium dedicated-hardware priority. **Shared interface proposal:** encode Q_EWADD_LEFT_SHIFT as unsigned EWADD P1[7:0], with supported range 0–20 and upper bits zero, as specified in RISCV_Research.md §6.4. Derive matching scale pairs from the pinned reference preparation and validate intermediate ranges. Do not reinterpret either signed input multiplier shift as this common pre-shift; that changes the rounding sequence.

### Depthwise convolution

Depthwise convolution applies one spatial filter per input channel (or `depth_multiplier` filters per channel), unlike dense Conv2D, where each output channel reduces across all input channels. For an NHWC input, a direct form is:

```text
out[oh, ow, oc] = bias[oc] + Σkh,kw
    (in[ih, iw, ic] - z_in) × weight[kh, kw, oc]
```

where `ic = floor(oc / depth_multiplier)` and out-of-bounds input uses `z_in`. It has much less arithmetic reuse across channels than dense convolution; expanding it into a dense GEMM with zero weights wastes MACs and bandwidth. DS-CNN, MobileNetV1, and Streaming DS-CNN report it, so compatibility priority is high. Their reported per-channel weight quantization means each `oc` requires its own bias/multiplier/shift record.

Three paths should be evaluated, not silently chosen:

1. **Software fallback:** use the RISC-V/runtime for early functional coverage. It is lowest hardware risk but likely slow; measure its share of DS-CNN/MobileNet execution before relying on it.
2. **Direct MAC-array mode:** schedule independent channel/window dot products on the existing scalar MAC resources. This maximizes reuse of existing arithmetic but needs a gather/scheduling mode and may underutilize the 8×8 dense mapping.
3. **Dedicated streaming depthwise unit:** use line/window buffering, per-channel weight streams, INT32 accumulators, and the common requantize/activation tail. This better matches the operation but adds control, BRAM-port pressure, and verification scope.

Initial recommendation: reserve `DWCONV` as Nahjay proposes, retain a software fallback for bring-up, and decide on direct-array versus dedicated hardware after M7-style measurements and actual layer dimensions. A depthwise output can share the completed INT32 requantize/activation pipeline in all three cases.

CPU fallback/reference kernels receive original TFLite-order weights and original bias. NPU execution receives separately referenced packed B and corrected bias. Never apply the activation zero-point correction twice. Export prepared integer parameters for the pinned CPU kernels; source scales use scale_f32_bits, distinct from Q31 execution multipliers. PARAM records remain 16 bytes/channel with int32 bias at 0, int32 multiplier at 4, int8 shift at 8, and seven zero bytes. See the [constant/numeric contract](interfaces/RAVEN_INTERFACE_CONTRACT.md#5-cpunpu-constants-and-numeric-metadata).

## 6. Proposed Operator Table

“Compatibility” is workload importance; “dedicated hardware” is whether a separate unit is justified immediately.

| Operator | Preliminary Priority | Inputs | Outputs | Proposed Hardware Implementation | Tradeoffs / Notes |
|---|---|---|---|---|---|
| Requantization | Compatibility: High; dedicated: High | Completed INT32 result; per-tensor or per-channel params | INT8 tensor | Shared multiplier/shift, rounding, zero-point add, saturating clamp tail; fuse after final MAC reduction | Required to use INT32 MAC results. Parameterized pipeline must sustain accepted result rate or backpressure safely. |
| ReLU / clamp | Compatibility: High; dedicated: Low | INT8 post-requant value or standalone INT8 tensor | INT8 tensor | Comparator/mux in requant tail; standalone streaming clamp only when graph requires it | ReLU threshold is output zero-point, not necessarily literal zero. |
| Average Pool | Compatibility: High; dedicated: Medium | INT8 NHWC, window/stride/padding | INT8 NHWC | Scratchpad streaming window reader, widened sum, rounded divide | Reported for DS-CNN, MobileNetV1, ResNet-8. Same input/output quantization. |
| Max Pool | Compatibility: Low; dedicated: Low | INT8 NHWC, window/stride/padding | INT8 NHWC | Same reader with comparator tree | Extension only; absent from Jackie's current inventories. Same quantization in/out. |
| EWADD | Compatibility: Medium; dedicated: Medium | Two INT8 tensors plus per-tensor quantization | INT8 tensor | Two rescale paths, INT32 add, shared output requant/clamp | Reported for ResNet-8; needs two scratchpad read streams and exact rounding policy. |
| Depthwise Conv | Compatibility: High; dedicated: Deferred | INT8 NHWC, per-channel INT8 weights, INT32 bias/params | INT8 NHWC | Initial CPU fallback; evaluate direct MAC-array mode or dedicated windowed unit; share requant tail | Required by DS-CNN/MobileNet. Per-channel indexing, padding, and channel multiplier need explicit support. |

## 7. Datapath Integration and Priorities

For `CONV2D`/`GEMM`, the compute controller should present only completed INT32 outputs to the operator tail. Bias and activation zero-point handling must occur exactly once per output reduction as agreed with Michael. On final K chunks, `REQUANT_EN` and `RELU_EN` can keep data on the result path and avoid an INT32 scratchpad round trip. On non-final chunks, `DST_ACCUM` must preserve INT32 partial sums and bypass the tail.

Standalone REQUANT, POOL, RELU, and EWADD read/write completed scratchpad tensors. Under Nahjay's proposed typed-source rules, POOL/RELU/EWADD may consume READY INT8 inputs or FULL INT8 outputs; retained FULL sources return to FULL, and retained READY inputs return to READY. REQUANT consumes a READY, validated completed INT32 tensor; an unfinished tagged PSUM is reserved for GEMM/Conv continuation, not standalone operators. A consumed source is COMPUTING, so DMA cannot overwrite or drain it; release follows the command flags. Standalone output operators use a distinct FREE destination bank and never overwrite an active source. Final MAC requantization reads the explicit PSUM_SRC/PSUM_PITCH context when continuing and writes to the separate INT8 DST (§6.6 of RISCV_Research.md).

**Shared preliminary result-tail plan.** Parameterize RESULT_LANES consistently across Michael's result interface, this tail, and Taylor's write path. Use **one lane for proposed functional bring-up**, with **four lanes as an evaluation configuration**; the integrated choice remains subject to joint sign-off. Both target initiation interval (II) one, not one-cycle latency. At 100 MHz, one lane has an ideal 100 million results/s and 100 MB/s INT8 output; four lanes have 400 million results/s and 400 MB/s output. Four INT32 input lanes require 16 bytes/cycle into the tail. These are analytical targets, not achieved rates. An 8×8 tile drains in 64 issue cycles with one lane, 16 with four, or 8 with eight, before stalls and pipeline latency.

Evaluate whether four lanes' reduced drain time justifies extra multiplier/rounding pipelines, parameter delivery/cache bandwidth, tags/address paths, and scratchpad writes. No resource or timing fit is assumed. Instrument CYC_STALL_OUT, FIFO occupancy, accepted results, and drain cycles on the same workloads. Hold each lane's data/tag/mask stable under backpressure; the beat-level acceptance contract must match the compute interface. Select the built lane count from those measurements rather than treating the four-lane alternative as already adopted.

Recommended staged work is: (1) define and verify one common requantize/clamp arithmetic helper and fuse it behind GEMM for AD01; (2) add average-pool scratchpad flow for DS-CNN; (3) measure/choose depthwise path; (4) add EWADD when ResNet-8 enters scope; and (5) retain max pool as an optional shared-pool-mode extension. This is a planning order, not a change to the team's opcode map.

## 8. Verification Considerations

Use trusted LiteRT/TFLite or independently written integer golden references with the exact model parameters; do not compare only against floating-point outputs. Minimum functional acceptance criteria are:

- Requantize/clamp matches the pinned TFLM single-rounding reference for positive/negative INT32 accumulators, `INT8_MIN`/`INT8_MAX`, nonzero zero-points, ties around rounding boundaries, every saturation direction, and per-channel records.
- ReLU fused and standalone produce the same INT8 result for the same source/output quantization, including nonzero output zero-point and finite upper clamps.
- Max and average pool match golden tensors for 1×1, normal, global, stride-greater-than-one, and edge/padded windows; average cases include negative sums and non-power-of-two divisors.
- EWADD matches the pinned TFLM ADD sequence when inputs share quantization and when both scale and zero-point differ; test pre-shift behavior, each multiplier rounding stage, saturation, and tensor-shape mismatch errors.
- Depthwise convolution matches golden output for multiple channels, depth multiplier greater than one if supported, padding, stride, nonzero activation zero-point, INT32 bias, and distinct per-output-channel scales.
- Verify canonical CPU and derived NPU constants, bias/correction once across K chunks, scale 1.0/per-axis metadata, and supported ACT/OUT destination routes.
- Inject downstream `ready` stalls and scratchpad/DMA delays. Every accepted output appears once at its intended address; no output is reordered beyond the documented tagged order, dropped, or overwritten.

Before claiming hardware support, run those vectors through the selected implementation and record mismatch count, command errors, and stall behavior. No simulation, synthesis, or FPGA measurement has been completed by this research.

## 9. Outstanding Decisions

1. Implement and verify the selected TFLM commit `c051fea55c4a6b4464186e1bb126708bea50f32e` with `TFLITE_SINGLE_ROUNDING=1` as the golden arithmetic reference, including its signed-shift, tie, overflow, and clamp behavior.
2. Implement the shared 16-byte parameter record and logical output-channel indexing; verify corrected-bias ranges with Michael and Jackie.
3. Generate reproducible fixtures from Jackie's artifact-specific inventory; preserve hashes, exact operator settings, prepared parameters, and pinned rounding configuration.
4. Ratify unsigned EWADD P1[7:0] for Q_EWADD_LEFT_SHIFT (supported 0–20) and the widened POOL P2 stride bytes; verify DS-CNN's stride 25 and ADD stage ordering.
5. Select a depthwise fallback/direct-array/dedicated-unit path after measured model profiling and BRAM-port analysis.
6. Ratify the common RESULT_LANES parameter (one-lane bring-up, four-lane evaluation), tags/order, and II; in-place aliasing remains deferred. Agree typed-bank ownership and explicit PSUM source/destination references.

## 10. References

1. Google, [LiteRT 8-bit quantization specification](https://developers.google.com/edge/litert/conversion/tensorflow/quantization/quantization_spec). Defines INT8 affine quantization, per-axis Conv2D/DepthwiseConv2D weights, bias scales, and the listed pooling/ADD formats.
2. Google, [LiteRT and TensorFlow operator compatibility](https://developers.google.com/edge/litert/conversion/tensorflow/ops_compatibility). Describes conversion and operator fusing context.
3. Michael, [RAVEN NPU Compute Architecture](NPU_ARCHITECTURE.md), especially §§5, 8, and 11. Internal proposed INT8/INT32 compute/result-interface assumptions.
4. Taylor, [RAVEN Memory System Research](RAVEN_Memory_System_Research.md), especially §§5–7. Internal proposed scratchpad, bank ownership, and DMA assumptions.
5. Nahjay, [RISC-V Research](RISCV_Research.md), especially §§6.2–6.4 and 21. Internal proposed opcode, command, and quantization-field interface.
6. Jackie, [RAVEN Quantized Models Research](Quantized_Models.md). Reported candidate-model operators and preliminary quantization observations.
7. MLCommons Tiny, [benchmark training models](https://github.com/mlcommons/tiny/tree/master/benchmark/training). Source location for the model artifacts referenced by Jackie's research; not independently inspected here.
8. TensorFlow Lite Micro, [pinned commit `c051fea55c4a6b4464186e1bb126708bea50f32e`](https://github.com/tensorflow/tflite-micro/tree/c051fea55c4a6b4464186e1bb126708bea50f32e): [`common.cc`](https://github.com/tensorflow/tflite-micro/blob/c051fea55c4a6b4464186e1bb126708bea50f32e/tensorflow/lite/micro/kernels/internal/common.cc), [`requantize.h`](https://github.com/tensorflow/tflite-micro/blob/c051fea55c4a6b4464186e1bb126708bea50f32e/tensorflow/lite/micro/kernels/internal/reference/requantize.h), [`integer_ops/add.h`](https://github.com/tensorflow/tflite-micro/blob/c051fea55c4a6b4464186e1bb126708bea50f32e/tensorflow/lite/micro/kernels/internal/reference/integer_ops/add.h), and [`integer_ops/pooling.h`](https://github.com/tensorflow/tflite-micro/blob/c051fea55c4a6b4464186e1bb126708bea50f32e/tensorflow/lite/micro/kernels/internal/reference/integer_ops/pooling.h). Proposed reference source for Sections 4–5; the source files, build macro, and commit must be retained together.
