# RAVEN Memory and Data Movement

## Overview

This directory contains the initial memory components and managed scratchpad model for the RAVEN FPGA Neural Processing Unit (NPU).

The memory subsystem is responsible for storing activation data, weight data, quantization parameters, and computed output values. These buffers provide the storage and interfaces needed to transfer data between the compute core, output operators, and system integration logic. The banked scratchpad adds explicit ownership and lifecycle management around generic byte addressable storage.

The initial implementation targets the pre-alpha demonstration of an 8×16 activation matrix multiplied by a 16×8 weight matrix, producing an 8×8 output matrix.

## Directory Contents

| File | Description |
|---|---|
| `activation_buffer.sv` | Stores the activation matrix. |
| `weight_buffer.sv` | Stores the weight matrix. |
| `parameter_buffer.sv` | Stores bias and quantization parameters. |
| `output_buffer.sv` | Stores the final INT8 output matrix. |
| `banked_scratchpad.sv` | Managed scratchpad model with bank ownership, lifecycle states, generation IDs, and generic read/write interfaces. |

## 1. Banked Scratchpad

**File:** `banked_scratchpad.sv`

The banked scratchpad is the first managed-memory model for the proposed RAVEN
scratchpad architecture. It is intentionally independent from the current
compute-memory interface while the adapter contract is being reviewed.

The default model contains six logical banks. Commands and data requests use
four-bit logical IDs matching the control interface. Status arrays still use
dense storage slots.

| Bank | Logical ID | Status slot | Role |
|---|---|---|---|
| `ACT0`, `ACT1` | 0, 1 | 0, 1 | Activation ping-pong banks |
| `WGT0`, `WGT1` | 2, 3 | 2, 3 | Weight ping-pong banks |
| `OUT0` | 4 | 4 | Output or future partial-sum bank |
| `PRM` | 6 | 5 | Parameter bank |

ID 5 is reserved for optional OUT1. This model rejects it because OUT1 is absent.

The module is parameterized by bank count, bank capacity, transfer width, and
generation width. Its default storage model is six 256-byte banks with
16-byte transfers; tests may use smaller configurations.

### Bank lifecycle

The current model supports these normal allocation paths:

```text
FREE -> DMA_FILLING -> READY -> COMPUTING -> FREE
FREE -> NPU_WRITING -> FREE
```

`ERROR` is available for failed or aborted ownership. A fill does not become
`READY` until an explicit `CMD_COMMIT` command is accepted. Bank ownership,
generation ID, and requested length are visible through the status outputs.
`FULL` and `DRAINING` are reserved for the future output-drain lifecycle.

### Management commands

The command interface supports:

- `CMD_ACQUIRE_FILL`: acquire a `FREE` bank for DMA or host filling.
- `CMD_COMMIT`: publish a completed fill as `READY`.
- `CMD_ACQUIRE_READ`: acquire a `READY` bank for compute reads.
- `CMD_ACQUIRE_WRITE`: acquire a `FREE` bank for NPU writes. Supply the new
  owner and requested length. The command returns the new generation for
  subsequent writes and release.
- `CMD_RELEASE`: return an owned bank to `FREE`.
- `CMD_ABORT`: move an owned bank to `ERROR`.

Commands return a response status such as `RESP_OK`, `RESP_BAD_STATE`,
`RESP_NOT_OWNER`, or `RESP_BAD_RANGE`.

### Generic data interfaces

Writes use a bank ID, owner, generation ID, byte address, data, and byte
strobe. Writes are valid only for an owned `DMA_FILLING` or `NPU_WRITING`
bank. Reads use a request/response valid/ready pair and are valid only for an
owned `COMPUTING` bank. Read data remains stable while the response is stalled.

Generation IDs distinguish a current bank allocation from a previous use of the
same bank. Reset clears generations, so requesters must discard outstanding
transactions and old allocation handles when they reset together.

## 2. Activation Buffer

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

## 3. Weight Buffer

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

## 4. Parameter Buffer

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

## 5. Output Buffer

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
| Banked scratchpad | RTL model implemented; directed testbench covers lifecycle, ownership, bounds, generation, read backpressure, release, and reset. |
| Activation buffer | RTL implemented; simulation tests passed. |
| Weight buffer | RTL implemented; testbench passed. |
| Parameter buffer | RTL implemented; simulation tests passed. |
| Output buffer | RTL implemented; simulation tests passed. |

## Known Limitations and Future Improvements (some could be condisdered as bugs)

- Activation and parameter buffers do not currently track whether
  individual entries have been initialized.
- Output buffer tracks written rows but does not prevent reads
  from unwritten rows.
- Read/write collision behavior should be explicitly defined
  during integration.
- Current output buffer supports 64 bytes of INT8 output data.
  Additional capacity and addressing will be required for future
  INT32 partial-sum storage.
- Activation buffer uses conservative write gating while read
  requests or responses are pending.
- Parameter buffer does not currently track whether all required
  parameters have been loaded.
- The banked scratchpad is a simulation model and is not connected to the
  compute top, physical BRAM, DMA, or the existing specialized buffers.
- Invalid generic writes are currently suppressed by the storage path rather
  than returned through a dedicated write-error response.
- The scratchpad lifecycle does not yet implement the complete production
  `FULL`, `DRAINING`, partial-sum, or DMA commit protocol.

## Integration Considerations

- The controller must ensure that data is written before it is read.
- Read requests and response consumption must follow the valid/ready
  handshake protocol.
- Simultaneous reads and writes to the same storage location
  require a defined collision policy.

## Future Work

- Define and verify memory ownership and bounds checks.
- Coordinate memory interfaces with the compute core and output operators.
- Integrate the buffers with the control and integration harness (in progress)
- Verify the complete GEMM operation against the golden reference (in progress)
- Evaluate FPGA synthesis and memory inference.
- Expand output storage to support future INT32 partial-sum requirements.

## Pre-alpha pipeline adapters

The default buffered path also implements
[per-byte staging parity and runtime recovery](../../docs/interfaces/RAVEN_STAGING_INTEGRITY.md).
Read parity is captured before native-buffer staging and checked before response
release; output parity is checked before backing commit. A mismatch triggers
ERR_UNIT, traffic flush and a halt until soft reset. It does not repair data or
protect backing storage outside the stated capture/commit boundary.

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
