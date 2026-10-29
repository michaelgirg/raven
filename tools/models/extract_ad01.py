from pathlib import Path
import json
import numpy as np
import tensorflow as tf

ROOT = Path(__file__).resolve().parents[2]

MODEL = ROOT / "models/deep_autoencoder/ad01_int8.tflite"
OUTPUT = ROOT / "build/models/ad01"
OUTPUT.mkdir(parents=True, exist_ok=True)

interpreter = tf.lite.Interpreter(model_path=str(MODEL))
interpreter.allocate_tensors()

details = {
    t["index"]: t
    for t in interpreter.get_tensor_details()
}

metadata = []
total_weights = 0
total_biases = 0

for i in range(10):
    # Based on your inspected AD01 tensor indices
    bias_index = i + 1
    weight_index = i + 11

    weights = interpreter.get_tensor(weight_index)
    biases = interpreter.get_tensor(bias_index)

    assert weights.dtype == np.int8
    assert biases.dtype == np.int32
    assert weights.shape[0] == biases.size

    layer_name = f"layer_{i+1}"

    np.save(OUTPUT / f"{layer_name}_weights.npy", weights)
    np.save(OUTPUT / f"{layer_name}_biases.npy", biases)

    metadata.append({
        "layer": i + 1,
        "weight_shape": list(weights.shape),
        "bias_shape": list(biases.shape),
        "weight_scale": details[weight_index]["quantization"][0],
        "weight_zero_point": details[weight_index]["quantization"][1]
    })

    total_weights += weights.size
    total_biases += biases.size

    print(f"{layer_name}: weights={weights.shape}, biases={biases.shape}")

assert total_weights == 264192
assert total_biases == 1672

with open(OUTPUT / "metadata.json", "w") as f:
    json.dump(metadata, f, indent=4)

print("\nAD01 extraction successful!")
print("Total weights:", total_weights)
print("Total biases:", total_biases)