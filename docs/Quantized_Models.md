# RAVEN Quantized Models Research

**Status:** Initial research on real quantized models, implementation has not started.  
**Owner:** Jackie Wang - Quantized Models to Use.  
**Target:** AMD/Avnet Ultra96-V2 (Zynq UltraScale+ MPSoC ZU3EG).  

## Summary

Five Example Models

1. Deep Autoencoder: https://github.com/mlcommons/tiny/tree/master/benchmark/training/anomaly_detection
2. DS-CNN: https://github.com/mlcommons/tiny/tree/master/benchmark/training/keyword_spotting
3. MobileNetV1 0.25x: https://github.com/mlcommons/tiny/tree/master/benchmark/training/visual_wake_words
4. ResNet-8: https://github.com/mlcommons/tiny/tree/master/benchmark/training/image_classification
5. Streaming DS-CNN: https://github.com/mlcommons/tiny/tree/master/benchmark

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

## 3. MobileNetV1 0.25x













Feasibility	High — no convolution hardware required
Feasibility: Medium — requires conventional convolution, depthwise convolution, pooling, and quantization support