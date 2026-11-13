# RAVEN FPGA design review

This is the baseline review before runtime staging parity was implemented. The
[integrity contract](../interfaces/RAVEN_STAGING_INTEGRITY.md),
[rubric mapping](RAVEN_PREALPHA_RUBRIC_COVERAGE.md) and
[current synthesis results](../../hw/README.md#verified-block-synthesis) describe
the subsequent protection and its measured cost. The baseline figures below
remain tied to the pinned revision; efficient buffering and board integration
are still future work.

[PR #4](https://github.com/michaelgirg/raven/pull/4) is a functional pre-alpha integration path and the NPU block
synthesizes for the Ultra96-V2 FPGA. It is not a complete board build. The staging
adapters should be treated as temporary bring-up logic: they add substantial
serialization and duplicate storage already present in the compute frontend.

Reviewed revision: `bf944c1749310a615bb6b7924edeb3b453fc21f9` (PR #4).
This review records that revision. It does not implement the recommended RTL changes.
The review PR is independent of PR #4 and may be reviewed separately; its evidence
describes PR #4 rather than the current `main` RTL.

## Actual synthesis check

Vivado 2025.2 synthesized `raven_npu_top` with `USE_TILE_BUFFERS=1` for
`xczu3eg-sbva484-1-e`, out of context, with a 10 ns clock constraint.

| Resource | Synthesized block | Device total | Approximate use |
|---|---:|---:|---:|
| LUTs | 15,346 | 70,560 | 21.7% |
| Flip-flops | 14,839 | 141,120 | 10.5% |
| DSP blocks | 16 | 360 | 4.4% |
| RAMB36 / RAMB18 | 0 / 0 | 216 RAMB36 equivalents | Backing storage absent |

The MAC array maps to LUT logic in this synthesis; the 16 DSP blocks are in
address/control/arithmetic support. Do not assume the 64 MACs consume 64 DSPs.
The small native buffers currently map to registers. That is not inherently
wrong for buffers this small, but it is not a suitable implementation strategy
for all full-capacity backing banks.

Preliminary internal worst setup slack is **+1.169 ns** at 100 MHz. The worst
reported setup path runs from a MAC sum register through result selection and
requantization to the INT8 output register. This is a synthesis estimate, not
routed timing closure. The report has 716 inputs and 357 outputs without I/O
delays and warns that the out-of-context clock source is unspecified. There is
no physical clock-tree, complete interface timing, board pin mapping or complete
system implementation in this check.

There were no synthesis errors or critical warnings. Warnings include native
memory reset/storage inference (`Synth 8-7137`, `Synth 8-4767`), removal of unused
state, and unused PARAM fields. The reset/storage warnings deserve cleanup and
post-synthesis equivalence/simulation before board sign-off. They are not, by
themselves, proof of a functional mismatch. A large bank should use a deliberate
synchronous BRAM template/IP with reset applied to validity/control rather than
to every stored byte.

Raw evidence:

- [Resource report](../../evidence/vivado/board-readiness/utilization_synth.rpt)
- [Timing summary](../../evidence/vivado/board-readiness/timing_synth.rpt)
- [Register-to-register timing](../../evidence/vivado/board-readiness/internal_timing_synth.rpt)
- [Synthesis transcript](../../evidence/vivado/board-readiness/synthesis.log)
- [Reproduction Tcl](../../hw/check_npu_synthesis.tcl)

The FPGA capacities above are listed in the
[Avnet Ultra96-V2 hardware guide, programmable logic section](https://www.avnet.com/wcm/connect/b85b9556-0b2a-42b3-ad6a-8dcf3eac1ff9/Ultra96-V2-HW-User-Guide-v1_3.pdf?MOD=AJPERES).

## Measured memory-path overhead

The existing integration bench was copied to an isolated directory and instrumented
to print differences in hardware busy/stall counters. Production RTL was unchanged.
Both configurations passed numerical comparisons for these cases.

| Shape / fixture | Direct-bank busy cycles | Buffered busy cycles | Buffered / direct |
|---|---:|---:|---:|
| 8x16x8 normal tile | 146 | 786 | 5.38x |
| 8x33x8, allocations at bank ends | 181 | 1,321 | 7.30x |
| 1x640x8, fully connected layer shape | 1,319 | 3,984 | 3.02x |

These are tile execution cycles with the existing simulation backing responder,
not board measurements or complete inference latency. The 1x640x8 fixture is a
synthetic zero-extension of the first row of the normal fixture; the retained
independent expected bytes are unchanged. It exercises a reduction length relevant
to AD01's first layer, but is not validation of the actual model weights or graph.
Data for the extra K positions has zero weights, preserving the original arithmetic
while the RTL executes all 640 positions.

The main causes are structural:

- ACT: each 128-bit word is fetched, written into a native buffer slot, then
  reconstructed using 16 separate native read request/response pairs. The core
  frontend then saves the reconstructed word into its own local row buffer.
- WGT: each word is split into two native rows and read back before returning to
  the frontend's own word buffers. Only one word can be outstanding per port.
- PARAM: each record is written and read back through staging even though the
  core and requant wrapper already save their required per-command values.
- OUT: each single byte from the writer causes a 64-bit row write/read before
  its original byte-strobed backing write. The output adapter adds four stall
  cycles per byte in the unstalled normal case.

The adapters prove functional participation of the actual native memory modules,
and their commit/reset behavior is covered by the earlier regression. They do
not provide effective tile reuse or the intended steady operand bandwidth.

See [measured counters](../../evidence/vivado/board-readiness/pipeline_cycles.json) and
[the measurement script](../../tools/verification/measure_buffer_pipeline.py).

## Work required for a board build

1. **Provide real backing banks and a loading/readback path.** The current
   architectural allocation is 76 KiB: four 16 KiB ACT/WGT banks, one 4 KiB PRM
   bank and one 8 KiB OUT bank. None is included in the resource count above.
   Use synchronous BRAM with byte enables and held responses. The two PRM readers
   must see the same contents; host writes need ownership/arbitration with those
   readers. The many current bank-port signals are internal FPGA connections,
   not board pins.
2. **Create the board wrapper and host interface.** Add the PS/processor or debug
   command path, a real register-bus bridge, FPGA clock/reset generation, project
   Tcl and constraints. The current register bus is not AXI4-Lite. DMA and RISC-V
   integration remain separate implementation work. A first on-board GEMM demo
   can use a simpler controlled loader before the complete runtime is ready.
3. **Make reset release and transactions physically safe.** Synchronize external
   reset release to each destination clock, keep clocks stable, and flush pending
   responses consistently. If a future backing port reports write completion
   separately, delay `stored_last` until that completion. Current ready means
   actual committed storage; accepting an AXI request alone is insufficient.
4. **Replace the redundant staging path before performance work.** Use the native
   activation/weight buffers as the actual frontend tile storage, with inactive
   buffers filled while active buffers feed vectors, or retain the word frontend
   and connect efficient BRAM responders directly. Avoid both storage layers plus
   a serial write/read round trip. Combine output bytes or write BRAM byte enables
   directly. Preserve command, PARAM, tag, backpressure and completion contracts
   while making this change; repeat the existing golden/reset/error tests.
5. **Validate the intended workload in stages.** Start with one loaded GEMM tile
   and exact output readback on the board, then multiple tiled FC layers and AD01.
   General Conv/window gathering, depthwise/pooling/fallback, saved partial sums
   and a complete model runtime are outside the implemented GEMM subset. The
   existing synthetic tests do not establish end-to-end model support.
6. **Close timing on the complete system and run hardware tests.** Check resource
   use after BRAM, control/processor, DMA and debug logic are present. Run place
   and route, DRC, CDC/reset review and fully constrained timing; then verify
   loading, repeated commands, resets, guard bytes and exact golden output on
   hardware. Revisit pipelining of the MAC-result-to-requant path if routed slack
   misses the target.

AMD documents the reset-release requirements and the mapping implications of
asynchronous resets in
[UG949](https://docs.amd.com/r/2025.1-English/ug949-vivado-design-methodology/Synchronous-Reset-vs.-Asynchronous-Reset).
Memory primitive behavior is described in
[UG573](https://docs.amd.com/r/en-US/ug573-ultrascale-memory-resources/Block-RAM-Summary).

The recommended next implementation is a synthesizable BRAM-backed board-demo
wrapper and an efficient, single-layer operand-buffer path. The existing MAC/GEMM
math and command contracts can remain the foundation. PR #4 should be understood
as pre-alpha functional integration rather than the final memory architecture.

## Reproduce the checks

Use Python 3.9+, a working Questa installation/license, and Vivado 2025.2 with the
ZU3EG device files. Discover Questa through PATH, QUESTA_BIN or `--questa-bin`;
put Vivado on PATH using your own installation settings. No helper contains a
personal checkout or installation path.

The reviewed RTL is on `michael/connect-memory-buffers` at revision
`bf944c1749310a615bb6b7924edeb3b453fc21f9`. Before PR #4 merges, keep a checkout
of that revision separate from this documentation branch. In the commands below,
replace `<reviewed-checkout>` and `<output-directory>` with your own directories.
The helpers check that the adapter RTL is present and fail clearly if it is absent.
After PR #4 merges, the source checkout can be the repository itself; a new run
records its input hashes and may differ if the RTL has changed.

From the repository containing this review:

```sh
vivado -mode batch -source hw/check_npu_synthesis.tcl -tclargs "<reviewed-checkout>" "<output-directory>" 1
python tools/verification/measure_buffer_pipeline.py --repo "<reviewed-checkout>" --build "<output-directory>"
```

Use separate output directories for synthesis and simulation. The synthesis helper
creates an in-memory, out-of-context project and writes the clock constraint,
resource/timing reports and checkpoint to the requested directory. It does not
create a complete board project or bitstream. The measurement helper creates a
fresh isolated copy under its output directory, adds only counter printing to the
copied testbench and runs both configurations sequentially with assertions and
golden comparisons. It also adds the synthetic 1x640x8 shape described above.
Production source files are never edited. Generated outputs normally belong under
`build/`; a short `--build` directory can avoid Windows simulator path-length limits.

The [review result record](../../evidence/vivado/board-readiness/review_results.json)
identifies the reviewed commit, source hashes and measured scope. The
[measurement record](../../evidence/vivado/board-readiness/measurement_results.json)
and [buffered](../../evidence/vivado/board-readiness/pipeline_buffered.log) /
[direct](../../evidence/vivado/board-readiness/pipeline_direct.log) simulation
transcripts support the cycle table. The curated tool reports remove host/date
headers and normalize workspace paths; measured numbers and diagnostic messages
are preserved. Tool build/version strings remain in the evidence.
