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
















Feasibility	High — no convolution hardware required