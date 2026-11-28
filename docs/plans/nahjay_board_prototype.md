# Board prototype plan: control bridge and board wrapper (Nahjay)

**Live result.** W14 passed on the Ultra96-V2 with the corrected MEMORY build.
All 14 smoke checks passed, the GEMM retired with `DONE_SEQ=1`, and the raw OUT0
capture matched 64/64 golden bytes. W1–W13 and T1–T16 also passed in Questa.
[Live evidence](../../evidence/vivado/board-prototype/live-gemm/results.json) · [Rerun instructions](../../hw/README.md#run-the-full-board-test)

**Earlier build record.** ModelSim ASE 18.1 passed W1–W13 with
`--no-sva-guard`. Vivado 2025.2 met 50 MHz routed timing for the original
PATTERN and MEMORY configurations. Those reports and packages are archived.
Section 13 records the MEMORY integration and later W14 result.
[Archived build reports](../../hw/README.md#verified-board-build) · [Archived packages](../../hw/handoff/README.md)
**Owner:** Nahjay (control/board bring-up). **Working branch:** `nahjay_control_prototype`.
**Goal:** one resident `M=8, K=16, N=8` GEMM on the Ultra96-V2. A live START
reaches DONE, and all 64 OUT0 bytes read back over JTAG match the golden.

This plan covers the control-side work that has to exist before the Vivado
project Tcl can produce a useful bitstream. The handoff contract is
[RAVEN_BOARD_PROTOTYPE_INTERFACE.md](../interfaces/RAVEN_BOARD_PROTOTYPE_INTERFACE.md).
If this plan and that document disagree, the interface document wins. Stop and
report the conflict.

## 1. Assignment

From the team split:

- Start the Vivado project Tcl. Set up the 50 MHz PL clock, reset, and the
  JTAG-to-AXI Lite bridge.
- Map NPU registers at `0xA4000000` and OUT0 readback at `0xA4002000`.
- Test the bridge with a known readback pattern while the real memory is built.
- Hand Michael the bitstream and the matching PS initialization Tcl.

Dependency order for the team: Taylor's memory ports, then Jackie and Michael
connect and simulate the datapath, then Quan runs the integrated golden check,
then this plan's final bitstream, then Michael's board run. This plan's bridge,
pattern responder and Tcl do **not** depend on Taylor's memory and can proceed now.

## 2. Current state

### Done and reused unchanged

- `rtl/control/raven_ctrl_pkg.sv`, `raven_ctrl_regs.sv`, `raven_ctrl.sv`. Every
  register offset and value in the interface document matches the package:
  ID `0x5241564E` at `0x000`, `CTRL` `0x010`, `STATUS` `0x014`, `IRQ_STATUS`
  `0x01C`, `NEXT_SEQ` `0x020`, `DONE_SEQ` `0x024`, `ERR_CODE`/`ERR_INFO`
  `0x028`/`0x02C`, staging `0x030`–`0x06C`. `OP_FLAGS = 0x47` passes CHECK.
- DONE already follows the last committed OUT0 write (plan D5). SOFT_RESET and
  `local_rst_no` work, and the register block stays on `rst_ni` so diagnostics
  remain readable while the datapath is held in reset.
- `rtl/top/raven_npu_top.sv` is the NPU block the wrapper instantiates.
- Out-of-context synthesis passes at 10 ns with +1.2 ns estimated slack, so
  50 MHz has margin.

### Missing

- Any AXI logic. The register bus is the pre-alpha native bus (D1 of the
  [pre-alpha plan](nahjay_control_integration_prealpha.md)).
- A board wrapper, a reset scheme for the board, and an OUT0 readback path.
- Backing memory with the per-port interface `raven_npu_top` expects. Taylor's
  `rtl/memory/banked_scratchpad.sv` currently has one generic read port and one
  generic write port with owner/generation fields, and an active-high `rst`.
- All Vivado project, block design, build and export scripts. `hw/` only holds
  the out-of-context synthesis checks.

## 3. Ground rules

- Do not modify Michael's files (`rtl/compute/*`, `tests/rtl/compute/*`) or
  Taylor's memory files. Request changes in the final report instead.
- Change `rtl/control/*` only to fix a bug a new test exposes, in its own
  `Fix <what> in <module>` commit.
- Match the existing RTL style: `` `default_nettype none `` and `wire` at the
  top and bottom, `_i/_o/_q` suffixes, `always_ff` with nonblocking assignments,
  a short comment on every port, and `ifndef SYNTHESIS` assertions.
- Synthesizable board logic goes in `rtl/board/`. Simulation-only models go
  under `tests/` with a `// TESTBENCH ONLY:` header.
- Generated output goes to `build/` and is never committed. Curated evidence
  goes to `evidence/questa/board/` and `evidence/vivado/board-prototype/`.
- Python 3.9+, standard library only. Questa and Vivado come from `PATH` or an
  explicit argument. Never hard-code a machine path.
- Stage files by name. Never `git add -A`. Leave the untracked
  `docs/diagrams/*.drawio` files alone unless asked.

## 4. Decisions

| # | Decision | Rationale |
|---|---|---|
| B1 | **One AXI4-Lite slave, 14-bit address, 32-bit data.** `0x0000–0x0FFF` goes to the NPU register bus, `0x1000–0x1FFF` is unmapped, and `0x2000–0x3FFF` is read-only OUT0. Upper address bits are decoded by the interconnect. | Matches the interface document's 16 KiB window at `0xA4000000`. |
| B2 | **Error responses:** DECERR (`2'b11`) for the unmapped hole. SLVERR (`2'b10`) for unaligned addresses, CSR writes with `WSTRB != 4'hF`, any OUT0 write, an NPU `reg_error_o`, and an OUT0 read abandoned by reset (B5). An errored access never reaches the NPU or memory. | The doc requires "an AXI error" for these cases. Separating DECERR makes a wrong base address obvious in Hardware Manager. |
| B3 | **One transaction in flight.** AW and W are captured independently in either order. A write starts once both are held. A read starts only when no partial write is held. If a complete write and a read are both ready on the same clock, the write goes first. B and R are held until accepted. | JTAG-to-AXI issues one transaction at a time, but the slave must still be correct for any legal ordering. |
| B4 | **OUT0 readback:** align the byte offset down to 16 bytes, issue one `out0_rd` request, wait for the 128-bit response, and return lane `offset[3:2]` (bits `[7:0]` = byte `offset`). | Exactly the interface document's readback contract. |
| B5 | **OUT0 read during datapath reset:** if `local_rst_no` is low when the read would be issued, or drops while it is pending, the bridge finishes the AXI read with SLVERR and does not wait for a response. | The memory clears pending responses on `local_rst_no`. Without this the bridge hangs JTAG during exactly the fault cases the host needs to diagnose. |
| B6 | **Bridge and register block stay on the board reset** (`proc_sys_reset` `peripheral_aresetn`, already synchronized to `pl_clk0`). Only the datapath and banks use `local_rst_no`. | The host must be able to read `ERR_CODE` and issue SOFT_RESET while the datapath is held in reset. |
| B7 | **Readback-pattern stand-in:** `raven_out0_pattern` answers `out0_rd` with `byte[i] = (addr + i)[7:0] ^ 8'h5A`. A wrapper parameter `OUT0_SOURCE` selects `"PATTERN"` or `"MEMORY"`. | Allows a bitstream and an end-to-end JTAG smoke test before Taylor's memory exists. The pattern differs at every byte and lane, so lane-select or alignment bugs show up immediately. |
| B8 | **Thin Verilog-2001 shell for the block design.** `raven_board_top_v.v` instantiates the SystemVerilog `raven_board_top`. The block design uses the `.v` file as a module reference. Confirm in Vivado 2025.2 whether this is still required; drop the shell if SystemVerilog module references work. | Vivado module references have historically refused SystemVerilog top files. |
| B9 | **Clock and reset:** a single `pl_clk0` at 50 MHz feeds the JTAG-to-AXI core, SmartConnect, wrapper, NPU and BRAM. No CDC in the design. | The interface document requires a single free-running clock for bring-up. |
| B10 | **The NPU IRQ is unused on the board.** Leave `npu_irq_o` unconnected in the wrapper. Michael polls `STATUS` and `IRQ_STATUS`. | No processor application in this demo. |

### Open items (need team agreement before Phase 4)

- **O1: memory port adapter owner.** Someone must adapt Taylor's banks to the
  `raven_npu_top` ports: ACT0/ACT1, WGT0/WGT1, PRM A and B (same contents),
  OUT0 write (ready means committed), and the new `out0_rd` read port, all on
  `local_rst_no`. Propose Taylor owns it and Michael reviews it against the core.
- **O2: ACT1/WGT1 in the fixture build.** If those banks get no storage, a
  command routed to them waits forever on a read. Choose one: (a) real storage
  for all four banks, (b) small responders that accept requests and return
  zero data, with the limitation documented, or (c) a wrapper rule that only
  ACT0/WGT0 commands are accepted. Never alias unsupported offsets onto the
  fixture bytes. Recommend (a) if BRAM allows (76 KiB fits easily on the ZU3EG).
- **O3: fixture preload.** Confirm the memory takes `act.hex`, `wgt.hex` and
  `prm.hex` from `export_fixtures.py` as BRAM init files, and how the fixture is
  restored after SOFT_RESET (the interface document leaves this to the board design).

## 5. Interfaces

### 5.1 `raven_axil_bridge` (`rtl/board/`)

AXI side, Vivado naming so the block design infers the interface:

- `s_axi_aclk`, `s_axi_aresetn`
- `s_axi_awaddr[13:0]`, `s_axi_awprot[2:0]` (ignored), `s_axi_awvalid`, `s_axi_awready`
- `s_axi_wdata[31:0]`, `s_axi_wstrb[3:0]`, `s_axi_wvalid`, `s_axi_wready`
- `s_axi_bresp[1:0]`, `s_axi_bvalid`, `s_axi_bready`
- `s_axi_araddr[13:0]`, `s_axi_arprot[2:0]` (ignored), `s_axi_arvalid`, `s_axi_arready`
- `s_axi_rdata[31:0]`, `s_axi_rresp[1:0]`, `s_axi_rvalid`, `s_axi_rready`

NPU side: the `reg_*` bus of `raven_npu_top` (issue on `reg_valid_o && reg_ready_i`,
complete on `reg_rvalid_i`, error on `reg_error_i`).

OUT0 side: `out0_rd_req_valid_o`, `out0_rd_req_ready_i`, `out0_rd_req_addr_o[12:0]`
(16-byte aligned), `out0_rd_rsp_valid_i`, `out0_rd_rsp_ready_o`,
`out0_rd_rsp_data_i[127:0]`, plus `local_rst_ni` for B5.

Assertions: `reg_valid_o` and `out0_rd_req_valid_o` are never high together;
B and R stay stable until accepted; at most one native access per AXI transaction;
no OUT0 request is issued for a write.

### 5.2 `raven_out0_pattern` (`rtl/board/`)

Implements the `out0_rd` responder contract: one outstanding request, held response,
variable latency parameter (`LATENCY`, default 1) so tests can stall it, and a
flush on `local_rst_ni`.

### 5.3 `raven_board_top` (`rtl/board/`)

- Ports: `s_axi_*` from 5.1 and `aclk`/`aresetn` only. All bank ports are internal.
- Instantiates `raven_axil_bridge`, `raven_npu_top` (`USE_TILE_BUFFERS=1`), and
  either `raven_out0_pattern` or the memory adapter from O1, selected by `OUT0_SOURCE`.
- In `"PATTERN"` mode the NPU bank ports are tied to safe idle values: read
  requests are never accepted and OUT0 writes are never accepted. A START in this
  mode is expected to hang in RUN. That is acceptable for the bridge smoke test
  and is recoverable with SOFT_RESET.
- Memory init file parameters pass through to the memory adapter in `"MEMORY"` mode.

## 6. File layout

```text
rtl/board/raven_axil_bridge.sv        # AXI4-Lite slave -> reg bus + OUT0 read port
rtl/board/raven_out0_pattern.sv       # deterministic OUT0 read responder (B7)
rtl/board/raven_board_top.sv          # bridge + npu_top + memory or pattern
rtl/board/raven_board_top_v.v         # Verilog shell for the block design (B8)
tests/rtl/board/axil_master_pkg.sv    # testbench AXI4-Lite master tasks
tests/rtl/board/tb_raven_axil_bridge.sv
tests/rtl/board/tb_raven_board_top.sv # end-to-end fixture over AXI (Phase 4)
tests/rtl/board/run_questa.py
hw/check_board_synthesis.tcl          # Phase 3 out-of-context check of the wrapper
hw/board_settings.tcl                 # Phase 5 shared options, paths and source list
hw/create_project.tcl
hw/bd.tcl
hw/build.tcl
hw/constraints/raven_board.xdc
hw/debug/board_bringup_xsdb.tcl       # xsdb: reset, program PL, psu_init, release PL reset
hw/debug/run_fixture.tcl              # Hardware Manager host script
```

## 7. Phases

### Phase 0: orient (no code)

- Run `python tests/rtl/integration/run_questa.py` to confirm the integration
  baseline still passes on this branch. If it fails, stop and report.
- `git fetch` and check `origin/taylor_memory` and `origin/main` for the memory
  adapter (O1). Record what was found.

### Phase 1: bridge

- Write `raven_axil_bridge.sv` per B1–B6 and 5.1.
- Write `axil_master_pkg.sv` with `axil_write(addr, data, strb, order, out resp)`
  and `axil_read(addr, out data, out resp)`, where `order` is AW-first, W-first,
  or same-clock, and with random `bready`/`rready` delays.

### Phase 2: pattern responder and bridge testbench

- Write `raven_out0_pattern.sv`.
- `tb_raven_axil_bridge.sv` drives the bridge connected to the real `raven_npu_top`
  (sim memory models from `tests/rtl/integration/` on the bank ports) and the
  pattern responder on `out0_rd`. Run the tests in §8 (W1–W12).

### Phase 3: board wrapper and Verilog shell

- Write `raven_board_top.sv` and `raven_board_top_v.v`.
- Run W1–W4 against `raven_board_top` in `"PATTERN"` mode.
- Run the out-of-context synthesis check on `raven_board_top` at 20 ns to catch
  non-synthesizable constructs before Phase 5.

### Phase 4: end-to-end fixture over AXI (needs O1–O3)

- Connect the memory adapter in `"MEMORY"` mode.
- `tb_raven_board_top.sv` runs `normal_8x16x8` using only AXI transactions,
  following the interface document's host procedure:
  1. read ID, check idle with no error, W1C `IRQ_STATUS`
  2. write every pair from `cmd.txt`, read `NEXT_SEQ`
  3. write `CTRL.START`, poll with a bounded timeout
  4. require DONE, BUSY clear and `DONE_SEQ == NEXT_SEQ` sampled before START
  5. read 16 words from `0x2000`, write `out0.bin`, and run
     `tools/goldens/compare_prealpha.py`
- Repeat with a SOFT_RESET between runs and check the second run still passes.
- Hand the testbench and runner to Quan for the integrated golden check.

### Phase 5: Vivado project Tcl

- `create_project.tcl`: part `xczu3eg-sbva484-1-e` with the Ultra96-V2 board
  file if installed. Add `rtl/control`, `rtl/compute`, `rtl/operators`,
  `rtl/memory`, `rtl/top` and `rtl/board` sources and the fixture `.hex` files.
  Project output goes under `build/hw/`.
- `bd.tcl`:
  - `zynq_ultra_ps_e` with the board preset, `pl_clk0` = 50 MHz, `pl_resetn0`
    enabled, unused PS-PL AXI ports disabled
  - `proc_sys_reset` on `pl_clk0`
  - `jtag_axi` with `PROTOCOL` = AXI4-Lite
  - `smartconnect` with one master port to the `raven_board_top_v` module reference
  - address assignment: `0xA4000000`, range 16K, in the JTAG master's address space
- `build.tcl`: synthesize, implement, write the bitstream and the debug probes
  file, write utilization/timing/DRC reports, and require that the implemented
  `pl_clk0` is 50 MHz with no negative slack. Export the hardware platform
  (`.xsa`) and extract `psu_init.tcl` from it.
- `hw/debug/run_fixture.tcl`: the Phase 4 host procedure as Hardware Manager
  `create_hw_axi_txn`/`run_hw_axi` commands, with an `-smoke` mode that only checks
  the ID and the OUT0 pattern.
- First bitstream uses `"PATTERN"` for the JTAG smoke test. The final handoff
  bitstream uses `"MEMORY"` after Quan's integrated check passes.

### Phase 6: handoff and evidence

- Send Michael the `.bit`, `.ltx`, `psu_init.tcl`, `run_fixture.tcl`, and the
  board bring-up order: program the PS with `psu_init.tcl` over JTAG, release
  the PL reset, program the bitstream, refresh Hardware Manager, then run the
  ID smoke test.
- Commit the curated Questa log and results to `evidence/questa/board/`, and the
  implementation utilization/timing reports to `evidence/vivado/board-prototype/`.
- Update `hw/README.md` with the build and bring-up commands.

## 8. Test matrix

| # | Test | Checks |
|---|---|---|
| W1 | ID smoke | Read `0x0000` returns `0x5241564E` with OKAY |
| W2 | Write ordering | CSR write with AW first, W first and same clock. Staging register reads back the value. Exactly one native write per transaction |
| W3 | Response backpressure | `bready`/`rready` held low for random cycles. B/R stay valid and stable, no second access starts |
| W4 | OUT0 pattern | Every word in `0x2000–0x203F`, plus the last word `0x3FFC`, matches the pattern with OKAY. Lane select correct for all four lanes |
| W5 | Unaligned | Read and write with `addr[1:0] != 0` give SLVERR and no native access |
| W6 | Partial strobe | CSR write with `WSTRB` other than `4'hF` gives SLVERR, register unchanged |
| W7 | OUT0 write | Write to `0x2000` gives SLVERR, no NPU or memory access |
| W8 | Unmapped hole | Read and write to `0x1000` and `0x1FFC` give DECERR |
| W9 | NPU error | Read at NPU offset `0x0B8` (past the map) gives SLVERR via `reg_error_o` |
| W10 | Read/write contention | A complete write and a read presented on the same clock: write completes first, both responses correct |
| W11 | Datapath reset | OUT0 read with `local_rst_no` low gives SLVERR. A SOFT_RESET during a stalled OUT0 read gives SLVERR, no hang, and the next read is OKAY. CSR reads still work while the datapath is reset |
| W12 | Board reset | `aresetn` asserted with an AW held and with a read pending. After release, no stale response appears and W1 passes |
| W13 | Fixture over AXI (Phase 4) | `normal_8x16x8`: DONE, `DONE_SEQ` match, 64/64 bytes match the golden via `compare_prealpha.py`. Repeat after SOFT_RESET |
| W14 | Board (Phase 6) | Michael's live run: ID smoke, START to DONE, 64/64 readback match |

## 9. Out of scope

- PS-side software, DMA, and runtime loading of the banks
- interrupts on the board
- AXI bursts, multiple outstanding transactions, and AXI4 (full) masters
- multi-tile workloads and performance work on the staging adapters
- clocks above 50 MHz

## 10. Coordination items

- **Taylor:** O1–O3. Share the memory adapter port list early, especially the two
  PRM readers and the `out0_rd` port from 5.1. Confirm its reset follows
  `local_rst_no` and that OUT0 write ready means committed.
- **Jackie:** the output path writes through the same OUT0 adapter that serves
  `out0_rd`. Confirm reads and NPU writes don't conflict (the host only reads
  after DONE, but the adapter must not depend on that for correctness).
- **Michael:** physical JTAG check (J3 header, cable) before the first bitstream.
  Agree on the `run_fixture.tcl` interface and the bring-up order in Phase 6.
- **Quan:** `tb_raven_board_top.sv` and its runner (Phase 4) are the integrated
  check. Agree on the `out0.bin` path and log format for the pass/fail record.

## 11. Definition of done

- `python tests/rtl/board/run_questa.py` passes W1–W13 from a clean checkout,
  and the integration runner still passes T1–T16.
- `vivado -mode batch -source hw/build.tcl` builds from a clean checkout with
  50 MHz timing met.
- Michael has the bitstream, probes file, `psu_init.tcl` and `run_fixture.tcl`.
- W14 passes on the board and Quan's 64/64 log is committed as evidence.

## 12. Commit plan

One commit per row, in order, on `nahjay_control_prototype`, after that row's check passes.

| # | Phase | Files | Check before committing | Message |
|---|---|---|---|---|
| P1 | — | `docs/plans/nahjay_board_prototype.md` | none | `Add board prototype control plan` |
| P2 | 1 | `rtl/board/raven_axil_bridge.sv` | compiles with `raven_npu_top` | `Add AXI4-Lite bridge for NPU registers and OUT0 readback` |
| P3 | 1 | `tests/rtl/board/axil_master_pkg.sv` | compiles | `Add testbench AXI4-Lite master` |
| P4 | 2 | `rtl/board/raven_out0_pattern.sv` | compiles | `Add OUT0 readback pattern responder` |
| P5 | 2 | `tests/rtl/board/tb_raven_axil_bridge.sv`, `tests/rtl/board/run_questa.py` | W1–W12 pass | `Add AXI bridge testbench and runner` |
| P6 | 3 | `rtl/board/raven_board_top.sv`, `rtl/board/raven_board_top_v.v`, `hw/check_board_synthesis.tcl`, bridge TB/runner (`BOARD_TOP` config) | W1–W4 pass on the wrapper; OOC synthesis clean | `Add board wrapper with pattern OUT0 source` |
| P7 | 5 | `hw/board_settings.tcl`, `hw/create_project.tcl`, `hw/bd.tcl`, `hw/build.tcl`, `hw/constraints/raven_board.xdc`, `rtl/board/raven_board_top_v.v` (integer `OUT0_MEMORY`), bridge TB | pattern bitstream builds, 50 MHz met | `Add Vivado project and block design scripts` |
| P8 | 5 | `hw/debug/board_bringup_xsdb.tcl`, `hw/debug/run_fixture.tcl` | `-smoke` mode passes on the board | `Add Hardware Manager fixture script` |
| P9 | 4 | `rtl/board/raven_board_top.sv`, `tests/rtl/board/tb_raven_board_top.sv`, runner | W13 passes | `Run the GEMM fixture end to end over AXI` |
| P10 | 6 | `evidence/questa/board/*`, `evidence/vivado/board-prototype/*`, `hw/README.md` | files come from passing runs | `Add board prototype evidence and bring-up guide` |
| P11 | 6 | `hw/handoff/raven_board_pattern.zip`, `hw/handoff/README.md` | built from the committed scripts, 50 MHz and timing met | `Add PATTERN board handoff package` |
| P12 | 4, 6 | memory adapter connection, `tb_raven_board_top.sv`, `hw/handoff/raven_board_memory.zip`, evidence | W13 passes; MEMORY build meets 50 MHz; 64/64 on the board | `Add MEMORY board build and GEMM demo handoff` |

P7 and P8 can land before P9: the Tcl is built and smoke-tested with the pattern
source while the memory adapter is finished.

## 13. Remaining work

Phases 1–3 and 5 are done and committed, as are the Vivado evidence and the
`hw/README.md` build and bring-up guide. Michael has the PATTERN bring-up package in
`hw/handoff/raven_board_pattern.zip` for README steps 1–2 (JTAG, PS initialization,
clock, address map, bridge, and a live NOP START → DONE).

### Final step: connect Taylor's memory interface and ship the demo bitstream

This is the last step of the prototype. It starts when Taylor shares the memory port
list ("the Phase 4 names"). Needed from Taylor (O1–O3):

- the adapter module name and its source files
- the signal names for each logical port: ACT0, ACT1, WGT0, WGT1, PRM port A, PRM
  port B (read request/response), the OUT0 write port, and the OUT0 read port that
  `raven_axil_bridge` uses (`out0_rd`, 13-bit offset, 128-bit response)
- the reset input and its polarity; it must follow the NPU's `local_rst_no`
- how the `act.hex`, `wgt.hex` and `prm.hex` fixture images are loaded, and what
  happens to them after SOFT_RESET (O3)
- the answer for ACT1/WGT1 storage (O2)

Then:

1. In `rtl/board/raven_board_top.sv`, replace the `g_unsupported` branch with a
   `"MEMORY"` branch that instantiates the adapter on the NPU bank ports, the `out0_rd`
   port and `local_rst_n`, and passes the fixture init files.
2. Add the adapter sources to `raven::rtl_sources` in `hw/board_settings.tcl`, and the
   fixture `.hex` files to the project in `hw/create_project.tcl`.
3. Write `tests/rtl/board/tb_raven_board_top.sv` (W13, Phase 4) and add it to
   `tests/rtl/board/run_questa.py`. Hand it to Quan for the integrated golden check.
4. Rebuild with `hw/build.tcl -tclargs -out0_memory 1`. Confirm 50 MHz and timing,
   package `hw/handoff/raven_board_memory.zip`, and update
   `evidence/vivado/board-prototype/`.
5. Michael runs README step 3 on the board and sends Quan `out0.bin`. Quan's 64/64 log
   goes into the evidence. Commit as P12.

**Status of this step.** Taylor's port list is `rtl/memory/raven_memory_banks.sv` (with
`raven_bram_bank.sv`), so items 1–3 are done:

