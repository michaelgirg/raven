`timescale 1ns/1ps
`default_nettype none
// Directed test using literal expected values calculated from the pinned TFLM
// single-rounding reference. It does not call the RTL arithmetic formula.
module tb_raven_requantize_clamp;
    logic clk=0, rst_n=0;
    always #5 clk=~clk;
    logic in_valid, in_ready;
    logic signed [31:0] in_data, multiplier;
    logic [15:0] in_row, in_col;
    logic [31:0] in_index, in_channel;
    logic in_last;
    logic signed [7:0] shift, zp, act_min, act_max;
    wire out_valid;
    logic out_ready;
    wire signed [7:0] out_data;
    wire [15:0] out_row, out_col;
    wire [31:0] out_index, out_channel;
    wire out_last;

    raven_requantize_clamp dut (
        .clk_i(clk), .rst_ni(rst_n), .in_valid_i(in_valid), .in_ready_o(in_ready),
        .in_data_i(in_data), .in_row_i(in_row), .in_col_i(in_col),
        .in_index_i(in_index), .in_channel_i(in_channel), .in_last_i(in_last),
        .multiplier_i(multiplier), .shift_i(shift), .output_zero_point_i(zp),
        .activation_min_i(act_min), .activation_max_i(act_max),
        .out_valid_o(out_valid), .out_ready_i(out_ready), .out_data_o(out_data),
        .out_row_o(out_row), .out_col_o(out_col), .out_index_o(out_index),
        .out_channel_o(out_channel), .out_last_o(out_last));

    logic signed [7:0] expected_data [0:63];
    logic [15:0] expected_row [0:63], expected_col [0:63];
    logic [31:0] expected_index [0:63], expected_channel [0:63];
    logic expected_last [0:63];
    integer push_count=0, pop_count=0;

    always @(posedge clk) begin
        if (rst_n && out_valid && out_ready) begin
            assert (pop_count < push_count) else $fatal(1,"Unexpected output");
            assert (out_data === expected_data[pop_count]) else $fatal(1,"Data mismatch %0d",pop_count);
            assert (out_row === expected_row[pop_count] && out_col === expected_col[pop_count]) else $fatal(1,"Row/column tag mismatch");
            assert (out_index === expected_index[pop_count] && out_channel === expected_channel[pop_count]) else $fatal(1,"Index/channel tag mismatch");
            assert (out_last === expected_last[pop_count]) else $fatal(1,"Last tag mismatch");
            pop_count <= pop_count+1;
        end
    end

    task automatic offer(
        input logic signed [31:0] x, input logic signed [31:0] m,
        input logic signed [7:0] s, input logic signed [7:0] z,
        input logic signed [7:0] lo, input logic signed [7:0] hi,
        input logic signed [7:0] expected,
        input logic [15:0] row, input logic [15:0] col,
        input logic [31:0] index, input logic [31:0] channel, input logic last);
        begin
            expected_data[push_count]=expected;
            expected_row[push_count]=row; expected_col[push_count]=col;
            expected_index[push_count]=index; expected_channel[push_count]=channel;
            expected_last[push_count]=last; push_count=push_count+1;
            @(negedge clk);
            in_data=x; multiplier=m; shift=s; zp=z; act_min=lo; act_max=hi;
            in_row=row; in_col=col; in_index=index; in_channel=channel; in_last=last; in_valid=1;
            do @(posedge clk); while (!in_ready);
            @(negedge clk); in_valid=0;
        end
    endtask

    task automatic consecutive_burst;
        begin
            // These three samples are accepted on three consecutive rising
            // edges. M=0.5 and shift=1 give an exact scale of one.
            expected_data[push_count]=1; expected_row[push_count]=40; expected_col[push_count]=41;
            expected_index[push_count]=42; expected_channel[push_count]=43; expected_last[push_count]=0; push_count=push_count+1;
            expected_data[push_count]=2; expected_row[push_count]=41; expected_col[push_count]=42;
            expected_index[push_count]=43; expected_channel[push_count]=44; expected_last[push_count]=0; push_count=push_count+1;
            expected_data[push_count]=3; expected_row[push_count]=42; expected_col[push_count]=43;
            expected_index[push_count]=44; expected_channel[push_count]=45; expected_last[push_count]=1; push_count=push_count+1;
            @(negedge clk);
            in_data=1; multiplier=32'sh4000_0000; shift=1; zp=0; act_min=-128; act_max=127;
            in_row=40; in_col=41; in_index=42; in_channel=43; in_last=0; in_valid=1;
            @(posedge clk); assert(in_ready) else $fatal(1,"First burst input stalled");
            @(negedge clk);
            in_data=2; in_row=41; in_col=42; in_index=43; in_channel=44;
            @(posedge clk); assert(in_ready) else $fatal(1,"Second burst input stalled");
            @(negedge clk);
            in_data=3; in_row=42; in_col=43; in_index=44; in_channel=45; in_last=1;
            @(posedge clk); assert(in_ready) else $fatal(1,"Third burst input stalled");
            @(negedge clk); in_valid=0;
        end
    endtask

    task automatic wait_outputs(input integer count);
        integer watchdog;
        begin
            watchdog=0;
            while (pop_count<count && watchdog<200) begin @(posedge clk); watchdog++; end
            assert(pop_count==count) else $fatal(1,"Output timeout / loss");
        end
    endtask

    initial begin
        in_valid=0; in_data=0; multiplier=0; shift=0; zp=0; act_min=-128; act_max=127;
        in_row=0; in_col=0; in_index=0; in_channel=0; in_last=0; out_ready=0;
        repeat(3) @(posedge clk); rst_n=1; @(posedge clk);
        // M=0.5, shift=0: +3/2 -> +2 and -3/2 -> -1.
        out_ready=1;
        offer(32'sd3,32'sh4000_0000,0,0,-128,127,2,1,2,3,4,0);
        offer(-32'sd3,32'sh4000_0000,0,0,-128,127,-1,2,3,4,5,0);
        offer(0,32'sh4000_0000,0,0,-128,127,0,3,4,5,6,0);
        offer(10,32'sh4000_0000,2,-5,-128,127,15,4,5,6,7,0);
        offer(-20,32'sh4000_0000,-1,7,-128,127,2,5,6,7,8,0);
        offer(32'sh7fff_ffff,32'sh7fff_ffff,0,0,-128,127,127,6,7,8,9,0);
        offer(-32'sh7fff_ffff,32'sh7fff_ffff,0,0,-128,127,-128,7,8,9,10,0);
        offer(100,32'sh4000_0000,1,0,-10,20,20,8,9,10,11,0);
        offer(-100,32'sh4000_0000,1,0,-10,20,-10,9,10,11,12,1);
        wait_outputs(9);

        // Hold the first output, then release the elastic register.
        out_ready=0;
        offer(1,32'sh4000_0000,1,0,-128,127,1,10,11,12,13,0);
        fork
            begin
                repeat(4) @(posedge clk); out_ready=1;
            end
            begin
                offer(2,32'sh4000_0000,1,0,-128,127,2,11,12,13,14,0);
                offer(3,32'sh4000_0000,1,0,-128,127,3,12,13,14,15,1);
            end
        join
        wait_outputs(12);
        consecutive_burst();
        wait_outputs(15);

        // Reset discards a held output, then a fresh result proves restart.
        out_ready=0;
        @(negedge clk);
        in_data=9; multiplier=32'sh4000_0000; shift=1; zp=0; act_min=-128; act_max=127;
        in_row=20; in_col=21; in_index=22; in_channel=23; in_last=0; in_valid=1;
        @(posedge clk); assert(in_ready) else $fatal(1,"Reset sample was not accepted");
        @(negedge clk); in_valid=0;
        @(negedge clk); rst_n=0; repeat(2) @(posedge clk);
        assert(!out_valid && !in_ready) else $fatal(1,"Reset did not clear/disable tail");
        // Drop the discarded expectation and restart with a new scoreboard.
        push_count=0; pop_count=0; @(negedge clk); in_valid=0; rst_n=1; out_ready=1;
        offer(-9,32'sh4000_0000,1,3,-128,127,-6,30,31,32,33,1);
        wait_outputs(1);
        $display("PASS REQUANT: rounding, clamps, tags, stalls, reset, and consecutive inputs");
        $finish;
    end
    initial begin #200000; $fatal(1,"Global timeout"); end
endmodule
`default_nettype wire
