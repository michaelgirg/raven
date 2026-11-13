# Pre-alpha rubric coverage

The demonstrated major use case is one register-controlled INT8 GEMM tile:

**Command interface -> saved configuration and bank references -> buffered operand/
PARAM reads -> INT32 GEMM -> requantization/clamp -> committed INT8 storage ->
completion status/interrupt.**

The rubric asks for prepared structures and connections at pre-alpha scope. The
implementation and tests below support that scope. The processor is represented
by a simulation driver, and full-capacity backing banks are simulation models;
the actual native tile-buffer RTL participates in the path. This is not a claim
that the complete board application has been implemented.

| Criterion | Implemented structure | Demonstration/evidence |
|---|---|---|
| External interface | Register valid/ready bus, staging registers, START snapshot, bank/offset references and status/IRQ readback. The command interface controls processing that reads/writes the data store. | T2 register traffic, a T4 GEMM command and its saved references, then committed OUT0 bytes and DONE. |
| Persistent state/data store | Defined ACT/WGT/PRM/OUT capacities and layouts, bank-local addresses, native buffer storage, request/response reads and byte-enabled writes. Commands reference this storage and processing consumes/updates it. | Bank images and PARAM record layout, selected-bank reads, output dumps and unchanged guard bytes. These are volatile tensor/parameter/result memories; power-loss persistence is not implemented. |
| Integrity and resilience | Synthesized command/range/overflow checks plus per-byte parity across native staging. A detected parity error blocks bad data, latches ERR_UNIT and bank/address information, stops traffic and halts the command. Soft reset and trusted reload/refill allow a fresh successful operation. | T10/T11 error rejection; T14 reset/restart; T16's fourteen native-path corruption/recovery pairs, repeated with simulation-only RTL assertions removed. Parity covers the explicit local fault model in the integrity contract, not arbitrary corruption or all attacks. |
| Communication/signaling | Valid/ready bank transactions, tagged compute/operator streams, byte strobes, command sequence numbers, error/DONE interrupts and retirement after the final committed write. | T7 bank routing, T8 stalls, adapter stability tests and monitors checking that DONE follows actual storage. |
| Internal processing | Actual frontend, MAC array/PEs, GEMM control, per-channel requantization/clamp and output writer connected to storage. | Independent INT8 golden comparisons through the complete buffered path, including partial tiles, signed values, saturation and rounding. |

## Presenting the evidence

Use the same GEMM example across the first, second, fourth and fifth criteria.
Show a command entering, the stored configuration and bank data it references,
the connected processing path, and the resulting OUT0 bytes with completion.
For communication, show a held transfer and its eventual acceptance under a stall.

For integrity/resilience, show one T16 fault with its actual ERR_CODE/ERR_INFO,
ERROR IRQ and HALTED state, followed by reset/reload and the successful restart.
The corrupted output beat is withheld by the RTL. This is different from a golden
scoreboard merely noticing a wrong result after the fact.

Explain that earlier committed bytes are discarded as part of the failed command's
destination; they are not rolled back. The recovery driver reloads trusted inputs
and reruns the command. A physical host loader is still future work.

## Boundaries to state accurately

Per-byte parity detects odd-bit changes in a protected byte after local reference
capture. It does not correct data, detect every even-bit change, authenticate
input data, protect backing memory before capture/after commit, or provide general
malicious-intrusion protection. Simulation assertions and golden scoreboards are
additional verification tools, not on-board protection mechanisms. See the
[implemented integrity and recovery contract](../interfaces/RAVEN_STAGING_INTEGRITY.md).

Physical backing banks, DMA/processor integration, a complete board wrapper,
routed timing closure and full-model quality/latency remain future work. The
[FPGA review](RAVEN_BOARD_READINESS_REVIEW.md) documents the board boundary and
staging overhead. Prepared simulation structures and block synthesis should be
presented at that scope.

## Where to find it

- [Top-level connections](../../rtl/top/raven_npu_top.sv)
- [Command checks and runtime error reporting](../../rtl/control/raven_ctrl.sv)
- [Read protection](../../rtl/memory/raven_read_buffer_adapter.sv) and
  [output protection](../../rtl/memory/raven_output_buffer_adapter.sv)
- [T1–T16 integration bench](../../tests/rtl/integration/tb_raven_npu_top.sv)
- [Adapter tests](../../tests/rtl/integration/tb_raven_memory_adapters.sv)
- [Source-hash/result record](../../evidence/questa/integration/results.json) and
  [execution log](../../evidence/questa/integration/verification.log)

This mapping identifies implemented evidence and its limits. The instructor's
interpretation of the rubric remains the grading authority.
