`default_nettype none
// Registered INT8 multiply-accumulate processing element.
//
// This PE calculates one output element:
//   init_i -> save the starting sum -> accept products -> add saved products
//                                                   \-> commit the last product
//
// A product is saved on one clock and added to the sum on the next clock.
// The PE can save a new product while adding the previous one.
module raven_mac_pe (
    input  wire                  clk_i, // Clock shared by the product and sum registers.
    input  wire                  rst_ni, // Active-low reset, checked on the rising clock edge.
    input  wire                  init_i, // Start a new output and discard the previous product.
    input  wire signed [31:0]    seed_i, // Starting sum, including corrected bias.
    input  wire                  step_valid_i, // Are the input operands real data for this clock?
    input  wire                  step_last_i, // Is this the last product in the reduction?
    input  wire signed [7:0]     a_i, // Signed activation value.
    input  wire signed [7:0]     b_i, // Signed weight value.
    output logic signed [31:0]   sum_o, // Accumulated result for this output element.
    output logic                 last_committed_o, // Pulses when the last saved product is added.
    output logic                 overflow_o // Stays high if any addition goes outside signed INT32.
);
    logic signed [15:0] product_q; // Product waiting to be added to the sum.
    logic product_valid_q, product_last_q; // Valid and last flags that travel with the saved product.

    // Extend both signed values before adding them.
    // The extra bit lets us check whether the result still fits in 32 bits.
    wire signed [32:0] next_sum = {sum_o[31], sum_o}
                                  + {{17{product_q[15]}}, product_q};

    always_ff @(posedge clk_i) begin
        // Reset clears the sum, saved product, completion flag, and overflow flag.
        if (!rst_ni) begin
            product_q <= '0;
            product_valid_q <= 1'b0;
            product_last_q <= 1'b0;
            sum_o <= '0;
            last_committed_o <= 1'b0;
            overflow_o <= 1'b0;
        end else if (init_i) begin // New output: load its seed instead of continuing the old sum.
            product_q <= '0;
            product_valid_q <= 1'b0;
            product_last_q <= 1'b0;
            sum_o <= seed_i; // Apply this output's corrected bias once at initialization.
            last_committed_o <= 1'b0;
            overflow_o <= 1'b0;
        end else begin
            /*
            Save the flags for the product being accepted now.
            At the same time, check the flags for the product already saved.
            Nonblocking assignments let these two pipeline steps happen together.
            */
            product_valid_q <= step_valid_i;
            product_last_q <= step_valid_i && step_last_i;
            last_committed_o <= product_valid_q && product_last_q; // Completion follows the addition, not just the input.
            if (step_valid_i) product_q <= a_i * b_i; // Save the full signed 16-bit product.
            if (product_valid_q) begin
                sum_o <= next_sum[31:0]; // Add only a valid saved product; bubbles do not repeat it.
                // If the top two bits differ, the signed sum did not fit in INT32.
                // Keep the flag set until reset or initialization. The core rejects this tile.
                overflow_o <= overflow_o || (next_sum[32] != next_sum[31]);
            end
        end
    end
endmodule
`default_nettype wire
