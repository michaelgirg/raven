# RAVEN NPU Operators and Datapath Support

**Status:** Initial research and proposed operator architecture; implementation has not started.

**Owner:** Quan — NPU Operators + Datapath Support.

**Target:** AMD/Avnet Ultra96-V2 (Zynq UltraScale+ MPSoC ZU3EG).

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

`a` includes the INT32 bias and any agreed activation-zero-point correction. Store the real multiplier as an integer fixed-point multiplier `M` plus a signed exponent/shift, rather than treating `Q_MULT` as a floating-point value. A conventional Q31 interpretation represents an approximately fractional multiplier by `M / 2^31`; a signed shift then accounts for the remaining power of two. The exact convention must state whether a positive `Q_SHIFT` means left or right shift, the rounding rule for negative values, and saturation order. Those details are necessary for golden vectors and bit-exact comparison.

**Proposal for review:** use a signed 32-bit Q31 multiplier, a signed shift, round-to-nearest with an explicitly specified tie rule, add `z_out` in a widened value, then saturate/clamp to signed INT8. Apply the same defined helper in fused and standalone REQUANT. Do not rely on implementation-language right-shift behavior for negative values. Saturation is required; truncation or wraparound creates materially different inference results.

Per-tensor parameters are sufficient for activations and pool outputs in the LiteRT scheme. For Conv2D and DepthwiseConv2D, index the weight/bias/multiplier/shift record by logical output channel, including channel multiplier in depthwise convolution. Nahjay's proposed 16-byte parameter record (`bias_corrected`, multiplier, shift, padding) is a reasonable placeholder, but its layout, corrected-bias range, and channel indexing remain proposals for team review.

## 5. Operator Research

### ReLU and activation clamps

ReLU implements `max(real_x, 0)`. In quantized storage, real zero is represented by `z_out`, not necessarily integer zero, so a standard ReLU after requantization is `max(q, z_out)`, followed by the normal INT8 upper bound. ReLU6 or a model-specific fused activation additionally uses a quantized upper clamp derived from the output scale and zero-point. The clamp must be applied in output quantization before values are committed to the INT8 tensor.

Fusing ReLU with final requantization avoids writing and rereading an intermediate INT8 tensor. `RELU_EN` should mean that output clamp policy is applied only on the final result of a GEMM/Conv command (`ACC_LAST`), not to intermediate INT32 partial sums. A standalone `RELU` command remains useful for a graph boundary or an externally produced tensor; it is a comparator/mux per lane and needs no DSP. ReLU compatibility is high; a standalone dedicated unit is low priority because the requantizer can perform the fused form.

### Max and average pooling

Pooling reduces a window in an INT8 NHWC feature map, commonly using `Kh×Kw`, stride, and explicit/SAME/VALID padding metadata. Output dimensions and padding must be supplied by the command/layout contract; boundary windows must never read unowned scratchpad bytes.

Max pool selects the largest *quantized integer* in a window. LiteRT requires input and output scale/zero-point to match, so no requantization is needed. For padding, the reference operator's padding semantics must be reproduced; a practical hardware rule is to compare only valid input elements, rather than inserting an arbitrary INT8 value. A line/window reader and comparator tree give one result per accepted window after fill. It consumes LUTs/registers primarily, and its size grows with window area and lane count.

Average pool requires a signed widened sum of the quantized window values and a correctly rounded division by the count of valid elements. LiteRT likewise requires matching input/output scale and zero-point for AVERAGE_POOL_2D. It can be implemented as a small INT16/INT32 accumulator plus constant divide/shift logic for fixed windows; variable boundary counts need selectable divisors or a reciprocal-multiply implementation. To preserve asymmetric quantization cleanly, average centered values and then add the common zero-point, equivalently `round(sum(q)/n)` when every element uses the same quantization and the intended rounding rule is honored. Global average pooling is the same reduction with a window equal to the spatial input; it needs a wider counter/sum and is a common classification-head case.

The reported models require average, not max, pooling. Start with a standalone scratchpad-to-scratchpad pooling engine, sharing address generation/window buffering between modes. It should use backpressure at input and output and only declare command completion after the final output write. Do not assume a dedicated line buffer is justified before actual layer shapes and BRAM ports are agreed with Taylor.

### Element-wise Addition

Residual ADD combines two equal-shaped tensors. If their scales/zero-points differ, raw INT8 addition is incorrect. Center each input, rescale both to a common accumulator scale, add in a widened signed path, requantize to the output scale, add `z_out`, and clamp:

```text
t = round((a_q - z_a) × r_a) + round((b_q - z_b) × r_b)
y_q = clamp(round(t × r_out) + z_out)
```

The exact decomposition into `r_a`, `r_b`, and `r_out` is a team-reviewed fixed-point convention; it must match the model/runtime reference. Use at least INT32 intermediates because two shifted/rescaled INT8 values can exceed INT8. Bias-style per-channel parameters are not implied by the LiteRT ADD specification, which lists per-tensor inputs and output.

