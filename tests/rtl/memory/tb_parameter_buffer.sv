//test bench for parameter buffer

`timescale 1ns/1ps

module tb_parameter_buffer;

    logic clk = 0;
    logic rst;

    logic wr_valid;
    logic wr_ready;
    logic [5:0] wr_addr;
    logic [31:0] wr_data;

    logic rd_valid_in;
    logic rd_ready;
    logic [2:0] rd_channel;

    logic rd_valid_out;
    logic rd_ready_out;

    logic signed [31:0] rd_bias;
    logic signed [31:0] rd_multiplier;
    logic signed [7:0] rd_shift;
    logic signed [7:0] rd_zero_point;
    logic signed [7:0] rd_clamp_min;
    logic signed [7:0] rd_clamp_max;

    parameterBuffer dut (
        .clk(clk),
        .rst(rst),

        .wr_valid(wr_valid),
        .wr_ready(wr_ready),
        .wr_addr(wr_addr),
        .wr_data(wr_data),

        .rd_valid_in(rd_valid_in),
        .rd_ready(rd_ready),
        .rd_channel(rd_channel),

        .rd_valid_out(rd_valid_out),
        .rd_ready_out(rd_ready_out),

        .rd_bias(rd_bias),
        .rd_multiplier(rd_multiplier),
        .rd_shift(rd_shift),
        .rd_zero_point(rd_zero_point),
        .rd_clamp_min(rd_clamp_min),
        .rd_clamp_max(rd_clamp_max)
    );

    always #5 clk = ~clk;

    logic signed [31:0] expected_bias [0:7];
    logic signed [31:0] expected_multiplier [0:7];
    logic signed [7:0] expected_shift [0:7];

    logic signed [7:0] expected_zero_point;
    logic signed [7:0] expected_clamp_min;
    logic signed [7:0] expected_clamp_max;

    task automatic write_parameter(
        input logic [5:0] address,
        input logic [31:0] data
    );
        begin
            @(negedge clk);

            wr_addr = address;
            wr_data = data;
            wr_valid = 1;

            @(posedge clk);
            #1;

            if (!wr_ready)
                $fatal(1, "Parameter write not ready");

            @(negedge clk);
            wr_valid = 0;
        end
    endtask

    task automatic read_channel(input integer channel);
        begin
            @(negedge clk);

            rd_channel = channel;
            rd_valid_in = 1;
            rd_ready_out = 0;

            @(posedge clk);
            #1;

            if (!rd_valid_out)
                $fatal(1, "Parameter read response missing");

            if (rd_bias !== expected_bias[channel])
                $fatal(1, "Bias mismatch on channel %0d", channel);

            if (rd_zero_point !== expected_zero_point)
                $fatal(1, "Zero-point mismatch");

            if (rd_clamp_min !== expected_clamp_min)
                $fatal(1, "Clamp minimum mismatch");

            if (rd_clamp_max !== expected_clamp_max)
                $fatal(1, "Clamp maximum mismatch");

            @(negedge clk);
            //stop requesting reads and consume the response
            rd_valid_in = 0;
            rd_ready_out = 1;

            @(posedge clk);
            #1;

            if (rd_valid_out)
                $fatal(1, "Output response did not clear");
            @(negedge clk);
            rd_ready_out = 0;
        end
    endtask

    initial begin
        rst = 1;

        wr_valid = 0;
        wr_addr = 0;
        wr_data = 0;

        rd_valid_in = 0;
        rd_channel = 0;
        rd_ready_out = 0;

        expected_zero_point = -3;
        expected_clamp_min = -128;
        expected_clamp_max = 127;

        for (int i = 0; i < 8; i++) begin
            expected_bias[i] = -100 - (i * 10);
            expected_multiplier[i] = 32'sd1000000000 + (i * 1000);
            expected_shift[i] = -7 - i;
        end

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 0;

        $display("\n--- PARAMETER BUFFER TEST ---");

        //write per channel bias values
        for (int i = 0; i < 8; i++)
            write_parameter(i, expected_bias[i]);

        //write per channel multiplier values
        for (int i = 0; i < 8; i++)
            write_parameter(8 + i, expected_multiplier[i]);

        //write per channel shift values
        for (int i = 0; i < 8; i++)
            write_parameter(16 + i, expected_shift[i]);

        //write shared params
        write_parameter(24, {{24{expected_zero_point[7]}}, expected_zero_point});
        write_parameter(25, {{24{expected_clamp_min[7]}}, expected_clamp_min});
        write_parameter(26, {{24{expected_clamp_max[7]}}, expected_clamp_max});

        $display("PASS: All parameter values written");

        //test per channel multiplier and shift mode
        write_parameter(27, 32'd1);
        write_parameter(28, 32'd1);

        for (int i = 0; i < 8; i++) begin
            read_channel(i);

            if (rd_multiplier !== expected_multiplier[i])
                $fatal(1, "Per-channel multiplier mismatch");

            if (rd_shift !== expected_shift[i])
                $fatal(1, "Per-channel shift mismatch");
        end

        $display("PASS: Per-channel bias, multiplier, and shift verified");

        //test shared multiplier and shift mode
        write_parameter(27, 32'd0);
        write_parameter(28, 32'd0);

        for (int i = 0; i < 8; i++) begin
            read_channel(i);

            if (rd_multiplier !== expected_multiplier[0])
                $fatal(1, "Shared multiplier mismatch");

            if (rd_shift !== expected_shift[0])
                $fatal(1, "Shared shift mismatch");
        end

        $display("PASS: Shared multiplier and shift verified");
        $display("PASS: Shared zero-point and clamp values verified");

        //backpressure test
        @(negedge clk);
        rd_channel = 2;
        rd_valid_in = 1;
        rd_ready_out = 0;

        @(posedge clk);
        #1;

        if (!rd_valid_out)
            $fatal(1, "Parameter response missing");

        begin
            logic signed [31:0] held_bias;
            held_bias = rd_bias;

            repeat (3) begin
                @(posedge clk);
                #1;

                if (!rd_valid_out || rd_bias !== held_bias)
                    $fatal(1, "Parameter backpressure failed");
            end
        end

        @(negedge clk);
        rd_valid_in = 0;
        rd_ready_out = 1;

        @(posedge clk);
        #1;

        if (rd_valid_out)
            $fatal(1, "Parameter response did not clear");

        $display("PASS: Parameter backpressure verified");

        $display("\nALL PARAMETER BUFFER TESTS PASSED");
        $finish;
    end

endmodule