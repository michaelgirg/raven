`default_nettype none
// AXI4-Lite slave for the board prototype: NPU registers and read-only OUT0.
//
// Window (byte offset inside the 16 KiB slave, B1 of docs/plans/nahjay_board_prototype.md):
//   0x0000-0x0FFF  NPU register bus (raven_npu_top reg_*), low 12 bits passed through
//   0x1000-0x1FFF  unmapped: DECERR
//   0x2000-0x3FFF  OUT0 readback through the out0_rd port; writes get SLVERR
//
// One transaction is in flight at a time (B3). AW and W are captured independently in
// either order; a write starts once both are held. A read is accepted only while no write
// address or data is held or presented, so a write offered on the same clock as a read goes
// first. Each access reaches the NPU or OUT0 at most once. B and R stay valid and stable
// until the master accepts them.
//
// Errors (B2), none of which reaches the NPU or memory: unaligned address, CSR write with a
// partial strobe, any OUT0 write -> SLVERR; unmapped hole -> DECERR. An NPU reg_error_i
// response becomes SLVERR.
//
// OUT0 reads (B4) align the offset down to 16 bytes, issue one request and return the
// 32-bit lane selected by offset[3:2]. The memory flushes on local_rst_ni, so a read issued
// or pending while the datapath is in reset completes with SLVERR instead of waiting (B5).
//
// The bridge and the NPU register block share the board reset (B6), so the host can
// still read diagnostics and issue SOFT_RESET while local_rst_ni holds the datapath.
module raven_axil_bridge (
    input wire s_axi_aclk, // Single board clock (pl_clk0).
    input wire s_axi_aresetn, // Board reset, active low, synchronous to s_axi_aclk.
    // AXI4-Lite write address channel.
    input wire [13:0] s_axi_awaddr, // Byte offset inside the 16 KiB window.
    input wire [2:0] s_axi_awprot, // Ignored.
    input wire s_axi_awvalid, // Write address presented.
    output wire s_axi_awready, // Write address captured.
    // AXI4-Lite write data channel.
    input wire [31:0] s_axi_wdata, // Write data.
    input wire [3:0] s_axi_wstrb, // Byte strobes; CSR writes must be 4'hF.
    input wire s_axi_wvalid, // Write data presented.
    output wire s_axi_wready, // Write data captured.
    // AXI4-Lite write response channel.
    output wire [1:0] s_axi_bresp, // OKAY, SLVERR or DECERR.
    output wire s_axi_bvalid, // Write response presented.
    input wire s_axi_bready, // Write response accepted.
    // AXI4-Lite read address channel.
    input wire [13:0] s_axi_araddr, // Byte offset inside the 16 KiB window.
    input wire [2:0] s_axi_arprot, // Ignored.
    input wire s_axi_arvalid, // Read address presented.
    output wire s_axi_arready, // Read address accepted.
    // AXI4-Lite read data channel.
    output wire [31:0] s_axi_rdata, // Read data (0 on an error response).
    output wire [1:0] s_axi_rresp, // OKAY, SLVERR or DECERR.
    output wire s_axi_rvalid, // Read response presented.
    input wire s_axi_rready, // Read response accepted.
    // NPU register bus (raven_npu_top reg_*).
    output wire reg_valid_o, // Native access presented.
    input wire reg_ready_i, // NPU accepts it.
    output wire reg_write_o, // 1 = write, 0 = read.
    output wire [11:0] reg_addr_o, // NPU register offset.
    output wire [31:0] reg_wdata_o, // Write data.
    input wire [31:0] reg_rdata_i, // Read data, valid with reg_rvalid_i.
    input wire reg_rvalid_i, // Response for the accepted access.
    input wire reg_error_i, // NPU rejected the access, valid with reg_rvalid_i.
    // OUT0 logical read port.
    input wire local_rst_ni, // Datapath/bank reset from raven_npu_top local_rst_no.
    output wire out0_rd_req_valid_o, // Read request presented.
    input wire out0_rd_req_ready_i, // OUT0 accepts the request.
    output wire [12:0] out0_rd_req_addr_o, // 16-byte-aligned bank-local byte offset.
    input wire out0_rd_rsp_valid_i, // Read data presented.
    output wire out0_rd_rsp_ready_o, // Read data accepted.
    input wire [127:0] out0_rd_rsp_data_i // Byte addr+n in bits [8*n +: 8].
);
    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;
    localparam logic [1:0] RESP_DECERR = 2'b11;

    // Window regions, selected by offset[13:12].
    localparam logic [1:0] REGION_CSR   = 2'd0;
    localparam logic [1:0] REGION_UNMAP = 2'd1;

    typedef enum logic [2:0] {
        S_IDLE,     // Capture AW/W, accept AR, decode.
        S_REG_REQ,  // Present the native register access.
        S_REG_RSP,  // Wait for the register response.
        S_OUT_REQ,  // Present the OUT0 read request.
        S_OUT_RSP,  // Wait for the OUT0 read response.
        S_B,        // Hold the write response.
        S_R         // Hold the read response.
    } state_e;

    state_e state_q;
    logic aw_held_q, w_held_q; // Write address / data captured, write not yet started.
    logic [13:0] aw_addr_q;
    logic [31:0] w_data_q;
    logic [3:0] w_strb_q;
    logic op_write_q; // The native register access is a write.
    logic [11:0] op_addr_q; // Native register offset.
    logic [12:0] out_addr_q; // OUT0 byte offset of the current read.
    logic [1:0] resp_q; // Response for S_B / S_R.
    logic [31:0] rdata_q; // Read data for S_R.

    wire idle = state_q == S_IDLE;
    wire write_ready = aw_held_q && w_held_q;
    // Write wins: a read is accepted only when no write is held or being offered.
    wire ar_ok = idle && !aw_held_q && !w_held_q && !s_axi_awvalid && !s_axi_wvalid;

    assign s_axi_awready = idle && !aw_held_q;
    assign s_axi_wready = idle && !w_held_q;
    assign s_axi_arready = ar_ok;
    assign s_axi_bvalid = state_q == S_B;
    assign s_axi_bresp = resp_q;
    assign s_axi_rvalid = state_q == S_R;
    assign s_axi_rresp = resp_q;
    assign s_axi_rdata = rdata_q;

    assign reg_valid_o = state_q == S_REG_REQ;
    assign reg_write_o = op_write_q;
    assign reg_addr_o = op_addr_q;
    assign reg_wdata_o = w_data_q;

    // The memory is in reset whenever local_rst_ni is low, so never handshake then.
    assign out0_rd_req_valid_o = state_q == S_OUT_REQ && local_rst_ni;
    assign out0_rd_req_addr_o = {out_addr_q[12:4], 4'd0};
    assign out0_rd_rsp_ready_o = state_q == S_OUT_RSP && local_rst_ni;

    // 32-bit lane offset[3:2] of a 128-bit OUT0 word.
    function automatic logic [31:0] out_lane(input logic [127:0] word, input logic [1:0] lane);
        return word[32*lane +: 32];
    endfunction

    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            state_q <= S_IDLE;
            aw_held_q <= 0; w_held_q <= 0;
            aw_addr_q <= '0; w_data_q <= '0; w_strb_q <= '0;
            op_write_q <= 0; op_addr_q <= '0; out_addr_q <= '0;
            resp_q <= RESP_OKAY; rdata_q <= '0;
        end else begin
            case (state_q)
                S_IDLE: begin
                    if (s_axi_awvalid && s_axi_awready) begin
                        aw_held_q <= 1; aw_addr_q <= s_axi_awaddr;
                    end
                    if (s_axi_wvalid && s_axi_wready) begin
                        w_held_q <= 1; w_data_q <= s_axi_wdata; w_strb_q <= s_axi_wstrb;
                    end
                    if (write_ready) begin
                        // Both halves are held, so AW/W ready are low this clock.
                        aw_held_q <= 0; w_held_q <= 0;
                        op_write_q <= 1; op_addr_q <= aw_addr_q[11:0];
                        rdata_q <= '0;
                        if (|aw_addr_q[1:0]) begin
                            resp_q <= RESP_SLVERR; state_q <= S_B;
                        end else if (aw_addr_q[13:12] == REGION_UNMAP) begin
                            resp_q <= RESP_DECERR; state_q <= S_B;
                        end else if (aw_addr_q[13:12] != REGION_CSR || w_strb_q != 4'hF) begin
                            resp_q <= RESP_SLVERR; state_q <= S_B; // OUT0 write or partial strobe.
                        end else state_q <= S_REG_REQ;
                    end else if (s_axi_arvalid && ar_ok) begin
                        op_write_q <= 0; op_addr_q <= s_axi_araddr[11:0];
                        out_addr_q <= s_axi_araddr[12:0];
                        rdata_q <= '0;
                        if (|s_axi_araddr[1:0]) begin
                            resp_q <= RESP_SLVERR; state_q <= S_R;
                        end else if (s_axi_araddr[13:12] == REGION_CSR) state_q <= S_REG_REQ;
                        else if (s_axi_araddr[13:12] == REGION_UNMAP) begin
                            resp_q <= RESP_DECERR; state_q <= S_R;
                        end else if (!local_rst_ni) begin
                            resp_q <= RESP_SLVERR; state_q <= S_R;
                        end else state_q <= S_OUT_REQ;
                    end
                end
                S_REG_REQ: if (reg_ready_i) state_q <= S_REG_RSP;
                S_REG_RSP: if (reg_rvalid_i) begin
                    resp_q <= reg_error_i ? RESP_SLVERR : RESP_OKAY;
                    rdata_q <= op_write_q || reg_error_i ? 32'd0 : reg_rdata_i;
                    state_q <= op_write_q ? S_B : S_R;
                end
                S_OUT_REQ: begin
                    if (!local_rst_ni) begin
                        resp_q <= RESP_SLVERR; state_q <= S_R;
                    end else if (out0_rd_req_ready_i) state_q <= S_OUT_RSP;
                end
                S_OUT_RSP: begin
                    if (!local_rst_ni) begin
                        resp_q <= RESP_SLVERR; state_q <= S_R;
                    end else if (out0_rd_rsp_valid_i) begin
                        resp_q <= RESP_OKAY;
                        rdata_q <= out_lane(out0_rd_rsp_data_i, out_addr_q[3:2]);
                        state_q <= S_R;
                    end
                end
                S_B: if (s_axi_bready) state_q <= S_IDLE;
                S_R: if (s_axi_rready) state_q <= S_IDLE;
                default: state_q <= S_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    // The two native ports are never used together.
    assert property (@(posedge s_axi_aclk) disable iff (!s_axi_aresetn)
        !(reg_valid_o && out0_rd_req_valid_o));
    // One native access per transaction: each request is dropped right after its handshake.
    assert property (@(posedge s_axi_aclk) disable iff (!s_axi_aresetn)
        reg_valid_o && reg_ready_i |=> !reg_valid_o);
    assert property (@(posedge s_axi_aclk) disable iff (!s_axi_aresetn)
        out0_rd_req_valid_o && out0_rd_req_ready_i |=> !out0_rd_req_valid_o);
    // Native requests hold their payload while stalled.
    assert property (@(posedge s_axi_aclk) disable iff (!s_axi_aresetn)
        reg_valid_o && !reg_ready_i |=> reg_valid_o && $stable({reg_write_o, reg_addr_o, reg_wdata_o}));
    // OUT0 is never written and never read for a write transaction.
    assert property (@(posedge s_axi_aclk) disable iff (!s_axi_aresetn)
        out0_rd_req_valid_o |-> !op_write_q);
    // AXI responses stay valid and stable until accepted.
    assert property (@(posedge s_axi_aclk) disable iff (!s_axi_aresetn)
        s_axi_bvalid && !s_axi_bready |=> s_axi_bvalid && $stable(s_axi_bresp));
    assert property (@(posedge s_axi_aclk) disable iff (!s_axi_aresetn)
        s_axi_rvalid && !s_axi_rready |=> s_axi_rvalid && $stable({s_axi_rresp, s_axi_rdata}));
    // Never both response channels at once.
    assert property (@(posedge s_axi_aclk) disable iff (!s_axi_aresetn)
        !(s_axi_bvalid && s_axi_rvalid));
`endif
endmodule
`default_nettype wire
