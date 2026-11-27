`timescale 1ns/1ps
`default_nettype none

// MEMORY-mode AXI-to-BRAM end-to-end fixture test.
// Run vsim from a working directory with the fixture paths used by
// rtl/board/raven_board_top.sv and +CMD=... specified below.
module tb_raven_board_memory;
    import axil_master_pkg::*;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;
    raven_axil_if axi(clk);

    raven_board_top_v #(
        .OUT0_MEMORY(1),
        .USE_TILE_BUFFERS(1)
    ) dut (
        .aclk(clk), .aresetn(rst_n),
        .s_axi_awaddr(axi.awaddr), .s_axi_awprot(3'b000),
        .s_axi_awvalid(axi.awvalid), .s_axi_awready(axi.awready),
        .s_axi_wdata(axi.wdata), .s_axi_wstrb(axi.wstrb),
        .s_axi_wvalid(axi.wvalid), .s_axi_wready(axi.wready),
        .s_axi_bresp(axi.bresp), .s_axi_bvalid(axi.bvalid),
        .s_axi_bready(axi.bready),
        .s_axi_araddr(axi.araddr), .s_axi_arprot(3'b000),
        .s_axi_arvalid(axi.arvalid), .s_axi_arready(axi.arready),
        .s_axi_rdata(axi.rdata), .s_axi_rresp(axi.rresp),
        .s_axi_rvalid(axi.rvalid), .s_axi_rready(axi.rready)
    );

    localparam logic [13:0] REG_ID         = 14'h0000;
    localparam logic [13:0] REG_CTRL       = 14'h0010;
    localparam logic [13:0] REG_STATUS     = 14'h0014;
    localparam logic [13:0] REG_IRQ_STATUS = 14'h001C;
    localparam logic [13:0] REG_NEXT_SEQ   = 14'h0020;
    localparam logic [13:0] REG_DONE_SEQ   = 14'h0024;
    localparam logic [13:0] REG_ERR_CODE   = 14'h0028;
    localparam logic [13:0] REG_ERR_INFO   = 14'h002C;

    string cmd_path, output_path;
    integer cmd_fd, output_fd, rc, count;
    logic [31:0] offset, value, data, status, irq, seq, done_seq;
    bit done;

    initial begin
        if (!$value$plusargs("CMD=%s", cmd_path))
            cmd_path = "build/prototype/fixtures/normal_8x16x8/cmd.txt";
        if (!$value$plusargs("OUT=%s", output_path))
            output_path = "out0.bin";

        bus = axi;
        axil_idle();
        timeout_cycles = 10000;
        repeat (8) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        axil_read32(REG_ID, data);
        if (data !== 32'h5241564E)
            $fatal(1, "Wrong RAVEN ID %08h", data);

        // Clear stale DONE before the next START.
        axil_read32(REG_STATUS, status);
        if (status[2:0] != 0)
            $fatal(1, "NPU not idle at start: STATUS=%08h", status);
        axil_write32(REG_IRQ_STATUS, 32'h1);

        cmd_fd = $fopen(cmd_path, "r");
        if (cmd_fd == 0) $fatal(1, "Cannot open command fixture %s", cmd_path);
        count = 0;
        // Exporter writes precisely 16 CSR staging offsets as hexadecimal pairs.
        for (int i = 0; i < 16; i++) begin
            rc = $fscanf(cmd_fd, "%h %h", offset, value);
            if (rc != 2) $fatal(1, "Bad or missing cmd.txt pair %0d", i);
            if (offset[31:14] != 0)
                $fatal(1, "CSR offset out of AXI window: %08h", offset);
            axil_write32(offset[13:0], value);
            count++;
        end
        $fclose(cmd_fd);
        $display("Loaded %0d staging registers from %s", count, cmd_path);

        axil_read32(REG_NEXT_SEQ, seq);
        axil_write32(REG_CTRL, 32'h00000001); // START

        done = 0;
        for (int poll = 0; poll < 10000; poll++) begin
            axil_read32(REG_STATUS, status);
            if (status[2] || status[1]) begin
                axil_read32(REG_ERR_CODE, data);
                $display("ERROR CODE=%08h", data);
                axil_read32(REG_ERR_INFO, data);
                $fatal(1, "NPU error/halt; STATUS=%08h ERR_INFO=%08h", status, data);
            end
            axil_read32(REG_IRQ_STATUS, irq);
            if (irq[0] && !status[0]) begin
                done = 1;
                break;
            end
        end
        if (!done) $fatal(1, "TIMEOUT waiting for GEMM DONE");
        axil_read32(REG_DONE_SEQ, done_seq);
        if (done_seq[15:0] !== seq[15:0])
            $fatal(1, "Sequence mismatch: expected %0d, got %0d", seq[15:0], done_seq[15:0]);
        $display("GEMM DONE, sequence %0d", done_seq[15:0]);

        // 16 aligned 32-bit AXI reads = 64 bytes. Lowest byte first.
        output_fd = $fopen(output_path, "wb");
        if (output_fd == 0) $fatal(1, "Cannot create %s", output_path);
        for (int i = 0; i < 16; i++) begin
            axil_read32(14'h2000 + 14'(4*i), data);
            for (int lane = 0; lane < 4; lane++)
                $fwrite(output_fd, "%c", data[lane*8 +: 8]);
        end
        $fclose(output_fd);
        $display("BOARD_MEMORY_READBACK_PASS: wrote 64 bytes to %s", output_path);
        $finish;
    end
endmodule
`default_nettype wire
