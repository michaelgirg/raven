`default_nettype none
// TESTBENCH ONLY: W13 of docs/plans/nahjay_board_prototype.md, the GEMM fixture over AXI.
//
// Tests raven_board_top_v with OUT0_MEMORY=1 exactly as the block design instantiates it:
// the bank init files keep their default bare names (act.hex, wgt.hex, prm.hex), so the
// runner copies hw/fixtures/normal_8x16x8 images into the simulation directory. The host
// side follows hw/debug/run_fixture.tcl: stage cmd.txt, START, poll STATUS/IRQ_STATUS,
// check DONE_SEQ, then read OUT0 through the bridge and compare with expected_int8.hex.
//
// Runs: (1) the ACT0/WGT0 command, (2) SOFT_RESET then the same command again (the BRAM
// preload must survive it), (3) the ACT1/WGT1 command (O2: every bank has storage).
// Each OUT0 readback is also written to +OUT=<dir>/out0_<run>.bin for compare_prealpha.py.
//
// Plusargs: +FIXTURE=<dir> (required; holds cmd.txt and expected_int8.hex),
//           +CMD_ALT=<file> (cmd.txt for run 3; run 3 is skipped without it),
//           +OUT=<dir> (default ".").
module tb_raven_board_top;
    import raven_ctrl_pkg::*;
    import axil_master_pkg::*;

    localparam int WATCHDOG_CYCLES = 2_000_000;
    localparam int POLL_LIMIT = 20_000; // STATUS polls per command.
    localparam logic [13:0] OUT0_BASE = 14'h2000;
    localparam logic [31:0] NPU_ID_VALUE = 32'h5241564E; // "RAVN"

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    raven_axil_if axi(clk);

    raven_board_top_v #(.OUT0_MEMORY(1)) u_board (
        .aclk(clk), .aresetn(rst_n),
        .s_axi_awaddr(axi.awaddr), .s_axi_awprot(3'd0), .s_axi_awvalid(axi.awvalid), .s_axi_awready(axi.awready),
        .s_axi_wdata(axi.wdata), .s_axi_wstrb(axi.wstrb), .s_axi_wvalid(axi.wvalid), .s_axi_wready(axi.wready),
        .s_axi_bresp(axi.bresp), .s_axi_bvalid(axi.bvalid), .s_axi_bready(axi.bready),
        .s_axi_araddr(axi.araddr), .s_axi_arprot(3'd0), .s_axi_arvalid(axi.arvalid), .s_axi_arready(axi.arready),
        .s_axi_rdata(axi.rdata), .s_axi_rresp(axi.rresp), .s_axi_rvalid(axi.rvalid), .s_axi_rready(axi.rready));

    // ---------------------------------------------------------------- monitors
    longint unsigned cycle;
    int unsigned out_writes; // OUT0 bank writes accepted from the NPU.
    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (cycle > WATCHDOG_CYCLES) $fatal(1, "Watchdog: simulation exceeded %0d cycles", WATCHDOG_CYCLES);
        if (u_board.u_top.out0_w_valid && u_board.u_top.out0_w_ready) out_writes <= out_writes + 1;
    end

    // ---------------------------------------------------------------- helpers
    string fixture, cmd_alt, out_dir;
    int unsigned passed, checks;
    logic [7:0] expected [$];

    task automatic expect_eq(input string what, input logic [31:0] got, input logic [31:0] exp);
        checks++;
        if (got !== exp) $fatal(1, "CHECK FAILED: %s: got %08h expected %08h", what, got, exp);
    endtask

    task automatic load_expected();
        int fd, v;
        fd = $fopen({fixture, "/expected_int8.hex"}, "r");
        if (fd == 0) $fatal(1, "Missing %s/expected_int8.hex", fixture);
        while ($fscanf(fd, "%h", v) == 1) expected.push_back(8'(v));
        $fclose(fd);
        if (expected.size() == 0 || expected.size() % 4 != 0)
            $fatal(1, "expected_int8.hex has %0d bytes; need a non-zero multiple of 4", expected.size());
    endtask

    // Write every "offset value" pair of a cmd.txt to the staging registers.
    task automatic stage(input string path);
        int fd, off, value, n = 0;
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "Missing %s", path);
        while ($fscanf(fd, "%h %h", off, value) == 2) begin
            axil_write32(14'(off), value);
            n++;
        end
        $fclose(fd);
        if (n == 0) $fatal(1, "%s has no staging writes", path);
    endtask

    // START the staged command, wait for DONE, check DONE_SEQ and that OUT0 was written.
    task automatic start_and_wait(input string tag);
        logic [31:0] seq, s, irq, d;
        int unsigned polls = 0, writes_before = out_writes;
        axil_read32(14'(REG_NEXT_SEQ), seq);
        axil_write32(14'(REG_CTRL), 32'h1);
        forever begin
            axil_read32(14'(REG_STATUS), s);
            axil_read32(14'(REG_IRQ_STATUS), irq);
            if (s[2]) $fatal(1, "CHECK FAILED: %s: NPU error (STATUS %08h)", tag, s);
            if (s[1]) $fatal(1, "CHECK FAILED: %s: NPU halted (STATUS %08h)", tag, s);
            if (irq[0] && !s[0]) break;
            if (++polls > POLL_LIMIT) $fatal(1, "CHECK FAILED: %s: no DONE (STATUS %08h)", tag, s);
        end
        axil_read32(14'(REG_DONE_SEQ), d);
        expect_eq({tag, " DONE_SEQ"}, d[15:0], seq[15:0]);
        checks++;
        if (out_writes == writes_before) $fatal(1, "CHECK FAILED: %s: DONE without an OUT0 write", tag);
        axil_write32(14'(REG_IRQ_STATUS), 32'h1);
    endtask

    // Read the result region over AXI, dump it, and compare byte by byte.
    task automatic check_out0(input string tag);
        logic [31:0] w;
        int fd, mism = 0;
        fd = $fopen({out_dir, "/out0_", tag, ".bin"}, "wb");
        if (fd == 0) $fatal(1, "Cannot write %s/out0_%s.bin", out_dir, tag);
        for (int off = 0; off < expected.size(); off += 4) begin
            axil_read32(OUT0_BASE + 14'(off), w);
            for (int b = 0; b < 4; b++) begin
                $fwrite(fd, "%c", w[8*b +: 8]);
                checks++;
                if (w[8*b +: 8] !== expected[off + b]) begin
                    if (mism < 8) $display("MISMATCH %s byte %0d: got %02h expected %02h",
                                           tag, off + b, w[8*b +: 8], expected[off + b]);
                    mism++;
                end
            end
        end
        $fclose(fd);
        if (mism) $fatal(1, "CHECK FAILED: %s: %0d/%0d OUT0 bytes differ", tag, mism, expected.size());
        $display("W13 %s: %0d/%0d bytes match", tag, expected.size(), expected.size());
    endtask

    task automatic require_idle(input string tag);
        logic [31:0] s;
        axil_read32(14'(REG_STATUS), s);
        expect_eq({tag, " STATUS idle"}, s & 32'h7, 32'h0);
    endtask

    // ---------------------------------------------------------------- main
    initial begin
        logic [31:0] d;
        if (!$value$plusargs("FIXTURE=%s", fixture)) $fatal(1, "+FIXTURE=<dir> is required");
        if (!$value$plusargs("CMD_ALT=%s", cmd_alt)) cmd_alt = "";
        if (!$value$plusargs("OUT=%s", out_dir)) out_dir = ".";
        bus = axi;
        axil_idle();
        load_expected();
        cycle = 0; out_writes = 0;
        repeat (4) @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        axil_read32(14'(REG_ID), d);
        expect_eq("ID", d, NPU_ID_VALUE);
        require_idle("reset");

        // Run 1: ACT0/WGT0.
        axil_write32(14'(REG_IRQ_STATUS), 32'h1);
        stage({fixture, "/cmd.txt"});
        start_and_wait("run1");
        check_out0("run1");
        passed++;

        // Run 2: SOFT_RESET, then the same command; the preload must be intact.
        axil_write32(14'(REG_CTRL), 32'h2);
        repeat (20) @(negedge clk);
        require_idle("soft_reset");
        stage({fixture, "/cmd.txt"});
        start_and_wait("run2");
        check_out0("run2");
        passed++;

        // Run 3: ACT1/WGT1 (same images, other banks).
        if (cmd_alt != "") begin
            stage(cmd_alt);
            start_and_wait("run3");
            check_out0("run3");
            passed++;
        end

        $display("TEST W13 PASS");
        $display("SUMMARY: %0d passed, 0 failed, %0d checks, %0d writes, %0d reads",
                 passed, checks, writes, reads);
        $display("ALL TESTS PASSED");
        $finish;
    end
endmodule
`default_nettype wire
