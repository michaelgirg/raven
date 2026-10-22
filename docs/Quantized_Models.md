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

## 1. Deep Autoencoder
Application: Industrial audio anomaly detection
Architecture: 640 → 128 → 128 → 128 → 128 → 8 → 128 → 128 → 128 → 128 → 640

Number of layers: 10 fully connected layers

Operators: FULLY_CONNECTED, fused RELU

Input tensor: [-1, 640], INT8

Output tensor: [-1, 640], INT8 (expected; final tensor can be checked)

Intermediate tensors: Eight 128-element tensors, one 8-element tensor

Weights: 264,192 INT8 parameters

Weight storage: 264,192 bytes (258 KiB)

Biases: 1,672 INT32 parameters

Bias storage: 6,688 bytes (~6.53 KiB)

Total parameter storage: 270,880 bytes (~264.5 KiB)

Computation:264,192 MACs per inference

Quantization: INT8 activations/weights, INT32 biases and accumulators

Information above found by visualizing the models\deep_autoencoder\ad01_int8.tflite file in Netron.
https://github.com/mlcommons/tiny/blob/master/benchmark/training/anomaly_detection/trained_models/ad01_int8.tflite
## 2. DS-CNN
Application: Speech keyword recognition 
Architecture: Conv2D → 4 × (DepthwiseConv2D → Pointwise Conv2D) → AveragePool2D → Reshape → FullyConnected → Softmax
Number of layers: 9 convolution layers (5 Conv2D, 4 DepthwiseConv2D), 1 average pooling, 1 reshape, 1 fully connected, 1 softmax
Operators: CONV_2D, DEPTHWISE_CONV_2D, AVERAGE_POOL_2D, RESHAPE, FULLY_CONNECTED, SOFTMAX, fused RELU
Input tensor: [-1, 49, 10, 1], INT8
Output tensor: [-1, 12], INT8 expected (verify final tensor)
Intermediate tensors: Primarily [-1, 25, 5, 64] (8,000 elements), followed by [-1, 1, 1, 64] and [-1, 64]
Weights: ~22,016 INT8 parameters (calculated from visible layer dimensions)
Weight storage: ~22,016 bytes (~21.5 KiB)
Biases: ~588 INT32 parameters
Bias storage: ~2,352 bytes (~2.30 KiB)
Total parameter storage: ~24,368 bytes (~23.8 KiB)
Computation: ~2,656,768 MACs per inference (estimated from the visible architecture)
Quantization: INT8 activations/weights, INT32 biases and accumulators; per-channel weight quantization observed

Information above found by visualizing the models\DS-CNN\kws_ref_model.tflite file in Netron.
https://github.com/mlcommons/tiny/blob/master/benchmark/training/keyword_spotting/trained_models/kws_ref_model.tflite
## 3. MobileNetV1 0.25x
Application: Visual wake words — person vs. no-person detection
Architecture: Initial 3×3 Conv2D → 13 × (DepthwiseConv2D → Pointwise Conv2D) → AveragePool2D → Reshape → FullyConnected → Softmax
Number of layers: 27 convolution operations (14 Conv2D, 13 DepthwiseConv2D), 1 AveragePool2D, 1 Reshape, 1 FullyConnected, 1 Softmax
Operators: CONV_2D, DEPTHWISE_CONV_2D, AVERAGE_POOL_2D, RESHAPE, FULLY_CONNECTED, SOFTMAX, fused RELU
Input tensor: [-1, 96, 96, 3], INT8
Output tensor: [-1, 2], INT8 expected (verify final tensor)
Intermediate tensors: Progressively reduced spatial dimensions: 48×48×8 → 24×24×16 → 12×12×32 → 6×6×64 → 3×3×256, with additional intermediate channel dimensions
Largest observed intermediate tensor: 48×48×16 = 36,864 elements (~36 KiB INT8)
Weights: Approximately 0.25–0.30 million INT8 parameters (estimate; exact count requires extraction)
Weight storage: Approximately 250–300 KiB (estimate)
Biases: INT32, one per convolution output channel or depthwise output channel (exact count TBD)
Bias storage: TBD — extract from model
Total parameter storage: TBD — extract from model
Computation: Millions of MACs per inference; exact count TBD
Quantization: INT8 activations/weights, INT32 biases and accumulators; per-channel quantization observed

