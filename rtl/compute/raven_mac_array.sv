`default_nettype none
// Parameterized output-stationary MAC array.
// Each active PE keeps the sum for one output element.
// Each A value is shared along its row; each B value is shared down its column.
module raven_mac_array #(
    parameter int ROWS = 8, // Number of output rows that fit in the physical array.
    parameter int COLS = 8 // Number of output columns that fit in the physical array.
) (
    input  wire                         clk_i,
    input  wire                         rst_ni,
    input  wire                         init_i,
    input  wire [ROWS-1:0]              row_mask_i, // Which rows belong to the requested tile?
    input  wire [COLS-1:0]              col_mask_i, // Which columns belong to the requested tile?
    input  wire signed [31:0]           seeds_i [COLS], // Starting bias for each output column.
    input  wire                         step_valid_i,
    input  wire                         step_last_i,
    input  wire signed [7:0]            a_i [ROWS], // One activation value for each row at the current K position.
    input  wire signed [7:0]            b_i [COLS], // One weight value for each column at the same K position.
    output wire signed [31:0]           sums_o [ROWS][COLS], // Accumulated output matrix.
    output wire                         last_committed_o, // Pulses after the active PEs add their last product.
    output logic                        overflow_o // Did any PE report an invalid signed INT32 sum?
);
    wire [ROWS*COLS-1:0] overflow; // One overflow flag per PE.
    wire [ROWS*COLS-1:0] last_committed; // One completion flag per PE.

    // For every row
    //      for every column
    //          create one PE that holds that output element's sum
    for (genvar r = 0; r < ROWS; r++) begin : g_row
        for (genvar c = 0; c < COLS; c++) begin : g_col
            // A PE is active only if both its row and column are part of this tile.
            wire active_lane = row_mask_i[r] && col_mask_i[c];
            raven_mac_pe u_pe (
                .clk_i, .rst_ni, .init_i,
                .seed_i(active_lane ? seeds_i[c] : 32'sd0), // Every active row uses this column's bias.
                .step_valid_i(step_valid_i && active_lane), .step_last_i, // Inactive PEs never accept products.
                .a_i(a_i[r]), .b_i(b_i[c]), .sum_o(sums_o[r][c]),
                .last_committed_o(last_committed[r*COLS+c]),
                .overflow_o(overflow[r*COLS+c])
            );
        end
    end
    // All active PEs accept products together, so their final additions happen together.
    // Inactive PEs never assert completion. Any active completion marks this array step done.
    assign last_committed_o = |last_committed;
    // One overflowing PE is enough to make the whole output tile invalid.
    always_comb overflow_o = |overflow;
endmodule
`default_nettype wire
