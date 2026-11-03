`timescale 1ns/1ps
`default_nettype none

// Independent, fixture-driven testbench for Quan's single-lane requantizer.
// Expected values are loaded from Python-generated files, never calculated in SV.
module tb_raven_requant_golden;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0;

    logic in_valid, in_ready;
    logic signed [31:0] in_data, multiplier;
    logic [15:0] in_row, in_col;
    logic [31:0] in_index, in_channel;
    logic in_last;
    logic signed [7:0] shift, zp, act_min, act_max;
    logic out_valid, out_ready;
    logic signed [7:0] out_data;
    logic [15:0] out_row, out_col;
    logic [31:0] out_index, out_channel;
    logic out_last;

    raven_requantize_clamp dut (
        .clk_i(clk), .rst_ni(rst_n),
        .in_valid_i(in_valid), .in_ready_o(in_ready),
        .in_data_i(in_data), .in_row_i(in_row), .in_col_i(in_col),
        .in_index_i(in_index), .in_channel_i(in_channel), .in_last_i(in_last),
        .multiplier_i(multiplier), .shift_i(shift),
        .output_zero_point_i(zp),
        .activation_min_i(act_min), .activation_max_i(act_max),
        .out_valid_o(out_valid), .out_ready_i(out_ready),
        .out_data_o(out_data), .out_row_o(out_row), .out_col_o(out_col),
        .out_index_o(out_index), .out_channel_o(out_channel),
        .out_last_o(out_last)
    );

    logic [31:0] acc_mem [0:63];
    logic [31:0] mul_mem [0:7];
    logic [7:0] shift_mem [0:7];
    logic [7:0] exp_mem [0:63];
    integer m, n, out_zp, lo, hi;
    integer checked = 0;
    integer cycles = 0;
    bit use_stalls;

    // Only count accepted output transactions. Validate values and tags.
    always @(posedge clk) begin
        if (rst_n && out_valid && out_ready) begin
            if (checked >= m*n)
                $fatal(1, "Unexpected extra output");
            if (out_data !== $signed(exp_mem[checked]))
                $fatal(1, "MISMATCH [%0d][%0d] expected=%0d actual=%0d",
                       checked/n, checked%n,
                       $signed(exp_mem[checked]), out_data);
            if (out_row !== (checked/n) || out_col !== (checked%n) ||
                out_index !== checked || out_channel !== (checked%n) ||
                out_last !== (checked == m*n-1))
                $fatal(1, "Output tag mismatch at element %0d", checked);
            checked = checked + 1;
        end
    end

    // Optional output backpressure; the rounding test uses the default no-stall mode.
    always @(negedge clk) begin
        if (rst_n) begin
            cycles = cycles + 1;
            out_ready = (!use_stalls || (cycles % 7 >= 3));
        end
    end

    initial begin
        if (!$value$plusargs("M=%d", m) || !$value$plusargs("N=%d", n) ||
            !$value$plusargs("ZP=%d", out_zp) ||
            !$value$plusargs("LO=%d", lo) || !$value$plusargs("HI=%d", hi))
            $fatal(1, "Missing quantization case plusargs");
        if (m < 1 || m > 8 || n < 1 || n > 8)
            $fatal(1, "Unsupported matrix dimensions");
        use_stalls = $test$plusargs("STALL");
        $readmemh("input_int32.hex", acc_mem);
        $readmemh("multipliers.hex", mul_mem);
        $readmemh("shifts.hex", shift_mem);
        $readmemh("expected_int8.hex", exp_mem);

        in_valid = 0;
        in_data = 0;
        in_row = 0; in_col = 0; in_index = 0; in_channel = 0;
        in_last = 0;
        multiplier = 0; shift = 0;
        zp = out_zp; act_min = lo; act_max = hi;
        out_ready = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;
        out_ready = 1;

        for (int i = 0; i < m*n; i++) begin
            @(negedge clk);
            in_valid = 1;
            in_data = $signed(acc_mem[i]);
            multiplier = $signed(mul_mem[i%n]);
            shift = $signed(shift_mem[i%n]);
            in_row = i/n;
            in_col = i%n;
            in_index = i;
            in_channel = i%n;
            in_last = (i == m*n-1);
            do @(posedge clk); while (!in_ready);
            @(negedge clk);
            in_valid = 0;
        end
        wait (checked == m*n);
        @(negedge clk);
        $display("PASS REQUANT GOLDEN: %0d/%0d INT8 outputs matched", checked, m*n);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "Timeout waiting for requantization results");
    end
endmodule
`default_nettype wire
