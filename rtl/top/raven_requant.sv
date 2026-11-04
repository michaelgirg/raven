`default_nettype none
// Requant stage of the NPU top: PARAM loading around Quan's raven_requantize_clamp.
//
// raven_requantize_clamp takes multiplier/shift/zero-point/clamp as per-element inputs and
// does no scratchpad access. This wrapper supplies the plan's §5.3 interface (D6, D7):
//   - cfg_load_i latches the command's quantization fields.
//   - PER_CHANNEL=1: it then reads the N PARAM records (16 bytes each, contract §5:
//     int32 multiplier at byte 4, int8 shift at byte 8) through PRM read port B into a
//     small per-channel table. PER_CHANNEL=0 uses Q_MULT/Q_SHIFT and skips the load.
//   - in_ready_o stays low until the table is loaded, so the core's results simply wait.
//   - Each element is sent to raven_requantize_clamp with its column's parameters.
// RELU_EN raises the effective clamp minimum to max(clamp_min, out_zp).
module raven_requant #(
    parameter int COLS = 8, // Physical array columns: the most output channels per command.
    parameter int ADDR_W = 24 // Width of the byte offset inside the PRM bank.
) (
    input wire clk_i, rst_ni, // Active-low reset is checked on the rising clock edge.
    // Per-command configuration, sampled on cfg_load_i.
    input wire cfg_load_i, // One-clock pulse when the command launches.
    input wire cfg_per_channel_i, // 1: per-channel multiplier/shift from PARAM records.
    input wire [15:0] cfg_n_i, // Output channels (N) to load.
    input wire [ADDR_W-1:0] cfg_param_base_i, // PRM byte offset of channel 0's record.
    input wire signed [31:0] cfg_mult_i, // Shared Q31 multiplier (PER_CHANNEL=0).
    input wire signed [7:0] cfg_shift_i, // Shared shift (PER_CHANNEL=0).
    input wire signed [7:0] cfg_out_zp_i, // Output zero point.
    input wire signed [7:0] cfg_clamp_min_i, cfg_clamp_max_i, // Activation clamp range.
    input wire cfg_relu_i, // RELU_EN: clamp minimum becomes max(clamp_min, out_zp).
    // INT32 results from the core.
    input wire in_valid_i, // Is an INT32 result presented?
    output wire in_ready_o, // Can the requant take it this clock?
    input wire signed [31:0] in_data_i, // Accumulator value including bias.
    input wire [15:0] in_row_i, in_col_i, // Position inside the tile; the column is the channel.
    input wire in_last_i, // Final element of the command.
    // PRM read port B (same shape as the core's parameter port).
    output wire p_req_valid_o, // Is a record read requested?
    input wire p_req_ready_i, // Bank accepts the request.
    output wire [ADDR_W-1:0] p_req_addr_o, // 16-byte-aligned record address.
    input wire p_rsp_valid_i, // Is a record presented?
    output wire p_rsp_ready_o, // Can the wrapper take it?
    input wire [127:0] p_rsp_data_i, // One 16-byte PARAM record.
    // INT8 results to the writer.
    output wire out_valid_o, // Is an INT8 result presented?
    input wire out_ready_i, // Can the writer take it?
    output wire [7:0] out_data_o, // Requantized INT8 value.
    output wire [15:0] out_row_o, out_col_o, // Position inside the tile.
    output wire out_last_o // Final element of the command.
);
    localparam int CH_W = $clog2(COLS);

    // Latched command configuration.
    logic per_channel_q, relu_q;
    logic [15:0] n_q;
    logic [ADDR_W-1:0] param_base_q;
    logic signed [31:0] mult_q;
    logic signed [7:0] shift_q, out_zp_q, clamp_min_q, clamp_max_q;
    // Per-channel table and load progress.
    logic signed [31:0] ch_mult_q [COLS];
    logic signed [7:0] ch_shift_q [COLS];
    logic loading_q; // Record reads are outstanding or still to be issued.
    logic [15:0] req_count_q, rsp_count_q; // Records requested and received.

    assign p_req_valid_o = loading_q && req_count_q < n_q;
    assign p_req_addr_o = param_base_q + ADDR_W'({req_count_q, 4'b0000});
    assign p_rsp_ready_o = loading_q;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            per_channel_q <= 0; relu_q <= 0; n_q <= 0; param_base_q <= '0;
            mult_q <= 0; shift_q <= 0; out_zp_q <= 0; clamp_min_q <= -8'sd128; clamp_max_q <= 8'sd127;
            loading_q <= 0; req_count_q <= 0; rsp_count_q <= 0;
            for (int c = 0; c < COLS; c++) begin
                ch_mult_q[c] <= 0; ch_shift_q[c] <= 0;
            end
        end else if (cfg_load_i) begin
            per_channel_q <= cfg_per_channel_i; relu_q <= cfg_relu_i;
            n_q <= cfg_n_i; param_base_q <= cfg_param_base_i;
            mult_q <= cfg_mult_i; shift_q <= cfg_shift_i; out_zp_q <= cfg_out_zp_i;
            clamp_min_q <= cfg_clamp_min_i; clamp_max_q <= cfg_clamp_max_i;
            loading_q <= cfg_per_channel_i && cfg_n_i != 0;
            req_count_q <= 0; rsp_count_q <= 0;
        end else if (loading_q) begin
            if (p_req_valid_o && p_req_ready_i) req_count_q <= req_count_q + 1;
            if (p_rsp_valid_i) begin
                ch_mult_q[CH_W'(rsp_count_q)] <= p_rsp_data_i[63:32];
                ch_shift_q[CH_W'(rsp_count_q)] <= p_rsp_data_i[71:64];
                rsp_count_q <= rsp_count_q + 1;
                if (rsp_count_q + 1 == n_q) loading_q <= 0;
            end
        end
    end

    // Parameters for the presented element; raven_requantize_clamp samples them on acceptance.
    wire [CH_W-1:0] ch = CH_W'(in_col_i);
    wire signed [31:0] el_mult = per_channel_q ? ch_mult_q[ch] : mult_q;
    wire signed [7:0] el_shift = per_channel_q ? ch_shift_q[ch] : shift_q;
    wire signed [7:0] el_min = relu_q && out_zp_q > clamp_min_q ? out_zp_q : clamp_min_q;

    wire q_in_ready;
    assign in_ready_o = q_in_ready && !loading_q;

    raven_requantize_clamp u_requant (
        .clk_i, .rst_ni,
        .in_valid_i(in_valid_i && !loading_q), .in_ready_o(q_in_ready),
        .in_data_i, .in_row_i, .in_col_i,
        .in_index_i(32'd0), // Unused downstream: the writer addresses by row/col.
        .in_channel_i(32'(in_col_i)), .in_last_i,
        .multiplier_i(el_mult), .shift_i(el_shift), .output_zero_point_i(out_zp_q),
        .activation_min_i(el_min), .activation_max_i(clamp_max_q),
        .out_valid_o, .out_ready_i, .out_data_o, .out_row_o, .out_col_o,
        .out_index_o(), .out_channel_o(), .out_last_o
    );

`ifndef SYNTHESIS
    // Soft reset can release after this clock's input sample.
    // Results arrive only for loaded channels, with parameters inside the TFLM range.
    assert property (@(posedge clk_i) disable iff (!rst_ni || !$sampled(rst_ni))
        in_valid_i && in_ready_o |-> 32'(in_col_i) < 32'(n_q)
                                   && el_mult >= 0 && el_shift >= -8'sd31 && el_shift <= 8'sd30)
        else $error("Requant element outside the loaded channels or the supported multiplier/shift range");
    // No record arrives that was not requested, and the table fits the array.
    assert property (@(posedge clk_i) disable iff (!rst_ni || !$sampled(rst_ni))
        p_rsp_valid_i |-> loading_q && rsp_count_q < req_count_q);
    assert property (@(posedge clk_i) disable iff (!rst_ni || !$sampled(rst_ni))
        cfg_load_i && cfg_per_channel_i |-> 32'(cfg_n_i) <= COLS);
    // A held request keeps its address.
    assert property (@(posedge clk_i) disable iff (!rst_ni || !$sampled(rst_ni))
        p_req_valid_o && !p_req_ready_i |=> p_req_valid_o && $stable(p_req_addr_o));
`endif
endmodule
`default_nettype wire
