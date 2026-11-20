# RAVEN Memory Buffer Testbenches

## Overview

This directory contains SystemVerilog testbenches for verifying the individual memory components and managed scratchpad model used in the RAVEN FPGA NPU.

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
| `tb_banked_scratchpad.sv` | Tests managed bank lifecycle, ownership, generic storage, and handshake behavior. |
| `tb_banked_scratchpad_preload.sv` | Tests fixed 128-bit `.hex` preload and reset-to-ready behavior. |

## Running the Tests

Add Questa's commands to PATH. Create and enter `build/tests/memory/standalone`
under the repository, then run:

```sh
vmap -c
vlib work
vmap work work
vlog -sv ../../../../rtl/memory/activation_buffer.sv ../../../../tests/rtl/memory/tb_activation_buffer.sv
vlog -sv ../../../../rtl/memory/weight_buffer.sv ../../../../tests/rtl/memory/tb_weight_buffer.sv
vlog -sv ../../../../rtl/memory/parameter_buffer.sv ../../../../tests/rtl/memory/tb_parameter_buffer.sv
vlog -sv ../../../../rtl/memory/output_buffer.sv ../../../../tests/rtl/memory/tb_output_buffer.sv
vlog -sv ../../../../rtl/memory/banked_scratchpad.sv ../../../../tests/rtl/memory/tb_banked_scratchpad.sv
vlog -sv ../../../../rtl/memory/banked_scratchpad.sv ../../../../tests/rtl/memory/tb_banked_scratchpad_preload.sv
vsim -c -onfinish exit -sva -immedassert work.tb_activation_buffer -do "run -all; quit -f"
vsim -c -onfinish exit -sva -immedassert work.tb_weight_buffer -do "run -all; quit -f"
vsim -c -onfinish exit -sva -immedassert work.tb_parameter_buffer -do "run -all; quit -f"
vsim -c -onfinish exit -sva -immedassert work.tb_output_buffer -do "run -all; quit -f"
vsim -c -onfinish exit -sva -immedassert work.tb_banked_scratchpad -do "run -all; quit -f"
vsim -c -onfinish exit -sva -immedassert work.tb_banked_scratchpad_preload -do "run -all; quit -f"
```

Run simulations sequentially. Check for each `ALL ... TESTS PASSED` marker and
zero simulator errors because Questa can exit successfully after `$fatal`.

## Test Coverage

### 1. Banked Scratchpad

The banked scratchpad testbench verifies:

- Reset initializes banks as `FREE` with no owner.
- A `FREE` bank can be acquired for DMA filling.
- A fill records ownership, length, and a new generation ID.
- Generic data can be written to an owned filling bank.
- `CMD_COMMIT` changes the bank from `DMA_FILLING` to `READY`.
- A second fill attempt on a non-`FREE` bank is rejected.
- A committed bank can be acquired for compute reads.
- Read response data remains stable while `rd_rsp_ready` is low.
- A read response clears after valid/ready acceptance.
- A bank can be released back to `FREE`.
- An old generation cannot commit after the bank is released.
- OUT0 accepts a write acquisition from `FREE`, records the owner and length,
  and stores the authorized write. Invalid owners, oversized allocations,
  duplicate acquisitions, and stale release requests are rejected.
- PRM supports fill, write, and read through logical ID 6. The absent OUT1 at
  ID 5 is rejected.
- Reset clears bank ownership and outstanding responses.

### 2. Activation Buffer

The activation buffer testbench verifies:

- Reset behavior.
- Writing all eight activation banks.
- Reading all 16 K positions.
- Correct retrieval of all 128 signed INT8 values.
- Correct bank-to-output byte ordering.
- Output backpressure.
- Response-valid clearing after consumption.

**Simulation result:** All activation buffer tests passed.

### 3. Weight Buffer

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

### 4. Parameter Buffer

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

### 5. Output Buffer

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

These testbenches verify the individual buffer RTL implementations and the
initial bank management model in simulation.

They do not yet verify:

- Integration with the compute core.
- Integration with the output operators.
- Full-system memory ownership and bounds checking.
- Complete GEMM execution.
- Golden-reference comparison of the final GEMM output.
- FPGA synthesis or BRAM inference.
- Physical FPGA hardware operation.

These items remain part of the broader RAVEN pre-alpha integration and verification effort.

## Development Notes

When modifying a buffer's interface or internal behavior, update its corresponding testbench to reflect the change.
Run the relevant testbench after each modification to ensure that existing functionality remains intact.
The individual memory tests are intended to provide a foundation for later system-level integration and verification.
