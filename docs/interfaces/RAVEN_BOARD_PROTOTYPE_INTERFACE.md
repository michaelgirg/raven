# RAVEN board prototype interface

This is the team handoff for the first Ultra96-V2 demo. Run one
resident `M=8, K=16, N=8` INT8 GEMM, requantize the INT32 accumulations, and
compare the 64 bytes read from FPGA OUT0 to the existing Python golden. The
ports and command values below match the MEMORY board prototype. The demo runs
over JTAG with preloaded operands. [Board test](../../hw/README.md#run-the-full-board-test) · [Live evidence](../../evidence/vivado/board-prototype/live-gemm/results.json)

## Board access for START and readback

Use **Vivado Hardware Manager over JTAG with a 32-bit JTAG-to-AXI Master in
AXI4-Lite mode**. The PC writes commands and reads stored output through a
single AXI4-Lite slave in the PL board wrapper. This lets Michael drive the
demo from Vivado Tcl without a processor application. A future PS master can
use the same wrapper and register offsets.

| JTAG AXI byte address, inclusive | Access | Board-wrapper decode |
| --- | --- | --- |
| `0xA4000000`–`0xA4000FFF` | NPU CSR reads and writes | Pass the low 12-bit offset to `reg_addr_i`. The NPU defines the register offsets and response behavior. |
| `0xA4001000`–`0xA4001FFF` | Unmapped | Return `DECERR`. |
| `0xA4002000`–`0xA4003FFF` | Read-only OUT0 | Subtract `0xA4002000` for the OUT0 byte offset. Read the output BRAM. Writes return `SLVERR`. |
| Outside `0xA4000000`–`0xA4003FFF` | Unmapped | Compare the full 32-bit AXI address and return `DECERR`. |

Use one aligned 32-bit transaction at a time and full byte strobes for CSR
writes. The wrapper must accept AXI address and write data independently,
issue the native access once, wait for `reg_rvalid_o`, and report
`reg_error_o` as an AXI error. Hold each AXI response until accepted. Reject
unaligned accesses, partial CSR writes, and writes to OUT0 with `SLVERR`.
AXI transfer completion for a START write acknowledges the register write.
Command retirement is reported separately through the NPU status registers.

Taylor provides a logical read port on OUT0 BRAM alongside the NPU write port.
Use the request/response handshake below. From the wrapper's perspective the
port prefix is `out0_rd`, the request address is a 13-bit bank-local byte
offset, and the response is 128 bits. The wrapper aligns the byte offset down
to 16 bytes for the BRAM request, then selects one 32-bit lane using the
original offset bits `[3:2]`. For offset `p`, returned
bits `[7:0]` contain byte `p`, bits `[15:8]` contain byte `p+1`, and so on.
The host sequences readback after successful DONE and finishes it before
issuing another START. Keep the debug window read-only.

Use a single free-running `pl_clk0` from the Zynq UltraScale+ PS block for
the JTAG AXI core, wrapper, NPU, and BRAM. Use **50 MHz** for initial board
bring-up and verify it in the implemented design. Nahjay supplies the matching
PS initialization Tcl and clock/reset setup with the bitstream. Initialize the
PS clock and release the board reset before refreshing the debug core in
Hardware Manager. Keep the debug core and register bridge on board reset so
the host can still read fault diagnostics and issue SOFT_RESET while
`local_rst_no` holds the datapath in reset.

The Ultra96-V2 needs a compatible JTAG cable on its J3 header. The Avnet
`AES-ACC-U96-JTAG` pod is the documented option. Confirm Vivado sees the board
and the programmed JTAG AXI core before attempting the fixture. As a bus smoke
test, read `0xA4000000` and require the NPU ID `0x5241564E` (`RAVN`).
See the [Avnet hardware guide](https://www.avnet.com/wcm/connect/b85b9556-0b2a-42b3-ad6a-8dcf3eac1ff9/Ultra96-V2-HW-User-Guide-v1_3.pdf?MOD=AJPERES),
[AMD JTAG-to-AXI guide](https://docs.amd.com/r/2025.1-English/ug908-vivado-programming-debugging/Hardware-System-Communication-Using-the-JTAG-to-AXI-Master-Debug-Core),
[AMD debug clock requirements](https://docs.amd.com/r/2025.2-English/ug908-vivado-programming-debugging/Debug-Core-Clocks),
and [AMD PS initialization documentation](https://docs.amd.com/r/en-US/pg201-zynq-ultrascale-plus-processing-system/Output-Generation).

## Module and port map

Use [`raven_npu_top`](../../rtl/top/raven_npu_top.sv) inside the board wrapper.
It already connects `raven_ctrl` to `raven_gemm_core`, routes operand reads, and
passes the core's signed INT32 result plus row, column, and last tags through
`raven_requant` to `raven_result_writer`. The requantizer uses the column tag
to select its PARAM record. `USE_TILE_BUFFERS=1` is the existing buffered path
with staging integrity checks.

| Boundary | Existing ports and behavior |
| --- | --- |
| Board wrapper to NPU control | `clk_i`, `rst_ni`, and `reg_*`. The register bus uses a 12-bit byte offset and 32-bit data. Issue one access at a time for bring-up, transfer on `reg_valid_i && reg_ready_o`, and wait for `reg_rvalid_o`. Check `reg_error_o` on every response, including writes. `npu_irq_o` is available if enabled. |
| Activation and weight reads | `act0_*`, `act1_*`, `wgt0_*`, `wgt1_*`. The snapshotted command chooses the A and B banks. The demo uses ACT0 and WGT0. |
| Parameter reads | `prm_a_*` serves corrected bias to compute. `prm_b_*` serves multiplier and shift to requantization. Both see the same PRM contents. The memory adapter can arbitrate a shared physical read port if it preserves both logical handshakes. |
| Output writes | `out0_w_valid_o`, `out0_w_ready_i`, `out0_w_addr_o`, `out0_w_data_o`, `out0_w_strb_o`. The address is an aligned 24-bit byte offset. A set strobe bit `n` writes `data[8*n +: 8]` at `addr+n`. For this writer each accepted beat commits one byte. |
| Datapath and bank reset | `local_rst_no` is active low and also reflects soft reset or a latched staging integrity fault. Use it to cancel pending bank transactions and suppress transfers during reset. External reset release belongs in the board wrapper. |
| OUT0 readback | The wrapper uses the separate BRAM read port mapped at `0xA4002000`. The host reads the **same physical OUT0 contents** the NPU wrote, after successful command retirement. |

Each memory read uses `<port>_req_valid_o`, `<port>_req_ready_i`, and
`<port>_req_addr_o` for the request, and `<port>_rsp_valid_i`,
`<port>_rsp_ready_o`, and `<port>_rsp_data_i` for its 128-bit response. Offsets
are bank-local bytes aligned to 16 bytes. Byte `addr+n` is response lane `n`,
bits `[8*n +: 8]`. Transfer on the rising edge when valid and ready are high.
Keep the request address and valid stable while stalled. Allow one outstanding
read per logical port, return exactly one response per accepted request, and
hold response valid/data until accepted. The NPU accepts variable latency.

A write handshake must mean storage is committed. Keep address, data and
strobes stable through backpressure. If the backing interface splits request
acceptance from completion, the adapter must wait for completion before
acknowledging the NPU and avoid issuing a duplicate write. DONE follows the
last committed write and successful command retirement.

Reset clears pending responses and writer state. The board design must define
how the fixture remains valid or is reloaded after reset. After an error,
discard partial OUT0, capture diagnostics, soft reset, ensure the fixture is
valid, and rewrite staging registers before starting again. See the
[staging integrity contract](RAVEN_STAGING_INTEGRITY.md) for fault recovery.

## Fixed fixture and address map

Use [`normal_8x16x8`](../../tests/vectors/prealpha/normal_8x16x8/reference.json)
from the existing golden fixtures. All base offsets are zero in their own
banks. The row pitch is 16 bytes for A and 8 bytes for OUT0.

| Payload | Logical bank ID | Byte window, inclusive | Layout |
| --- | --- | --- | --- |
| A | ACT0 (`0`) | `0x000000`–`0x00007F` | 128 signed INT8 bytes, `16*row+k`. |
| B | WGT0 (`2`) | `0x000000`–`0x00007F` | 128 signed INT8 bytes, `8*k+col`. |
| PARAM | PRM (`6`) | `0x000000`–`0x00007F` | Eight 16-byte records at `16*col`. Bytes 0–3 are little-endian signed corrected bias, 4–7 are little-endian signed Q31 multiplier, 8 is signed shift, and 9–15 are zero. |
| Result | OUT0 (`4`) | `0x000000`–`0x00003F` | 64 signed INT8 bytes, `8*row+col`. Writes target aligned word offsets `0x00`, `0x10`, `0x20`, and `0x30` with the corresponding byte strobe. |

Keep the control ABI's logical bank IDs even if the physical BRAM layout uses
different indices. ACT1 is `1`, WGT1 is `3`, and `5` is reserved for optional
OUT1. PRM remains `6`. The windows above are the bytes used by this fixture.
The current NPU validates against 16 KiB ACT/WGT banks, 4 KiB PRM, and 8 KiB
OUT0. Use backing storage that honors those limits, or explicitly constrain
the commands accepted by a smaller fixed-fixture board wrapper. Never alias
unsupported offsets to the fixture bytes.

Generate the preload and staging data from the repository root:

```sh
python tests/rtl/integration/export_fixtures.py --output build/prototype/fixtures
```

In `build/prototype/fixtures/normal_8x16x8/`, `act.hex`, `wgt.hex`, and
`prm.hex` are bank images with one 128-bit word per line, with the lowest
addressed byte in the least significant lane. `cmd.txt` provides staging
register offsets and 32-bit values as hex pairs. Use it as the source of
truth for the complete command. Key values are:

| Register | Offset | Fixture value |
| --- | --- | --- |
| `OPCODE` | `0x030` | `0x00000002` (GEMM) |
| `OP_FLAGS` | `0x034` | `0x00000047` (ACC_INIT, ACC_LAST, REQUANT_EN, PER_CHANNEL) |
| `SRC_A`, `SRC_B`, `PARAM`, `DST` | `0x038`, `0x03C`, `0x05C`, `0x058` | `0x00000000`, `0x20000000`, `0x60000000`, `0x40000000` |
| `P0`, `P1`, `P2`, `P4` | `0x040`, `0x044`, `0x048`, `0x050` | `0x00080008`, `0x00000010`, `0x00000010`, `0x00000008` |
| `Q_ZP`, `Q_CLAMP` | `0x060`, `0x06C` | `0x00FC0000` (output zero point −4), `0x00007F80` (−128 to 127) |

## START, completion, and verification

Run aligned 32-bit transactions from the Vivado Hardware Manager Tcl console
with `create_hw_axi_txn` and `run_hw_axi`. Add `0xA4000000` to each CSR offset
below and to the staging offsets in `cmd.txt`.

1. Confirm the fixture is loaded and the NPU is idle with no error. Clear any
   old completion indication by writing bit 0 to `IRQ_STATUS` (`0x01C`,
   write-one-to-clear). Write all staging pairs from `cmd.txt` and read
   `NEXT_SEQ` (`0x020`) for the command sequence.
2. Write `0x00000001` to `CTRL` (`0x010`) once. Poll with a bounded host timeout.
   Check `STATUS.ERROR` (bit 2), `STATUS.HALTED` (bit 1), and the new DONE bit
   in `IRQ_STATUS` (bit 0). For success require DONE, BUSY clear (bit 0 of
   `STATUS` at `0x014`), and `DONE_SEQ` (`0x024`) matching `NEXT_SEQ` sampled
   before START. On failure or timeout capture `STATUS`, `ERR_CODE` (`0x028`),
   and `ERR_INFO` (`0x02C`). `CTRL` bit 1 issues SOFT_RESET.
3. Read 16 words at `0xA4002000`, `0xA4002004`, …, `0xA400203C`. Write each
   word low byte first to `build/prototype/out0.bin` for exactly 64 raw bytes.
   Run the independent comparison:

   ```sh
   python tools/goldens/compare_prealpha.py --case tests/vectors/prealpha/normal_8x16x8 --kind int8 --actual build/prototype/out0.bin
   ```

The existing [integration runner](../../tests/rtl/integration/run_questa.py)
can run the fixture with `--tests T4` against simulated backing memory. Use
the same fixture with the new backing adapter before generating a bitstream.
Check all 64 write addresses/bytes, backpressure, cancellation of pending
responses on reset, and that DONE follows the last committed write. Verify the
wrapper with AXI address and write data arriving in either order, a stalled
response, and error responses for invalid accesses. The board handoff needs a
Vivado implementation report and a live START-to-DONE trace with a 64/64 board
readback match.

Keep the [shared interface contract](RAVEN_INTERFACE_CONTRACT.md) as the home
for future DMA ownership, wider workload support, and command capabilities.
This fixture can use fixed preload today. The board-side control bridge and
memory adapter provide the extension points for runtime loading later.
