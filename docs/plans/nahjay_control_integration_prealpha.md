# Pre-alpha plan: control and integration harness (Nahjay)

**Status:** C1–C17 implemented, with licensed Questa validation and follow-up fixes.
See [Licensed Questa validation](#licensed-questa-validation) and the known limitations below.
**Owner:** Nahjay (control/runtime). **Integration branch:** `main`.

This plan is written for a coding agent working in a fresh session. Read all of it before
writing code. The **Decisions** section settles the open design choices. Don't reopen them
unless a teammate's merged RTL conflicts with them, and if one does, stop and report the conflict.

## Progress log

Hashes are after the November 3 history rewrite that removed commit trailers.

| Commit | Step | Hash |
|---|---|---|
| C1 | Plan | `19d366f` |
| — | Merge `origin/main` (Quan's requant, Taylor's buffers) | `2858e21` |
| C2 | `rtl/control/raven_ctrl_pkg.sv` | `e006cf9` |
| C3 | `rtl/control/raven_ctrl_regs.sv` | `63ea593` |
| C4 | `rtl/control/raven_ctrl.sv` | `e1748e4` |
| — | Plan progress (C1–C4), RTL subset docs | `6fe8c49`, `4372612` |
| — | Merge `origin/main` (memory goldens, requant golden bench, doc reorganization) | `57ea061` |
| C5 | `rtl/top/raven_result_writer.sv` | `a5e16d6` |
| C6′ | `rtl/top/raven_requant.sv` (replaces `sim_requant.sv`, see below) | `aa2966b` |
| C7 | `tests/rtl/integration/sim_write_memory.sv` | `403601e` |
| C8 | `rtl/top/raven_npu_top.sv` | `bef0b96` |
| C9 | `tests/rtl/integration/export_fixtures.py` | `eabf976` |
| C10 | `tests/rtl/integration/raven_tb_driver_pkg.sv` | `f1f1dba` |
| C11 | testbench T1–T4 | `de09c6d` |
| C12 | T5–T8, exporter `golden.txt` | `b64a02d` |
| C13 | T9–T11 | `4452f8f` |
| C14 | T12–T15 | `2e2a27f` |
| C15 | `run_questa.py`, `run_batch.do` | `8850032` |
| C16 | evidence | [Passing Questa records](../../evidence/questa/integration/) |
| C17 | README, rtl/README, tests/README | `2f5f7ef` |

### Licensed Questa validation

Questa Intel Starter FPGA Edition-64 2021.2 passes T1–T15 with both immediate and
concurrent assertion guards: 51 PASS records, 721 checks and 22 independent INT8
comparisons in each of the buffered and direct configurations. The runner also
passes 1,536 adapter checks, elaborates `COLS=1` and checks reset/NOP behavior
(43 checks). The standalone compute regression passes all 168 fixtures and
12 reset/restart phases. Curated [results](../../evidence/questa/integration/results.json)
and the [combined log](../../evidence/questa/integration/verification.log) record
the tested source hashes, commands and outcomes.

The licensed run and added regressions exposed three problems:

- Nine protocol assertion errors occurred on synchronous soft-reset release.
  Assertion reset masks now include the reset value sampled on that clock.
  Deliberate request/data-hold violations still fail with assertions enabled.
- The requant loader issued PARAM reads before the core rejected invalid
  commands. It now waits for the core's first validated bias request. PARAM
  alignment/span regressions and read-count checks enforce clean rejection.
- `$clog2(1)` produced zero-width channel casts. The wrapper now uses a minimum
  index width of one, covered by the single-column runner check.

The [original reset failure](../../evidence/questa/integration/experiments/01-soft-reset-assertions.log),
[premature-read regression](../../evidence/questa/integration/experiments/02-premature-parameter-reads.log)
and [single-column failure](../../evidence/questa/integration/experiments/03-single-column-elaboration.log)
are retained alongside the passing evidence. Physical memory/DMA, firmware,
synthesis and timing remain out of scope as listed in §9.

### Memory-buffer connection validation

The buffered path stages all ACT/WGT/PRM words through the actual native buffers
and stages every strobed OUT byte through `outputBuffer`. The direct path produces
the same INT8 bytes on every dumped case. The added K=33 fixture zero-extends the
normal golden's operands and places ACT, WGT, PRM and OUT allocations at their bank
ends; it runs with and without backing stalls. This checks address preservation,
multiple K chunks and staging-slot reuse beyond the native buffer capacity.

Dedicated adapter benches check all sixteen byte lanes, sparse/full strobes,
backing request stalls, held upstream responses and reset during pending traffic.
The output adapter withholds upstream acceptance until the actual backing commit.
Isolated corruptions of native activation, weight, parameter and output reads each
make the normal integrated GEMM fail the independent OUT0 scoreboard. Those four
intentional failures, and the two assertion guards, are expected in the combined log.

The first connected elaboration failed because the native memory files specify a
timescale while the existing integration top did not. The runner now supplies a
default `1ns/1ps` compile timescale without changing the memory or compute modules.
The [original elaboration failure](../../evidence/questa/integration/experiments/04-buffer-timescale.log)
is retained. A build path containing spaces also exposed an old Questa optimizer
crash (`Unexpected signal: 11`); preserving signal visibility with `-voptargs=+acc`
allows that hierarchy to run. The [original optimizer failure](../../evidence/questa/integration/experiments/05-buffer-optimizer.log)
is retained. The final compile has no warnings or errors. Staging adds latency;
efficient tile reuse and physical backing storage remain future work.

### What was verified (ModelSim 2020.1, `--no-sva-guard`)

- T1–T15 all pass: 47 PASS records, 657 checks, and 20 INT8 dumps each re-checked by
  `compare_prealpha.py` with 0 mismatches. A deliberately corrupted expected byte makes the
  run fail with the address of the bad byte.
- That limited run did not expose the reset-assertion and malformed-PARAM paths
  found by the licensed Questa validation above.
- Throwaway unit smoke tests (not committed): the writer, under random stalls, wrote the
  correct pitched bytes and kept the guards. The requant wrapper plus Quan's module was
  bit-exact on all six fixtures with PRM and output stalls. The six fixtures also passed
  end to end through `raven_npu_top` before the testbench existed.

### Deviations from the plan

- **C6 / D6 resolved as a wrapper.** Quan's `raven_requantize_clamp` is merged but takes
  multiplier/shift/zero-point/clamp as per-element inputs. `rtl/top/raven_requant.sv` keeps
  the §5.3 port list, loads the N PARAM records through PRM port B when PER_CHANNEL=1 (D7),
  holds `in_ready` low until they are loaded, and feeds Quan's module unmodified, with each
  column's parameters. `sim_requant.sv` was not written.
- **Taylor's buffers (D6) are connected through staging adapters.** The top defaults
  to `USE_TILE_BUFFERS=1`: each ACT/WGT/PRM read and OUT write passes through the native
  buffer RTL. Full-capacity backing banks remain external ports, currently served by
  `sim_read_memory`/`sim_write_memory`. The original direct path remains available with
  `USE_TILE_BUFFERS=0` and is covered by the full runner. See the
  [adapter contracts](../../rtl/memory/README.md#pre-alpha-pipeline-adapters).
- **`run_questa.py --no-sva-guard`** was added so the suite can run on ModelSim. It records
  `"sva_checked": false`.
- **Testbench output** adds `dumps.txt` (`<tag> <fixture>` for each `actual_int8_<tag>.bin`),
  and the exporter adds `golden.txt` per valid case so the runner knows which vectors case
  to compare against.
- **T10** uses two reserved-bit cases (SRC_A bit 24 → info 0x038, P5 → info 0x054) and two
  DST range cases (offset 0x008 misaligned, offset 0x1FF0 span overflow).
- **T11's overflow fixture** is synthetic: A = B = 127, K = 16, bias INT32_MAX − 1000. It is
  generated by the exporter, as the plan allowed.

### Interpretations (list in the final report)

From C2–C4:

- `OUT0_BYTES` = 8192 (the contract's lower bound).
- CHECK tests K only for zero. K's bank span is left to the core's backstop, since
  `HW_LIMITS[15:0]=8` applies to M/N.
- START while busy records ERR_CODE seq = the NEXT_SEQ that START would have received, and
  ERR_INFO = `0x010` (CTRL). The first error wins over a later core error.
- The register bus returns `reg_rvalid_o` for writes as well as reads (one-cycle response to
  every access).
- `local_rst_no = rst_ni && !soft_reset`. The register block stays on `rst_ni` and clears its
  own staging on SOFT_RESET. IRQ_ENABLE survives SOFT_RESET (T13 checks this).

From C5–C15:

- The writer and the requant are one-entry elastic stages. `out_stall_i` is
  `(core result valid && !ready) || writer stall`.
- The writer latches DST/P4 on `op_cfg_load_o` (the core launch handshake). The top
  defers requant configuration until the core's first validated bias request.
- RELU_EN: the effective clamp minimum is `max(clamp_min, out_zp)`. The
  `channel_scales_relu_clamp` fixture sets RELU_EN, and its clamp_min already equals out_zp.
- Control does not range-check Q_SHIFT/Q_MULT. `raven_requant` has a simulation assertion
  for the TFLM range. Raise with Quan whether CHECK should reject out-of-range values
  (ERR_RSVD at 0x068?).
- A hardware reset clears IRQ_ENABLE, so firmware must re-run `raven_init` (T14 does).

---

## 1. Assignment and acceptance

From the pre-alpha task list:

- Implement the initial command interface and start/busy/done/error behavior.
- Support one operation at a time for bring-up.
- Create a testbench command driver that stands in for the future RISC-V processor.
- Connect control, memory, compute and output modules in the simulation top level.
- Verify reset, completion and invalid-command handling.

**Acceptance:** each submitted command launches exactly one operation. Completion is reported
only after the outputs are stored. Defined errors are reported correctly.

## 2. Required reading (in this order)

1. `README.md`: the "Compute implementation" section and its "Known bugs, limitations and
   integration boundaries" list.
2. `rtl/compute/raven_gemm_core.sv`: the module this plan integrates. Learn its command
   handshake, its error codes (0x02, 0x03, 0x08), and the meaning of `compute_done_o`,
   `result_done_o` and `error_o`.
3. `docs/RISCV_Research.md`, sections 5 (control FSM, completion definitions) and 6.2–6.8
   (register map, opcodes, scratchpad references, GEMM P0–P5 packing, error codes). Read 8.2
   (C API) for the driver task names.
4. `docs/interfaces/RAVEN_INTERFACE_CONTRACT.md`, sections 1 (ports, result destinations),
   3 (reset semantics) and 5 (PARAM record layout).
5. `tests/rtl/compute/`: `tb_raven_gemm_core.sv`, `sim_read_memory.sv`, `run_questa.py` and
   `run_batch.do`. Reuse their style, their memory model and their runner pattern.
6. `tests/vectors/prealpha/` (Jackie's fixtures), `tools/goldens/generate_prealpha.py` (the
   requantization reference, `quantized_multiplier`), `tools/goldens/compare_prealpha.py` and
   `tools/goldens/export_compute_fixture.py` (bank-image layout).

## 3. Ground rules for the agent

- **Do not modify Michael's files** (`rtl/compute/*`, `tests/rtl/compute/*`). If the core
  needs a change, write the request up in the final report instead of editing it.
- Match the existing RTL style: `` `default_nettype none `` and `wire` at the top and bottom,
  synchronous active-low `rst_ni`, `_i/_o/_q` suffixes, `always_ff` with nonblocking
  assignments, a short comment on every port, and `ifndef SYNTHESIS` assertions.
- Simulation-only models go under `tests/`, with a `// TESTBENCH ONLY:` header the way
  `sim_read_memory.sv` does it. Synthesizable RTL goes under `rtl/`.
- Generated output goes to `build/tests/integration/` and is never committed. Curated
  evidence goes to `evidence/questa/integration/`.
- Python is 3.9+ and uses the standard library only, like the compute runner.
- Questa is located through `--questa-bin`, `QUESTA_BIN` or `PATH`. Never hard-code a
  machine path.
- Before starting, run `git fetch` and check `rtl/operators/`, `rtl/memory/` and `origin/*`
  for merged modules from Quan or Taylor. See Decision D6.
- Commit exactly as laid out in **§12 Commit plan**: one commit per completed step, each with
  its listed files and message, and only after that step's check passes. Never batch
  several steps into one commit. Don't push or open a PR unless asked.

## 4. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | **Command interface:** a small synchronous register bus (`reg_valid_i/reg_ready_o/reg_write_i/reg_addr_i[11:0]/reg_wdata_i[31:0]/reg_rdata_o/reg_rvalid_o/reg_error_o`), not AXI4-Lite. Register **offsets and field layouts are the §6.2 offsets exactly**, for the subset implemented. | Keeps firmware offsets, traces and the future generated CSR compatible. An AXI4-Lite wrapper or PeakRDL `raven_csr` can replace the block later without changing the FSM. |
| D2 | **One operation at a time:** queue depth 0. `STATUS.Q_FULL` is 1 whenever a command is active, and `HW_CONFIG[27:24]` = 1. | This is the bring-up requirement. It keeps the §6.5 rule "START while Q_FULL → ERR_Q_OVERFLOW". |
| D3 | **Supported opcodes:** `0x02 GEMM` (single resident tile: M,N ≤ 8, full K) and `0x00 NOP` (completes immediately, gets a sequence number, launches nothing). Every other opcode gives `ERR_ILLEGAL_OP`. `HW_LIMITS[31:16]` = `0x0005`, `HW_LIMITS[15:0]` = 8. | NOP tests start/done/sequence logic without compute. |
| D4 | **FSM:** a subset of the §5.1 FSM with the **same 4-bit state codes**: IDLE(0), CHECK(2), ISSUE(4), RUN(5), DRAIN(6), RETIRE(7), ERROR(8), HALTED(9). FETCH and WAIT_DEP are not entered (there is no queue and no bank-state interlock yet). | Firmware and tests that read `STATUS.FSM` keep working when the queue arrives. |
| D5 | **Completion = output stored.** RETIRE happens only when the core has pulsed `result_done_o` without `error_o` **and** the result writer has had its last byte-write accepted by the OUT bank. Accepted = committed (synchronous BRAM write). Then `DONE_SEQ` ← seq, `CMD_COUNT`++, `IRQ_STATUS.DONE` is set and BUSY clears. | Matches the "Command complete (DONE)" row of §5.1. Flag for Taylor: if the real write port adds a write response, wait for that instead. |
| D6 | **Output path:** INT32 results → requant (Quan) → result writer (this plan, `rtl/top/`). If Quan's requant RTL is **not merged**, write a stand-in `tests/rtl/integration/sim_requant.sv` that is bit-exact with `quantized_multiplier()` in `generate_prealpha.py`, and put the requant behind a fixed port list (§5.3) so Quan's module drops in. Do the same for Taylor's banks: use `sim_read_memory` plus a new `sim_write_memory` until real banks exist. | Integration should not be blocked on teammates, and the swap point stays explicit. |
| D7 | **Requant parameters:** the requant reads the N PARAM records (multiplier at byte 4, shift at byte 8, per the contract §5) through a **second read port on the PRM bank** while the core reads bias through the first. Its result-ready stays low until its records are loaded. `PER_CHANNEL=0` uses `Q_MULT/Q_SHIFT` instead and skips the load. | PRM as a dual-port BRAM is realistic. Backpressure orders the two naturally, with no arbitration. In the testbench both ports get the same PRM image. |
| D8 | **Bank routing:** `BANK_ID` selects among ACT0(0)/ACT1(1) for SRC_A, WGT0(2)/WGT1(3) for SRC_B, PRM(6) for PARAM and OUT0(4) for DST. OUT1(5) is absent in pre-alpha (`HW_FEATURES[3]=0`). Any other ID, or an ID of the wrong bank type for its field, gives `ERR_BANK_RANGE`. No bank states (FREE/READY/…) yet. `RELEASE_*` flags are accepted and have no effect. | §6.4 table, and "PRM stays ID 6 when OUT1 is absent". |
| D9 | **Error policy:** any error → ERROR → HALTED. `ERR_CODE[7:0]` = code, `[31:16]` = the failing command's seq. `ERR_INFO` = the **register offset** of the first offending field (for example `0x038` for SRC_A), or 0 for unit-reported errors. In HALTED, START is ignored (no launch, no seq consumed). `CLEAR_ERR` clears ERR_CODE/ERR_INFO/STATUS.ERROR but **stays HALTED**. `SOFT_RESET` is the only way back to IDLE. | Mirrors §5.1 and §6.2. Deterministic ERR_INFO makes the tests exact. |
| D10 | **START while busy:** the extra START is not launched and consumes no seq. `ERR_Q_OVERFLOW` is latched immediately. The in-flight command **finishes its writes and retires normally** (DONE_SEQ updates), then the FSM goes to HALTED instead of IDLE. | A command never stops halfway through writing a bank, and the error stays visible. |
| D11 | **SOFT_RESET** drives a one-cycle synchronous local reset, `local_rst_n`, into the core, requant, writer **and the bank models / bank ports**. It clears staging, errors, IRQs and counters, sets `NEXT_SEQ=0` and `DONE_SEQ=0xFFFF`, and returns to IDLE. ABORT, ZERO_LOCAL and QUIESCENT are **out of scope** for pre-alpha: ABORT and ZERO_LOCAL writes are ignored, and `STATUS[12]` reads `!busy`. | The core README requires compute and memory responders to reset together, and stale responses after an independent reset are unsupported. |
| D12 | **Validation split:** control checks everything it can **before launching**, so a rejected command never touches the core. The core's own rejection (pitch, A/B/PARAM span, overflow 0x08) is the backstop and its code passes through unchanged. Codes 0x02, 0x03 and 0x08 already agree between the core and §6.8. | "Invalid commands never issue memory reads." |

## 5. Interfaces

### 5.1 Registers implemented (subset of RISCV_Research §6.2; offsets unchanged)

| Offset | Name | Access | Pre-alpha behavior |
|---|---|---|---|
| 0x000 | ID | RO | `0x5241_564E` |
| 0x004 | VERSION | RO | `0x0000_0001` (major 0, minor 0, build 1) |
| 0x008 | HW_CONFIG | RO | rows=ROWS, cols=COLS, banks=6, log2 KiB=4, queue depth=1 |
| 0x00C | HW_LIMITS | RO | `[15:0]`=8, `[31:16]`=0x0005 |
| 0x010 | CTRL | W1S | [0] START, [1] SOFT_RESET, [3] CLEAR_ERR, [4] CNT_CLEAR; [2],[5] ignored |
| 0x014 | STATUS | RO | [0] BUSY, [1] HALTED, [2] ERROR, [3] Q_FULL, [4] Q_EMPTY, [8:5] FSM, [11:9] occupancy (0/1), [12] QUIESCENT(=!BUSY), [31:16] executing seq |
| 0x018 | IRQ_ENABLE | RW | [0] DONE, [1] ERROR |
| 0x01C | IRQ_STATUS | W1C | [0] DONE, [1] ERROR; output `npu_irq_o` = OR of (STATUS & ENABLE) |
| 0x020 | NEXT_SEQ | RO | reset 0 |
| 0x024 | DONE_SEQ | RO | reset 0xFFFF |
| 0x028 | ERR_CODE | RO | D9 |
| 0x02C | ERR_INFO | RO | D9 |
| 0x030–0x06C | OPCODE, OP_FLAGS, SRC_A, SRC_B, P0–P5, DST, PARAM, Q_ZP, Q_MULT, Q_SHIFT, Q_CLAMP | RW staging | Q_CLAMP reset `0x7F80`; all others reset 0. The values are **snapshotted at START**, so firmware may rewrite staging while a command runs. |
| 0x080/0x084 | CYC_TOTAL_LO/HI | RO | free-running since CNT_CLEAR |
| 0x088/0x08C | CYC_BUSY_LO/HI | RO | cycles in RUN or DRAIN |
| 0x094 | CYC_STALL_IN | RO | sum of the core's `input_stall_cycles_o` over retired commands |
| 0x098 | CYC_STALL_OUT | RO | cycles the writer or requant held off the result |
| 0x0AC | CMD_COUNT | RO | commands retired (NOP included) |
| 0x0B0 | HW_FEATURES | RO | 0 |

Registers not listed (0x070–0x07C, 0x090, 0x09C–0x0A8, 0x0B4) read 0 and ignore writes.
Unmapped offsets (≥0x0B8) and unaligned addresses set `reg_error_o` (which becomes AXI SLVERR later).

### 5.2 GEMM command fields (from §6.4)

`P0` = {N[31:16], M[15:0]}. `P1[15:0]` = K. `P2[15:0]` = A row pitch. `P3[15:0]` = B panel
pitch (unused for a single panel, not checked). `P4[15:0]` = INT8 output row pitch.
`P5` = 0. `SRC_A/SRC_B/PARAM/DST` use the reference format `{BANK_ID[31:28], rsvd[27:24],
BYTE_OFFSET[23:0]}`. `Q_ZP[23:16]` = output zero point. `Q_CLAMP` = {max[15:8], min[7:0]}.
`Q_MULT/Q_SHIFT[7:0]` apply when `PER_CHANNEL=0`. With `RELU_EN`, the effective
clamp-min is `max(clamp_min, output_zp)`.

Required flags for GEMM: `ACC_INIT | ACC_LAST | REQUANT_EN`. Optional: `RELU_EN`,
`PER_CHANNEL` and `RELEASE_A/B/PARAM` (ignored). Anything else, including `DST_ACCUM`,
`SRC_A_CB` or a missing required flag, gives `ERR_BAD_FLAGS`.

### 5.3 Internal module ports (new modules)

- **`raven_requant`** (Quan's module, or the stand-in `sim_requant`):
  - `in_valid/in_ready/in_data[31:0]/in_row/in_col/in_last`
  - `cfg_load_i` (pulse after core validation, at the first bias request), `cfg_per_channel_i`, `cfg_n_i`, `cfg_param_base_i`, `cfg_mult_i`, `cfg_shift_i`, `cfg_out_zp_i`, `cfg_clamp_min_i`, `cfg_clamp_max_i`, `cfg_relu_i`
  - PRM read port B: `p_req_*`/`p_rsp_*`, the same shape as the core's
  - `out_valid/out_ready/out_data[7:0]/out_row/out_col/out_last`
  - Arithmetic: `scaled = (x*mul + (1 << (30-shift))) >>> (31-shift)` computed in at least 64 bits, then `+ out_zp`, then clamp.
  - Hold the output stable under backpressure and add an SVA like the core's drain assertion.
- **`raven_result_writer`** (`rtl/top/`):
  - Takes the requant output plus `dst_offset`, `out_pitch`.
  - `addr = dst_offset + row*out_pitch + col`. Write port: `w_valid/w_ready/w_addr[23:0]` (16-byte aligned), `w_data[127:0]` (byte replicated into its lane), `w_strb[15:0] = 1 << addr[3:0]`.
  - `stored_last_o` pulses when the `last` element's write is accepted.
- **`sim_write_memory`** (`tests/rtl/integration/`):
  - Byte-strobed 128-bit writes with optional random `w_ready` stalls.
  - Asserts aligned, in-range addresses.
  - Pre-filled with guard byte `0xA5`.
  - Exposes the memory for `$writememh` or a dump task.

## 6. File layout

```text
rtl/control/raven_ctrl_pkg.sv        # offsets, opcodes, flag bits, error codes, FSM codes, bank IDs
rtl/control/raven_ctrl_regs.sv       # register bus, staging, RO/W1S/W1C behavior (stand-in for generated raven_csr)
rtl/control/raven_ctrl.sv            # snapshot, CHECK, ISSUE/RUN/DRAIN/RETIRE, errors, seq, IRQ, counters
rtl/top/raven_result_writer.sv       # requant output → byte writes into the OUT bank
rtl/top/raven_npu_top.sv             # ctrl + gemm_core + requant + writer + bank routing; bank ports are top ports
tests/rtl/integration/sim_write_memory.sv
tests/rtl/integration/sim_requant.sv           # only if Quan's RTL is absent (D6)
tests/rtl/integration/raven_tb_driver_pkg.sv   # the "RISC-V" command driver
tests/rtl/integration/tb_raven_npu_top.sv      # sim top: npu_top + bank models + driver + scoreboard
tests/rtl/integration/export_fixtures.py       # prealpha vectors → bank images + command file
tests/rtl/integration/run_questa.py            # runner (copy the compute runner pattern)
tests/rtl/integration/run_batch.do
```

`raven_npu_top` keeps full-capacity **backing storage outside**: it exposes
ACT0/ACT1/WGT0/WGT1 read ports, two PRM read ports, an OUT0 write port and
`local_rst_no`. Native tile buffers and adapters are now inside the top. The sim top
attaches `sim_read_memory` / `sim_write_memory` to the backing ports. Physical backing
banks must implement the same reset/handshake contract; accepted OUT writes must mean
committed storage. The small native buffers do not replace the advertised bank capacities.

## 7. Phases

Each step ends with a compile that has no errors or warnings except the benign `vopt-10587`,
then the matching commit from §12. Most phases produce more than one commit.

### Phase 0: orient (no code)
- Read §2. Run `python tests/rtl/compute/run_questa.py` to confirm Questa works and the
  compute baseline passes. If it doesn't, stop and report.
- Check for teammates' modules (D6). Record what was found in the final report.

### Phase 1: package and registers
- `raven_ctrl_pkg.sv`: the constants in §5. No magic numbers in other files.
- `raven_ctrl_regs.sv`: the §5.1 behavior. W1S bits pulse for one cycle. Unmapped or unaligned
  access sets `reg_error_o`. Reads have fixed latency (one cycle) and never wait on the FSM.

### Phase 2: control FSM
- Accept START (IDLE only) → snapshot staging → seq = NEXT_SEQ, NEXT_SEQ++ → CHECK.
- CHECK, in this priority order, stopping at the first failure:
  1. opcode not in {0x00, 0x02} → `0x01 ERR_ILLEGAL_OP` (info 0x030)
  2. nonzero reserved bits in OPCODE[31:8], OP_FLAGS[31:12], ref[27:24] of the four refs, P1[31:16], P2[31:16], P4[31:16] or P5 → `0x07 ERR_RSVD` (info = offset)
  3. flag rule in §5.2 → `0x0B ERR_BAD_FLAGS` (info 0x034)
  4. bank ID or type (D8) → `0x03` (info = ref offset)
  5. M/N/K zero or > limit, or P4 < N → `0x02 ERR_BAD_DIM` (info 0x040/0x044/0x050)
  6. DST offset not 16-aligned, or `offset + (M-1)*P4 + N > OUT0_BYTES` (64-bit math) → `0x03` (info 0x058)

  NOP skips 2–6 and goes straight to RETIRE.
- ISSUE: drive the core's `cmd_valid_i` from the snapshot until `cmd_valid && cmd_ready`
  (exactly one handshake), configure the writer and mark requant configuration pending → RUN.
  Load the requant only when the core begins its first validated bias request.
- RUN/DRAIN: RUN until `compute_done_o`, then DRAIN.
  - On the core's `error_o`: if `error_code_o` is 0x02, 0x03 or 0x08, pass it through; anything else becomes `0x09 ERR_UNIT`.
  - RETIRE when the D5 conditions are met. The two events can arrive in either order: latch each one.
- RETIRE → IDLE (or HALTED per D10). ERROR → HALTED, setting `IRQ_STATUS.ERROR`.
- Assertions: at most one core command handshake per START; no `cmd_valid` outside ISSUE;
  `DONE_SEQ` changes only in RETIRE.

### Phase 3: output path
- `raven_result_writer` and, if needed, `sim_requant` per §5.3.
- Quick unit sanity check of the requant against the `rounding_ties` and
  `positive_negative_saturation` fixtures. These can be exercised through the full top in
  Phase 5 if a separate testbench costs too much.

### Phase 4: top-level integration
- `raven_npu_top`: instantiate `raven_ctrl`, `raven_gemm_core` (unmodified), the requant and
  the writer.
- Mux the core's A port to ACT0/ACT1 and its B port to WGT0/WGT1 using the snapshot bank IDs.
  Strip BANK_ID and pass BYTE_OFFSET as the core's 24-bit offsets.
- Drive every submodule reset from `rst_ni && local_rst_n`, and export it as `local_rst_no`.

### Phase 5: simulation harness
- `export_fixtures.py`: for every case in `tests/vectors/prealpha/manifest.json`, emit into
  `build/tests/integration/fixtures/<case>/`:
  - `act.hex` (16 KiB), `wgt.hex` (16 KiB) and `prm.hex` (4 KiB), one 128-bit little-endian
    word per line, using the same layout as `export_compute_fixture.py`
  - `cmd.txt`: the staging register writes as `offset value` hex pairs, built by the same
    packing rules the C helpers will use
  - `expected_int8.hex`, plus a `meta` line holding M, N, P4, the expected error and the stall flag

  Error-only cases (`invalid_zero_k`) produce only `cmd.txt` and the expected code. Also
  generate the synthetic error cases in §8 here, so the testbench has no hand-typed command
  constants.
- `raven_tb_driver_pkg.sv` mirrors the firmware API in §8.2 so the sequences carry over to C:
  - `npu_write32`, `npu_read32`: drive the register bus on the falling edge, like the compute tb
  - `raven_init()`: check ID and VERSION, set IRQ_ENABLE
  - `raven_set_op_from_file(path)`
  - `raven_start(output seq)`: check that `STATUS.Q_FULL` is 0 and `NEXT_SEQ` is the expected
    value, then write `CTRL.START`
  - `raven_wait(seq, timeout_cycles, output err)`: poll STATUS and DONE_SEQ, and return on
    done, error or timeout
  - `raven_soft_reset()`, `raven_clear_err()`

  Log every register transaction as `W|R offset value` to `build/.../trace_<case>.txt`. These
  traces seed `tests/traces/` for M4 later.
- `tb_raven_npu_top.sv`:
  - Load the bank images with `$readmemh`, the way the compute tb loads `sim_read_memory`.
  - Run each case.
  - After completion, compare the OUT bank's M×N region (with pitch P4) against
    `expected_int8.hex` and check that **every other byte is still 0xA5**.
  - Dump the packed result to `actual_int8.bin` for `compare_prealpha.py`.
  - Independent monitors: count core command handshakes per START, record the cycle of the
    last OUT write and of the DONE_SEQ update, and fail if done comes first.
  - Use a global watchdog `$fatal` for hangs.

### Phase 6: runner, evidence and docs
- `run_questa.py`: compile the compute RTL, control, top and the integration testbench files;
  run the fixture exporter; simulate; scan the transcript like the compute runner; then run
  `compare_prealpha.py` on each `actual_int8.bin`. Write the report and `latest.json` under
  `build/tests/integration/questa/`.
- Copy the passing `verification.log` and `results.json` (source hashes, case list, pass
  counts, Questa version) into `evidence/questa/integration/`.
- Update `rtl/README.md` (control/ and top/ rows), `tests/README.md` (integration row and the
  run command), and the README status line and mermaid diagram. Add a short "Control
  pre-alpha" section listing what's implemented, D-decisions that differ from the full §6
  spec, and known limitations (§9).

## 8. Test matrix (all must pass)

| # | Test | Checks |
|---|---|---|
| T1 | Reset values | ID, VERSION, HW_*, STATUS = idle/Q_EMPTY/FSM 0, NEXT_SEQ 0, DONE_SEQ 0xFFFF, ERR 0, Q_CLAMP 0x7F80, IRQ line low |
| T2 | Register access | RW round-trip on every staging reg; RO ignores writes; W1C clears; unmapped/unaligned → `reg_error_o` |
| T3 | NOP | START → done; DONE_SEQ=0; CMD_COUNT=1; IRQ DONE raised/cleared; no core handshake |
| T4 | Six valid fixtures | normal, signed_nonzero_zp_stalled (memory + write stalls on), partial_tile_7x13x5, positive_negative_saturation, rounding_ties, channel_scales_relu_clamp: INT8 bytes exact, guard bytes intact, exactly one core launch, done after last write, DONE_SEQ increments 0,1,2… back to back without reset |
| T5 | PER_CHANNEL=0 | Rerun `normal_8x16x8` with Q_MULT/Q_SHIFT from its uniform record values; same bytes |
| T6 | Padded output pitch | `partial_tile` with DST offset 0x100 and P4=16; gaps keep 0xA5 |
| T7 | Bank routing | A from ACT1, B from WGT1 (images loaded there); result identical |
| T8 | Backpressure | random OUT write stalls plus memory stalls on all fixtures; same results |
| T9 | `invalid_zero_k` | ERR_CODE=0x02 with seq, ERR_INFO=0x044, HALTED, IRQ ERROR, **zero core launches, zero OUT writes** |
| T10 | Each control-detected error | illegal opcode 0x03 → 0x01; reserved bit → 0x07; missing ACC_LAST → 0x0B; SRC_A bank 6 → 0x03; DST bank 5 → 0x03; M=9 → 0x02; P4<N → 0x02; DST misaligned / overflowing span → 0x03. Each with exact ERR_INFO, no launch, no writes |
| T11 | Core-detected errors | A pitch < round_up(K,16) → 0x02 from the core; A base misaligned → 0x03; accumulation overflow (synthetic fixture: 127×127 × K=16 with bias near INT32_MAX) → 0x08. No OUT writes in all three |
| T12 | START while busy | ERR 0x06; in-flight result still correct and retired; then HALTED; exactly one launch |
| T13 | Halted behavior | START in HALTED does nothing (NEXT_SEQ unchanged); CLEAR_ERR clears ERR but stays HALTED; SOFT_RESET → IDLE, NEXT_SEQ 0, DONE_SEQ 0xFFFF; next valid fixture passes |
| T14 | Reset mid-operation | Hardware `rst_ni` and separately `SOFT_RESET` asserted during RUN and during DRAIN; then a fresh fixture passes with correct bytes (OUT region re-guarded first) |
| T15 | Staging rewrite during run | Change every staging register while RUN; the active command's result is unaffected |

## 9. Out of scope (document as known limitations)

These are out of scope for pre-alpha:

- the command queue (depth > 1), FETCH and WAIT_DEP
- bank-state interlock and RELEASE semantics
- ABORT, ZERO_LOCAL, QUIESCENT tracking and the dependency watchdog
- AXI4-Lite and the PeakRDL-generated CSR
- multi-tile traversal, K-chunk/PSUM continuation, CONV2D/POOL/EWADD/T_* opcodes
- DMA and the adapter
- the RISC-V core and C firmware
- synthesis and timing

The core still has no timeout (README limitation), so a stuck memory hangs the command until
SOFT_RESET.

## 10. Coordination items to raise with the team (put these in the final report)

- **Quan:** the requant port list in §5.3 and the PRM second-port assumption (D7).
- **Taylor:** OUT write-port shape and whether accepted means committed (D5); dual-port PRM
  (D7); reset of bank responders through `local_rst_no` (D11).
- **Michael:** nothing needs to change in the core. Confirm that passing 0x02/0x03/0x08
  through as system error codes is intended.
- **Jackie:** `export_fixtures.py` reads your manifest. Ask whether to add an overflow (0x08)
  and a bad-pitch fixture to `tests/vectors/prealpha/` rather than generating them in the harness.

## 11. Definition of done

- `python tests/rtl/integration/run_questa.py` passes T1–T15 from a clean checkout, and
  `python tests/rtl/compute/run_questa.py` still passes.
- Evidence is committed under `evidence/questa/integration/`, and the docs are updated per Phase 6.
- The final report lists:
  - which teammate modules were real and which were stand-ins
  - any deviation from the decisions above
  - the coordination items in §10

## 12. Commit plan

Make one commit per row, in this order, on `nahjay_control`. Before each commit:

1. Run that row's check.
2. Run `git status` and stage **only** the listed files (by name, never `git add -A`). The
   working tree has unrelated untracked `*.sync-conflict-*` files and a stray `README`, so
   never stage those.
3. Use the message shown, in the repo's existing style (imperative, sentence case, no
   prefix). Add a short body when it helps explain the change.

If a check fails, fix it before committing; don't commit broken steps. If a later step needs
a fix to an earlier file, include that fix in the later commit and mention it in the body.
Don't amend or squash earlier commits.

| # | Phase | Files | Check before committing | Message |
|---|---|---|---|---|
| C1 | — | `docs/plans/nahjay_control_integration_prealpha.md` (if not already committed) | none | `Add control and integration pre-alpha plan` |
| C2 | 1 | `rtl/control/raven_ctrl_pkg.sv` | compiles alone with `vlog -sv` | `Add control package with register map, opcodes and error codes` |
| C3 | 1 | `rtl/control/raven_ctrl_regs.sv` | compiles with C2 | `Add pre-alpha control register block` |
| C4 | 2 | `rtl/control/raven_ctrl.sv` | compiles with C2–C3 | `Add single-command control FSM with validation and retirement` |
| C5 | 3 | `rtl/top/raven_result_writer.sv` | compiles | `Add INT8 result writer for the output bank` |
| C6 | 3 | `tests/rtl/integration/sim_requant.sv` (skip this row if Quan's requant is merged) | compiles | `Add testbench requantization stand-in` |
| C7 | 3 | `tests/rtl/integration/sim_write_memory.sv` | compiles | `Add testbench output-bank write model` |
| C8 | 4 | `rtl/top/raven_npu_top.sv` | compiles with all RTL plus `rtl/compute/*` | `Connect control, compute, requant and writer in NPU top` |
| C9 | 5 | `tests/rtl/integration/export_fixtures.py` | runs on every manifest case and writes the expected files under `build/` | `Add pre-alpha fixture exporter for integration tests` |
| C10 | 5 | `tests/rtl/integration/raven_tb_driver_pkg.sv` | compiles | `Add testbench command driver standing in for the RISC-V` |
| C11 | 5 | `tests/rtl/integration/tb_raven_npu_top.sv` | T1–T4 pass when run by hand | `Add integration testbench with reset, NOP and fixture tests` |
| C12 | 5 | `tests/rtl/integration/tb_raven_npu_top.sv` (and fixture exporter if extended) | T5–T8 pass | `Add output pitch, bank routing and backpressure tests` |
| C13 | 5 | same | T9–T11 pass | `Add invalid-command and core-error tests` |
| C14 | 5 | same | T12–T15 pass | `Add busy, halted, reset and staging-rewrite tests` |
| C15 | 6 | `tests/rtl/integration/run_questa.py`, `tests/rtl/integration/run_batch.do` | full runner passes T1–T15; compute runner still passes | `Add Questa runner for integration tests` |
| C16 | 6 | `evidence/questa/integration/*` | files come from the passing C15 run | `Add integration simulation evidence` |
| C17 | 6 | `README.md`, `rtl/README.md`, `tests/README.md` | links resolve | `Document control and integration pre-alpha` |

If the testbench work in C11–C14 shows a bug in an RTL file from C2–C8, fix it in its own
commit before continuing: `Fix <what> in <module>`, with a body naming the failing test.
