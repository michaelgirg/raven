# RAVEN Memory and Data Movement

## Overview

This directory contains the initial memory components for the RAVEN FPGA Neural Processing Unit (NPU).

The memory subsystem is responsible for storing activation data, weight data, quantization parameters, and computed output values. These buffers provide the storage and interfaces needed to transfer data between the compute core, output operators, and system integration logic.

The initial implementation targets the pre-alpha demonstration of an 8×16 activation matrix multiplied by a 16×8 weight matrix, producing an 8×8 output matrix.

## Directory Contents

| File | Description |
|---|---|
| `activation_buffer.sv` | Stores the activation matrix. |
| `weight_buffer.sv` | Stores the weight matrix. |
| `parameter_buffer.sv` | Stores bias and quantization parameters. |
| `output_buffer.sv` | Stores the final INT8 output matrix. |

## 1. Activation Buffer

**File:** `activation_buffer.sv`

The activation buffer stores an 8×16 matrix of signed INT8 values.

- Capacity: 128 bytes.
- Organization: 8 banks, each containing 16 INT8 values.
- Write interface: 128-bit input, writing one complete bank.
- Read interface: 4-bit K index.
- Read output: 64-bit vector containing one INT8 value from each of the eight banks.

The read interface allows the compute core to retrieve eight activation values corresponding to a selected K position.

**Data organization:**

- `rd_data[7:0]`: Bank 0
- `rd_data[15:8]`: Bank 1
- `rd_data[23:16]`: Bank 2
- `rd_data[31:24]`: Bank 3
- `rd_data[39:32]`: Bank 4
- `rd_data[47:40]`: Bank 5
- `rd_data[55:48]`: Bank 6
- `rd_data[63:56]`: Bank 7

The buffer uses valid/ready handshaking and synchronous read behavior.

## 2. Weight Buffer

**File:** `weight_buffer.sv`

The weight buffer stores a 16×8 matrix of signed INT8 values.

- Capacity: 128 bytes.
- Organization: 16 banks, each containing 8 INT8 values.
- Write interface: 64-bit input, writing one complete bank.
- Read interface: 4-bit K index.
- Read output: 64-bit vector containing eight INT8 values representing the output channels for the selected K position.

The organization allows the compute core to retrieve the eight weight values associated with a selected K position.

**Data organization:**

- `rd_data[7:0]`: Output channel 0
- `rd_data[15:8]`: Output channel 1
- `rd_data[23:16]`: Output channel 2
- `rd_data[31:24]`: Output channel 3
- `rd_data[39:32]`: Output channel 4
- `rd_data[47:40]`: Output channel 5
- `rd_data[55:48]`: Output channel 6
- `rd_data[63:56]`: Output channel 7

The buffer uses valid/ready handshaking and synchronous read behavior.

## 3. Parameter Buffer

**File:** `parameter_buffer.sv`

The parameter buffer stores the bias and quantization parameters required by the output operators.

The parameter organization follows the specifications provided by the output-operator developer.

### Parameter definitions

| Parameter | Data type | Organization |
|---|---|---|
| Corrected bias | Signed 32-bit | Per-output-channel |
| Q31 multiplier | Signed 32-bit | Shared or per-output-channel |
| Quantization shift | Signed 8-bit | Shared or per-output-channel |
| Output zero-point | Signed 8-bit | Shared |
| Activation clamp minimum | Signed 8-bit | Shared |
| Activation clamp maximum | Signed 8-bit | Shared |

### Address map

| Address | Parameter |
|---|---|
| 0–7 | Corrected bias, channels 0–7 |
| 8–15 | Q31 multiplier, channels 0–7 |
| 16–23 | Quantization shift, channels 0–7 |
| 24 | Output zero-point |
| 25 | Activation clamp minimum |
| 26 | Activation clamp maximum |
| 27 | Multiplier organization mode |
| 28 | Shift organization mode |

For multiplier and shift organization:
- `0`: Shared mode; use entry 0 for every output channel.
- `1`: Per-channel mode; use the selected output channel's entry.

The write interface uses a 6-bit address and 32-bit data input. For 8-bit parameters, the value is stored in the lowest eight bits of the write data.

The read interface accepts a 3-bit output-channel selection and returns the corresponding bias, multiplier, shift, zero-point, and clamp values.

The parameter buffer uses valid/ready handshaking and synchronous read behavior.

## 4. Output Buffer

**File:** `output_buffer.sv`

The output buffer stores the final quantized INT8 output matrix produced by the output operators.

