from pathlib import Path

import tensorflow as tf

MODEL = Path(__file__).resolve().parents[2] / "models/deep_autoencoder/ad01_int8.tflite"

interpreter = tf.lite.Interpreter(model_path=str(MODEL))
interpreter.allocate_tensors()

# Get all tensors
tensors = interpreter.get_tensor_details()

for tensor in tensors:
    print("Name:", tensor["name"])
    print("Index:", tensor["index"])
    print("Shape:", tensor["shape"])
    print("Dtype:", tensor["dtype"])
    print("Quantization:", tensor["quantization"])
    print("------------------------")

# Get model input and output information
print("\nINPUT:", interpreter.get_input_details())
print("\nOUTPUT:", interpreter.get_output_details())
