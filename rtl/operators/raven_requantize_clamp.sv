`default_nettype none
// One-lane INT32-to-INT8 result tail.
// TFLM c051fea55 with TFLITE_SINGLE_ROUNDING=1: Q0.31 multiplier,
// multiplier >= 0, and -31 <= shift <= 30. Parameters are sampled on input
// acceptance. Scratchpad parameter lookup and destination addressing are out
// of scope. Channel is carried for later result-interface integration.
module raven_requantize_clamp (
    input  wire                     clk_i,
    input  wire                     rst_ni,
    input  wire                     in_valid_i,
    output wire                     in_ready_o,
    input  wire signed [31:0]       in_data_i,
    input  wire [15:0]              in_row_i,
    input  wire [15:0]              in_col_i,
    input  wire [31:0]              in_index_i,
    input  wire [31:0]              in_channel_i,
    input  wire                     in_last_i,
    input  wire signed [31:0]       multiplier_i,
    input  wire signed [7:0]        shift_i,
    input  wire signed [7:0]        output_zero_point_i,
    input  wire signed [7:0]        activation_min_i,
    input  wire signed [7:0]        activation_max_i,
    output wire                     out_valid_o,
    input  wire                     out_ready_i,
    output logic signed [7:0]       out_data_o,
    output logic [15:0]             out_row_o,
    output logic [15:0]             out_col_o,
    output logic [31:0]             out_index_o,
    output logic [31:0]             out_channel_o,
    output logic                    out_last_o
);
    logic out_valid_q;
    logic signed [63:0] scaled_c;
    logic signed [63:0] with_zero_point_c;
    logic signed [63:0] activation_min_c;
    logic signed [63:0] activation_max_c;
    logic signed [7:0] clamped_c;

    // TFLM single-rounding: add a positive half-ULP before arithmetic shift.
    function automatic logic signed [63:0] tflm_single_round (
        input logic signed [31:0] value,
        input logic signed [31:0] multiplier,
        input logic signed [7:0] shift
    );
        logic signed [63:0] product;
        logic signed [63:0] rounding;
        integer total_shift;
        begin
            total_shift = 31 - $signed(shift);
            product = value * multiplier;
            rounding = 64'sd1 <<< (total_shift - 1);
            tflm_single_round = (product + rounding) >>> total_shift;
        end
    endfunction

    always_comb begin
        scaled_c = tflm_single_round(in_data_i, multiplier_i, shift_i);
        with_zero_point_c = scaled_c + {{56{output_zero_point_i[7]}}, output_zero_point_i};
        activation_min_c = {{56{activation_min_i[7]}}, activation_min_i};
        activation_max_c = {{56{activation_max_i[7]}}, activation_max_i};
        if (with_zero_point_c < activation_min_c)
            clamped_c = activation_min_i;
        else if (with_zero_point_c > activation_max_c)
            clamped_c = activation_max_i;
        else if (with_zero_point_c < -64'sd128)
            clamped_c = -8'sd128;
        else if (with_zero_point_c > 64'sd127)
            clamped_c = 8'sd127;
        else
            clamped_c = with_zero_point_c[7:0];
    end

    // One-entry elastic register; tags hold with data during a stall.
    assign in_ready_o = rst_ni && (!out_valid_q || out_ready_i);
    assign out_valid_o = out_valid_q;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            out_valid_q   <= 1'b0;
            out_data_o    <= '0;
            out_row_o     <= '0;
            out_col_o     <= '0;
            out_index_o   <= '0;
            out_channel_o <= '0;
            out_last_o    <= 1'b0;
        end else if (in_valid_i && in_ready_o) begin
            out_valid_q   <= 1'b1;
            out_data_o    <= clamped_c;
            out_row_o     <= in_row_i;
            out_col_o     <= in_col_i;
            out_index_o   <= in_index_i;
            out_channel_o <= in_channel_i;
            out_last_o    <= in_last_i;
        end else if (out_valid_q && out_ready_i) begin
            out_valid_q <= 1'b0;
        end
    end

`ifndef SYNTHESIS
    initial begin
        assert ($bits(shift_i) == 8) else $fatal(1, "Unexpected requant shift width");
    end
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        out_valid_o && !out_ready_i |=> out_valid_o &&
        $stable({out_data_o, out_row_o, out_col_o, out_index_o, out_channel_o, out_last_o}));
`endif
endmodule
`default_nettype wire
