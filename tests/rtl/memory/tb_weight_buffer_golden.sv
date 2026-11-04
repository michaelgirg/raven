`timescale 1ns/1ps

// Fixture-driven test: 16 K banks x 8 signed INT8 weights, read by K index.
module tb_weight_buffer_golden;
    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst;
    logic wr_valid;
    logic wr_ready;
    logic [3:0] wr_bank;
    logic [63:0] wr_data;
    logic rd_valid_in;
    logic rd_ready;
    logic [3:0] rd_k;
    logic rd_valid_out;
    logic rd_ready_out;
    logic [63:0] rd_data;

    logic [63:0] expected_banks [0:15];
    string bhex;
    string case_name;
    integer valid_k, valid_n;

    weightBuffer dut (
        .clk(clk), .rst(rst),
        .wr_valid(wr_valid), .wr_ready(wr_ready),
        .wr_bank(wr_bank), .wr_data(wr_data),
        .rd_valid_in(rd_valid_in), .rd_ready(rd_ready), .rd_k(rd_k),
        .rd_valid_out(rd_valid_out), .rd_ready_out(rd_ready_out),
        .rd_data(rd_data)
    );

    initial begin
        #100000;
        $fatal(1, "TIMEOUT weight buffer golden test");
    end

    initial begin
        if (!$value$plusargs("BHEX=%s", bhex))
            $fatal(1, "Missing +BHEX=<absolute path>");
        if (!$value$plusargs("CASE=%s", case_name))
            case_name = "unknown";
        if (!$value$plusargs("VALID_K=%d", valid_k)) valid_k = 16;
        if (!$value$plusargs("VALID_N=%d", valid_n)) valid_n = 8;
        if (valid_k < 1 || valid_k > 16 || valid_n < 1 || valid_n > 8)
            $fatal(1, "Invalid tile K=%0d N=%0d", valid_k, valid_n);
        $readmemh(bhex, expected_banks);

        rst = 1'b1;
        wr_valid = 1'b0;
        wr_bank = '0;
        wr_data = '0;
        rd_valid_in = 1'b0;
        rd_k = '0;
        rd_ready_out = 1'b0;
        repeat (3) @(negedge clk);
        rst = 1'b0;

        // Write each physical 64-bit K row through the memory input interface.
        for (int k = 0; k < 16; k++) begin
            @(negedge clk);
            wr_bank = 4'(k);
            wr_data = expected_banks[k];
            wr_valid = 1'b1;
            if (wr_ready !== 1'b1)
                $fatal(1, "Write not ready: k=%0d", k);
            @(posedge clk);
            @(negedge clk);
            wr_valid = 1'b0;
        end

        // Read 8 weights at each K index, hold the response under backpressure.
        for (int k = 0; k < 16; k++) begin
            @(negedge clk);
            rd_k = 4'(k);
            rd_valid_in = 1'b1;
            rd_ready_out = 1'b0;
            if (rd_ready !== 1'b1)
                $fatal(1, "Read not ready: k=%0d", k);
            @(posedge clk);
            @(negedge clk);
            rd_valid_in = 1'b0;

            for (int stalled = 0; stalled < 3; stalled++) begin
                if (rd_valid_out !== 1'b1)
                    $fatal(1, "Read response disappeared: k=%0d stall=%0d", k, stalled);
                if (wr_ready !== 1'b0)
                    $fatal(1, "Write accepted while output pending: k=%0d", k);
                if (rd_ready !== 1'b0)
                    $fatal(1, "Read accepted while output pending: k=%0d", k);
                for (int channel = 0; channel < 8; channel++) begin
                    if (rd_data[8*channel +: 8] !== expected_banks[k][8*channel +: 8])
                        $fatal(1,
                            "MISMATCH K=%0d channel=%0d expected=%0d actual=%0d",
                            k, channel,
                            $signed(expected_banks[k][8*channel +: 8]),
                            $signed(rd_data[8*channel +: 8]));
                end
                if (stalled < 2) begin
                    @(posedge clk);
                    @(negedge clk);
                end
            end
            rd_ready_out = 1'b1;
            @(posedge clk);
            @(negedge clk);
            if (rd_valid_out !== 1'b0)
                $fatal(1, "Read response did not clear: k=%0d", k);
            rd_ready_out = 1'b0;
        end

        $display("PASS WEIGHT GOLDEN: 128/128 INT8 values matched (%s); output stalls verified", case_name);
        $display("VALID TILE: %0d/%0d meaningful weight values, %0d padded physical positions checked",
                 valid_k*valid_n, valid_k*valid_n, 128-valid_k*valid_n);
        $finish;
    end
endmodule
