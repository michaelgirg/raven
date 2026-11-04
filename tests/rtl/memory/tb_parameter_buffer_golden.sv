`timescale 1ns/1ps

module tb_parameter_buffer_golden;
    logic clk = 0;
    always #5 clk = ~clk;

    logic rst = 1;
    logic wr_valid = 0;
    logic wr_ready;
    logic [5:0] wr_addr = '0;
    logic [31:0] wr_data = '0;
    logic rd_valid_in = 0;
    logic rd_ready;
    logic [2:0] rd_channel = '0;
    logic rd_valid_out;
    logic rd_ready_out = 0;
    logic signed [31:0] rd_bias, rd_multiplier;
    logic signed [7:0] rd_shift, rd_zero_point, rd_clamp_min, rd_clamp_max;

    parameterBuffer dut (
        .clk(clk), .rst(rst),
        .wr_valid(wr_valid), .wr_ready(wr_ready),
        .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_valid_in(rd_valid_in), .rd_ready(rd_ready),
        .rd_channel(rd_channel),
        .rd_valid_out(rd_valid_out), .rd_ready_out(rd_ready_out),
        .rd_bias(rd_bias), .rd_multiplier(rd_multiplier),
        .rd_shift(rd_shift), .rd_zero_point(rd_zero_point),
        .rd_clamp_min(rd_clamp_min), .rd_clamp_max(rd_clamp_max)
    );

    logic [31:0] words [0:28];
    string params_file, case_name;
    int check_count = 0;

    task automatic write_reg(input int index, input logic [31:0] data);
        @(negedge clk);
        wr_valid = 1'b1;
        wr_addr = index[5:0];
        wr_data = data;
        @(posedge clk);
        #1;
        if (!wr_ready) $fatal(1, "Write not accepted at address %0d", index);
        @(negedge clk);
        wr_valid = 1'b0;
    endtask

    task automatic assert_payload(input int ch, input bit per_channel);
        int selected;
        selected = per_channel ? ch : 0;
        if (!rd_valid_out) $fatal(1, "Missing read response ch=%0d", ch);
        if (rd_bias !== $signed(words[ch]))
            $fatal(1, "Bias mismatch ch=%0d actual=%0d expected=%0d", ch, rd_bias, $signed(words[ch]));
        if (rd_multiplier !== $signed(words[8+selected]))
            $fatal(1, "Multiplier mismatch ch=%0d actual=%0d expected=%0d", ch, rd_multiplier, $signed(words[8+selected]));
        if (rd_shift !== $signed(words[16+selected][7:0]))
            $fatal(1, "Shift mismatch ch=%0d actual=%0d expected=%0d", ch, rd_shift, $signed(words[16+selected][7:0]));
        if (rd_zero_point !== $signed(words[24][7:0]))
            $fatal(1, "Zero-point mismatch ch=%0d", ch);
        if (rd_clamp_min !== $signed(words[25][7:0]))
            $fatal(1, "Clamp min mismatch ch=%0d", ch);
        if (rd_clamp_max !== $signed(words[26][7:0]))
            $fatal(1, "Clamp max mismatch ch=%0d", ch);
    endtask

    task automatic check_channel(input int ch, input bit per_channel);
        @(negedge clk);
        if (!rd_ready) $fatal(1, "Read request not ready ch=%0d", ch);
        rd_channel = ch[2:0];
        rd_valid_in = 1'b1;
        rd_ready_out = 1'b0;
        @(posedge clk);
        #1;
        assert_payload(ch, per_channel);
        // Stop sending requests and hold the current response under backpressure.
        @(negedge clk);
        rd_valid_in = 1'b0;
        repeat (2) begin
            @(posedge clk);
            #1;
            assert_payload(ch, per_channel);
        end
        // Accept this response and ensure valid clears.
        @(negedge clk);
        rd_ready_out = 1'b1;
        @(posedge clk);
        #1;
        if (rd_valid_out) $fatal(1, "Read response did not clear ch=%0d", ch);
        @(negedge clk);
        rd_ready_out = 1'b0;
        check_count++;
    endtask

    initial begin
        if (!$value$plusargs("PARAM_HEX=%s", params_file))
            $fatal(1, "Missing +PARAM_HEX=<path>");
        if (!$value$plusargs("CASE=%s", case_name))
            case_name = "unknown";
        $readmemh(params_file, words);
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        for (int i = 0; i < 29; i++)
            write_reg(i, words[i]);
        // Verify per-channel parameters and bias for all eight physical channels.
        for (int i = 0; i < 8; i++)
            check_channel(i, 1'b1);
        // Switch to shared multiplier and shift modes, checking channel-0 fallback.
        write_reg(27, 32'd0);
        write_reg(28, 32'd0);
        for (int i = 0; i < 8; i++)
            check_channel(i, 1'b0);

        if (check_count != 16) $fatal(1, "Wrong number of checked responses: %0d", check_count);
        $display("PASS PARAMETER GOLDEN: 8/8 channels matched (%s); per-channel and shared modes; output stalls verified", case_name);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "Timeout in parameter golden test");
    end
endmodule
