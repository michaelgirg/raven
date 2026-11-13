# Pre-alpha staging integrity and recovery

The buffered NPU configuration implements per-byte parity across its actual
activation, weight, parameter and output staging paths. This is synthesizable
logic used during execution, in addition to simulation scoreboards and assertions.
It provides a bounded corruption-detection and recovery mechanism for the
pre-alpha GEMM use case.

## Protected path

`raven_integrity_pkg.byte_parity` computes one parity bit for each of the sixteen
bytes in a 128-bit word. Each read adapter saves these bits when it accepts a
backing-memory response, before writing/reading the native tile buffer. The
reconstructed response is checked against that saved reference before release
and continuously while held under backpressure. A failed response is never
accepted by the core or PARAM loader.

The output adapter saves parity when it captures a writer request. Native-buffer
readback is checked before the backing write and while that write is stalled.
Only strobed output bytes are checked, because other bytes are not committed.
A failed write receives neither backing valid nor upstream acknowledgement.

This adds no normal-path staging cycle. The existing write/read round trips and
their performance cost remain; parity does not optimize the buffering architecture.
The original compute RTL and the four native buffer modules are unchanged.

## Error signaling and safe stop

An adapter latches an integrity error and its aligned bank-local word address.
The top saves the first observed fault reference. Simultaneous detections use
ACT0, ACT1, WGT0, WGT1, PRM A, PRM B, then OUT0 priority.

The top immediately holds the datapath, adapters and backing responders in reset
through `local_rst_no`. The control block remains clocked and operational so it
can retain diagnostics and enter ERROR/HALTED. Connected backing responders must
flush pending transactions on this shared reset without erasing their stored data.

| Field/event | Behavior |
|---|---|
| `ERR_CODE[7:0]` | Existing `ERR_UNIT = 0x09`. |
| `ERR_CODE[31:16]` | Sequence of the failed command. |
| `ERR_INFO` | `{BANK_ID[3:0], 4'b0, WORD_BYTE_OFFSET[23:0]}` for a detected staging fault. Both PRM ports use bank ID 6. |
| Status/IRQ | STATUS.ERROR and IRQ_STATUS.ERROR are set; the command halts. |
| Retirement | The failed command does not update DONE_SEQ, increment CMD_COUNT or raise a new DONE interrupt. |
| `CLEAR_ERR` | Clears diagnostics only; the datapath remains held and START cannot resume it. |
| `SOFT_RESET` | Clears the latched integrity abort and pending state; returns control to IDLE. |

The existing first-error rule still applies: an earlier latched error is preserved.
A fault coincident with a new busy START has priority over that new START error.
The register map and public bank ports are unchanged. For other failures, ERR_INFO
retains the existing register-offset/core-error meaning.

## Recovery and output validity

1. Read the error/status fields and treat the failed command's entire destination
   as invalid. Some earlier output bytes may already have committed; they are not
   rolled back or automatically repaired.
2. Issue SOFT_RESET and wait for IDLE. CLEAR_ERR alone is insufficient.
3. Restore/reload trusted operand and parameter data if its integrity is uncertain,
   and reinitialize or overwrite the destination as appropriate. Reset clears
   staging/validity state, not the full backing memories.
4. Restage and run a fresh command. Consume its result only after successful
   completion for that command's sequence and no reported error.

The pre-alpha test driver reloads known-good bank images before the recovery run.
The physical host/DMA loader remains future work. The test demonstrates a safe
stop followed by reset, trusted reload/refill and correct recomputation; it does
not demonstrate reconstruction of damaged data without a trusted source.

## Fault model and limits

- Parity detects a single changed bit, or any odd number of changed bits, within
  each protected byte. An even number of changed bits within the same byte can
  escape detection. Errors are detected, not corrected.
- Read protection begins when backing data and its local parity reference are
  captured. It does not detect incorrect data already present in backing memory,
  or corruption before that capture. There is no end-to-end reference checksum
  supplied by the host.
- Output protection begins at writer capture and covers staging/readback until
  backing acceptance. It does not protect the backing data after commit.
- This mechanism does not generally protect addresses/strobes, control logic,
  parity metadata against coordinated faults, post-response consumer logic, or
  attacks that preserve parity. It is not ECC, a cryptographic check, access
  control or authentication.
- A missing memory response still requires software timeout/recovery; there is
  no autonomous hardware watchdog in this pre-alpha.
- Protection is enabled by `USE_TILE_BUFFERS=1`, the default. The direct-bank
  configuration is a numerical reference without these staging parity checks.

## Verification and reproduction

```sh
python tests/rtl/integration/run_questa.py
python tests/rtl/integration/run_questa.py --tests T16
```

The adapter benches flip every data bit of a stalled read response for each of
ACT/WGT/PRM and every strobed output bit: 512 single-bit cases. They also corrupt
native-buffer readback beats and verify sticky errors and a clean restart.

T16 flips an actual native readback bit on all seven ports, with and without
backing stalls: fourteen fault/recovery pairs. It verifies runtime ERR_UNIT,
sequence and bank/address diagnostics, ERROR IRQ, HALTED state, stopped traffic,
no successful retirement, ineffective CLEAR_ERR/START, then soft reset and a
trusted reload followed by independent golden output comparison. OUT includes
both a first-byte fault and a fault after three earlier bytes committed; the bad
byte never commits and no later bytes are written after the stop.

A full run repeats T16 after compiling with `SYNTHESIS` defined. The RTL's
simulation-only properties are removed, but all fourteen runtime detections and
recovery results must still pass. The direct configuration repeats the recovery
GEMMs for byte-for-byte numerical comparison; it does not claim parity protection.

See the [integration results](../../evidence/questa/integration/results.json) and
[execution log](../../evidence/questa/integration/verification.log). The
[rubric mapping](../reviews/RAVEN_PREALPHA_RUBRIC_COVERAGE.md) identifies what this
implemented mechanism supports in the pre-alpha architecture criteria.
