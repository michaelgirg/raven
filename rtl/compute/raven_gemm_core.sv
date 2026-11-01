`default_nettype none
// GEMM controller for one physical array tile and one complete K reduction.
//
// This core handles one command at a time:
//   IDLE -> PARAM_REQ -> PARAM_RSP -> INIT -> RUN -> PIPE_WAIT -> DRAIN -> FINISH
//        \-> invalid command -> REJECT       \-> overflow -> REJECT
//
// M and N must fit the physical array. The output is one signed INT32 lane.
// These are compute-side command and memory ports, not an AXI interface or CSR map.
module raven_gemm_core #(
    parameter int ROWS = 8, // Number of physical array rows.
    parameter int COLS = 8, // Number of physical array columns.
    parameter int ADDR_W = 24, // Width of the byte offset inside each selected bank.
    parameter int ACT_BYTES = 16384, // Owned activation-bank capacity.
    parameter int WGT_BYTES = 16384, // Owned weight-bank capacity.
    parameter int PRM_BYTES = 4096 // Owned parameter-bank capacity.
) (
    input wire clk_i, rst_ni, // Active-low reset is checked on the rising clock edge.
    input wire cmd_valid_i, // Is there a command for the core to accept?
    output wire cmd_ready_o, // Can the core accept a new command this clock?
    input wire [15:0] cmd_m_i, cmd_n_i, cmd_k_i, cmd_a_pitch_i, // Logical M/N/K and bytes between A rows.
    input wire [ADDR_W-1:0] cmd_a_base_i, cmd_b_base_i, cmd_param_base_i, // Operand and parameter byte offsets.
    // Activation-memory request and response.
    output wire a_req_valid_o,
    input wire a_req_ready_i,
    output wire [ADDR_W-1:0] a_req_addr_o,
    input wire a_rsp_valid_i,
    output wire a_rsp_ready_o,
    input wire [127:0] a_rsp_data_i,
    // Weight-memory request and response.
    output wire b_req_valid_o,
    input wire b_req_ready_i,
    output wire [ADDR_W-1:0] b_req_addr_o,
    input wire b_rsp_valid_i,
    output wire b_rsp_ready_o,
    input wire [127:0] b_rsp_data_i,
    // Parameter-memory request and response. Each channel record is 16 bytes.
    output wire p_req_valid_o,
    input wire p_req_ready_i,
    output wire [ADDR_W-1:0] p_req_addr_o,
    input wire p_rsp_valid_i,
    output wire p_rsp_ready_o,
    input wire [127:0] p_rsp_data_i,
    output wire result_valid_o, // Is the selected INT32 result ready to be consumed?
    input wire result_ready_i, // Can the consumer accept that result?
    output logic signed [31:0] result_data_o, // Current output element, including bias.
    output wire [15:0] result_row_o, result_col_o, // Position of this element inside the tile.
    output wire [31:0] result_index_o, // Logical row-major index; this is not a memory byte address.
    output wire result_last_o, // Marks the final element when result_valid_o is high.
    output wire busy_o, // Is the core still processing a command?
    output logic compute_done_o, result_done_o, error_o, // One-clock completion and rejection pulses.
    output logic [7:0] error_code_o, // Holds the command's error code until the next command or reset.
    // Per-command diagnostic counters, not the full system's CSR counters.
    output logic [31:0] cycles_o, issued_steps_o, input_stall_cycles_o,
    output logic [31:0] output_stall_cycles_o
);
    typedef enum logic [3:0] {IDLE, PARAM_REQ, PARAM_RSP, INIT, RUN,
                             PIPE_WAIT, DRAIN, FINISH, REJECT} state_t;
    state_t state_q; // Current command-processing state.
    logic [15:0] m_q, n_q, k_q, pitch_q; // Dimensions and pitch after the command is accepted.
    logic [ADDR_W-1:0] a_base_q, b_base_q, p_base_q; // Saved bank-local starting offsets.
    logic [31:0] p_col_q, drain_row_q, drain_col_q; // Parameter channel and next output position.
    logic signed [31:0] seeds_q [COLS]; // Corrected bias for each active output column.
    // Compute uses only the corrected bias. The rest of the record is for the output operators.
    wire [95:0] unused_param_quantization = p_rsp_data_i[127:32];
    logic [ROWS-1:0] row_mask; // Which physical rows belong to this command?
    logic [COLS-1:0] col_mask; // Which physical columns belong to this command?
    wire signed [31:0] sums [ROWS][COLS]; // Current sums coming from the MAC array.
    wire signed [7:0] a_vec [ROWS], b_vec [COLS]; // Paired operands from the frontend.
    wire vec_valid, vec_last, last_committed, acc_overflow; // Operand and array-completion flags.
    wire vec_ready = state_q == RUN; // Only accept new K positions while computing.

    // Round K up to the full 16-byte reads made by the A frontend.
    // Padding must belong to the bank even though it is not included in the sum.
    wire [63:0] rounded_k = (64'(cmd_k_i) + 15) & ~64'd15;
    // Calculate exclusive end offsets in 64 bits before checking bank capacity.
    // A includes the last row's padded read; B has eight physical lanes per K.
    wire [63:0] a_end = 64'(cmd_a_base_i)
                        + ((cmd_m_i == 0 ? 0 : 64'(cmd_m_i)-1)*64'(cmd_a_pitch_i))
                        + rounded_k;
    wire [63:0] b_end = 64'(cmd_b_base_i) + ((64'(cmd_k_i)*8+15) & ~64'd15);
    wire [63:0] p_end = 64'(cmd_param_base_i) + 64'(cmd_n_i)*16; // One full record per active column.
    // Reject zero/oversized dimensions or an A pitch too short for its padded row.
    wire bad_dim = cmd_m_i == 0 || cmd_n_i == 0 || cmd_k_i == 0
                   || 32'(cmd_m_i) > ROWS || 32'(cmd_n_i) > COLS
                   || 64'(cmd_a_pitch_i) < rounded_k;
    // Every read begins on a 16-byte boundary, and the full read must fit its bank.
    wire bad_range = |cmd_a_base_i[3:0] || |cmd_b_base_i[3:0]
                     || |cmd_param_base_i[3:0] || |cmd_a_pitch_i[3:0]
                     || a_end > 64'(ACT_BYTES) || b_end > 64'(WGT_BYTES)
                     || p_end > 64'(PRM_BYTES);

    // Connect the current state and saved positions to the public interfaces.
    // A command is accepted only when valid and ready are both high.
    assign cmd_ready_o = rst_ni && state_q == IDLE;
    assign busy_o = state_q != IDLE;
    assign p_req_valid_o = rst_ni && state_q == PARAM_REQ;
    assign p_req_addr_o = p_base_q + ADDR_W'(p_col_q << 4); // PARAM base + channel * 16 bytes.
    assign p_rsp_ready_o = rst_ni && state_q == PARAM_RSP;
    assign result_valid_o = rst_ni && state_q == DRAIN;
    assign result_row_o = 16'(drain_row_q);
    assign result_col_o = 16'(drain_col_q);
    assign result_index_o = drain_row_q * 32'(n_q) + drain_col_q; // Flatten row/column into a logical element number.
    assign result_last_o = drain_row_q + 1 == 32'(m_q) && drain_col_q + 1 == 32'(n_q);
    always_comb begin
        // Disable the unused physical rows and columns for a smaller logical tile.
        for (int r = 0; r < ROWS; r++) row_mask[r] = r < int'(m_q);
        for (int c = 0; c < COLS; c++) col_mask[c] = c < int'(n_q);
        result_data_o = sums[drain_row_q][drain_col_q]; // Select the element being drained; valid only in DRAIN.
    end
    // The frontend owns operand reads and byte selection.
    // INIT starts it with the saved command, so later command-bus changes do not affect this tile.
    raven_gemm_frontend #(.ROWS(ROWS), .COLS(COLS), .ADDR_W(ADDR_W)) u_frontend (
        .clk_i, .rst_ni, .start_i(state_q == INIT), .m_i(m_q), .k_i(k_q),
        .a_pitch_i(pitch_q), .a_base_i(a_base_q), .b_base_i(b_base_q),
        .a_req_valid_o, .a_req_ready_i, .a_req_addr_o, .a_rsp_valid_i, .a_rsp_ready_o, .a_rsp_data_i,
        .b_req_valid_o, .b_req_ready_i, .b_req_addr_o, .b_rsp_valid_i, .b_rsp_ready_o, .b_rsp_data_i,
        .vec_valid_o(vec_valid), .vec_ready_i(vec_ready), .vec_last_o(vec_last),
        .a_vec_o(a_vec), .b_vec_o(b_vec)
    );
    // The array owns the actual products and sums. The core supplies masks and bias seeds.
    raven_mac_array #(.ROWS(ROWS), .COLS(COLS)) u_array (
        .clk_i, .rst_ni, .init_i(state_q == INIT), .row_mask_i(row_mask), .col_mask_i(col_mask),
        .seeds_i(seeds_q), .step_valid_i(vec_valid && vec_ready), .step_last_i(vec_last),
        .a_i(a_vec), .b_i(b_vec), .sums_o(sums),
        .last_committed_o(last_committed), .overflow_o(acc_overflow)
    );
    /*
           IDLE: save and check the command
            |
        PARAM_REQ -> PARAM_RSP: read one bias record per active column
            |
           INIT: load the bias seeds and start operand gathering
            |
            RUN: issue paired A/B values until the last K position
            |
        PIPE_WAIT: wait for the last saved product to be added
            |
           DRAIN: send each INT32 result when the consumer is ready
            |
          FINISH: pulse result_done and return to IDLE

    Invalid command fields or an overflowing sum take the REJECT path.
    */
    always_ff @(posedge clk_i) begin
        // Reset clears the saved command, bias values, positions, status, and counters.
        if (!rst_ni) begin
            state_q <= IDLE;
            m_q <= 0; n_q <= 0; k_q <= 0; pitch_q <= 0;
            a_base_q <= 0; b_base_q <= 0; p_base_q <= 0;
            p_col_q <= 0; drain_row_q <= 0; drain_col_q <= 0;
            compute_done_o <= 0; result_done_o <= 0; error_o <= 0; error_code_o <= 0;
            cycles_o <= 0; issued_steps_o <= 0;
            input_stall_cycles_o <= 0; output_stall_cycles_o <= 0;
            for (int c = 0; c < COLS; c++) seeds_q[c] <= 0;
        end else begin
            // Default to no completion/error pulse. The matching state sets it for one clock.
            compute_done_o <= 0; result_done_o <= 0; error_o <= 0;
            // Count busy clocks, missing operand pairs, and blocked output clocks separately.
            if (busy_o) cycles_o <= cycles_o + 1;
            if (state_q == RUN && !vec_valid) input_stall_cycles_o <= input_stall_cycles_o + 1;
            if (result_valid_o && !result_ready_i) output_stall_cycles_o <= output_stall_cycles_o + 1;
            case (state_q)
                // The core is waiting for a command. Save its fields before starting any reads.
                IDLE: if (cmd_valid_i) begin
                    m_q <= cmd_m_i; n_q <= cmd_n_i; k_q <= cmd_k_i; pitch_q <= cmd_a_pitch_i;
                    a_base_q <= cmd_a_base_i; b_base_q <= cmd_b_base_i; p_base_q <= cmd_param_base_i;
                    p_col_q <= 0; drain_row_q <= 0; drain_col_q <= 0;
                    cycles_o <= 0; issued_steps_o <= 0;
                    input_stall_cycles_o <= 0; output_stall_cycles_o <= 0;
                    error_code_o <= bad_dim ? 8'h02 : bad_range ? 8'h03 : 8'h00; // Dimensions take priority over range errors.
                    state_q <= bad_dim || bad_range ? REJECT : PARAM_REQ; // Invalid commands never issue memory reads.
                end
                // Ask for this column's record, then keep waiting until the response arrives.
                PARAM_REQ: if (p_req_ready_i) state_q <= PARAM_RSP;
                PARAM_RSP: if (p_rsp_valid_i) begin
                    seeds_q[p_col_q] <= $signed(p_rsp_data_i[31:0]); // Corrected bias is the first signed INT32 field.
                    if (p_col_q + 1 == 32'(n_q)) state_q <= INIT; // All active columns now have their bias.
                    else begin p_col_q <= p_col_q + 1; state_q <= PARAM_REQ; end
                end
                INIT: state_q <= RUN; // The array loads its seeds and the frontend starts on this clock.
                RUN: if (vec_valid) begin
                    issued_steps_o <= issued_steps_o + 1; // One accepted pair represents one logical K position.
                    if (vec_last) state_q <= PIPE_WAIT; // The last product is still in the PE pipeline.
                end
                PIPE_WAIT: if (last_committed) begin
                    compute_done_o <= 1; // The final product has reached the sums, even if overflow makes them invalid.
                    // Do not emit any successful results if one PE overflowed.
                    if (acc_overflow) begin error_code_o <= 8'h08; state_q <= REJECT; end
                    else state_q <= DRAIN;
                end
                DRAIN: if (result_ready_i) begin
                    // Result valid is high in this state, so ready completes one transfer.
                    // Without ready, leave the selected element and its tags unchanged.
                    if (result_last_o) state_q <= FINISH;
                    else if (drain_col_q + 1 == 32'(n_q)) begin
                        drain_col_q <= 0; drain_row_q <= drain_row_q + 1; // Finished a row; begin the next one.
                    end else drain_col_q <= drain_col_q + 1;
                end
                FINISH: begin result_done_o <= 1; state_q <= IDLE; end // Every INT32 result was accepted.
                REJECT: begin error_o <= 1; result_done_o <= 1; state_q <= IDLE; end // Complete the command with its saved error code.
                default: state_q <= IDLE;
            endcase
        end
    end
    // These checks catch unsupported configurations and an output that changes during a stall.
    // Final INT8 storage and system command retirement still belong to the downstream integration.
`ifndef SYNTHESIS
    initial begin
        assert (ROWS >= 1 && ROWS <= 8 && COLS >= 1 && COLS <= 8)
            else $fatal(1, "Pre-alpha array dimensions must be within 1..8");
        assert (ADDR_W >= 14 && ADDR_W <= 32)
            else $fatal(1, "Unsupported address width");
    end
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        result_valid_o && !result_ready_i |=> result_valid_o &&
        $stable({result_data_o, result_row_o, result_col_o, result_index_o, result_last_o}));
`endif
endmodule
`default_nettype wire
