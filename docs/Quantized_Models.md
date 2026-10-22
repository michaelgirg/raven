# RAVEN Quantized Models Research

**Status:** Initial research on real quantized models, implementation has not started.  
**Owner:** Jackie Wang - Quantized Models to Use.  
**Target:** AMD/Avnet Ultra96-V2 (Zynq UltraScale+ MPSoC ZU3EG).  

## Summary

Five Example Models

1. Deep Autoencoder (AD01) — Audio Anomaly Detection: https://github.com/mlcommons/tiny/tree/master/benchmark/training/anomaly_detection
2. DS-CNN — Keyword Spotting: https://github.com/mlcommons/tiny/tree/master/benchmark/training/keyword_spotting
3. MobileNetV1 0.25x — Visual Wake Words (Person Detection): https://github.com/mlcommons/tiny/tree/master/benchmark/training/visual_wake_words
4. ResNet-8 — Image Classification: https://github.com/mlcommons/tiny/tree/master/benchmark/training/image_classification
5. Streaming DS-CNN — Streaming Wake Word Detection: https://github.com/mlcommons/tiny/tree/master/benchmark

Used Netron to help visualize models by uploading a .tflite or .onnx model to look at network graph, operator types, weights, tensor dimensions, and connectivity. 
https://netron.app/

## Source Provenance and Reproducibility