An EWADD engine needs two scratchpad read streams, address/shape checking, two multiplier/shift paths (which may be time-multiplexed if throughput permits), an adder, and a final clamp. It is a medium compatibility priority because it enables reported ResNet-8, and a medium dedicated-hardware priority: it is much cheaper than a MAC array, but does need two read ports/banks. Nahjay's `Q_MULT_A`, `Q_MULT_B`, input zero-points, output zero-point, and shifts are appropriate placeholders; their exact left-pre-shift and rounding semantics must be finalized with this document's numeric contract.

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

Standalone REQUANT, POOL, RELU, and EWADD should read/write scratchpad tensors because their input is a completed tensor and because this respects Taylor's bank ownership and Nahjay's command completion rules. The dispatch unit waits for all source banks to be `READY`; an operator transitions them through its consuming state and releases them only under the agreed flags. It must not overwrite a bank that is still a source, including an aliasing/in-place request, unless that case is explicitly proven safe.

Recommended staged work is: (1) define and verify one common requantize/clamp arithmetic helper and fuse it behind GEMM for AD01; (2) add average-pool scratchpad flow for DS-CNN; (3) measure/choose depthwise path; (4) add EWADD when ResNet-8 enters scope; and (5) retain max pool as an optional shared-pool-mode extension. This is a planning order, not a change to the team's opcode map.

## 8. Verification Considerations

Use trusted LiteRT/TFLite or independently written integer golden references with the exact model parameters; do not compare only against floating-point outputs. Minimum functional acceptance criteria are:

- Requantize/clamp matches the selected integer reference for positive/negative INT32 accumulators, `INT8_MIN`/`INT8_MAX`, nonzero zero-points, ties around rounding boundaries, every saturation direction, and per-channel records.
- ReLU fused and standalone produce the same INT8 result for the same source/output quantization, including nonzero output zero-point and finite upper clamps.
- Max and average pool match golden tensors for 1×1, normal, global, stride-greater-than-one, and edge/padded windows; average cases include negative sums and non-power-of-two divisors.
- EWADD matches golden tensors when inputs share quantization and when both scale and zero-point differ; test saturation and tensor-shape mismatch errors.
- Depthwise convolution matches golden output for multiple channels, depth multiplier greater than one if supported, padding, stride, nonzero activation zero-point, INT32 bias, and distinct per-output-channel scales.
- Inject downstream `ready` stalls and scratchpad/DMA delays. Every accepted output appears once at its intended address; no output is reordered beyond the documented tagged order, dropped, or overwritten.

Before claiming hardware support, run those vectors through the selected implementation and record mismatch count, command errors, and stall behavior. No simulation, synthesis, or FPGA measurement has been completed by this research.

## 9. Outstanding Decisions

1. Ratify the Q31 multiplier and signed-shift convention, rounding/tie rule, overflow behavior, and clamp order for all `Q_*` fields.
2. Ratify per-channel parameter record fields, logical output-channel indexing, and corrected-bias range with Michael, Nahjay, Taylor, and Jackie.
3. Confirm whether actual model files use only the reported operators and determine exact pooling/window, activation, quantization, and depthwise depth-multiplier parameters by inspecting the selected `.tflite` artifacts.
4. Specify pooling padding/division semantics and EWADD's fixed-point rescale decomposition against the runtime golden reference.
5. Select a depthwise fallback/direct-array/dedicated-unit path after measured model profiling and BRAM-port analysis.
6. Agree result tags/order, result-tail throughput, and legal in-place scratchpad aliasing with the compute and memory owners.

## 10. References

1. Google, [LiteRT 8-bit quantization specification](https://developers.google.com/edge/litert/conversion/tensorflow/quantization/quantization_spec). Defines INT8 affine quantization, per-axis Conv2D/DepthwiseConv2D weights, bias scales, and the listed pooling/ADD formats.
2. Google, [LiteRT and TensorFlow operator compatibility](https://developers.google.com/edge/litert/conversion/tensorflow/ops_compatibility). Describes conversion and operator fusing context.
3. Michael, [RAVEN NPU Compute Architecture](NPU_ARCHITECTURE.md), especially §§5, 8, and 11. Internal proposed INT8/INT32 compute/result-interface assumptions.
4. Taylor, [RAVEN Memory System Research](RAVEN_Memory_System_Research.md), especially §§5–7. Internal proposed scratchpad, bank ownership, and DMA assumptions.
5. Nahjay, [RISC-V Research](RISCV_Research.md), especially §§6.2–6.4 and 21. Internal proposed opcode, command, and quantization-field interface.
6. Jackie, [RAVEN Quantized Models Research](Quantized_Models.md). Reported candidate-model operators and preliminary quantization observations.
7. MLCommons Tiny, [benchmark training models](https://github.com/mlcommons/tiny/tree/master/benchmark/training). Source location for the model artifacts referenced by Jackie's research; not independently inspected here.
