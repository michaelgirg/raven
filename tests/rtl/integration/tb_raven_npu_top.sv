`default_nettype none
// TESTBENCH ONLY: pre-alpha integration testbench for raven_npu_top.
//
// The NPU top connects to sim_read_memory models for ACT0/ACT1/WGT0/WGT1 and both PRM
// ports, and to a sim_write_memory model for OUT0. raven_tb_driver_pkg stands in for the
// RISC-V and talks to the register bus only. Fixtures come from export_fixtures.py.
//
// Plusargs:
//   +FIXTURES=<dir>  export_fixtures.py output (required)
//   +OUT=<dir>       where traces and actual_int8 dumps go (default: FIXTURES)
//   +TESTS=<list>    tests to run, e.g. "T1,T2,T3,T4" (default: all implemented)
//
// Independent monitors count core command handshakes and OUT writes, record the cycle of
// the last OUT write and of every DONE_SEQ change, and fail if completion comes first.
module tb_raven_npu_top;
    import raven_ctrl_pkg::*;
    import raven_tb_driver_pkg::*;

    localparam int WATCHDOG_CYCLES = 2_000_000; // Whole-run hang guard.
    localparam int WAIT_CYCLES = 20_000; // Per-command raven_wait timeout.

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    raven_reg_bus_if bus_if(clk);
    wire irq, lrst_n;
    bit stalls; // Random stalls in every bank model.

    // Bank model wiring. Index: 0 ACT0, 1 ACT1, 2 WGT0, 3 WGT1, 4 PRM port A, 5 PRM port B.
    wire rq_valid [6], rq_ready [6], rs_valid [6], rs_ready [6];
    wire [23:0] rq_addr [6];
    wire [127:0] rs_data [6];
    wire [31:0] reads [6];
    wire ow_valid, ow_ready;
    wire [23:0] ow_addr;
    wire [127:0] ow_data;
    wire [15:0] ow_strb;
    wire [31:0] out_writes, out_last_cycle;

    raven_npu_top dut (
        .clk_i(clk), .rst_ni(rst_n),
        .reg_valid_i(bus_if.valid), .reg_ready_o(bus_if.ready), .reg_write_i(bus_if.write),
        .reg_addr_i(bus_if.addr), .reg_wdata_i(bus_if.wdata), .reg_rdata_o(bus_if.rdata),
        .reg_rvalid_o(bus_if.rvalid), .reg_error_o(bus_if.error),
        .npu_irq_o(irq), .local_rst_no(lrst_n),
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
        .out0_w_data_o(ow_data), .out0_w_strb_o(ow_strb)
    );

    // Bank responders reset with the datapath (D11).
    sim_read_memory #(.BYTES(ACT_BYTES), .SEED(11)) m_act0 (.clk_i(clk), .rst_ni(lrst_n), .stalls_i(stalls),
        .req_valid_i(rq_valid[0]), .req_ready_o(rq_ready[0]), .req_addr_i(rq_addr[0]),
        .rsp_valid_o(rs_valid[0]), .rsp_ready_i(rs_ready[0]), .rsp_data_o(rs_data[0]), .reads_o(reads[0]));
    sim_read_memory #(.BYTES(ACT_BYTES), .SEED(12)) m_act1 (.clk_i(clk), .rst_ni(lrst_n), .stalls_i(stalls),
        .req_valid_i(rq_valid[1]), .req_ready_o(rq_ready[1]), .req_addr_i(rq_addr[1]),
        .rsp_valid_o(rs_valid[1]), .rsp_ready_i(rs_ready[1]), .rsp_data_o(rs_data[1]), .reads_o(reads[1]));
    sim_read_memory #(.BYTES(WGT_BYTES), .SEED(13)) m_wgt0 (.clk_i(clk), .rst_ni(lrst_n), .stalls_i(stalls),
        .req_valid_i(rq_valid[2]), .req_ready_o(rq_ready[2]), .req_addr_i(rq_addr[2]),
        .rsp_valid_o(rs_valid[2]), .rsp_ready_i(rs_ready[2]), .rsp_data_o(rs_data[2]), .reads_o(reads[2]));
    sim_read_memory #(.BYTES(WGT_BYTES), .SEED(14)) m_wgt1 (.clk_i(clk), .rst_ni(lrst_n), .stalls_i(stalls),
        .req_valid_i(rq_valid[3]), .req_ready_o(rq_ready[3]), .req_addr_i(rq_addr[3]),
        .rsp_valid_o(rs_valid[3]), .rsp_ready_i(rs_ready[3]), .rsp_data_o(rs_data[3]), .reads_o(reads[3]));
    sim_read_memory #(.BYTES(PRM_BYTES), .SEED(15)) m_prm_a (.clk_i(clk), .rst_ni(lrst_n), .stalls_i(stalls),
        .req_valid_i(rq_valid[4]), .req_ready_o(rq_ready[4]), .req_addr_i(rq_addr[4]),
        .rsp_valid_o(rs_valid[4]), .rsp_ready_i(rs_ready[4]), .rsp_data_o(rs_data[4]), .reads_o(reads[4]));
    sim_read_memory #(.BYTES(PRM_BYTES), .SEED(16)) m_prm_b (.clk_i(clk), .rst_ni(lrst_n), .stalls_i(stalls),
        .req_valid_i(rq_valid[5]), .req_ready_o(rq_ready[5]), .req_addr_i(rq_addr[5]),
        .rsp_valid_o(rs_valid[5]), .rsp_ready_i(rs_ready[5]), .rsp_data_o(rs_data[5]), .reads_o(reads[5]));
    sim_write_memory #(.BYTES(OUT0_BYTES), .SEED(17)) m_out0 (.clk_i(clk), .rst_ni(lrst_n), .stalls_i(stalls),
        .w_valid_i(ow_valid), .w_ready_o(ow_ready), .w_addr_i(ow_addr), .w_data_i(ow_data),
        .w_strb_i(ow_strb), .writes_o(out_writes), .last_write_cycle_o(out_last_cycle));

    // ---------------------------------------------------------------- monitors
    // These run on the global clock count and survive every reset.
    longint unsigned cycle; // Clocks since time zero.
    int unsigned launches; // Core command handshakes.
    int unsigned out_wr; // Accepted OUT0 writes.
    longint unsigned last_out_cycle; // Cycle of the most recent accepted OUT0 write.
    longint unsigned done_cycle; // Cycle DONE_SEQ last changed to a retired command.
    logic [15:0] done_seq_seen;
    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (cycle > WATCHDOG_CYCLES) $fatal(1, "Watchdog: simulation exceeded %0d cycles", WATCHDOG_CYCLES);
        if (dut.core_cmd_valid && dut.core_cmd_ready) launches <= launches + 1;
        if (ow_valid && ow_ready) begin out_wr <= out_wr + 1; last_out_cycle <= cycle; end
        if (rst_n && dut.status.done_seq != done_seq_seen) begin
            done_seq_seen <= dut.status.done_seq;
            // A reset back to 0xFFFF is not a completion.
            if (dut.status.done_seq != 16'hFFFF) done_cycle <= cycle;
        end
    end

    // ---------------------------------------------------------------- helpers
    string fixtures, out_dir, tests;
    int unsigned passed, failed, checks;

    function automatic bit want(input string t);
        if (tests == "") return 1;
        for (int i = 0; i + t.len() <= tests.len(); i++)
            if (tests.substr(i, i + t.len() - 1) == t
                && (i + t.len() == tests.len() || tests[i + t.len()] == ",")
                && (i == 0 || tests[i - 1] == ","))
                return 1;
        return 0;
    endfunction

    // Hard failure: report and stop, so the transcript scan sees it.
    task automatic expect_eq(input string what, input logic [31:0] got, input logic [31:0] exp);
        checks++;
        if (got !== exp) $fatal(1, "CHECK FAILED: %s: got %08h expected %08h", what, got, exp);
    endtask

    task automatic expect_reg(input string what, input logic [11:0] offset, input logic [31:0] exp);
        logic [31:0] v;
        npu_read32(offset, v);
        expect_eq(what, v, exp);
    endtask

    task automatic hw_reset();
        rst_n = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);
    endtask

    typedef struct {
        int m, n, p4, dst_offset, a_bank, b_bank, err_code, err_info, stall, expect_launch;
    } meta_t;

    task automatic read_meta(input string name, output meta_t mt);
        int fd, got;
        fd = $fopen({fixtures, "/", name, "/meta.txt"}, "r");
        if (fd == 0) $fatal(1, "Missing fixture %s", name);
        got = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d", mt.m, mt.n, mt.p4, mt.dst_offset,
                      mt.a_bank, mt.b_bank, mt.err_code, mt.err_info, mt.stall, mt.expect_launch);
        $fclose(fd);
        if (got != 10) $fatal(1, "Malformed meta.txt for %s", name);
    endtask

    // Load the case's images into the bank models its command reads from.
    task automatic load_banks(input string name, input meta_t mt);
        string d = {fixtures, "/", name, "/"};
        case (mt.a_bank)
            BANK_ACT1: $readmemh({d, "act.hex"}, m_act1.mem);
            default:   $readmemh({d, "act.hex"}, m_act0.mem);
        endcase
        case (mt.b_bank)
            BANK_WGT1: $readmemh({d, "wgt.hex"}, m_wgt1.mem);
            default:   $readmemh({d, "wgt.hex"}, m_wgt0.mem);
        endcase
        $readmemh({d, "prm.hex"}, m_prm_a.mem); // Both PRM ports see the same image (D7).
        $readmemh({d, "prm.hex"}, m_prm_b.mem);
    endtask

    // Compare OUT0 against the expected M x N region at dst/pitch; every other byte must be guard.
    task automatic check_out_bank(input string name, input meta_t mt);
        logic [7:0] exp [];
        int fd, got, mism = 0;
        logic [7:0] b;
        exp = new[mt.m * mt.n];
        if (mt.m * mt.n > 0) begin
            fd = $fopen({fixtures, "/", name, "/expected_int8.hex"}, "r");
            if (fd == 0) $fatal(1, "Missing expected_int8.hex for %s", name);
            for (int i = 0; i < mt.m * mt.n; i++) begin
                got = $fscanf(fd, "%h", b);
                if (got != 1) $fatal(1, "Truncated expected_int8.hex for %s", name);
                exp[i] = b;
            end
            $fclose(fd);
        end
        for (int a = 0; a < OUT0_BYTES; a++) begin
            int off = a - mt.dst_offset;
            int r = off >= 0 && mt.p4 > 0 ? off / mt.p4 : -1;
            int c = off >= 0 && mt.p4 > 0 ? off % mt.p4 : -1;
            logic [7:0] want_b = r >= 0 && r < mt.m && c < mt.n ? exp[r * mt.n + c] : 8'hA5;
            if (m_out0.read_byte(a) !== want_b) begin
                if (mism < 8) $display("  %s OUT0[%04h] = %02h, expected %02h", name, a,
                                       m_out0.read_byte(a), want_b);
                mism++;
            end
        end
        checks++;
        if (mism != 0) $fatal(1, "CHECK FAILED: %s: %0d OUT0 bytes wrong", name, mism);
    endtask

    // Packed M x N result for compare_prealpha.py.
    task automatic dump_actual(input string name, input meta_t mt);
        int fd = $fopen({out_dir, "/actual_int8_", name, ".bin"}, "wb");
        if (fd == 0) $fatal(1, "Cannot write actual_int8 for %s", name);
        for (int r = 0; r < mt.m; r++)
            for (int c = 0; c < mt.n; c++)
                $fwrite(fd, "%c", m_out0.read_byte(mt.dst_offset + r * mt.p4 + c));
        $fclose(fd);
    endtask

    // Run one fixture end to end and check everything the plan asks for it.
    // force_stall turns on random stalls in every bank model regardless of the fixture.
    task automatic run_case(input string name, input bit force_stall = 0);
        meta_t mt;
        logic [15:0] seq;
        logic [31:0] err, v;
        raven_status_t st;
        int unsigned launch0, wr0;
        read_meta(name, mt);
        load_banks(name, mt);
        m_out0.fill_guard();
        stalls = force_stall || mt.stall != 0;
        raven_open_trace({out_dir, "/trace_", name, force_stall ? "_stalled" : "", ".txt"});
        launch0 = launches; wr0 = out_wr;
        raven_set_op_from_file({fixtures, "/", name, "/cmd.txt"});
        raven_start(seq, st);
        expect_eq({name, ": raven_start"}, st, RAVEN_OK);
        raven_wait(seq, WAIT_CYCLES, err, st);
        if (mt.err_code == 0) begin
            expect_eq({name, ": raven_wait"}, st, RAVEN_OK);
            expect_reg({name, ": DONE_SEQ"}, REG_DONE_SEQ, 32'(seq));
            expect_reg({name, ": ERR_CODE"}, REG_ERR_CODE, 0);
            npu_read32(REG_IRQ_STATUS, v);
            expect_eq({name, ": IRQ_STATUS.DONE"}, v[IRQ_DONE], 1);
            expect_eq({name, ": npu_irq"}, irq, 1);
            npu_write32(REG_IRQ_STATUS, 32'd1 << IRQ_DONE);
            expect_eq({name, ": npu_irq after W1C"}, irq, 0);
            expect_eq({name, ": core launches"}, launches - launch0, mt.expect_launch);
            expect_eq({name, ": OUT0 writes"}, out_wr - wr0, mt.m * mt.n);
            if (mt.m * mt.n > 0) begin
                checks++;
                if (!(done_cycle > last_out_cycle))
                    $fatal(1, "CHECK FAILED: %s: DONE_SEQ changed at %0d before the last OUT0 write at %0d",
                           name, done_cycle, last_out_cycle);
                dump_actual(name, mt);
            end
            check_out_bank(name, mt);
        end else begin
            expect_eq({name, ": raven_wait"}, st, RAVEN_E_HW);
            expect_eq({name, ": ERR_CODE.code"}, err[7:0], mt.err_code);
            expect_eq({name, ": ERR_CODE.seq"}, err[31:16], seq);
            expect_reg({name, ": ERR_INFO"}, REG_ERR_INFO, mt.err_info);
            // ERROR -> HALTED takes one clock after STATUS.ERROR is visible.
            repeat (2) @(negedge clk);
            npu_read32(REG_STATUS, v);
            expect_eq({name, ": STATUS.HALTED"}, v[STATUS_HALTED], 1);
            expect_eq({name, ": STATUS.FSM"}, v[STATUS_FSM_LSB +: 4], FSM_HALTED);
            npu_read32(REG_IRQ_STATUS, v);
            expect_eq({name, ": IRQ_STATUS.ERROR"}, v[IRQ_ERROR], 1);
            expect_eq({name, ": npu_irq"}, irq, 1);
            expect_eq({name, ": core launches"}, launches - launch0, mt.expect_launch);
            expect_eq({name, ": OUT0 writes"}, out_wr - wr0, 0);
            check_out_bank(name, mt);
            raven_soft_reset(); // The only way out of HALTED (D9).
            expect_reg({name, ": STATUS after SOFT_RESET"}, REG_STATUS, 32'h0000_1010);
        end
        raven_close_trace();
        stalls = 0;
        if (force_stall) $display("PASS %s (stalled)", name);
        else $display("PASS %s", name);
        passed++;
    endtask

    // ---------------------------------------------------------------- tests
    // T1: every reset value the plan lists.
    task automatic t1_reset_values();
        raven_open_trace({out_dir, "/trace_t1_reset.txt"});
        expect_reg("T1 ID", REG_ID, NPU_ID);
        expect_reg("T1 VERSION", REG_VERSION, NPU_VERSION);
        // [7:0] rows, [15:8] cols, [19:16] banks, [23:20] log2 KiB, [27:24] queue depth.
        expect_reg("T1 HW_CONFIG", REG_HW_CONFIG, 32'h0146_0808);
        expect_reg("T1 HW_LIMITS", REG_HW_LIMITS, 32'h0005_0008);
        expect_reg("T1 HW_FEATURES", REG_HW_FEATURES, 0);
        // Idle: Q_EMPTY and QUIESCENT only, FSM IDLE, executing seq 0.
        expect_reg("T1 STATUS", REG_STATUS, 32'h0000_1010);
        expect_reg("T1 NEXT_SEQ", REG_NEXT_SEQ, 0);
        expect_reg("T1 DONE_SEQ", REG_DONE_SEQ, 32'h0000_FFFF);
        expect_reg("T1 ERR_CODE", REG_ERR_CODE, 0);
        expect_reg("T1 ERR_INFO", REG_ERR_INFO, 0);
        expect_reg("T1 IRQ_ENABLE", REG_IRQ_ENABLE, 0);
        expect_reg("T1 IRQ_STATUS", REG_IRQ_STATUS, 0);
        expect_reg("T1 CMD_COUNT", REG_CMD_COUNT, 0);
        for (logic [11:0] r = REG_OPCODE; r <= REG_Q_SHIFT; r += 4)
            expect_reg($sformatf("T1 staging %03h", r), r, 0);
        expect_reg("T1 Q_CLAMP", REG_Q_CLAMP, Q_CLAMP_RESET);
        expect_eq("T1 npu_irq", irq, 0);
        raven_close_trace();
        $display("PASS t1_reset_values"); passed++;
    endtask

    // T2: staging round trip, RO and W1C behavior, bus errors.
    task automatic t2_register_access();
        logic [31:0] v, prev;
        bit e;
        logic [31:0] patterns [3] = '{32'hFFFF_FFFF, 32'hA5A5_5A5A, 32'h0000_0000};
        logic [11:0] ro [] = '{REG_ID, REG_VERSION, REG_HW_CONFIG, REG_HW_LIMITS, REG_STATUS,
                               REG_NEXT_SEQ, REG_DONE_SEQ, REG_ERR_CODE, REG_ERR_INFO,
                               REG_CMD_COUNT, REG_HW_FEATURES};
        logic [11:0] hole [5] = '{12'h070, 12'h07C, 12'h090, 12'h0A8, 12'h0B4};
        logic [11:0] bad [6] = '{12'h0B8, 12'h100, 12'hFFC, 12'h002, 12'h011, 12'h03B};
        raven_open_trace({out_dir, "/trace_t2_registers.txt"});
        foreach (patterns[p])
            for (logic [11:0] r = REG_OPCODE; r <= REG_Q_CLAMP; r += 4) begin
                npu_write32(r, patterns[p] ^ 32'(r));
                expect_reg($sformatf("T2 staging %03h", r), r, patterns[p] ^ 32'(r));
            end
        foreach (ro[i]) begin
            npu_read32(ro[i], prev);
            npu_access(1, ro[i], ~prev, v, e);
            expect_eq($sformatf("T2 RO %03h write error", ro[i]), e, 0);
            expect_reg($sformatf("T2 RO %03h unchanged", ro[i]), ro[i], prev);
        end
        // IRQ_ENABLE keeps only DONE/ERROR. A W1C of a clear bit leaves it clear.
        npu_write32(REG_IRQ_ENABLE, 32'hFFFF_FFFF);
        expect_reg("T2 IRQ_ENABLE mask", REG_IRQ_ENABLE, IRQ_MASK);
        npu_write32(REG_IRQ_STATUS, 32'hFFFF_FFFF);
        expect_reg("T2 IRQ_STATUS W1C of clear bits", REG_IRQ_STATUS, 0);
        expect_eq("T2 npu_irq", irq, 0);
        // Reserved holes read 0 without error; unmapped and unaligned offsets error.
        foreach (hole[i]) begin
            npu_access(1, hole[i], 32'hFFFF_FFFF, v, e);
            expect_eq($sformatf("T2 hole %03h write error", hole[i]), e, 0);
            npu_access(0, hole[i], 0, v, e);
            expect_eq($sformatf("T2 hole %03h read error", hole[i]), e, 0);
            expect_eq($sformatf("T2 hole %03h value", hole[i]), v, 0);
        end
        foreach (bad[i]) begin
            npu_access(0, bad[i], 0, v, e);
            expect_eq($sformatf("T2 bad read %03h", bad[i]), e, 1);
            npu_access(1, bad[i], 32'h1, v, e);
            expect_eq($sformatf("T2 bad write %03h", bad[i]), e, 1);
        end
        // A bad write to an address aliasing CTRL must not start anything.
        expect_reg("T2 still idle", REG_STATUS, 32'h0000_1010);
        // Leave staging and IRQ_ENABLE as the driver expects.
        hw_reset();
        raven_close_trace();
        $display("PASS t2_register_access"); passed++;
    endtask

    // T3: NOP retires with a sequence number, raises DONE, and never touches the core.
    task automatic t3_nop();
        int unsigned launch0 = launches;
        run_case("t3_nop");
        expect_reg("T3 CMD_COUNT", REG_CMD_COUNT, 1);
        expect_eq("T3 core launches", launches - launch0, 0);
    endtask

    // T4: the six valid fixtures back to back, without reset; DONE_SEQ counts 1, 2, ...
    task automatic t4_fixtures();
        string names [6] = '{"normal_8x16x8", "signed_nonzero_zp_stalled", "partial_tile_7x13x5",
                             "positive_negative_saturation", "rounding_ties", "channel_scales_relu_clamp"};
        logic [31:0] count0, v;
        npu_read32(REG_CMD_COUNT, count0);
        foreach (names[i]) begin
            npu_read32(REG_NEXT_SEQ, v);
            expect_eq({"T4 NEXT_SEQ before ", names[i]}, v, 32'(sw_next_seq));
            run_case(names[i]);
        end
        expect_reg("T4 CMD_COUNT", REG_CMD_COUNT, count0 + 6);
    endtask

    // ---------------------------------------------------------------- main
    initial begin
        raven_status_t st;
        if (!$value$plusargs("FIXTURES=%s", fixtures)) $fatal(1, "Missing +FIXTURES=<dir>");
        if (!$value$plusargs("OUT=%s", out_dir)) out_dir = fixtures;
        if (!$value$plusargs("TESTS=%s", tests)) tests = "";
        bus = bus_if;
        npu_bus_idle();
        cycle = 0; launches = 0; out_wr = 0; done_seq_seen = 16'hFFFF;
        hw_reset();

        if (want("T1")) begin t1_reset_values(); $display("TEST T1 PASS"); end
        if (want("T2")) begin t2_register_access(); $display("TEST T2 PASS"); end
        raven_init(st);
        expect_eq("raven_init", st, RAVEN_OK);
        if (want("T3")) begin t3_nop(); $display("TEST T3 PASS"); end
        if (want("T4")) begin t4_fixtures(); $display("TEST T4 PASS"); end

        $display("SUMMARY: %0d passed, %0d failed, %0d checks", passed, failed, checks);
        if (failed == 0) $display("ALL TESTS PASSED");
        $finish;
    end
endmodule
`default_nettype wire