**Repository:** [MLCommons Tiny (`mlcommons/tiny`)](https://github.com/mlcommons/tiny)  
**Pinned repository revision:** [`4addd0fa08d216e20637637874e084895f289da4`](https://github.com/mlcommons/tiny/commit/4addd0fa08d216e20637637874e084895f289da4)  
**Revision choice:** This is the repository snapshot selected for this research since it was the most recent one found at the time of starting this research.

All five `.tflite` source paths below were checked to exist at the pinned revision. Their links point directly to that **same immutable Git commit**, rather than to `master`.

| Model | Model file at pinned revision | Git commit (all five) |
|---|---|---|
| AD01 | [`benchmark/training/anomaly_detection/trained_models/ad01_int8.tflite`](https://github.com/mlcommons/tiny/blob/4addd0fa08d216e20637637874e084895f289da4/benchmark/training/anomaly_detection/trained_models/ad01_int8.tflite) | [`4addd0fa08d2`](https://github.com/mlcommons/tiny/commit/4addd0fa08d216e20637637874e084895f289da4) |
| DS-CNN | [`benchmark/training/keyword_spotting/trained_models/kws_ref_model.tflite`](https://github.com/mlcommons/tiny/blob/4addd0fa08d216e20637637874e084895f289da4/benchmark/training/keyword_spotting/trained_models/kws_ref_model.tflite) | [`4addd0fa08d2`](https://github.com/mlcommons/tiny/commit/4addd0fa08d216e20637637874e084895f289da4) |
| MobileNetV1 | [`benchmark/training/visual_wake_words/trained_models/vww_96_int8.tflite`](https://github.com/mlcommons/tiny/blob/4addd0fa08d216e20637637874e084895f289da4/benchmark/training/visual_wake_words/trained_models/vww_96_int8.tflite) | [`4addd0fa08d2`](https://github.com/mlcommons/tiny/commit/4addd0fa08d216e20637637874e084895f289da4) |
| ResNet-8 | [`benchmark/training/image_classification/trained_models/pretrainedResnet_quant.tflite`](https://github.com/mlcommons/tiny/blob/4addd0fa08d216e20637637874e084895f289da4/benchmark/training/image_classification/trained_models/pretrainedResnet_quant.tflite) | [`4addd0fa08d2`](https://github.com/mlcommons/tiny/commit/4addd0fa08d216e20637637874e084895f289da4) |
| Streaming DS-CNN | [`benchmark/training/streaming_wakeword/trained_models/str_ww_ref_model.tflite`](https://github.com/mlcommons/tiny/blob/4addd0fa08d216e20637637874e084895f289da4/benchmark/training/streaming_wakeword/trained_models/str_ww_ref_model.tflite) | [`4addd0fa08d2`](https://github.com/mlcommons/tiny/commit/4addd0fa08d216e20637637874e084895f289da4) |


## 1. Deep Autoencoder
- **Application:** Industrial audio anomaly detection.
- **Architecture:** `640 → 128 → 128 → 128 → 128 → 8 → 128 → 128 → 128 → 128 → 640` (10 fully connected layers).
- **Source:** [AD01 `.tflite` at pinned repository revision](https://github.com/mlcommons/tiny/blob/4addd0fa08d216e20637637874e084895f289da4/benchmark/training/anomaly_detection/trained_models/ad01_int8.tflite).
- **FlatBuffer version:** TFLite model version 3, **one subgraph**, **10 operators**, all `FULLY_CONNECTED` **builtin operator version 4**; no additional operator types in the graph.
- **Input tensor:** `INT8 [-1, 640]` (dynamic batch signature); stored tensor shape `[1, 640]`.
- **Output tensor:** `INT8 [-1, 640]` (dynamic batch signature); stored tensor shape `[1, 640]`.
- **All intermediate activations:** INT8; each layer's input/output types directly confirmed by parsing the uploaded FlatBuffer.
- **Weights:** **264,192 INT8 parameters**, **264,192 bytes** (258 KiB).
- **Biases:** **1,672 INT32 parameters**, **6,688 bytes** (~6.53 KiB).
- **Total parameters:** **265,864**, consistent with Netron's graph-level parameter count.
- **Combined weight/bias storage:** **270,880 bytes** (~264.53 KiB), excluding FlatBuffer metadata, activation buffers, and runtime overhead.
- **Computation:** **264,192 dense MACs per inference**, batch size 1; excludes bias addition, requantization, activation and transfer costs.
- **Quantization:** All weight and bias tensors have zero-point **0**, with per-tensor linear scales (not per-channel). Input scale `0.391015232`, input zero-point **89**; output scale `0.364498466`, output zero-point **96**. Intermediate activations have varying per-tensor scales and zero-point **−128**. INT32 biases are confirmed; accumulator width/rounding on RAVEN remains a hardware implementation detail.

**Verified per-operator tensors and counts** (operator identifiers are zero-based):

| ID | Weight tensor | Bias tensor | Output tensor | Fused activation | Weights | Bias values | MACs (batch 1) |
|---:|---|---|---|---|---:|---:|---:|
| 0 | `INT8 [128, 640]` | `INT32 [128]` | `INT8 [-1, 128]` | `RELU` | 81,920 | 128 | 81,920 |
| 1 | `INT8 [128, 128]` | `INT32 [128]` | `INT8 [-1, 128]` | `RELU` | 16,384 | 128 | 16,384 |
| 2 | `INT8 [128, 128]` | `INT32 [128]` | `INT8 [-1, 128]` | `RELU` | 16,384 | 128 | 16,384 |
| 3 | `INT8 [128, 128]` | `INT32 [128]` | `INT8 [-1, 128]` | `RELU` | 16,384 | 128 | 16,384 |
| 4 | `INT8 [8, 128]` | `INT32 [8]` | `INT8 [-1, 8]` | `RELU` | 1,024 | 8 | 1,024 |
| 5 | `INT8 [128, 8]` | `INT32 [128]` | `INT8 [-1, 128]` | `RELU` | 1,024 | 128 | 1,024 |
| 6 | `INT8 [128, 128]` | `INT32 [128]` | `INT8 [-1, 128]` | `RELU` | 16,384 | 128 | 16,384 |
| 7 | `INT8 [128, 128]` | `INT32 [128]` | `INT8 [-1, 128]` | `RELU` | 16,384 | 128 | 16,384 |
| 8 | `INT8 [128, 128]` | `INT32 [128]` | `INT8 [-1, 128]` | `RELU` | 16,384 | 128 | 16,384 |
| 9 | `INT8 [640, 128]` | `INT32 [640]` | `INT8 [-1, 640]` | `NONE` | 81,920 | 640 | 81,920 |
| **Total** | | | | | **264,192** | **1,672** | **264,192** |

**Exact `FULLY_CONNECTED` operator options:** All ten operators have `weights_format=DEFAULT`, `keep_num_dims=false`, `asymmetric_quantize_inputs=false`, and `quantized_bias_type=FLOAT32` as the **operator option** (the actual bias tensor type is INT32). `fused_activation_function=RELU` for identifiers **0–8**, and `NONE` for identifier **9**. Netron displays no value for `quant_spec`; no non-default quantization specification was extracted. Each operation uses builtin operator version **4**.

**Per-layer quantization scales** (weight/bias zero-points are 0; intermediate output zero-points are −128, except final output 96):

| ID | Weight scale | Bias scale | Output scale | Output zero-point |
|---:|---:|---:|---:|---:|
| 0 | 0.000376874988 | 0.000147363855 | 0.0494591296 | -128 |
| 1 | 0.0150283268 | 0.000743287965 | 0.0354056843 | -128 |
| 2 | 0.0535003953 | 0.00189421815 | 0.013730743 | -128 |
| 3 | 0.072035417 | 0.000989099848 | 0.0236037932 | -128 |
| 4 | 0.00834463444 | 0.000196965033 | 0.0249294806 | -128 |
| 5 | 0.0267344881 | 0.000666476903 | 0.0317561701 | -128 |
| 6 | 0.0193354338 | 0.000614019344 | 0.032071162 | -128 |
| 7 | 0.0128027415 | 0.00041059879 | 0.0282959733 | -128 |
| 8 | 0.00704988418 | 0.000199483329 | 0.0247908905 | -128 |
| 9 | 0.0195566826 | 0.000484827586 | 0.364498466 | 96 |

Information above found by visualizing the models\deep_autoencoder\ad01_int8.tflite file in Netron.
https://github.com/mlcommons/tiny/blob/master/benchmark/training/anomaly_detection/trained_models/ad01_int8.tflite
## 2. DS-CNN
- **Application:** Keyword spotting (12 classes).
- **Source:** [`kws_ref_model.tflite` at pinned commit](https://github.com/mlcommons/tiny/blob/4addd0fa08d216e20637637874e084895f289da4/benchmark/training/keyword_spotting/trained_models/kws_ref_model.tflite).
- **Inspected file:** `kws_ref_model.tflite`, SHA-256 `aeea436800704fce17b17292e4412630ad856e9d777c044c64ef748a880bd0ae`; 53,936 bytes.
- **Graph:** 13 operator nodes; `CONV_2D` × 5, `DEPTHWISE_CONV_2D` × 4, `AVERAGE_POOL_2D` × 1, `RESHAPE` × 1, `FULLY_CONNECTED` × 1, `SOFTMAX` × 1.
- **Operator versions:** `CONV_2D` v3, `DEPTHWISE_CONV_2D` v3, `AVERAGE_POOL_2D` v2, `RESHAPE` v1, `FULLY_CONNECTED` v4, `SOFTMAX` v2.
- **Model input:** `INT8 [-1, 49, 10, 1]` (stored `[1, 49, 10, 1]`); scale `0.584702909`, zero-point `83`.
- **Model output:** `INT8 [-1, 12]` (stored `[1, 12]`); scale `0.00390625`, zero-point `-128`.
- **Intermediate numerical tensors:** `INT8` for activation tensors; all learnable weights `INT8`; all learnable biases `INT32`. Some `INT32` shape tensors are metadata, not activations.
- **Parameters:** **22,016 INT8 weights** (22,016 bytes); **588 INT32 bias values** (2,352 bytes); **22,604 parameter values**.
- **Combined constant weight/bias storage:** **24,368 bytes** (~23.80 KiB), excluding graph metadata, activation buffers, runtime overhead.
- **Dense MAC count:** **2,656,768 per batch-one inference** (standard convolution + depthwise convolution + fully connected; excludes non-MAC ops and padding optimizations).
- **Largest observed INT8 graph tensor (including input/output):** [1, 25, 5, 64] = 8,000 bytes (~7.81 KiB). This is not a calculated peak live-memory budget.
- **Weight quantization:** 9 of 10 weighted operators use per-channel INT8 weight scales; remaining weighted operators use per-tensor scales. Weight and bias zero-points are 0 in the uploaded file.

**Exact per-operator settings and arithmetic counts** (operator IDs are zero-based; weights shown in TFLite order, i.e., output-channel-first for standard convolutions; all computation operator outputs are INT8):

| ID | Operator (version) | Weight shape | Output shape | Exact configuration | Fused activation | Dense MACs |
|---:|---|---|---|---|---|---:|
| 0 | `CONV_2D` v3 | `[64, 10, 4, 1]` | `[1, 25, 5, 64]` | SAME; stride 2×2; dilation 1×1 | `RELU` | 320,000 |
| 1 | `DEPTHWISE_CONV_2D` v3 | `[1, 3, 3, 64]` | `[1, 25, 5, 64]` | SAME; stride 1×1; dilation 1×1; multiplier 1 | `RELU` | 72,000 |
| 2 | `CONV_2D` v3 | `[64, 1, 1, 64]` | `[1, 25, 5, 64]` | SAME; stride 1×1; dilation 1×1 | `RELU` | 512,000 |
| 3 | `DEPTHWISE_CONV_2D` v3 | `[1, 3, 3, 64]` | `[1, 25, 5, 64]` | SAME; stride 1×1; dilation 1×1; multiplier 1 | `RELU` | 72,000 |
| 4 | `CONV_2D` v3 | `[64, 1, 1, 64]` | `[1, 25, 5, 64]` | SAME; stride 1×1; dilation 1×1 | `RELU` | 512,000 |
| 5 | `DEPTHWISE_CONV_2D` v3 | `[1, 3, 3, 64]` | `[1, 25, 5, 64]` | SAME; stride 1×1; dilation 1×1; multiplier 1 | `RELU` | 72,000 |
| 6 | `CONV_2D` v3 | `[64, 1, 1, 64]` | `[1, 25, 5, 64]` | SAME; stride 1×1; dilation 1×1 | `RELU` | 512,000 |
| 7 | `DEPTHWISE_CONV_2D` v3 | `[1, 3, 3, 64]` | `[1, 25, 5, 64]` | SAME; stride 1×1; dilation 1×1; multiplier 1 | `RELU` | 72,000 |
| 8 | `CONV_2D` v3 | `[64, 1, 1, 64]` | `[1, 25, 5, 64]` | SAME; stride 1×1; dilation 1×1 | `RELU` | 512,000 |
| 9 | `AVERAGE_POOL_2D` v2 | `—` | `[1, 1, 1, 64]` | VALID; pool 25×5; stride 25×5 | `NONE` | — |
| 10 | `RESHAPE` v1 | `—` | `[1, 64]` | target [-1, 64] (shape tensor) | `—` | — |
| 11 | `FULLY_CONNECTED` v4 | `[12, 64]` | `[1, 12]` | DEFAULT; keep_num_dims=false; asymmetric_quantize_inputs=false | `NONE` | 768 |
| 12 | `SOFTMAX` v2 | `—` | `[1, 12]` | beta=1 | `—` | — |

**Quantization and implementation notes:** All 10 weighted operators have actual `INT8` constant-weight tensors and `INT32` constant-bias tensors. `FULLY_CONNECTED` options are `weights_format=DEFAULT`, `keep_num_dims=false`, `asymmetric_quantize_inputs=false`, `quantized_bias_type=FLOAT32` **operator option only** (actual bias tensor remains INT32). `CONV_2D` records `quantized_bias_type=FLOAT32` as an option, not as the bias tensor dtype; its `padding`, `stride`, `dilation`, and fused activation are specified above. `SOFTMAX` has `beta=1.0` where present. `RESHAPE` uses a constant second input tensor for the target shape where present. Per-channel weight quantization dimension: **0** for `CONV_2D` and **3** for `DEPTHWISE_CONV_2D`; fully connected weights use per-tensor scales (quantized dimension 0).


Information above found by visualizing the models\DS-CNN\kws_ref_model.tflite file in Netron.
https://github.com/mlcommons/tiny/blob/master/benchmark/training/keyword_spotting/trained_models/kws_ref_model.tflite
## 3. MobileNetV1 0.25x
- **Application:** Visual wake words: person/no-person.
- **Source:** [`vww_96_int8.tflite` at pinned commit](https://github.com/mlcommons/tiny/blob/4addd0fa08d216e20637637874e084895f289da4/benchmark/training/visual_wake_words/trained_models/vww_96_int8.tflite).
- **Inspected file:** `vww_96_int8.tflite`, SHA-256 `597a384c8c2c8a1276f04702f25013b7838f2f814f1ca7c174d295b73e3d6b7b`; 333,288 bytes.
- **Graph:** 31 operator nodes; `CONV_2D` × 14, `DEPTHWISE_CONV_2D` × 13, `AVERAGE_POOL_2D` × 1, `RESHAPE` × 1, `FULLY_CONNECTED` × 1, `SOFTMAX` × 1.
- **Operator versions:** `CONV_2D` v3, `DEPTHWISE_CONV_2D` v3, `AVERAGE_POOL_2D` v2, `RESHAPE` v1, `FULLY_CONNECTED` v4, `SOFTMAX` v2.
- **Model input:** `INT8 [-1, 96, 96, 3]` (stored `[1, 96, 96, 3]`); scale `0.00392156886`, zero-point `-128`.
- **Model output:** `INT8 [-1, 2]` (stored `[1, 2]`); scale `0.00390625`, zero-point `-128`.
- **Intermediate numerical tensors:** `INT8` for activation tensors; all learnable weights `INT8`; all learnable biases `INT32`. Some `INT32` shape tensors are metadata, not activations.
- **Parameters:** **208,112 INT8 weights** (208,112 bytes); **2,738 INT32 bias values** (10,952 bytes); **210,850 parameter values**.
- **Combined constant weight/bias storage:** **219,064 bytes** (~213.93 KiB), excluding graph metadata, activation buffers, runtime overhead.
- **Dense MAC count:** **7,489,664 per batch-one inference** (standard convolution + depthwise convolution + fully connected; excludes non-MAC ops and padding optimizations).
- **Largest observed INT8 graph tensor (including input/output):** [1, 48, 48, 16] = 36,864 bytes (~36.00 KiB). This is not a calculated peak live-memory budget.
- **Weight quantization:** 27 of 28 weighted operators use per-channel INT8 weight scales; remaining weighted operators use per-tensor scales. Weight and bias zero-points are 0 in the uploaded file.

**Exact per-operator settings and arithmetic counts** (operator IDs are zero-based; weights shown in TFLite order, i.e., output-channel-first for standard convolutions; all computation operator outputs are INT8):

| ID | Operator (version) | Weight shape | Output shape | Exact configuration | Fused activation | Dense MACs |
|---:|---|---|---|---|---|---:|
| 0 | `CONV_2D` v3 | `[8, 3, 3, 3]` | `[1, 48, 48, 8]` | SAME; stride 2×2; dilation 1×1 | `RELU` | 497,664 |
| 1 | `DEPTHWISE_CONV_2D` v3 | `[1, 3, 3, 8]` | `[1, 48, 48, 8]` | SAME; stride 1×1; dilation 1×1; multiplier 1 | `RELU` | 165,888 |
| 2 | `CONV_2D` v3 | `[16, 1, 1, 8]` | `[1, 48, 48, 16]` | SAME; stride 1×1; dilation 1×1 | `RELU` | 294,912 |
| 3 | `DEPTHWISE_CONV_2D` v3 | `[1, 3, 3, 16]` | `[1, 24, 24, 16]` | SAME; stride 2×2; dilation 1×1; multiplier 1 | `RELU` | 82,944 |
| 4 | `CONV_2D` v3 | `[32, 1, 1, 16]` | `[1, 24, 24, 32]` | SAME; stride 1×1; dilation 1×1 | `RELU` | 294,912 |
| 5 | `DEPTHWISE_CONV_2D` v3 | `[1, 3, 3, 32]` | `[1, 24, 24, 32]` | SAME; stride 1×1; dilation 1×1; multiplier 1 | `RELU` | 165,888 |
| 6 | `CONV_2D` v3 | `[32, 1, 1, 32]` | `[1, 24, 24, 32]` | SAME; stride 1×1; dilation 1×1 | `RELU` | 589,824 |
| 7 | `DEPTHWISE_CONV_2D` v3 | `[1, 3, 3, 32]` | `[1, 12, 12, 32]` | SAME; stride 2×2; dilation 1×1; multiplier 1 | `RELU` | 41,472 |
| 8 | `CONV_2D` v3 | `[64, 1, 1, 32]` | `[1, 12, 12, 64]` | SAME; stride 1×1; dilation 1×1 | `RELU` | 294,912 |
| 9 | `DEPTHWISE_CONV_2D` v3 | `[1, 3, 3, 64]` | `[1, 12, 12, 64]` | SAME; stride 1×1; dilation 1×1; multiplier 1 | `RELU` | 82,944 |
| 10 | `CONV_2D` v3 | `[64, 1, 1, 64]` | `[1, 12, 12, 64]` | SAME; stride 1×1; dilation 1×1 | `RELU` | 589,824 |
| 11 | `DEPTHWISE_CONV_2D` v3 | `[1, 3, 3, 64]` | `[1, 6, 6, 64]` | SAME; stride 2×2; dilation 1×1; multiplier 1 | `RELU` | 20,736 |
| 12 | `CONV_2D` v3 | `[128, 1, 1, 64]` | `[1, 6, 6, 128]` | SAME; stride 1×1; dilation 1×1 | `RELU` | 294,912 |
| 13 | `DEPTHWISE_CONV_2D` v3 | `[1, 3, 3, 128]` | `[1, 6, 6, 128]` | SAME; stride 1×1; dilation 1×1; multiplier 1 | `RELU` | 41,472 |
| 14 | `CONV_2D` v3 | `[128, 1, 1, 128]` | `[1, 6, 6, 128]` | SAME; stride 1×1; dilation 1×1 | `RELU` | 589,824 |
| 15 | `DEPTHWISE_CONV_2D` v3 | `[1, 3, 3, 128]` | `[1, 6, 6, 128]` | SAME; stride 1×1; dilation 1×1; multiplier 1 | `RELU` | 41,472 |
| 16 | `CONV_2D` v3 | `[128, 1, 1, 128]` | `[1, 6, 6, 128]` | SAME; stride 1×1; dilation 1×1 | `RELU` | 589,824 |
| 17 | `DEPTHWISE_CONV_2D` v3 | `[1, 3, 3, 128]` | `[1, 6, 6, 128]` | SAME; stride 1×1; dilation 1×1; multiplier 1 | `RELU` | 41,472 |
| 18 | `CONV_2D` v3 | `[128, 1, 1, 128]` | `[1, 6, 6, 128]` | SAME; stride 1×1; dilation 1×1 | `RELU` | 589,824 |
| 19 | `DEPTHWISE_CONV_2D` v3 | `[1, 3, 3, 128]` | `[1, 6, 6, 128]` | SAME; stride 1×1; dilation 1×1; multiplier 1 | `RELU` | 41,472 |
| 20 | `CONV_2D` v3 | `[128, 1, 1, 128]` | `[1, 6, 6, 128]` | SAME; stride 1×1; dilation 1×1 | `RELU` | 589,824 |
| 21 | `DEPTHWISE_CONV_2D` v3 | `[1, 3, 3, 128]` | `[1, 6, 6, 128]` | SAME; stride 1×1; dilation 1×1; multiplier 1 | `RELU` | 41,472 |
| 22 | `CONV_2D` v3 | `[128, 1, 1, 128]` | `[1, 6, 6, 128]` | SAME; stride 1×1; dilation 1×1 | `RELU` | 589,824 |
| 23 | `DEPTHWISE_CONV_2D` v3 | `[1, 3, 3, 128]` | `[1, 3, 3, 128]` | SAME; stride 2×2; dilation 1×1; multiplier 1 | `RELU` | 10,368 |
| 24 | `CONV_2D` v3 | `[256, 1, 1, 128]` | `[1, 3, 3, 256]` | SAME; stride 1×1; dilation 1×1 | `RELU` | 294,912 |
| 25 | `DEPTHWISE_CONV_2D` v3 | `[1, 3, 3, 256]` | `[1, 3, 3, 256]` | SAME; stride 1×1; dilation 1×1; multiplier 1 | `RELU` | 20,736 |
| 26 | `CONV_2D` v3 | `[256, 1, 1, 256]` | `[1, 3, 3, 256]` | SAME; stride 1×1; dilation 1×1 | `RELU` | 589,824 |
| 27 | `AVERAGE_POOL_2D` v2 | `—` | `[1, 1, 1, 256]` | VALID; pool 3×3; stride 3×3 | `NONE` | — |
| 28 | `RESHAPE` v1 | `—` | `[1, 256]` | target [-1, 256] (shape tensor) | `—` | — |
| 29 | `FULLY_CONNECTED` v4 | `[2, 256]` | `[1, 2]` | DEFAULT; keep_num_dims=false; asymmetric_quantize_inputs=false | `NONE` | 512 |
| 30 | `SOFTMAX` v2 | `—` | `[1, 2]` | beta=1 | `—` | — |

**Quantization and implementation notes:** All 28 weighted operators have actual `INT8` constant-weight tensors and `INT32` constant-bias tensors. `FULLY_CONNECTED` options are `weights_format=DEFAULT`, `keep_num_dims=false`, `asymmetric_quantize_inputs=false`, `quantized_bias_type=FLOAT32` **operator option only** (actual bias tensor remains INT32). `CONV_2D` records `quantized_bias_type=FLOAT32` as an option, not as the bias tensor dtype; its `padding`, `stride`, `dilation`, and fused activation are specified above. `SOFTMAX` has `beta=1.0` where present. `RESHAPE` uses a constant second input tensor for the target shape where present. Per-channel weight quantization dimension: **0** for `CONV_2D` and **3** for `DEPTHWISE_CONV_2D`; fully connected weights use per-tensor scales (quantized dimension 0).


**Correction to initial Netron estimate:** The exact binary has 208,112 weights, not the previous rough 250–300K estimate. The model is a *binary person/no-person detector*, not a general ImageNet classifier.


Information above found by visualizing the models\modelnetv1\vww_96_int8.tflite file in Netron.
https://github.com/mlcommons/tiny/blob/master/benchmark/training/visual_wake_words/trained_models/vww_96_int8.tflite
## 4. ResNet-8
- **Application:** CIFAR-10 image classification.
- **Source:** [`pretrainedResnet_quant.tflite` at pinned commit](https://github.com/mlcommons/tiny/blob/4addd0fa08d216e20637637874e084895f289da4/benchmark/training/image_classification/trained_models/pretrainedResnet_quant.tflite).
- **Inspected file:** `pretrainedResnet_quant.tflite`, SHA-256 `3c002613d1b2475eb51dd78dfb85a546c8ae658dee71cf6ade43b022fe205415`; 98,496 bytes.
- **Graph:** 16 operator nodes; `CONV_2D` × 9, `ADD` × 3, `AVERAGE_POOL_2D` × 1, `RESHAPE` × 1, `FULLY_CONNECTED` × 1, `SOFTMAX` × 1.
- **Operator versions:** `CONV_2D` v3, `ADD` v2, `AVERAGE_POOL_2D` v2, `RESHAPE` v1, `FULLY_CONNECTED` v4, `SOFTMAX` v2.
- **Model input:** `INT8 [-1, 32, 32, 3]` (stored `[1, 32, 32, 3]`); scale `1`, zero-point `-128`.
- **Model output:** `INT8 [-1, 10]` (stored `[1, 10]`); scale `0.00390625`, zero-point `-128`.
- **Intermediate numerical tensors:** `INT8` for activation tensors; all learnable weights `INT8`; all learnable biases `INT32`. Some `INT32` shape tensors are metadata, not activations.
- **Parameters:** **77,360 INT8 weights** (77,360 bytes); **346 INT32 bias values** (1,384 bytes); **77,706 parameter values**.
- **Combined constant weight/bias storage:** **78,744 bytes** (~76.90 KiB), excluding graph metadata, activation buffers, runtime overhead.
- **Dense MAC count:** **12,501,632 per batch-one inference** (standard convolution + depthwise convolution + fully connected; excludes non-MAC ops and padding optimizations).
- **Largest observed INT8 graph tensor (including input/output):** [1, 32, 32, 16] = 16,384 bytes (~16.00 KiB). This is not a calculated peak live-memory budget.
- **Weight quantization:** 9 of 10 weighted operators use per-channel INT8 weight scales; remaining weighted operators use per-tensor scales. Weight and bias zero-points are 0 in the uploaded file.

**Exact per-operator settings and arithmetic counts** (operator IDs are zero-based; weights shown in TFLite order, i.e., output-channel-first for standard convolutions; all computation operator outputs are INT8):

| ID | Operator (version) | Weight shape | Output shape | Exact configuration | Fused activation | Dense MACs |
|---:|---|---|---|---|---|---:|
| 0 | `CONV_2D` v3 | `[16, 3, 3, 3]` | `[1, 32, 32, 16]` | SAME; stride 1×1; dilation 1×1 | `RELU` | 442,368 |
| 1 | `CONV_2D` v3 | `[16, 3, 3, 16]` | `[1, 32, 32, 16]` | SAME; stride 1×1; dilation 1×1 | `RELU` | 2,359,296 |
| 2 | `CONV_2D` v3 | `[16, 3, 3, 16]` | `[1, 32, 32, 16]` | SAME; stride 1×1; dilation 1×1 | `NONE` | 2,359,296 |
| 3 | `ADD` v2 | `—` | `[1, 32, 32, 16]` | pot_scale_int16=false | `RELU` | — |
| 4 | `CONV_2D` v3 | `[32, 3, 3, 16]` | `[1, 16, 16, 32]` | SAME; stride 2×2; dilation 1×1 | `RELU` | 1,179,648 |
| 5 | `CONV_2D` v3 | `[32, 3, 3, 32]` | `[1, 16, 16, 32]` | SAME; stride 1×1; dilation 1×1 | `NONE` | 2,359,296 |
| 6 | `CONV_2D` v3 | `[32, 1, 1, 16]` | `[1, 16, 16, 32]` | SAME; stride 2×2; dilation 1×1 | `NONE` | 131,072 |
| 7 | `ADD` v2 | `—` | `[1, 16, 16, 32]` | pot_scale_int16=false | `RELU` | — |
| 8 | `CONV_2D` v3 | `[64, 3, 3, 32]` | `[1, 8, 8, 64]` | SAME; stride 2×2; dilation 1×1 | `RELU` | 1,179,648 |
| 9 | `CONV_2D` v3 | `[64, 3, 3, 64]` | `[1, 8, 8, 64]` | SAME; stride 1×1; dilation 1×1 | `NONE` | 2,359,296 |
| 10 | `CONV_2D` v3 | `[64, 1, 1, 32]` | `[1, 8, 8, 64]` | SAME; stride 2×2; dilation 1×1 | `NONE` | 131,072 |
| 11 | `ADD` v2 | `—` | `[1, 8, 8, 64]` | pot_scale_int16=false | `RELU` | — |
| 12 | `AVERAGE_POOL_2D` v2 | `—` | `[1, 1, 1, 64]` | VALID; pool 8×8; stride 8×8 | `NONE` | — |
| 13 | `RESHAPE` v1 | `—` | `[1, 64]` | target [-1, 64] (shape tensor) | `—` | — |
| 14 | `FULLY_CONNECTED` v4 | `[10, 64]` | `[1, 10]` | DEFAULT; keep_num_dims=false; asymmetric_quantize_inputs=false | `NONE` | 640 |
| 15 | `SOFTMAX` v2 | `—` | `[1, 10]` | beta=1 | `—` | — |

**Quantization and implementation notes:** All 10 weighted operators have actual `INT8` constant-weight tensors and `INT32` constant-bias tensors. `FULLY_CONNECTED` options are `weights_format=DEFAULT`, `keep_num_dims=false`, `asymmetric_quantize_inputs=false`, `quantized_bias_type=FLOAT32` **operator option only** (actual bias tensor remains INT32). `CONV_2D` records `quantized_bias_type=FLOAT32` as an option, not as the bias tensor dtype; its `padding`, `stride`, `dilation`, and fused activation are specified above. `SOFTMAX` has `beta=1.0` where present. `RESHAPE` uses a constant second input tensor for the target shape where present. Per-channel weight quantization dimension: **0** for `CONV_2D` and **3** for `DEPTHWISE_CONV_2D`; fully connected weights use per-tensor scales (quantized dimension 0).


**Residual connections:** All three `ADD` nodes use `fused_activation_function=RELU` and `pot_scale_int16=false`. Their INT8 elementwise arithmetic is not included in the convolution/FC MAC total.

Information above found by visualizing the models\resnet-8\pretrainedResnet_quant.tflite file in Netron.
https://github.com/mlcommons/tiny/blob/master/benchmark/training/image_classification/trained_models/pretrainedResnet_quant.tflite
## 5. Streaming DS-CNN
- **Application:** Streaming wake-word detection (3 classes).
- **Source:** [`str_ww_ref_model.tflite` at pinned commit](https://github.com/mlcommons/tiny/blob/4addd0fa08d216e20637637874e084895f289da4/benchmark/training/streaming_wakeword/trained_models/str_ww_ref_model.tflite).
- **Inspected file:** `str_ww_ref_model.tflite`, SHA-256 `3af8550895ba7d5c584277102b5075c52dcfa63ba9d2b2240f37c4e6abd5dd2b`; 74,520 bytes.
- **Graph:** 11 operator nodes; `DEPTHWISE_CONV_2D` × 4, `CONV_2D` × 4, `RESHAPE` × 1, `FULLY_CONNECTED` × 1, `SOFTMAX` × 1.
- **Operator versions:** `DEPTHWISE_CONV_2D` v3, `CONV_2D` v3, `RESHAPE` v1, `FULLY_CONNECTED` v4, `SOFTMAX` v2.
- **Model input:** `INT8 [-1, 30, 1, 40]` (stored `[1, 30, 1, 40]`); scale `0.00370104262`, zero-point `-128`.
- **Model output:** `INT8 [-1, 3]` (stored `[1, 3]`); scale `0.00390625`, zero-point `-128`.
- **Intermediate numerical tensors:** `INT8` for activation tensors; all learnable weights `INT8`; all learnable biases `INT32`. Some `INT32` shape tensors are metadata, not activations.
- **Parameters:** **46,040 INT8 weights** (46,040 bytes); **843 INT32 bias values** (3,372 bytes); **46,883 parameter values**.
- **Combined constant weight/bias storage:** **49,412 bytes** (~48.25 KiB), excluding graph metadata, activation buffers, runtime overhead.
- **Dense MAC count:** **826,368 per batch-one inference** (standard convolution + depthwise convolution + fully connected; excludes non-MAC ops and padding optimizations).
- **Largest observed INT8 graph tensor (including input/output):** [1, 28, 1, 128] = 3,584 bytes (~3.50 KiB). This is not a calculated peak live-memory budget.
- **Weight quantization:** 8 of 9 weighted operators use per-channel INT8 weight scales; remaining weighted operators use per-tensor scales. Weight and bias zero-points are 0 in the uploaded file.

**Exact per-operator settings and arithmetic counts** (operator IDs are zero-based; weights shown in TFLite order, i.e., output-channel-first for standard convolutions; all computation operator outputs are INT8):

| ID | Operator (version) | Weight shape | Output shape | Exact configuration | Fused activation | Dense MACs |
|---:|---|---|---|---|---|---:|
| 0 | `DEPTHWISE_CONV_2D` v3 | `[1, 3, 1, 40]` | `[1, 28, 1, 40]` | VALID; stride 1×1; dilation 1×1; multiplier 1 | `NONE` | 3,360 |
| 1 | `CONV_2D` v3 | `[128, 1, 1, 40]` | `[1, 28, 1, 128]` | VALID; stride 1×1; dilation 1×1 | `RELU` | 143,360 |
| 2 | `DEPTHWISE_CONV_2D` v3 | `[1, 5, 1, 128]` | `[1, 24, 1, 128]` | VALID; stride 1×1; dilation 1×1; multiplier 1 | `NONE` | 15,360 |
| 3 | `CONV_2D` v3 | `[128, 1, 1, 128]` | `[1, 24, 1, 128]` | VALID; stride 1×1; dilation 1×1 | `RELU` | 393,216 |
| 4 | `DEPTHWISE_CONV_2D` v3 | `[1, 10, 1, 128]` | `[1, 15, 1, 128]` | VALID; stride 1×1; dilation 1×1; multiplier 1 | `NONE` | 19,200 |
| 5 | `CONV_2D` v3 | `[128, 1, 1, 128]` | `[1, 15, 1, 128]` | VALID; stride 1×1; dilation 1×1 | `RELU` | 245,760 |
| 6 | `DEPTHWISE_CONV_2D` v3 | `[1, 15, 1, 128]` | `[1, 1, 1, 128]` | VALID; stride 1×1; dilation 1×1; multiplier 1 | `NONE` | 1,920 |
| 7 | `CONV_2D` v3 | `[32, 1, 1, 128]` | `[1, 1, 1, 32]` | VALID; stride 1×1; dilation 1×1 | `RELU` | 4,096 |
| 8 | `RESHAPE` v1 | `—` | `[1, 32]` | target [-1, 32] (shape tensor) | `—` | — |
| 9 | `FULLY_CONNECTED` v4 | `[3, 32]` | `[1, 3]` | DEFAULT; keep_num_dims=false; asymmetric_quantize_inputs=false | `NONE` | 96 |
| 10 | `SOFTMAX` v2 | `—` | `[1, 3]` | beta=1 | `—` | — |

**Quantization and implementation notes:** All 9 weighted operators have actual `INT8` constant-weight tensors and `INT32` constant-bias tensors. `FULLY_CONNECTED` options are `weights_format=DEFAULT`, `keep_num_dims=false`, `asymmetric_quantize_inputs=false`, `quantized_bias_type=FLOAT32` **operator option only** (actual bias tensor remains INT32). `CONV_2D` records `quantized_bias_type=FLOAT32` as an option, not as the bias tensor dtype; its `padding`, `stride`, `dilation`, and fused activation are specified above. `SOFTMAX` has `beta=1.0` where present. `RESHAPE` uses a constant second input tensor for the target shape where present. Per-channel weight quantization dimension: **0** for `CONV_2D` and **3** for `DEPTHWISE_CONV_2D`; fully connected weights use per-tensor scales (quantized dimension 0).


**Streaming-specific note:** This TFLite graph processes a 30×1×40 input feature window; any rolling buffer/state handling outside the graph is a separate runtime/preprocessing requirement.

Information above found by visualizing the models\streaming-ds-cnn\str_ww_ref_model.tflite file in Netron. 
https://github.com/mlcommons/tiny/blob/master/benchmark/training/streaming_wakeword/trained_models/str_ww_ref_model.tflite


## Proposed NPU / CPU Operator Compatibility

**Status:** Proposed execution mapping for the initial RAVEN prototype; implementation has not started. The table below identifies a *target* execution location, not hardware that is already working. CPU fallback means running the equivalent quantized operation on the Ultra96-V2 ARM processor when RAVEN does not yet support it in programmable logic.

| TFLite operator | Proposed NPU execution | Proposed CPU fallback | Implementation decision / notes |
|---|---|---|---|
| `FULLY_CONNECTED` | **NPU target (first priority)** | Yes, until the NPU kernel works | Dense INT8 matrix-vector / matrix-multiply operations on the planned 8×8 MAC array; implement INT32 accumulation, bias addition, quantized rescaling, and fused activation as needed. |
| `CONV_2D` (including 1×1 pointwise) | **NPU target (after FC)** | Yes, until convolution is supported | Map convolution to the dense array using appropriate input/weight tiling or patch extraction; verify stride, padding, and per-channel quantization. |
| `DEPTHWISE_CONV_2D` | **TBD — not committed** | **Proposed initial fallback** | Each channel uses its own filter; DS-CNN, MobileNetV1, and Streaming DS-CNN require it. Decide whether to implement a dedicated depthwise dataflow/kernel in RTL or retain ARM execution. |
| `AVERAGE_POOL_2D` | Not planned initially | **CPU** | Quantized average/requantization; may be moved to NPU later if useful. |
| `ADD` (ResNet residual connection) | Not planned initially | **CPU** | Requires correctly scaled INT8 elementwise addition and the specified fused activation. A future NPU elementwise unit is optional. |
| `RESHAPE` | No MAC-array compute | **ARM runtime / metadata** | Often a shape/stride interpretation with no tensor arithmetic or copy; runtime handles the tensor view and any required layout changes. |
| `SOFTMAX` | Not planned initially | **CPU** | Nonlinear normalization/postprocessing; required for exact output compatibility if evaluating the full TFLite graph. |
| Fused `RELU` | **With NPU FC / Conv if implemented** | **With CPU-executed operator** | Not a separate operator node in these files. Implement the fused activation on the same execution side as its parent operation; otherwise add an explicit postprocessing step. |

**Proposed partition for each model** (operator counts are from the inspected TFLite graphs):

| Model | Planned NPU operations | Proposed initial CPU operations | Metadata/runtime | Key limitation |
|---|---|---|---|---|
| **AD01** | `FULLY_CONNECTED` × 10 | None after all FC functionality is supported | Input/output handling | Best first hardware/software bring-up; no depthwise convolution. |
| **DS-CNN** | `CONV_2D` × 5; `FULLY_CONNECTED` × 1 | `DEPTHWISE_CONV_2D` × 4; `AVERAGE_POOL_2D` × 1; `SOFTMAX` × 1 | `RESHAPE` × 1 | Four depthwise layers require an implementation decision. |
| **MobileNetV1 0.25x** | `CONV_2D` × 14; `FULLY_CONNECTED` × 1 | `DEPTHWISE_CONV_2D` × 13; `AVERAGE_POOL_2D` × 1; `SOFTMAX` × 1 | `RESHAPE` × 1 | Thirteen depthwise layers make CPU/NPU transfers especially relevant. |
| **ResNet-8** | `CONV_2D` × 9; `FULLY_CONNECTED` × 1 | `ADD` × 3; `AVERAGE_POOL_2D` × 1; `SOFTMAX` × 1 | `RESHAPE` × 1 | Residual `ADD` needs software support unless an NPU elementwise path is added. |
| **Streaming DS-CNN** | `CONV_2D` × 4; `FULLY_CONNECTED` × 1 | `DEPTHWISE_CONV_2D` × 4; `SOFTMAX` × 1 | `RESHAPE` × 1 | Depthwise execution plus streaming input-window management. |


## Which Models To Use
Should target the first 3 models (Deep Autoencoder, DS-CNN, MobileNet) since they cover different applications (audio anomaly detection, speech recognition, and image classification) while progressively increasing hardware complexity and reusing common NPU operators. Most likely use the first one since has the simplest architecture, requiring only fully connected layers and basic INT8 operations, making it ideal for initially testing and verifying RAVEN's hardware and software integration. 
