`default_nettype none
// TESTBENCH ONLY: AXI4-Lite bridge tests W1-W12 (docs/plans/nahjay_board_prototype.md §8).
//
// axil_master_pkg drives raven_axil_bridge, which talks to the real raven_npu_top and to
// raven_out0_pattern on the out0_rd port. The NPU bank ports use the integration sim
// memories; no GEMM runs here. The bridge and NPU share the board reset (B6). The datapath
// reset seen by the bridge and the pattern responder is the NPU's local_rst_no ANDed with
// fault_inject, which models a latched staging fault holding the datapath in reset.
//
// Independent monitors, all immediate checks so they run without SVA support:
//   - count native register and OUT0 accesses and log their order;
//   - require B/R to stay valid and stable while stalled;
//   - forbid native accesses while a response is held, and both native ports at once;
//   - forbid any B or R response without a matching outstanding request (stale responses).
//
// With BOARD_TOP=1 the same tests run against raven_board_top_v in "PATTERN" mode instead:
// the Verilog shell, wrapper, bridge, NPU and pattern responder exactly as the block design
// instantiates them, with tied-idle bank ports. The monitors observe the wrapper's internal
// nets hierarchically, and fault_inject forces the wrapper's datapath reset net low.
//
// Plusargs: +TESTS=<list> (e.g. "W1,W4"; default all), +SEED=<n> (default 1).
module tb_raven_axil_bridge #(
    parameter int OUT0_LATENCY = 4, // Pattern responder latency; the runner also uses 0.
    parameter bit BOARD_TOP = 0, // 1: test raven_board_top_v instead of the separate parts.
    parameter bit BOARD_MEMORY = 0
);
    import raven_ctrl_pkg::*;
    import axil_master_pkg::*;

    localparam int WATCHDOG_CYCLES = 500_000;
    localparam logic [7:0] PATTERN_KEY = 8'h5A;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic fault_inject = 0; // Hold the datapath view of reset low (models a latched fault).

    raven_axil_if axi(clk);

    // Bridge <-> NPU register bus.
    wire reg_valid, reg_ready, reg_write, reg_rvalid, reg_error;
    wire [11:0] reg_addr;
    wire [31:0] reg_wdata, reg_rdata;
    // Bridge <-> OUT0 pattern.
    wire o_rq_valid, o_rq_ready, o_rs_valid, o_rs_ready;
    wire [12:0] o_rq_addr;
    wire [127:0] o_rs_data;
    wire lrst_n; // NPU local_rst_no.
    wire dp_rst_n = lrst_n && !fault_inject;

    if (!BOARD_TOP) begin : g_parts
    raven_axil_bridge dut (
        .s_axi_aclk(clk), .s_axi_aresetn(rst_n),
        .s_axi_awaddr(axi.awaddr), .s_axi_awprot(3'd0), .s_axi_awvalid(axi.awvalid), .s_axi_awready(axi.awready),
        .s_axi_wdata(axi.wdata), .s_axi_wstrb(axi.wstrb), .s_axi_wvalid(axi.wvalid), .s_axi_wready(axi.wready),
        .s_axi_bresp(axi.bresp), .s_axi_bvalid(axi.bvalid), .s_axi_bready(axi.bready),
        .s_axi_araddr(axi.araddr), .s_axi_arprot(3'd0), .s_axi_arvalid(axi.arvalid), .s_axi_arready(axi.arready),
        .s_axi_rdata(axi.rdata), .s_axi_rresp(axi.rresp), .s_axi_rvalid(axi.rvalid), .s_axi_rready(axi.rready),
        .reg_valid_o(reg_valid), .reg_ready_i(reg_ready), .reg_write_o(reg_write), .reg_addr_o(reg_addr),
        .reg_wdata_o(reg_wdata), .reg_rdata_i(reg_rdata), .reg_rvalid_i(reg_rvalid), .reg_error_i(reg_error),
        .local_rst_ni(dp_rst_n),
        .out0_rd_req_valid_o(o_rq_valid), .out0_rd_req_ready_i(o_rq_ready), .out0_rd_req_addr_o(o_rq_addr),
        .out0_rd_rsp_valid_i(o_rs_valid), .out0_rd_rsp_ready_o(o_rs_ready), .out0_rd_rsp_data_i(o_rs_data));

    raven_out0_pattern #(.LATENCY(OUT0_LATENCY)) u_pattern (
        .clk_i(clk), .local_rst_ni(dp_rst_n),
        .req_valid_i(o_rq_valid), .req_ready_o(o_rq_ready), .req_addr_i(o_rq_addr),
        .rsp_valid_o(o_rs_valid), .rsp_ready_i(o_rs_ready), .rsp_data_o(o_rs_data));

    // NPU bank wiring. Index: 0 ACT0, 1 ACT1, 2 WGT0, 3 WGT1, 4 PRM port A, 5 PRM port B.
    wire rq_valid [6], rq_ready [6], rs_valid [6], rs_ready [6];
    wire [23:0] rq_addr [6];
    wire [127:0] rs_data [6];
    wire [31:0] bank_reads [6];
    wire ow_valid, ow_ready;
    wire [23:0] ow_addr;
    wire [127:0] ow_data;
    wire [15:0] ow_strb;
    wire [31:0] out_writes, out_last_cycle;

    raven_npu_top npu (
        .clk_i(clk), .rst_ni(rst_n),
        .reg_valid_i(reg_valid), .reg_ready_o(reg_ready), .reg_write_i(reg_write), .reg_addr_i(reg_addr),
        .reg_wdata_i(reg_wdata), .reg_rdata_o(reg_rdata), .reg_rvalid_o(reg_rvalid), .reg_error_o(reg_error),
        .npu_irq_o(), .local_rst_no(lrst_n),
        .act0_req_valid_o(rq_valid[0]), .act0_req_ready_i(rq_ready[0]), .act0_req_addr_o(rq_addr[0]),
        .act0_rsp_valid_i(rs_valid[0]), .act0_rsp_ready_o(rs_ready[0]), .act0_rsp_data_i(rs_data[0]),
        .act1_req_valid_o(rq_valid[1]), .act1_req_ready_i(rq_ready[1]), .act1_req_addr_o(rq_addr[1]),
        .act1_rsp_valid_i(rs_valid[1]), .act1_rsp_ready_o(rs_ready[1]), .act1_rsp_data_i(rs_data[1]),
        .wgt0_req_valid_o(rq_valid[2]), .wgt0_req_ready_i(rq_ready[2]), .wgt0_req_addr_o(rq_addr[2]),
        .wgt0_rsp_valid_i(rs_valid[2]), .wgt0_rsp_ready_o(rs_ready[2]), .wgt0_rsp_data_i(rs_data[2]),
        .wgt1_req_valid_o(rq_valid[3]), .wgt1_req_ready_i(rq_ready[3]), .wgt1_req_addr_o(rq_addr[3]),
        .wgt1_rsp_valid_i(rs_valid[3]), .wgt1_rsp_ready_o(rs_ready[3]), .wgt1_rsp_data_i(rs_data[3]),
        .prm_a_req_valid_o(rq_valid[4]), .prm_a_req_ready_i(rq_ready[4]), .prm_a_req_addr_o(rq_addr[4]),
        .prm_a_rsp_valid_i(rs_valid[4]), .prm_a_rsp_ready_o(rs_ready[4]), .prm_a_rsp_data_i(rs_data[4]),
        .prm_b_req_valid_o(rq_valid[5]), .prm_b_req_ready_i(rq_ready[5]), .prm_b_req_addr_o(rq_addr[5]),
        .prm_b_rsp_valid_i(rs_valid[5]), .prm_b_rsp_ready_o(rs_ready[5]), .prm_b_rsp_data_i(rs_data[5]),
        .out0_w_valid_o(ow_valid), .out0_w_ready_i(ow_ready), .out0_w_addr_o(ow_addr),
        .out0_w_data_o(ow_data), .out0_w_strb_o(ow_strb));

    for (genvar b = 0; b < 6; b++) begin : g_bank
        localparam int BYTES = b < 4 ? ACT_BYTES : PRM_BYTES;
        sim_read_memory #(.BYTES(BYTES), .SEED(21 + b)) m_read (.clk_i(clk), .rst_ni(lrst_n), .stalls_i(1'b0),
            .req_valid_i(rq_valid[b]), .req_ready_o(rq_ready[b]), .req_addr_i(rq_addr[b]),
            .rsp_valid_o(rs_valid[b]), .rsp_ready_i(rs_ready[b]), .rsp_data_o(rs_data[b]),
            .reads_o(bank_reads[b]));
    end
    sim_write_memory #(.BYTES(OUT0_BYTES), .SEED(27)) m_out0 (.clk_i(clk), .rst_ni(lrst_n), .stalls_i(1'b0),
        .w_valid_i(ow_valid), .w_ready_o(ow_ready), .w_addr_i(ow_addr), .w_data_i(ow_data),
        .w_strb_i(ow_strb), .writes_o(out_writes), .last_write_cycle_o(out_last_cycle));
    end else begin : g_board
        raven_board_top_v #(.OUT0_MEMORY(BOARD_MEMORY), .OUT0_LATENCY(OUT0_LATENCY)) u_board (
            .aclk(clk), .aresetn(rst_n),
            .s_axi_awaddr(32'(axi.awaddr)), .s_axi_awprot(3'd0), .s_axi_awvalid(axi.awvalid), .s_axi_awready(axi.awready),
            .s_axi_wdata(axi.wdata), .s_axi_wstrb(axi.wstrb), .s_axi_wvalid(axi.wvalid), .s_axi_wready(axi.wready),
            .s_axi_bresp(axi.bresp), .s_axi_bvalid(axi.bvalid), .s_axi_bready(axi.bready),
            .s_axi_araddr(32'(axi.araddr)), .s_axi_arprot(3'd0), .s_axi_arvalid(axi.arvalid), .s_axi_arready(axi.arready),
            .s_axi_rdata(axi.rdata), .s_axi_rresp(axi.rresp), .s_axi_rvalid(axi.rvalid), .s_axi_rready(axi.rready));
        // Observe the wrapper's internal nets for the monitors.
        assign reg_valid = u_board.u_top.reg_valid;
        assign reg_ready = u_board.u_top.reg_ready;
        assign reg_write = u_board.u_top.reg_write;
        assign reg_addr = u_board.u_top.reg_addr;
        assign o_rq_valid = u_board.u_top.out0_rq_valid;
        assign o_rq_ready = u_board.u_top.out0_rq_ready;
        assign o_rq_addr = u_board.u_top.out0_rq_addr;
        assign lrst_n = u_board.u_top.local_rst_n;
        // A latched fault holds the datapath reset low inside the wrapper.
        always @(fault_inject)
            if (fault_inject) force u_board.u_top.local_rst_n = 1'b0;
            else release u_board.u_top.local_rst_n;
        // The pattern source never lets the NPU touch a bank.
        always @(posedge clk)
            if (rst_n && (u_board.u_top.out0_w_valid && u_board.u_top.out0_w_ready))
                $fatal(1, "CHECK FAILED: OUT0 write accepted in PATTERN mode");
    end

    // ---------------------------------------------------------------- monitors
    longint unsigned cycle;
    int unsigned native_reg; // Accepted native register accesses.
    int unsigned native_out; // Accepted OUT0 read requests.
    bit native_log [$]; // Per native register access: 1 = write.
    logic [11:0] last_reg_addr;
    logic [12:0] last_out_addr;
    int unsigned b_stall_cycles, r_stall_cycles; // Clocks a response waited on the master.
    // Outstanding-request bookkeeping for the stale-response check. Cleared by board reset.
    int unsigned aw_hs, w_hs, ar_hs, b_hs, r_hs;
    logic prev_bvalid, prev_bready, prev_rvalid, prev_rready;
    logic [1:0] prev_bresp, prev_rresp;
    logic [31:0] prev_rdata;

    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (cycle > WATCHDOG_CYCLES) $fatal(1, "Watchdog: simulation exceeded %0d cycles", WATCHDOG_CYCLES);
        if (reg_valid && reg_ready) begin
            native_reg <= native_reg + 1; native_log.push_back(reg_write); last_reg_addr <= reg_addr;
        end
        if (o_rq_valid && o_rq_ready) begin native_out <= native_out + 1; last_out_addr <= o_rq_addr; end
        if (!rst_n) begin
            aw_hs <= 0; w_hs <= 0; ar_hs <= 0; b_hs <= 0; r_hs <= 0;
            prev_bvalid <= 0; prev_rvalid <= 0; prev_bready <= 0; prev_rready <= 0;
        end else begin
            if (axi.awvalid && axi.awready) aw_hs <= aw_hs + 1;
            if (axi.wvalid && axi.wready) w_hs <= w_hs + 1;
            if (axi.arvalid && axi.arready) ar_hs <= ar_hs + 1;
            if (axi.bvalid && axi.bready) b_hs <= b_hs + 1;
            if (axi.rvalid && axi.rready) r_hs <= r_hs + 1;
            if (axi.bvalid && !axi.bready) b_stall_cycles <= b_stall_cycles + 1;
            if (axi.rvalid && !axi.rready) r_stall_cycles <= r_stall_cycles + 1;
            // A response needs a request (a write needs both its address and its data).
            if (axi.bvalid && (aw_hs <= b_hs || w_hs <= b_hs))
                $fatal(1, "CHECK FAILED: write response without an outstanding write");
            if (axi.rvalid && ar_hs <= r_hs)
                $fatal(1, "CHECK FAILED: read response without an outstanding read");
            // Responses hold while stalled.
            if (prev_bvalid && !prev_bready && !(axi.bvalid && axi.bresp === prev_bresp))
                $fatal(1, "CHECK FAILED: B changed before it was accepted");
            if (prev_rvalid && !prev_rready
                && !(axi.rvalid && axi.rresp === prev_rresp && axi.rdata === prev_rdata))
                $fatal(1, "CHECK FAILED: R changed before it was accepted");
            // One transaction at a time: no native access while a response is held.
            if ((reg_valid || o_rq_valid) && (axi.bvalid || axi.rvalid))
                $fatal(1, "CHECK FAILED: native access while an AXI response is held");
            if (reg_valid && o_rq_valid) $fatal(1, "CHECK FAILED: both native ports active");
            prev_bvalid <= axi.bvalid; prev_bready <= axi.bready; prev_bresp <= axi.bresp;
            prev_rvalid <= axi.rvalid; prev_rready <= axi.rready; prev_rresp <= axi.rresp;
            prev_rdata <= axi.rdata;
        end
    end

    // ---------------------------------------------------------------- helpers
    string tests;
    int unsigned passed, checks;
    logic [1:0] resp_scratch; // Response of a write whose result is checked inline.

    function automatic bit want(input string t);
        if (tests == "") return 1;
        for (int i = 0; i + t.len() <= tests.len(); i++)
            if (tests.substr(i, i + t.len() - 1) == t
                && (i + t.len() == tests.len() || tests[i + t.len()] == ",")
                && (i == 0 || tests[i - 1] == ","))
                return 1;
        return 0;
    endfunction

    task automatic expect_eq(input string what, input logic [31:0] got, input logic [31:0] exp);
        checks++;
        if (got !== exp) $fatal(1, "CHECK FAILED: %s: got %08h expected %08h", what, got, exp);
    endtask

    task automatic pass(input string name);
        $display("PASS %s", name); passed++;
    endtask

    // OUT0 word at window address a, as the pattern responder defines it.
    function automatic logic [31:0] pattern32(input logic [13:0] a);
        logic [31:0] w;
        for (int n = 0; n < 4; n++) w[8*n +: 8] = 8'(a[12:0] + 13'(n)) ^ PATTERN_KEY;
        return w;
    endfunction

    // Response from an access that must fail before reaching the NPU or OUT0.
    task automatic expect_rejected_write(input string what, input logic [13:0] a, input logic [31:0] d,
                                         input logic [3:0] strb, input logic [1:0] exp_resp);
        int unsigned n_reg = native_reg, n_out = native_out;
        logic [1:0] r;
        axil_write(a, d, strb, ORDER_SAME, r);
        expect_eq({what, " resp"}, r, exp_resp);
        expect_eq({what, " no native access"}, (native_reg - n_reg) + (native_out - n_out), 0);
    endtask

    task automatic expect_rejected_read(input string what, input logic [13:0] a, input logic [1:0] exp_resp);
        int unsigned n_reg = native_reg, n_out = native_out;
        logic [31:0] d;
        logic [1:0] r;
        axil_read(a, d, r);
        expect_eq({what, " resp"}, r, exp_resp);
        expect_eq({what, " rdata"}, d, 0);
        expect_eq({what, " no native access"}, (native_reg - n_reg) + (native_out - n_out), 0);
    endtask

    task automatic board_reset(input int unsigned clocks = 4);
        @(negedge clk); rst_n = 0;
        axil_idle();
        repeat (clocks) @(negedge clk);
        rst_n = 1;
        @(negedge clk);
    endtask

    // ---------------------------------------------------------------- tests
    // W1: ID smoke.
    task automatic w1_id();
        logic [31:0] d;
        logic [1:0] r;
        axil_read(14'h0000, d, r);
        expect_eq("W1 ID", d, NPU_ID);
        expect_eq("W1 ID resp", r, AXI_OKAY);
        axil_read(14'h0004, d, r);
        expect_eq("W1 VERSION", d, NPU_VERSION);
        pass("w1_id");
    endtask

    // W2: every staging register, written in each channel order, reads back. One native
    // write per AXI write.
    task automatic w2_write_ordering();
        wr_order_e orders [3] = '{ORDER_SAME, ORDER_AW_FIRST, ORDER_W_FIRST};
        foreach (orders[o]) begin
            for (logic [13:0] a = 14'(REG_OPCODE); a <= 14'(REG_Q_CLAMP); a += 4) begin
                logic [31:0] v = $urandom, d;
                logic [1:0] r;
                int unsigned n = native_reg;
                axil_write(a, v, 4'hF, orders[o], r);
                expect_eq($sformatf("W2 %s write %03h resp", orders[o].name, a), r, AXI_OKAY);
                expect_eq($sformatf("W2 %s write %03h native", orders[o].name, a), native_reg - n, 1);
                expect_eq($sformatf("W2 %s write %03h kind", orders[o].name, a), native_log[$], 1);
                expect_eq($sformatf("W2 %s write %03h addr", orders[o].name, a), last_reg_addr, a[11:0]);
                axil_read32(a, d);
                expect_eq($sformatf("W2 %s readback %03h", orders[o].name, a), d, v);
            end
            pass($sformatf("w2_%s", orders[o].name.tolower()));
        end
    endtask

    // W3: random response stalls on a mixed stream. The monitor checks stability; this
    // test checks the data and that stalls actually happened.
    task automatic w3_backpressure();
        logic [31:0] model [16];
        int unsigned b0 = b_stall_cycles, r0 = r_stall_cycles;
        max_resp_delay = 8;
        for (int i = 0; i < 16; i++) begin
            model[i] = $urandom;
            axil_write(14'(REG_OPCODE + 4*i), model[i], 4'hF, wr_order_e'($urandom_range(2)), resp_scratch);
            expect_eq("W3 seed write", resp_scratch, AXI_OKAY);
        end
        repeat (120) begin
            int unsigned i = $urandom_range(15);
            logic [31:0] d;
            case ($urandom_range(2))
                0: begin
                    model[i] = $urandom;
                    axil_write(14'(REG_OPCODE + 4*i), model[i], 4'hF, wr_order_e'($urandom_range(2)), resp_scratch);
                    expect_eq("W3 write", resp_scratch, AXI_OKAY);
                end
                1: begin
                    axil_read32(14'(REG_OPCODE + 4*i), d);
                    expect_eq("W3 staging read", d, model[i]);
                end
                2: begin
                    logic [13:0] a = 14'h2000 | 14'($urandom_range(14'h07FF) << 2);
                    axil_read32(a, d);
                    expect_eq($sformatf("W3 OUT0 read %04h", a), d, pattern32(a));
                end
            endcase
        end
        max_resp_delay = 0;
        expect_eq("W3 B stalls observed", b_stall_cycles > b0, 1);
        expect_eq("W3 R stalls observed", r_stall_cycles > r0, 1);
        pass("w3_backpressure");
    endtask

    // W4: OUT0 pattern through every lane, the fixture window, the last word, and random words.
    task automatic w4_out0_pattern();
        logic [13:0] addrs [$];
        for (int a = 'h2000; a < 'h2040; a += 4) addrs.push_back(14'(a));
        addrs.push_back(14'h3FFC);
        repeat (32) addrs.push_back(14'h2000 | 14'($urandom_range(14'h07FF) << 2));
        foreach (addrs[i]) begin
            logic [31:0] d;
            logic [1:0] r;
            int unsigned n = native_out, m = native_reg;
            axil_read(addrs[i], d, r);
            expect_eq($sformatf("W4 %04h resp", addrs[i]), r, AXI_OKAY);
            expect_eq($sformatf("W4 %04h data", addrs[i]), d, pattern32(addrs[i]));
            expect_eq($sformatf("W4 %04h one request", addrs[i]), native_out - n, 1);
            expect_eq($sformatf("W4 %04h no reg access", addrs[i]), native_reg - m, 0);
            expect_eq($sformatf("W4 %04h aligned request", addrs[i]), last_out_addr, {addrs[i][12:4], 4'd0});
        end
        pass("w4_out0_pattern");
    endtask

    // W5: unaligned addresses in every region.
    task automatic w5_unaligned();
        logic [13:0] addrs [6] = '{14'h0001, 14'h0042, 14'h0043, 14'h2001, 14'h2002, 14'h1001};
        foreach (addrs[i]) begin
            expect_rejected_write($sformatf("W5 write %04h", addrs[i]), addrs[i], 32'hDEAD_BEEF, 4'hF, AXI_SLVERR);
            expect_rejected_read($sformatf("W5 read %04h", addrs[i]), addrs[i], AXI_SLVERR);
        end
        pass("w5_unaligned");
    endtask

    // W6: partial strobes on a CSR leave it unchanged.
    task automatic w6_partial_strobe();
        logic [3:0] strbs [6] = '{4'h0, 4'h1, 4'h3, 4'h7, 4'h8, 4'hE};
        logic [31:0] d;
        axil_write32(14'(REG_P3), 32'h1234_5678);
        foreach (strbs[i])
            expect_rejected_write($sformatf("W6 strobe %01h", strbs[i]), 14'(REG_P3), 32'hFFFF_FFFF, strbs[i], AXI_SLVERR);
        axil_read32(14'(REG_P3), d);
        expect_eq("W6 P3 unchanged", d, 32'h1234_5678);
        pass("w6_partial_strobe");
    endtask

    // W7: OUT0 is read-only.
    task automatic w7_out0_write();
        expect_rejected_write("W7 write 2000", 14'h2000, 32'h0, 4'hF, AXI_SLVERR);
        expect_rejected_write("W7 write 3FFC", 14'h3FFC, 32'h0, 4'hF, AXI_SLVERR);
        expect_rejected_write("W7 write 2010 partial", 14'h2010, 32'h0, 4'h1, AXI_SLVERR);
        pass("w7_out0_write");
    endtask

    // W8: the unmapped hole decodes as DECERR, even with bad strobes.
    task automatic w8_unmapped();
        logic [13:0] addrs [3] = '{14'h1000, 14'h1800, 14'h1FFC};
        foreach (addrs[i]) begin
            expect_rejected_write($sformatf("W8 write %04h", addrs[i]), addrs[i], 32'h1, 4'hF, AXI_DECERR);
            expect_rejected_write($sformatf("W8 write %04h partial", addrs[i]), addrs[i], 32'h1, 4'h1, AXI_DECERR);
            expect_rejected_read($sformatf("W8 read %04h", addrs[i]), addrs[i], AXI_DECERR);
        end
        pass("w8_unmapped");
    endtask

    // W9: NPU-reported errors reach the NPU once and come back as SLVERR.
    task automatic w9_npu_error();
        logic [31:0] d;
        logic [1:0] r;
        int unsigned n = native_reg;
        axil_read(14'(REG_MAP_END), d, r);
        expect_eq("W9 read past map resp", r, AXI_SLVERR);
        expect_eq("W9 read past map rdata", d, 0);
        expect_eq("W9 read past map native", native_reg - n, 1);
        n = native_reg;
        axil_write(14'h0FFC, 32'h1, 4'hF, ORDER_SAME, r);
        expect_eq("W9 write 0FFC resp", r, AXI_SLVERR);
        expect_eq("W9 write 0FFC native", native_reg - n, 1);
        pass("w9_npu_error");
    endtask

    // W10: write/read contention. A complete write offered on the same clock as a read goes
    // first; a read offered while a write address is held waits for that write.
    task automatic w10_contention();
        logic [31:0] d;
        logic [1:0] wr, rr;
        int unsigned base;
        axil_write32(14'(REG_P4), 32'h0);
        // Same clock.
        base = native_log.size();
        fork
            axil_write(14'(REG_P4), 32'hABCD_0008, 4'hF, ORDER_SAME, wr);
            axil_read(14'(REG_P4), d, rr);
        join
        expect_eq("W10 same-clock write resp", wr, AXI_OKAY);
        expect_eq("W10 same-clock read resp", rr, AXI_OKAY);
        expect_eq("W10 same-clock order", {native_log[base], native_log[base+1]}, 2'b10);
        expect_eq("W10 same-clock read sees write", d, 32'hABCD_0008);
        // Held AW, then AR, then W.
        base = native_log.size();
        fork
            begin
                axil_send_aw(14'(REG_P4));
                wait_clocks(6);
                axil_send_w(32'h5555_0010, 4'hF);
                axil_get_b(wr);
            end
            begin
                wait_clocks(2);
                axil_read(14'(REG_P4), d, rr);
            end
        join
        expect_eq("W10 held-AW write resp", wr, AXI_OKAY);
        expect_eq("W10 held-AW order", {native_log[base], native_log[base+1]}, 2'b10);
        expect_eq("W10 held-AW read sees write", d, 32'h5555_0010);
        // Held W, then AR, then AW.
        base = native_log.size();
        fork
            begin
                axil_send_w(32'h6666_0010, 4'hF);
                wait_clocks(6);
                axil_send_aw(14'(REG_P4));
                axil_get_b(wr);
            end
            begin
                wait_clocks(2);
                axil_read(14'(REG_P4), d, rr);
            end
        join
        expect_eq("W10 held-W order", {native_log[base], native_log[base+1]}, 2'b10);
        expect_eq("W10 held-W read sees write", d, 32'h6666_0010);
        pass("w10_contention");
    endtask

    // W11: datapath reset. OUT0 reads fail fast instead of hanging; CSRs stay reachable.
    task automatic w11_datapath_reset();
        logic [31:0] d;
        logic [1:0] r;
        int unsigned n;
        // Held fault: no request is issued, CSRs still work.
        @(negedge clk); fault_inject = 1;
        expect_rejected_read("W11 OUT0 in reset", 14'h2000, AXI_SLVERR);
        axil_read32(14'h0000, d);
        expect_eq("W11 ID during reset", d, NPU_ID);
        axil_write32(14'(REG_P5), 32'h0000_0055);
        axil_read32(14'(REG_P5), d);
        expect_eq("W11 staging during reset", d, 32'h0000_0055);
        @(negedge clk); fault_inject = 0;
        axil_read(14'h2020, d, r);
        expect_eq("W11 read after fault clears", d, pattern32(14'h2020));
        pass("w11_fault_held");

        // Reset pulse after the request is accepted, while the response is pending.
        n = native_out;
        fork
            axil_read(14'h2010, d, r);
            begin
                wait (native_out == n + 1);
                @(negedge clk); fault_inject = 1;
                @(negedge clk); fault_inject = 0;
            end
        join
        expect_eq("W11 pending read resp", r, AXI_SLVERR);
        expect_eq("W11 pending read rdata", d, 0);
        repeat (OUT0_LATENCY + 4) @(negedge clk); // A stale response would trip the monitor.
        axil_read(14'h2014, d, r);
        expect_eq("W11 next read resp", r, AXI_OKAY);
        expect_eq("W11 next read data", d, pattern32(14'h2014));
        pass("w11_pending_read");

        // Real SOFT_RESET through the bridge pulses local_rst_no; the bridge still answers.
        axil_write32(14'(REG_CTRL), 32'h1 << CTRL_SOFT_RESET);
        axil_read32(14'(REG_P5), d);
        expect_eq("W11 SOFT_RESET cleared staging", d, 0);
        axil_read32(14'(REG_STATUS), d);
        expect_eq("W11 idle after SOFT_RESET", d[STATUS_BUSY], 0);
        axil_read32(14'h203C, d);
        expect_eq("W11 OUT0 after SOFT_RESET", d, pattern32(14'h203C));
        // A NOP through the bridge proves START reaches control.
        axil_write32(14'(REG_OPCODE), 32'(OP_NOP));
        axil_write32(14'(REG_CTRL), 32'h1 << CTRL_START);
        repeat (8) @(negedge clk);
        axil_read32(14'(REG_DONE_SEQ), d);
        expect_eq("W11 NOP retired", d, 0);
        pass("w11_soft_reset");
    endtask

    // W12: board reset with a held write address, held write data, and a pending read.
    task automatic w12_board_reset();
        logic [31:0] d;
        int unsigned n;
        // Held AW: a later write must not pair with it.
        axil_send_aw(14'(REG_P0));
        board_reset();
        repeat (10) @(negedge clk); // The monitor rejects any response here.
        axil_write32(14'(REG_P1), 32'h0000_1111);
        axil_read32(14'(REG_P0), d);
        expect_eq("W12 held AW dropped", d, 0);
        axil_read32(14'(REG_P1), d);
        expect_eq("W12 write after held AW", d, 32'h0000_1111);
        pass("w12_held_aw");
        // Held W.
        axil_send_w(32'hBAD0_BAD0, 4'hF);
        board_reset();
        repeat (10) @(negedge clk);
        axil_write32(14'(REG_P2), 32'h0000_2222);
        axil_read32(14'(REG_P2), d);
        expect_eq("W12 held W dropped", d, 32'h0000_2222);
        pass("w12_held_w");
        // Pending OUT0 read.
        n = native_out;
        axil_send_ar(14'h2030);
        wait (native_out == n + 1);
        board_reset();
        repeat (OUT0_LATENCY + 10) @(negedge clk);
        axil_read32(14'h0000, d);
        expect_eq("W12 ID after reset", d, NPU_ID);
        axil_read32(14'h2030, d);
        expect_eq("W12 OUT0 after reset", d, pattern32(14'h2030));
        // Pending CSR read: reset after the register access, before its R response.
        axil_send_ar(14'h0000);
        board_reset(1);
        repeat (10) @(negedge clk);
        axil_read32(14'h0004, d);
        expect_eq("W12 VERSION after reset", d, NPU_VERSION);
        pass("w12_pending_read");
    endtask

    // ---------------------------------------------------------------- main
    initial begin
        int seed;
        if (!$value$plusargs("TESTS=%s", tests)) tests = "";
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        void'($urandom(seed));
        bus = axi;
        axil_idle();
        cycle = 0; native_reg = 0; native_out = 0;
        repeat (4) @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        if (want("W1")) begin w1_id(); $display("TEST W1 PASS"); end
        if (want("W2")) begin w2_write_ordering(); $display("TEST W2 PASS"); end
        if (want("W3")) begin w3_backpressure(); $display("TEST W3 PASS"); end
        if (want("W4")) begin w4_out0_pattern(); $display("TEST W4 PASS"); end
        if (want("W5")) begin w5_unaligned(); $display("TEST W5 PASS"); end
        if (want("W6")) begin w6_partial_strobe(); $display("TEST W6 PASS"); end
        if (want("W7")) begin w7_out0_write(); $display("TEST W7 PASS"); end
        if (want("W8")) begin w8_unmapped(); $display("TEST W8 PASS"); end
        if (want("W9")) begin w9_npu_error(); $display("TEST W9 PASS"); end
        if (want("W10")) begin w10_contention(); $display("TEST W10 PASS"); end
        if (want("W11")) begin w11_datapath_reset(); $display("TEST W11 PASS"); end
        if (want("W12")) begin w12_board_reset(); $display("TEST W12 PASS"); end

        $display("SUMMARY: %0d passed, 0 failed, %0d checks, %0d writes, %0d reads",
                 passed, checks, writes, reads);
        $display("ALL TESTS PASSED");
        $finish;
    end
endmodule
`default_nettype wire