- O1: `raven_board_top` `"MEMORY"` connects `raven_memory_banks` directly; no extra adapter
  was needed. Its reset is `rst_ni` (active low) driven by `local_rst_no`. The bridge's
  13-bit `out0_rd` offset is zero-extended to the banks' 24-bit byte address.
- O2: (a) all four ACT/WGT banks have real 16 KiB storage; ACT1/WGT1 load the same images
  as ACT0/WGT0, so a command routed to either bank ID produces the same result.
- O3: `act.hex`/`wgt.hex`/`prm.hex` are BRAM init images (`$readmemh`, bare names found
  via the Vivado project's memory files), committed in `hw/fixtures/normal_8x16x8`. The
  ACT/WGT/PRM write ports are tied off, so SOFT_RESET leaves the fixture intact.
- W13: `tests/rtl/board/tb_raven_board_top.sv`, run by `tests/rtl/board/run_questa.py`,
  passes under ModelSim ASE 18.1 (`--no-sva-guard`) and `compare_prealpha.py` reports 0
  mismatches for all three OUT0 dumps.

Item 4 is done: the MEMORY build meets timing at 50 MHz, its record and reports are in
`evidence/vivado/board-prototype/memory/`, and the package is
`hw/handoff/raven_board_memory.zip`. `run_fixture.tcl` now detects the build from
`build_info.txt` and checks OUT0 against `expected_int8.hex` on the board.

Item 5 passed with the corrected MEMORY bitstream and `run_board_test.tcl`.
The record includes the Vivado JTAG transcript, raw OUT0 bytes, independent
golden comparison and routed timing. [W14 results](../../evidence/vivado/board-prototype/live-gemm/results.json)

The live result covers the MEMORY configuration. The separate PATTERN hardware
smoke test remains open.