Information above found by visualizing the models\modelnetv1\vww_96_int8.tflite file in Netron.
https://github.com/mlcommons/tiny/blob/master/benchmark/training/visual_wake_words/trained_models/vww_96_int8.tflite
## 4. ResNet-8
Application: Image classification (CIFAR-10, 10 classes)
Architecture: Initial Conv2D (3→16) → Residual Block (16 channels) → Residual Block (16→32 channels) → Residual Block (32→64 channels) → AveragePool2D → Reshape → FullyConnected → Softmax
Number of layers: 9 Conv2D, 3 element-wise Add, 1 AveragePool2D, 1 Reshape, 1 FullyConnected, 1 Softmax
Operators: CONV_2D, ADD, AVERAGE_POOL_2D, RESHAPE, FULLY_CONNECTED, SOFTMAX, fused RELU
Input tensor: [-1, 32, 32, 3], INT8
Output tensor: [-1, 10], INT8 (final output node labeled Identity_int8)
Intermediate tensors: Primarily [-1,32,32,16], [-1,16,16,32], [-1,8,8,64], followed by [-1,1,1,64] and [-1,64]
Largest intermediate tensor: 32×32×16 = 16,384 elements (16 KiB INT8)
Weights: 77,360 INT8 parameters (calculated from displayed dimensions)
Weight storage: 77,360 bytes (~75.55 KiB)
Biases: 346 INT32 parameters
Bias storage: 1,384 bytes (~1.35 KiB)
Total parameter storage: 78,744 bytes (~76.90 KiB)
Computation: ~12,501,632 MACs per inference
Quantization: INT8 activations/weights, INT32 biases and accumulators; per-channel weight quantization

Information above found by visualizing the models\resnet-8\pretrainedResnet_quant.tflite file in Netron.
https://github.com/mlcommons/tiny/blob/master/benchmark/training/image_classification/trained_models/pretrainedResnet_quant.tflite
## 5. Streaming DS-CNN
Application: Continuous audio wake-word detection (3 output classes)
Architecture: DepthwiseConv2D (3×1) → Conv2D (1×1, 40→128) → DepthwiseConv2D (5×1) → Conv2D (1×1, 128→128) → DepthwiseConv2D (10×1) → Conv2D (1×1, 128→128) → DepthwiseConv2D (15×1) → Conv2D (1×1, 128→32) → Reshape → FullyConnected → Softmax
Number of layers: 8 convolution operations (4 DepthwiseConv2D, 4 Conv2D), 1 Reshape, 1 FullyConnected, 1 Softmax
Operators: DEPTHWISE_CONV_2D, CONV_2D, RESHAPE, FULLY_CONNECTED, SOFTMAX, fused RELU
Input tensor: [-1, 30, 1, 40], INT8
Output tensor: [-1, 3], final datatype to verify
Intermediate tensors: 28×1×40 → 28×1×128 → 24×1×128 → 24×1×128 → 15×1×128 → 15×1×128 → 1×1×128 → 1×1×32
Largest intermediate tensor: 28×1×128 = 3,584 elements (~3.5 KiB INT8)
Weights: 46,040 INT8 parameters
Weight storage: 46,040 bytes (~44.96 KiB)
Biases: 843 INT32 parameters
Bias storage: 3,372 bytes (~3.29 KiB)
Total parameter storage: 49,412 bytes (~48.25 KiB)
Computation: ~826,368 MACs per inference
Quantization: INT8 inputs/weights and intermediate activations, INT32 biases and accumulators; per-channel weight quantization observed


Information above found by visualizing the models\streaming-ds-cnn\str_ww_ref_model.tflite file in Netron. 
https://github.com/mlcommons/tiny/blob/master/benchmark/training/streaming_wakeword/trained_models/str_ww_ref_model.tflite


## Which Models To Use
Should target the first 3 models (Deep Autoencoder, DS-CNN, MobileNet) since they cover different applications (audio anomaly detection, speech recognition, and image classification) while progressively increasing hardware complexity and reusing common NPU operators. Most likely use the first one since has the simplest architecture, requiring only fully connected layers and basic INT8 operations, making it ideal for initially testing and verifying RAVEN's hardware and software integration. 
