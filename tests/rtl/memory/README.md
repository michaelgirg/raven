# RAVEN Memory Buffer Testbenches

## Overview

This directory contains SystemVerilog testbenches for verifying the individual memory components used in the RAVEN FPGA NPU.

The testbenches are designed to verify basic read/write functionality, data integrity, signed-value handling, valid/ready handshaking, and output backpressure.

All four components passed independently with Questa Intel Starter FPGA Edition-64
2021.2 on merged revision `3577d48d063182e0e2e9560623f58cf0804621ae`. The
[full validation record](../../../evidence/questa/final-prealpha/results.json)
also includes eight rejected reset/validity/mode faults and the six-case golden
matrix. Connected pipeline coverage is described in the
[main test README](../../README.md#verified-pre-alpha-results).

## Directory Contents

| File | Description |
|---|---|
| `tb_activation_buffer.sv` | Tests activation matrix storage and retrieval. |
| `tb_weight_buffer.sv` | Tests weight matrix storage and retrieval. |
| `tb_parameter_buffer.sv` | Tests bias and quantization parameter storage and retrieval. |
| `tb_output_buffer.sv` | Tests output matrix storage and retrieval. |

## Running the Tests

Add Questa's commands to PATH. Create and enter
`build/tests/memory/standalone` under the repository, then run:

```sh
vmap -c
vlib work
vmap work work
vlog -sv ../../../../rtl/memory/activation_buffer.sv ../../../../tests/rtl/memory/tb_activation_buffer.sv
vlog -sv ../../../../rtl/memory/weight_buffer.sv ../../../../tests/rtl/memory/tb_weight_buffer.sv
vlog -sv ../../../../rtl/memory/parameter_buffer.sv ../../../../tests/rtl/memory/tb_parameter_buffer.sv
vlog -sv ../../../../rtl/memory/output_buffer.sv ../../../../tests/rtl/memory/tb_output_buffer.sv
vsim -c -onfinish exit -sva -immedassert work.tb_activation_buffer -do "run -all; quit -f"
vsim -c -onfinish exit -sva -immedassert work.tb_weight_buffer -do "run -all; quit -f"
vsim -c -onfinish exit -sva -immedassert work.tb_parameter_buffer -do "run -all; quit -f"
vsim -c -onfinish exit -sva -immedassert work.tb_output_buffer -do "run -all; quit -f"
```

Run simulations sequentially if the license permits only one active simulation.
Require the matching `ALL ... BUFFER TESTS PASSED` marker and zero simulator
errors; this Questa configuration can return exit code zero even after `$fatal`.
The golden-buffer runners also check completion markers and data comparisons.

## Test Coverage

### 1. Activation Buffer

The activation buffer testbench verifies:

- Reset behavior.
- Writing all eight activation banks.
- Reading all 16 K positions.
- Correct retrieval of all 128 signed INT8 values.
- Correct bank-to-output byte ordering.
- Output backpressure.
- Response-valid clearing after consumption.

**Simulation result:** All activation buffer tests passed.

### 2. Weight Buffer

The weight buffer testbench verifies:

- Reset behavior.
- Writing all 16 weight banks.
- Reading all 16 K positions.
- Correct retrieval of all 128 signed INT8 values.
- Correct output-channel byte ordering.
- Output backpressure.
- Response-valid clearing after consumption.
- Overwriting an existing weight bank.

**Simulation result:** All weight buffer tests passed.

### 3. Parameter Buffer

The parameter buffer testbench verifies:

- Reset behavior.
- Writing all eight corrected bias values.
- Writing all eight Q31 multiplier values.
- Writing all eight quantization shift values.
- Writing shared zero-point and activation clamp values.
- Reading the correct per-channel bias values.
- Shared multiplier mode.
- Per-channel multiplier mode.
- Shared shift mode.
- Per-channel shift mode.
- Signed 8-bit and signed 32-bit parameter handling.
- Output backpressure.
- Response-valid clearing after consumption.

**Simulation result:** All parameter buffer tests passed.

### 4. Output Buffer

The output buffer testbench verifies:

- Reset behavior.
- Writing all eight output rows.
- Reading all eight output rows.
- Correct retrieval of all 64 signed INT8 values.
- Correct row-to-output byte ordering.
- Overwriting an existing output row.
- Output backpressure.
- Response-valid clearing after consumption.

**Simulation result:** All output buffer tests passed.

## Testbench Design

Each testbench uses a clocked simulation environment and drives the corresponding memory module through its exposed interface.

The testbenches use:
- Directed write operations.
- Directed read operations.
- Expected-value arrays for data comparisons.
- Signed comparisons for INT8 and INT32 values.
- Valid/ready handshake checks.
- Backpressure tests to ensure response data remains stable until consumed.
- `$fatal` to terminate simulation when a test fails.

A successful simulation ends with an `ALL ... BUFFER TESTS PASSED` message.

## Verification Limitations

These testbenches verify the individual buffer RTL implementations in simulation.

The [integration suite](../integration/run_questa.py) separately verifies the
connected GEMM, buffer and operator path against golden INT8 outputs. It covers
command rejection, stalls, reset recovery, destination bounds and guard bytes.
Standalone NPU block synthesis also passed; the
[FPGA review](../../../docs/reviews/RAVEN_BOARD_READINESS_REVIEW.md) explains its
memory-inference warnings and limited scope.

Physical backing BRAM, DMA/bank ownership, complete board timing and physical
FPGA operation remain future work. These small buffer tests do not establish a
working full-capacity scratchpad or a full-model implementation.

## Development Notes

When modifying a buffer's interface or internal behavior, update its corresponding testbench to reflect the change.
Run the relevant testbench after each modification to ensure that existing functionality remains intact.
The individual memory tests are intended to provide a foundation for later system-level integration and verification.
