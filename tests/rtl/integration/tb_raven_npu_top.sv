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
//   +TESTS=<list>    tests to run, e.g. "T1,T4,T12" (default: all, T1-T15)
//
// Independent monitors count core command handshakes and OUT writes, record the cycle of
// the last OUT write and of every DONE_SEQ change, and fail if completion comes first.
module tb_raven_npu_top #(
    parameter int COLS = 8
);
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

    raven_npu_top #(.COLS(COLS)) dut (
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


    bit dbg_held = 0;
    logic [23:0] dbg_addr;

    always @(posedge clk) begin
        if (dbg_held &&
            (!rq_valid[5] || rq_addr[5] !== dbg_addr)) begin
            $display(
                "DEBUG PRM_B: t=%0t rst=%b soft_reset=%b core_error=%b valid=%b ready=%b addr=%h previous=%h loading=%b",
                $time,
                lrst_n,
                dut.soft_reset,
                dut.core_error,
                rq_valid[5],
                rq_ready[5],
                rq_addr[5],
                dbg_addr,
                dut.u_requant.loading_q
            );
        end

        dbg_held <= lrst_n && rq_valid[5] && !rq_ready[5];
        dbg_addr <= rq_addr[5];
    end

    // ---------------------------------------------------------------- monitors
    // These run on the global clock count and survive every reset.
    longint unsigned cycle; // Clocks since time zero.
    int unsigned launches; // Core command handshakes.
    int unsigned out_wr; // Accepted OUT0 writes.
    longint unsigned last_out_cycle; // Cycle of the most recent accepted OUT0 write.
    longint unsigned done_cycle; // Cycle DONE_SEQ last changed to a retired command.
    logic [15:0] done_seq_seen;
    fsm_state_e fsm_at_soft_reset; // Control state on the clock SOFT_RESET was applied.
    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (cycle > WATCHDOG_CYCLES) $fatal(1, "Watchdog: simulation exceeded %0d cycles", WATCHDOG_CYCLES);
        if (dut.core_cmd_valid && dut.core_cmd_ready) launches <= launches + 1;
        if (dut.soft_reset) fsm_at_soft_reset <= dut.u_ctrl.state_q;
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
    task automatic check_out_bank(input string name, input meta_t mt, input string tag = "");
        logic [7:0] exp [];
        int fd, got, mism = 0;
        logic [7:0] b;
        if (tag == "") tag = name;
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
            int r = -1;
            int c = -1;
            logic [7:0] want_b;

            // Prevent division by zero
            if (off >= 0 && mt.p4 > 0) begin
                r = off / mt.p4;
                c = off % mt.p4;
            end

            want_b = (r >= 0 && r < mt.m && c >= 0 && c < mt.n)
                ? exp[r * mt.n + c] : 8'hA5;

            if (m_out0.read_byte(a) !== want_b) begin
                if (mism < 8)
                    $display("  %s OUT0[%04h] = %02h, expected %02h",
                            tag, a, m_out0.read_byte(a), want_b);
                mism++;
            end
        end
        checks++;
        if (mism != 0) $fatal(1, "CHECK FAILED: %s: %0d OUT0 bytes wrong", tag, mism);
    endtask

    // Packed M x N result for compare_prealpha.py, listed in dumps.txt as "<tag> <fixture>".
    task automatic dump_actual(input string name, input string tag, input meta_t mt);
        int fd = $fopen({out_dir, "/actual_int8_", tag, ".bin"}, "wb");
        if (fd == 0) $fatal(1, "Cannot write actual_int8 for %s", tag);
        for (int r = 0; r < mt.m; r++)
            for (int c = 0; c < mt.n; c++)
                $fwrite(fd, "%c", m_out0.read_byte(mt.dst_offset + r * mt.p4 + c));
        $fclose(fd);
        fd = $fopen({out_dir, "/dumps.txt"}, "a");
        $fdisplay(fd, "%s %s", tag, name);
        $fclose(fd);
    endtask

    // Load a case's banks, re-guard OUT0, set stalls, open its trace and stage its command.
    // force_stall turns on random stalls in every bank model regardless of the fixture.
    task automatic prepare_case(input string name, input bit force_stall, input string tag,
                                output meta_t mt);
        read_meta(name, mt);
        load_banks(name, mt);
        m_out0.fill_guard();
        stalls = force_stall || mt.stall != 0;
        raven_open_trace({out_dir, "/trace_", tag, ".txt"});
        raven_set_op_from_file({fixtures, "/", name, "/cmd.txt"});
    endtask

    // Checks after a command that must retire: done after the last write, exact bytes,
    // guards intact, DONE IRQ raised and cleared, and the expected number of launches.
    task automatic check_retired(input string name, input string tag, input meta_t mt, input logic [15:0] seq,
                                 input int unsigned launches_seen, input int unsigned writes_seen);
        logic [31:0] v;
        expect_reg({tag, ": DONE_SEQ"}, REG_DONE_SEQ, 32'(seq));
        npu_read32(REG_IRQ_STATUS, v);
        expect_eq({tag, ": IRQ_STATUS.DONE"}, v[IRQ_DONE], 1);
        expect_eq({tag, ": npu_irq"}, irq, 1);
        npu_write32(REG_IRQ_STATUS, 32'd1 << IRQ_DONE);
        npu_read32(REG_IRQ_STATUS, v);
        expect_eq({tag, ": IRQ_STATUS.DONE after W1C"}, v[IRQ_DONE], 0);
        expect_eq({tag, ": core launches"}, launches_seen, mt.expect_launch);
        expect_eq({tag, ": OUT0 writes"}, writes_seen, mt.m * mt.n);
        if (mt.m * mt.n > 0) begin
            checks++;
            if (!(done_cycle > last_out_cycle))
                $fatal(1, "CHECK FAILED: %s: DONE_SEQ changed at %0d before the last OUT0 write at %0d",
                       tag, done_cycle, last_out_cycle);
            dump_actual(name, tag, mt);
        end
        check_out_bank(name, mt, tag);
    endtask

    // Checks after a command that must fail, then SOFT_RESET out of HALTED.
    task automatic check_failed(input string name, input string tag, input meta_t mt, input logic [15:0] seq,
                                input logic [31:0] err, input int unsigned launches_seen,
                                input int unsigned writes_seen);
        logic [31:0] v;
        expect_eq({tag, ": ERR_CODE.code"}, err[7:0], mt.err_code);
        expect_eq({tag, ": ERR_CODE.seq"}, err[31:16], seq);
        expect_reg({tag, ": ERR_INFO"}, REG_ERR_INFO, mt.err_info);
        // ERROR -> HALTED takes one clock after STATUS.ERROR is visible.
        repeat (2) @(negedge clk);
        npu_read32(REG_STATUS, v);
        expect_eq({tag, ": STATUS.HALTED"}, v[STATUS_HALTED], 1);
        expect_eq({tag, ": STATUS.FSM"}, v[STATUS_FSM_LSB +: 4], FSM_HALTED);
        npu_read32(REG_IRQ_STATUS, v);
        expect_eq({tag, ": IRQ_STATUS.ERROR"}, v[IRQ_ERROR], 1);
        expect_eq({tag, ": npu_irq"}, irq, 1);
        expect_eq({tag, ": core launches"}, launches_seen, mt.expect_launch);
        expect_eq({tag, ": OUT0 writes"}, writes_seen, 0);
        check_out_bank(name, mt, tag);
        raven_soft_reset(); // The only way out of HALTED (D9).
        expect_reg({tag, ": STATUS after SOFT_RESET"}, REG_STATUS, 32'h0000_1010);
    endtask

    function automatic int unsigned total_bank_reads();
        int unsigned total;
        total = 0;
        foreach (reads[i]) total += reads[i];
        return total;
    endfunction

    // Run one fixture end to end and check everything the plan asks for it.
    task automatic run_case(input string name, input bit force_stall = 0);
        meta_t mt;
        logic [15:0] seq;
        logic [31:0] err;
        raven_status_t st;
        int unsigned launch0, wr0, read0;
        string tag = name;
        if (force_stall) tag = {name, "_stalled"};
        prepare_case(name, force_stall, tag, mt);
        launch0 = launches; wr0 = out_wr; read0 = total_bank_reads();
        raven_start(seq, st);
        expect_eq({tag, ": raven_start"}, st, RAVEN_OK);
        raven_wait(seq, WAIT_CYCLES, err, st);
        if (mt.err_code == 0) begin
            expect_eq({tag, ": raven_wait"}, st, RAVEN_OK);
            expect_reg({tag, ": ERR_CODE"}, REG_ERR_CODE, 0);
            check_retired(name, tag, mt, seq, launches - launch0, out_wr - wr0);
        end else begin
            expect_eq({tag, ": raven_wait"}, st, RAVEN_E_HW);
            // Command-validation failures must not start either parameter reader.
            if (mt.err_code != ERR_ACC_RANGE)
                expect_eq({tag, ": invalid command issued bank reads"}, total_bank_reads() - read0, 0);
            check_failed(name, tag, mt, seq, err, launches - launch0, out_wr - wr0);
        end
        raven_close_trace();
        stalls = 0;
        $display("PASS %s", tag);
        passed++;
    endtask

    // Every case export_fixtures.py assigned to test t, in cases.txt order.
    task automatic cases_for(input string t, ref string names [$]);
        int fd, got;
        string name, test;
        names.delete();
        fd = $fopen({fixtures, "/cases.txt"}, "r");
        if (fd == 0) $fatal(1, "Missing cases.txt in %s", fixtures);
        forever begin
            got = $fscanf(fd, "%s %s\n", name, test);
            if (got != 2) break;
            if (test == t) names.push_back(name);
        end
        $fclose(fd);
        if (names.size() == 0) $fatal(1, "No fixtures for %s in cases.txt", t);
    endtask

    task automatic run_test_cases(input string t, input bit force_stall = 0);
        string names [$];
        cases_for(t, names);
        foreach (names[i]) run_case(names[i], force_stall);
    endtask

    // Wait (bounded) until the control FSM reaches state s.
    task automatic wait_fsm(input fsm_state_e s, input string what);
        int n = 0;
        while (dut.u_ctrl.state_q != s) begin
            @(negedge clk);
            if (++n > WAIT_CYCLES) $fatal(1, "%s: FSM never reached %s", what, s.name);
        end
    endtask

    // ---------------------------------------------------------------- tests
    // T1: every reset value the plan lists.
    task automatic t1_reset_values();
        raven_open_trace({out_dir, "/trace_t1_reset.txt"});
        expect_reg("T1 ID", REG_ID, NPU_ID);
        expect_reg("T1 VERSION", REG_VERSION, NPU_VERSION);
        // [7:0] rows, [15:8] cols, [19:16] banks, [23:20] log2 KiB, [27:24] queue depth.
        expect_reg("T1 HW_CONFIG", REG_HW_CONFIG, 32'h0146_0008 | (32'(COLS) << 8));
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

    // T4: the six valid fixtures back to back, without reset; DONE_SEQ counts up.
    task automatic t4_fixtures();
        string names [$];
        logic [31:0] count0, v;
        cases_for("T4", names);
        npu_read32(REG_CMD_COUNT, count0);
        foreach (names[i]) begin
            npu_read32(REG_NEXT_SEQ, v);
            expect_eq({"T4 NEXT_SEQ before ", names[i]}, v, 32'(sw_next_seq));
            run_case(names[i]);
        end
        expect_reg("T4 CMD_COUNT", REG_CMD_COUNT, count0 + names.size());
    endtask

    // T5: PER_CHANNEL=0 with Q_MULT/Q_SHIFT gives the same bytes as the per-channel records.
    task automatic t5_shared_scale();
        run_test_cases("T5");
    endtask

    // T6: padded output pitch at a nonzero destination; the gaps keep their guard bytes.
    task automatic t6_output_pitch();
        run_test_cases("T6");
    endtask

    // T7: A from ACT1 and B from WGT1. ACT0/WGT0 still hold the previous case's data, so
    // a routing mistake changes the result; their read counters must not move either.
    task automatic t7_bank_routing();
        int unsigned a0 = reads[0], w0 = reads[2], a1 = reads[1], w1 = reads[3];
        run_test_cases("T7");
        expect_eq("T7 ACT0 reads", reads[0], a0);
        expect_eq("T7 WGT0 reads", reads[2], w0);
        checks++;
        if (reads[1] == a1 || reads[3] == w1) $fatal(1, "CHECK FAILED: T7 ACT1/WGT1 were not read");
    endtask

    // T8: every valid fixture again with random stalls in every bank model, OUT0 included.
    task automatic t8_backpressure();
        string tests [4] = '{"T4", "T5", "T6", "T7"};
        foreach (tests[i]) run_test_cases(tests[i], 1);
    endtask

    // T9: Jackie's zero-K case: ERR_BAD_DIM at P1, no launch, no OUT0 write.
    task automatic t9_zero_k();
        run_test_cases("T9");
    endtask

    // T10: every control-detected rule, each with its exact ERR_INFO, no launch, no writes.
    task automatic t10_control_errors();
        run_test_cases("T10");
    endtask

    // T11: rules only the core checks (pitch, A alignment, accumulator overflow): one launch,
    // the core's code passed through with ERR_INFO 0, and no OUT0 writes.
    task automatic t11_core_errors();
        run_test_cases("T11");
    endtask

    // T12: START while busy. The extra START is refused by the driver (Q_FULL), then forced
    // onto the bus: ERR_Q_OVERFLOW latches at once with the seq it would have received,
    // the in-flight command still retires with correct bytes, then the FSM halts.
    task automatic t12_start_while_busy();
        meta_t mt;
        logic [15:0] seq, seq2;
        logic [31:0] v, err;
        raven_status_t st;
        int unsigned launch0, wr0;
        int n = 0;
        prepare_case("normal_8x16x8", 1, "t12_start_while_busy", mt);
        launch0 = launches; wr0 = out_wr;
        raven_start(seq, st);
        expect_eq("T12 raven_start", st, RAVEN_OK);
        wait_fsm(FSM_RUN, "T12");
        raven_start(seq2, st);
        expect_eq("T12 driver refuses START while Q_FULL", st, RAVEN_E_BUSY);
        npu_write32(REG_CTRL, 32'd1 << CTRL_START);
        npu_read32(REG_STATUS, v);
        expect_eq("T12 STATUS.ERROR latched while busy", v[STATUS_ERROR], 1);
        expect_eq("T12 still busy", v[STATUS_BUSY], 1);
        expect_reg("T12 ERR_CODE", REG_ERR_CODE, {seq + 16'd1, 8'd0, ERR_Q_OVERFLOW});
        expect_reg("T12 ERR_INFO", REG_ERR_INFO, 32'(REG_CTRL));
        do begin
            npu_read32(REG_DONE_SEQ, v);
            if (++n > WAIT_CYCLES) $fatal(1, "T12: in-flight command never retired");
        end while (v[15:0] != seq);
        repeat (2) @(negedge clk);
        npu_read32(REG_STATUS, v);
        expect_eq("T12 HALTED after retirement", v[STATUS_HALTED], 1);
        expect_reg("T12 NEXT_SEQ: extra START consumed nothing", REG_NEXT_SEQ, 32'(seq) + 1);
        expect_reg("T12 ERR_CODE still visible", REG_ERR_CODE, {seq + 16'd1, 8'd0, ERR_Q_OVERFLOW});
        expect_eq("T12 one launch", launches - launch0, 1);
        expect_eq("T12 OUT0 writes", out_wr - wr0, mt.m * mt.n);
        checks++;
        if (!(done_cycle > last_out_cycle)) $fatal(1, "CHECK FAILED: T12 retired before the last write");
        check_out_bank("normal_8x16x8", mt, "t12_start_while_busy");
        dump_actual("normal_8x16x8", "t12_start_while_busy", mt);
        raven_soft_reset();
        raven_close_trace();
        stalls = 0;
        $display("PASS t12_start_while_busy"); passed++;
    endtask

    // T13: HALTED ignores START, CLEAR_ERR clears diagnostics but stays HALTED, and
    // SOFT_RESET restores every reset value; then a valid fixture passes from seq 0.
    task automatic t13_halted();
        meta_t mt;
        logic [15:0] seq;
        logic [31:0] v, err, err_code;
        raven_status_t st;
        int unsigned launch0;
        prepare_case("t10_m9", 0, "t13_halted", mt);
        raven_start(seq, st);
        raven_wait(seq, WAIT_CYCLES, err, st);
        expect_eq("T13 error reported", st, RAVEN_E_HW);
        repeat (2) @(negedge clk);
        npu_read32(REG_STATUS, v);
        expect_eq("T13 HALTED", v[STATUS_HALTED], 1);
        npu_read32(REG_ERR_CODE, err_code);
        // START in HALTED: no launch, no sequence, nothing changes.
        launch0 = launches;
        npu_read32(REG_NEXT_SEQ, v);
        npu_write32(REG_CTRL, 32'd1 << CTRL_START);
        repeat (20) @(negedge clk);
        expect_reg("T13 NEXT_SEQ unchanged by START", REG_NEXT_SEQ, v);
        expect_reg("T13 ERR_CODE unchanged by START", REG_ERR_CODE, err_code);
        expect_eq("T13 no launch from HALTED", launches - launch0, 0);
        npu_read32(REG_STATUS, v);
        expect_eq("T13 still HALTED after START", v[STATUS_HALTED], 1);
        // CLEAR_ERR: diagnostics only.
        raven_clear_err();
        npu_read32(REG_STATUS, v);
        expect_eq("T13 STATUS.ERROR cleared", v[STATUS_ERROR], 0);
        expect_eq("T13 still HALTED after CLEAR_ERR", v[STATUS_HALTED], 1);
        expect_reg("T13 ERR_CODE cleared", REG_ERR_CODE, 0);
        expect_reg("T13 ERR_INFO cleared", REG_ERR_INFO, 0);
        // SOFT_RESET: back to the reset values (IRQ_ENABLE is configuration and survives).
        raven_soft_reset();
        expect_reg("T13 STATUS idle", REG_STATUS, 32'h0000_1010);
        expect_reg("T13 NEXT_SEQ", REG_NEXT_SEQ, 0);
        expect_reg("T13 DONE_SEQ", REG_DONE_SEQ, 32'h0000_FFFF);
        expect_reg("T13 CMD_COUNT", REG_CMD_COUNT, 0);
        expect_reg("T13 IRQ_STATUS", REG_IRQ_STATUS, 0);
        expect_reg("T13 IRQ_ENABLE kept", REG_IRQ_ENABLE, IRQ_MASK);
        expect_reg("T13 staging P0 cleared", REG_P0, 0);
        expect_reg("T13 staging Q_CLAMP reset", REG_Q_CLAMP, Q_CLAMP_RESET);
        raven_close_trace();
        $display("PASS t13_halted"); passed++;
        run_case("normal_8x16x8");
        expect_reg("T13 first command after SOFT_RESET was seq 0", REG_DONE_SEQ, 0);
    endtask

    // T14: hardware reset and SOFT_RESET, each during RUN and during DRAIN. Afterwards the
    // NPU is idle with reset values and a fresh fixture passes with correct bytes.
    task automatic t14_reset_mid_operation();
        fsm_state_e states [2] = '{FSM_RUN, FSM_DRAIN};
        raven_status_t st;
        foreach (states[i])
            for (int hard = 0; hard < 2; hard++) begin
                meta_t mt;
                logic [15:0] seq;
                string tag = "t14_";
                // Built piecewise: some simulators pad ternary string results to equal length.
                if (hard) tag = {tag, "hw"}; else tag = {tag, "soft"};
                if (states[i] == FSM_RUN) tag = {tag, "_reset_in_run"}; else tag = {tag, "_reset_in_drain"};
                prepare_case("normal_8x16x8", 1, tag, mt);
                raven_start(seq, st);
                expect_eq({tag, ": raven_start"}, st, RAVEN_OK);
                wait_fsm(states[i], tag);
                if (hard) begin
                    // Asserted on this falling edge, so the FSM is still in the target state.
                    rst_n = 0;
                    repeat (3) @(negedge clk);
                    rst_n = 1;
                    repeat (2) @(negedge clk);
                    raven_init(st); // A hardware reset clears IRQ_ENABLE; firmware re-inits.
                    expect_eq({tag, ": raven_init"}, st, RAVEN_OK);
                end else begin
                    raven_soft_reset();
                    repeat (2) @(negedge clk); // The SOFT_RESET pulse lands one clock after the write.
                    checks++;
                    if (fsm_at_soft_reset != states[i])
                        $fatal(1, "CHECK FAILED: %s: SOFT_RESET landed in %s", tag, fsm_at_soft_reset.name);
                end
                expect_reg({tag, ": STATUS idle"}, REG_STATUS, 32'h0000_1010);
                expect_reg({tag, ": NEXT_SEQ"}, REG_NEXT_SEQ, 0);
                expect_reg({tag, ": DONE_SEQ"}, REG_DONE_SEQ, 32'h0000_FFFF);
                expect_reg({tag, ": ERR_CODE"}, REG_ERR_CODE, 0);
                raven_close_trace();
                stalls = 0;
                $display("PASS %s", tag); passed++;
                run_case("normal_8x16x8");
            end
    endtask

    // T15: rewrite every staging register while the command runs; the snapshot is unaffected
    // and the new staging values read back.
    task automatic t15_staging_rewrite();
        meta_t mt;
        logic [15:0] seq;
        logic [31:0] v, err;
        raven_status_t st;
        int unsigned launch0, wr0;
        prepare_case("normal_8x16x8", 1, "t15_staging_rewrite", mt);
        launch0 = launches; wr0 = out_wr;
        raven_start(seq, st);
        expect_eq("T15 raven_start", st, RAVEN_OK);
        wait_fsm(FSM_RUN, "T15");
        for (logic [11:0] r = REG_OPCODE; r <= REG_Q_CLAMP; r += 4) begin
            npu_read32(r, v);
            npu_write32(r, ~v);
        end
        npu_read32(REG_STATUS, v);
        checks++;
        if (!v[STATUS_BUSY]) $fatal(1, "CHECK FAILED: T15 command finished before the rewrite did");
        raven_wait(seq, WAIT_CYCLES, err, st);
        expect_eq("T15 raven_wait", st, RAVEN_OK);
        check_retired("normal_8x16x8", "t15_staging_rewrite", mt, seq, launches - launch0, out_wr - wr0);
        expect_reg("T15 OPCODE holds the rewrite", REG_OPCODE, ~32'(OP_GEMM));
        raven_close_trace();
        stalls = 0;
        $display("PASS t15_staging_rewrite"); passed++;
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
        if (want("T5")) begin t5_shared_scale(); $display("TEST T5 PASS"); end
        if (want("T6")) begin t6_output_pitch(); $display("TEST T6 PASS"); end
        if (want("T7")) begin t7_bank_routing(); $display("TEST T7 PASS"); end
        if (want("T8")) begin t8_backpressure(); $display("TEST T8 PASS"); end
        if (want("T9")) begin t9_zero_k(); $display("TEST T9 PASS"); end
        if (want("T10")) begin t10_control_errors(); $display("TEST T10 PASS"); end
        if (want("T11")) begin t11_core_errors(); $display("TEST T11 PASS"); end
        if (want("T12")) begin t12_start_while_busy(); $display("TEST T12 PASS"); end
        if (want("T13")) begin t13_halted(); $display("TEST T13 PASS"); end
        if (want("T14")) begin t14_reset_mid_operation(); $display("TEST T14 PASS"); end
        if (want("T15")) begin t15_staging_rewrite(); $display("TEST T15 PASS"); end

        $display("SUMMARY: %0d passed, %0d failed, %0d checks", passed, failed, checks);
        if (failed == 0) $display("ALL TESTS PASSED");
        $finish;
    end
endmodule
`default_nettype wire
