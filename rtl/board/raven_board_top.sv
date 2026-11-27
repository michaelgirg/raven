`default_nettype none
// Board prototype wrapper (§5.3 of docs/plans/nahjay_board_prototype.md).
//
//   JTAG-to-AXI --AXI4-Lite--> raven_axil_bridge --reg bus--> raven_npu_top
//                                     \--out0_rd--> OUT0 source
//
// The only external ports are one AXI4-Lite slave plus its clock and reset; every bank
// port is internal. The block design reaches this module through raven_board_top_v (B8).
//
// Clock and reset (B6, B9): aclk is the single pl_clk0. aresetn must already be
// synchronized to aclk; the block design drives it from proc_sys_reset
// peripheral_aresetn. The bridge and the NPU register block stay on aresetn, so the host
// can read diagnostics and issue SOFT_RESET while local_rst_no holds the datapath.
//
// OUT0_SOURCE selects what answers OUT0 readback:
//   "PATTERN"  raven_out0_pattern (B7). The NPU bank ports are tied idle: reads and OUT0
//              writes are never accepted, so a GEMM START stays in RUN until SOFT_RESET.
//              NOP commands retire normally. Use this for bridge/JTAG bring-up.
//   "MEMORY"   the BRAM-backed bank adapter (open item O1). Not available yet;
//              elaboration fails until it is connected.
module raven_board_top #(
    parameter string OUT0_SOURCE = "PATTERN", // "PATTERN" or "MEMORY".
    parameter int OUT0_LATENCY = 1, // Pattern responder latency, in extra clocks.
    parameter bit USE_TILE_BUFFERS = 1 // Passed to raven_npu_top.
) (
    input wire aclk, // pl_clk0, 50 MHz for bring-up.
    input wire aresetn, // Board reset, active low, synchronous to aclk.
    // AXI4-Lite slave (14-bit window: CSR 0x0000, unmapped 0x1000, OUT0 0x2000).
    input wire [13:0] s_axi_awaddr,
    input wire [2:0] s_axi_awprot,
    input wire s_axi_awvalid,
    output wire s_axi_awready,
    input wire [31:0] s_axi_wdata,
    input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid,
    output wire s_axi_wready,
    output wire [1:0] s_axi_bresp,
    output wire s_axi_bvalid,
    input wire s_axi_bready,
    input wire [13:0] s_axi_araddr,
    input wire [2:0] s_axi_arprot,
    input wire s_axi_arvalid,
    output wire s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0] s_axi_rresp,
    output wire s_axi_rvalid,
    input wire s_axi_rready
);
    // Bridge <-> NPU register bus.
    wire reg_valid, reg_ready, reg_write, reg_rvalid, reg_error;
    wire [11:0] reg_addr;
    wire [31:0] reg_wdata, reg_rdata;
    // Datapath/bank reset from the NPU (soft reset or latched integrity fault).
    wire local_rst_n;
    // Bridge <-> OUT0 source.
    wire out0_rq_valid, out0_rq_ready, out0_rs_valid, out0_rs_ready;
    wire [12:0] out0_rq_addr;
    wire [127:0] out0_rs_data;
    // NPU bank ports. Index: 0 ACT0, 1 ACT1, 2 WGT0, 3 WGT1, 4 PRM port A, 5 PRM port B.
    wire [5:0] bank_rq_valid, bank_rq_ready, bank_rs_valid, bank_rs_ready;
    wire [23:0] bank_rq_addr [6];
    wire [127:0] bank_rs_data [6];
    wire out0_w_valid, out0_w_ready;
    wire [23:0] out0_w_addr;
    wire [127:0] out0_w_data;
    wire [15:0] out0_w_strb;

    raven_axil_bridge u_bridge (
        .s_axi_aclk(aclk), .s_axi_aresetn(aresetn),
        .s_axi_awaddr, .s_axi_awprot, .s_axi_awvalid, .s_axi_awready,
        .s_axi_wdata, .s_axi_wstrb, .s_axi_wvalid, .s_axi_wready,
        .s_axi_bresp, .s_axi_bvalid, .s_axi_bready,
        .s_axi_araddr, .s_axi_arprot, .s_axi_arvalid, .s_axi_arready,
        .s_axi_rdata, .s_axi_rresp, .s_axi_rvalid, .s_axi_rready,
        .reg_valid_o(reg_valid), .reg_ready_i(reg_ready), .reg_write_o(reg_write),
        .reg_addr_o(reg_addr), .reg_wdata_o(reg_wdata), .reg_rdata_i(reg_rdata),
        .reg_rvalid_i(reg_rvalid), .reg_error_i(reg_error),
        .local_rst_ni(local_rst_n),
        .out0_rd_req_valid_o(out0_rq_valid), .out0_rd_req_ready_i(out0_rq_ready),
        .out0_rd_req_addr_o(out0_rq_addr),
        .out0_rd_rsp_valid_i(out0_rs_valid), .out0_rd_rsp_ready_o(out0_rs_ready),
        .out0_rd_rsp_data_i(out0_rs_data));

    raven_npu_top #(.USE_TILE_BUFFERS(USE_TILE_BUFFERS)) u_npu (
        .clk_i(aclk), .rst_ni(aresetn),
        .reg_valid_i(reg_valid), .reg_ready_o(reg_ready), .reg_write_i(reg_write),
        .reg_addr_i(reg_addr), .reg_wdata_i(reg_wdata), .reg_rdata_o(reg_rdata),
        .reg_rvalid_o(reg_rvalid), .reg_error_o(reg_error),
        .npu_irq_o(), // B10: polled, no interrupt on the board.
        .local_rst_no(local_rst_n),
        .act0_req_valid_o(bank_rq_valid[0]), .act0_req_ready_i(bank_rq_ready[0]), .act0_req_addr_o(bank_rq_addr[0]),
        .act0_rsp_valid_i(bank_rs_valid[0]), .act0_rsp_ready_o(bank_rs_ready[0]), .act0_rsp_data_i(bank_rs_data[0]),
        .act1_req_valid_o(bank_rq_valid[1]), .act1_req_ready_i(bank_rq_ready[1]), .act1_req_addr_o(bank_rq_addr[1]),
        .act1_rsp_valid_i(bank_rs_valid[1]), .act1_rsp_ready_o(bank_rs_ready[1]), .act1_rsp_data_i(bank_rs_data[1]),
        .wgt0_req_valid_o(bank_rq_valid[2]), .wgt0_req_ready_i(bank_rq_ready[2]), .wgt0_req_addr_o(bank_rq_addr[2]),
        .wgt0_rsp_valid_i(bank_rs_valid[2]), .wgt0_rsp_ready_o(bank_rs_ready[2]), .wgt0_rsp_data_i(bank_rs_data[2]),
        .wgt1_req_valid_o(bank_rq_valid[3]), .wgt1_req_ready_i(bank_rq_ready[3]), .wgt1_req_addr_o(bank_rq_addr[3]),
        .wgt1_rsp_valid_i(bank_rs_valid[3]), .wgt1_rsp_ready_o(bank_rs_ready[3]), .wgt1_rsp_data_i(bank_rs_data[3]),
        .prm_a_req_valid_o(bank_rq_valid[4]), .prm_a_req_ready_i(bank_rq_ready[4]), .prm_a_req_addr_o(bank_rq_addr[4]),
        .prm_a_rsp_valid_i(bank_rs_valid[4]), .prm_a_rsp_ready_o(bank_rs_ready[4]), .prm_a_rsp_data_i(bank_rs_data[4]),
        .prm_b_req_valid_o(bank_rq_valid[5]), .prm_b_req_ready_i(bank_rq_ready[5]), .prm_b_req_addr_o(bank_rq_addr[5]),
        .prm_b_rsp_valid_i(bank_rs_valid[5]), .prm_b_rsp_ready_o(bank_rs_ready[5]), .prm_b_rsp_data_i(bank_rs_data[5]),
        .out0_w_valid_o(out0_w_valid), .out0_w_ready_i(out0_w_ready), .out0_w_addr_o(out0_w_addr),
        .out0_w_data_o(out0_w_data), .out0_w_strb_o(out0_w_strb));

    if (OUT0_SOURCE == "PATTERN") begin : g_pattern
        raven_out0_pattern #(.LATENCY(OUT0_LATENCY)) u_out0 (
            .clk_i(aclk), .local_rst_ni(local_rst_n),
            .req_valid_i(out0_rq_valid), .req_ready_o(out0_rq_ready), .req_addr_i(out0_rq_addr),
            .rsp_valid_o(out0_rs_valid), .rsp_ready_i(out0_rs_ready), .rsp_data_o(out0_rs_data));
        // No backing storage: never accept a bank read or an OUT0 write.
        assign bank_rq_ready = '0;
        assign bank_rs_valid = '0;
        for (genvar b = 0; b < 6; b++) begin : g_idle
            assign bank_rs_data[b] = '0;
        end
        assign out0_w_ready = 1'b0;
    end else if (OUT0_SOURCE == "MEMORY") begin : g_memory
        raven_memory_banks #(
            .ACT0_INIT_FILE("build/prototype/fixtures/normal_8x16x8/act.hex"),
            .WGT0_INIT_FILE("build/prototype/fixtures/normal_8x16x8/wgt.hex"),
            .PRM_INIT_FILE("build/prototype/fixtures/normal_8x16x8/prm.hex")
        ) u_memory (
            .clk_i(aclk),
            .rst_ni(local_rst_n),

            // OUT0 writes from NPU
            .out0_w_valid_i(out0_w_valid),
            .out0_w_ready_o(out0_w_ready),
            .out0_w_addr_i(out0_w_addr),
            .out0_w_data_i(out0_w_data),
            .out0_w_strb_i(out0_w_strb),

            // OUT0 readback toward AXI bridge
            .out0_rd_req_valid_i(out0_rq_valid),
            .out0_rd_req_ready_o(out0_rq_ready),
            .out0_rd_req_addr_i({11'b0, out0_rq_addr}),
            .out0_rd_rsp_valid_o(out0_rs_valid),
            .out0_rd_rsp_ready_i(out0_rs_ready),
            .out0_rd_rsp_data_o(out0_rs_data),

            // ACT0
            .act0_req_valid_i(bank_rq_valid[0]),
            .act0_req_ready_o(bank_rq_ready[0]),
            .act0_req_addr_i(bank_rq_addr[0]),
            .act0_rsp_valid_o(bank_rs_valid[0]),
            .act0_rsp_ready_i(bank_rs_ready[0]),
            .act0_rsp_data_o(bank_rs_data[0]),

            // ACT1
            .act1_req_valid_i(bank_rq_valid[1]),
            .act1_req_ready_o(bank_rq_ready[1]),
            .act1_req_addr_i(bank_rq_addr[1]),
            .act1_rsp_valid_o(bank_rs_valid[1]),
            .act1_rsp_ready_i(bank_rs_ready[1]),
            .act1_rsp_data_o(bank_rs_data[1]),

            // WGT0
            .wgt0_req_valid_i(bank_rq_valid[2]),
            .wgt0_req_ready_o(bank_rq_ready[2]),
            .wgt0_req_addr_i(bank_rq_addr[2]),
            .wgt0_rsp_valid_o(bank_rs_valid[2]),
            .wgt0_rsp_ready_i(bank_rs_ready[2]),
            .wgt0_rsp_data_o(bank_rs_data[2]),

            // WGT1
            .wgt1_req_valid_i(bank_rq_valid[3]),
            .wgt1_req_ready_o(bank_rq_ready[3]),
            .wgt1_req_addr_i(bank_rq_addr[3]),
            .wgt1_rsp_valid_o(bank_rs_valid[3]),
            .wgt1_rsp_ready_i(bank_rs_ready[3]),
            .wgt1_rsp_data_o(bank_rs_data[3]),

            // PRM port A
            .prm_a_req_valid_i(bank_rq_valid[4]),
            .prm_a_req_ready_o(bank_rq_ready[4]),
            .prm_a_req_addr_i(bank_rq_addr[4]),
            .prm_a_rsp_valid_o(bank_rs_valid[4]),
            .prm_a_rsp_ready_i(bank_rs_ready[4]),
            .prm_a_rsp_data_o(bank_rs_data[4]),

            // PRM port B
            .prm_b_req_valid_i(bank_rq_valid[5]),
            .prm_b_req_ready_o(bank_rq_ready[5]),
            .prm_b_req_addr_i(bank_rq_addr[5]),
            .prm_b_rsp_valid_o(bank_rs_valid[5]),
            .prm_b_rsp_ready_i(bank_rs_ready[5]),
            .prm_b_rsp_data_o(bank_rs_data[5]),

            // Disable host writes to preloaded input banks
            .act0_w_valid_i(1'b0),
            .act0_w_ready_o(),
            .act0_w_addr_i(24'd0),
            .act0_w_data_i(128'd0),
            .act0_w_strb_i(16'd0),

            .act1_w_valid_i(1'b0),
            .act1_w_ready_o(),
            .act1_w_addr_i(24'd0),
            .act1_w_data_i(128'd0),
            .act1_w_strb_i(16'd0),

            .wgt0_w_valid_i(1'b0),
            .wgt0_w_ready_o(),
            .wgt0_w_addr_i(24'd0),
            .wgt0_w_data_i(128'd0),
            .wgt0_w_strb_i(16'd0),

            .wgt1_w_valid_i(1'b0),
            .wgt1_w_ready_o(),
            .wgt1_w_addr_i(24'd0),
            .wgt1_w_data_i(128'd0),
            .wgt1_w_strb_i(16'd0),

            .prm_w_valid_i(1'b0),
            .prm_w_ready_o(),
            .prm_w_addr_i(24'd0),
            .prm_w_data_i(128'd0),
            .prm_w_strb_i(16'd0)
        );

    end else begin : g_unsupported
        initial $error("Invalid OUT0_SOURCE");
    end
endmodule
`default_nettype wire