The pre-alpha GEMM operation produces an 8×8 output matrix.

- Capacity: 64 bytes.
- Organization: 8 rows, each containing 8 INT8 values.
- Write interface: 64-bit input, writing one complete row.
- Read interface: 3-bit row selection.
- Read output: 64-bit vector containing one complete output row.

The buffer uses byte-addressable internal storage and tracks whether each output row has been written.

The initial pre-alpha implementation stores final INT8 results only. The storage organization is intended to support future expansion for INT32 partial-sum storage, although the current implementation provides 64 bytes of capacity and does not yet implement the expanded INT32 capacity.

## Interface and Handshaking

The memory components use valid/ready handshaking for data transfers.

- `wr_valid`: Indicates that the producer is presenting valid write data.
- `wr_ready`: Indicates that the buffer can accept the write.
- `rd_valid_in`: Indicates that a read request is being presented.
- `rd_ready`: Indicates that the buffer can accept a read request.
- `rd_valid_out`: Indicates that read data is available.
- `rd_ready_out`: Indicates that the consumer can accept the read response.

The buffers use synchronous read operations. Read responses remain valid while the consumer is applying backpressure.

## Reset Behavior

The buffers use active-high asynchronous reset.

Control and response-valid registers are reset. Large storage arrays are not necessarily cleared during reset, avoiding unnecessary reset logic on the memory arrays.

The integration logic must ensure that required data has been written before it is read.

## Current Development Status

| Component | Status |
|---|---|
| Activation buffer | RTL implemented; simulation tests passed. |
| Weight buffer | RTL implemented; testbench passed. |
| Parameter buffer | RTL implemented; simulation tests passed. |
| Output buffer | RTL implemented; simulation tests passed. |

## Future Work

- Define and verify memory ownership and bounds checks.
- Optimize the connected staging path for tile prefetch and reuse.
- Replace simulation backing banks with physical storage and verify board operation.
- Evaluate FPGA synthesis and memory inference.
- Expand output storage to support future INT32 partial-sum requirements.

## Pre-alpha pipeline adapters

`raven_npu_top` defaults to `USE_TILE_BUFFERS=1`. The two adapter modules connect
these four native buffers to the existing 128-bit bank interfaces without changing
the compute RTL, command layout or architectural capacities. Backing storage still
provides 16 KiB per ACT/WGT bank, 4 KiB PRM and 8 KiB OUT0; the small native buffers
are staging slots refilled for each transaction.

| Adapter | Native operations |
|---|---|
| `raven_read_buffer_adapter`, KIND=0 | Write one ACT word into the slot selected by address bits 6:4; read K=0..15 and gather that slot's lane into the returned 128-bit word. |
| `raven_read_buffer_adapter`, KIND=1 | Write the low/high halves into consecutive WGT rows, then read both rows back. |
| `raven_read_buffer_adapter`, KIND=2 | Write corrected bias, multiplier and shift into the selected channel, then read it back. Set native per-channel modes after reset. Reserved PARAM bytes pass through; command zero-point/clamp stay in the operator configuration. |
| `raven_output_buffer_adapter` | Write/read each strobed 64-bit half through `outputBuffer`, then issue the original address/strobes to backing storage. Upstream ready is asserted only with the accepted backing write, so DONE still means stored. |

ACT0/ACT1 and WGT0/WGT1 each have a staging instance; the two independent PRM ports
also have separate instances. Full addresses go to backing storage. Low bits choose
reused staging slots and do not truncate the architectural bank address. Each read
port permits one outstanding transaction and holds its response during a stall.

All adapters use `local_rst_no`; native buffers receive its inverse. Hardware or
soft reset cancels pending adapter traffic. The backing responder must reset with
them and discard pending replies. ACT/WGT arrays may retain data, PARAM clears on
reset, and OUT row-valid bits clear; every consumed slot is rewritten before read.

Run `python tests/rtl/integration/run_questa.py` from the repository root. The suite
checks the buffered pipeline against independent INT8 goldens, repeats it with the
direct-bank configuration, and tests adapter address reuse, stalls, reset recovery,
all output byte lanes and sparse/full strobes. A K=33 zero-extension at the bank
ends checks that staging capacity does not limit the supported command span. See
the [integration report](../../evidence/questa/integration/results.json) and
[project run instructions](../../README.md#run-the-integration-tests).

This path adds staging latency and does not yet provide optimized tile reuse,
physical backing BRAM, DMA or bank ownership. Standalone screenshots remain under
`evidence/prealpha/memory/`.
