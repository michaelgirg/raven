# Output operators

## Requantization and clamp

`raven_requantize_clamp.sv` is a one-lane tail for completed signed INT32
results. It converts completed signed INT32 results to INT8 using a one-entry register with valid/ready handshaking.

The arithmetic follows TensorFlow Lite Micro commit
`c051fea55c4a6b4464186e1bb126708bea50f32e` with
`TFLITE_SINGLE_ROUNDING=1`:

- Signed INT32 input multiplied by a nonnegative Q0.31 multiplier.
- Signed shift from -31 through 30; positive shifts scale up.
- Positive half-ULP added before the arithmetic right shift. A `-1.5` tie
  therefore rounds to `-1`, matching the pinned TFLM helper.
- Signed output zero-point added after scaling, then activation min/max and
  INT8 limits applied.

Parameters are direct inputs and are sampled when `in_valid_i` and
`in_ready_o` handshake. Parameter-bank lookup and output-memory addressing are
not part of this module.

## Interface

The input carries INT32 data, row, column, index, channel, and last tags. The
output preserves those tags with the converted INT8 data. `in_ready_o` is high
when the one-entry output register is empty or its current result is accepted.
While `out_valid_o` is high and `out_ready_i` is low, data and all tags remain
stable.

The current GEMM core supplies data, row, column, index, and last, but not a
channel tag. Channel mapping, parameter delivery, and output memory connections still need to be finalized with Michael and Taylor.

## Verification

`tests/rtl/operators/tb_raven_requantize_clamp.sv` uses literal expected INT8
values derived from the pinned TFLM behavior. It covers positive, negative, and
zero inputs; positive and negative shifts; positive and negative rounding ties;
nonzero output zero-points; activation and INT8 saturation; tags; stalls;
consecutive-cycle input handshakes; reset; and restart.

Run from the repository root:

```sh
python tests/rtl/operators/run_questa.py
```

The test passed on November 2, 2026 with Intel ModelSim FPGA Edition 2020.1:

```text
PASS REQUANT: rounding, clamps, tags, stalls, reset, and consecutive inputs
```

ModelSim reported that full SVA support requires Questa. The directed
testbench scoreboard and immediate assertions ran without errors.

## Limits

This is one lane only. It does not fetch per-channel parameters, write a
scratchpad destination, or connect directly to the GEMM core. It assumes valid
TFLM-prepared multiplier and shift inputs and does not implement a parameter
range-error response.
