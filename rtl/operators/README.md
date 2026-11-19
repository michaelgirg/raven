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

The integrated path uses the column tag as the output-channel index.
`rtl/top/raven_requant.sv` supplies shared or per-channel PARAM values, and
`rtl/top/raven_result_writer.sv` converts accepted INT8 results to byte-strobed
OUT0 writes. The connected Pre-Alpha GEMM-to-output path is verified in
simulation; this leaf module remains independently reusable.

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

The directed test has passed with Intel ModelSim FPGA Edition 2020.1 and
Questa Intel Starter FPGA Edition-64 2021.2:

```text
PASS REQUANT: rounding, clamps, tags, stalls, reset, and consecutive inputs
```

The runner requires both immediate and concurrent assertions to execute. It
first proves this using two deliberate fatal probes, then checks the real bench
for simulator errors and the exact completion marker. A simulator exit code of
zero alone is not accepted as a passing test. Use Questa with full SVA support;
ModelSim configurations without concurrent assertions fail the guard check.

Each run uses a fresh directory under `build/tests/operators/questa/`, including
local library mappings, transcripts and a source-hash/result report. `latest.json`
points to that report relative to its own directory. Tools are discovered through
PATH, QUESTA_BIN or `--questa-bin`; `--timeout` bounds each tool invocation.

## Prototype memory work

The Pre-Alpha result path is complete through simulated OUT0 storage. For the
board prototype, the remaining work is to connect the writer's aligned 128-bit
data and byte strobe to synthesizable output memory, then verify each output
address and byte against the expected INT8 result. Taylor's
`rtl/memory/banked_scratchpad.sv` currently provides a separate managed-memory
model with bank ownership, generation IDs, 16-byte generic transfers, and
valid/ready reads; it is not yet connected to the NPU top or physical BRAM.

The prototype readback goal is all 64 INT8 values of the 8-by-8 output tile.
It requires an agreed output-bank adapter/readback interface and an Ultra96-V2
test that compares the stored bytes and addresses with the golden result. No
synthesizable-memory or board readback result is claimed here.

## Limits

This is one lane only. The leaf module does not fetch parameters or address a
scratchpad itself; the integrated wrapper and writer provide those functions.
It assumes valid TFLM-prepared multiplier and shift inputs and does not
implement a parameter range-error response.
