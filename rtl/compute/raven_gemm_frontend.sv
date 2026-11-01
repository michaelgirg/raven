`default_nettype none
// Gets activation and weight values from memory and pairs them for the MAC array.
// A is stored row-major. B is stored with eight physical column lanes per K step.
//
// Each memory port handles one request at a time:
//   IDLE -> REQUEST -> RESPONSE -> save the returned word -> IDLE
//
// Two A buffers hold row blocks. Two B registers hold packed weight words.
// The array advances only when both sides have data for the same K position.
module raven_gemm_frontend #(
    parameter int ROWS = 8, // Activation lanes feeding the array rows.
    parameter int COLS = 8, // Weight lanes feeding the array columns.
    parameter int ADDR_W = 24 // Width of each bank-local byte offset.
) (
    input wire clk_i, rst_ni, start_i, // Start saves the command fields for this reduction.
    input wire [15:0] m_i, k_i, a_pitch_i, // Active rows, reduction length, and bytes between A rows.
    input wire [ADDR_W-1:0] a_base_i, b_base_i, // Starting byte offsets inside the selected A and B banks.
    // Activation-memory request and response. A transfer occurs only on valid && ready.
    output wire a_req_valid_o,
    input wire a_req_ready_i,
    output wire [ADDR_W-1:0] a_req_addr_o,
    input wire a_rsp_valid_i,
    output wire a_rsp_ready_o,
    input wire [127:0] a_rsp_data_i,
    // Weight-memory request and response, independent of the activation port.
    output wire b_req_valid_o,
    input wire b_req_ready_i,
    output wire [ADDR_W-1:0] b_req_addr_o,
    input wire b_rsp_valid_i,
    output wire b_rsp_ready_o,
    input wire [127:0] b_rsp_data_i,
    // Paired operands going to the array. Keep the same K position until accepted.
    output wire vec_valid_o,
    input wire vec_ready_i,
    output wire vec_last_o, // Is this the last logical K position, including a short final block?
    output logic signed [7:0] a_vec_o [ROWS],
    output logic signed [7:0] b_vec_o [COLS]
);
    typedef enum logic [1:0] {IDLE, REQUEST, RESPONSE} read_state_t;
    read_state_t a_state_q, b_state_q; // Current read state for each independent memory port.
    logic active_q; // Is there an unfinished reduction to feed?
    logic [15:0] m_q, k_q, pitch_q; // Saved command dimensions and A row pitch.
    logic [ADDR_W-1:0] a_base_q, b_base_q; // Saved operand starting offsets.
    logic [31:0] issue_k_q, a_block_q, a_row_q, b_word_q; // Current K position and memory-fill positions.
    logic [127:0] a_cache_q [2][ROWS]; // Two buffers, each holding one 16-byte word per array row.
    logic [127:0] b_cache_q [2]; // Two words, each holding two eight-byte weight vectors.
    logic [1:0] a_full_q, b_full_q; // Which buffer slots contain data that has not been consumed?

    /*
    issue_k_q: "Which K position is the array about to use?"
    a_block_q: "Which group of 16 K values am I filling from A?"
    a_row_q:   "Which active A row still needs its word for that block?"
    b_word_q:  "Which pair of K vectors am I fetching from B?"
    */
    wire a_slot = issue_k_q[4]; // Switch A slots every 16 accepted K positions.
    wire b_slot = issue_k_q[1]; // Switch B slots every two accepted K positions.
    wire take = vec_valid_o && vec_ready_i; // Did the array actually accept this pair?

    // Hold each request address until memory accepts it.
    // A address = base + row * pitch + block * 16 bytes.
    assign a_req_valid_o = rst_ni && active_q && a_state_q == REQUEST;
    assign a_req_addr_o = ADDR_W'(32'(a_base_q) + a_row_q * 32'(pitch_q) + (a_block_q << 4));
    assign a_rsp_ready_o = rst_ni && active_q && a_state_q == RESPONSE;
    // B address = base + word * 16 bytes. Each word contains two K vectors.
    assign b_req_valid_o = rst_ni && active_q && b_state_q == REQUEST;
    assign b_req_addr_o = ADDR_W'(32'(b_base_q) + (b_word_q << 4));
    assign b_rsp_ready_o = rst_ni && active_q && b_state_q == RESPONSE;
    // Send a pair only if:
    // 1. this reduction is still active
    // 2. the selected A block is full
    // 3. the selected B word is full
    assign vec_valid_o = active_q && a_full_q[a_slot] && b_full_q[b_slot];
    assign vec_last_o = issue_k_q + 1 == 32'(k_q); // Stop at logical K; do not multiply the padding bytes.
    always_comb begin
        // Pick the same byte position from each cached A row.
        for (int r = 0; r < ROWS; r++)
            a_vec_o[r] = $signed(a_cache_q[a_slot][r][issue_k_q[3:0]*8 +: 8]);
        // K bit 0 picks the lower or upper eight-byte vector, then c picks its column.
        for (int c = 0; c < COLS; c++)
            b_vec_o[c] = $signed(b_cache_q[b_slot][(int'(issue_k_q[0])*8+c)*8 +: 8]);
    end

    always_ff @(posedge clk_i) begin
        // Reset clears cached operands and all pending local read state.
        // The connected memory responders must be reset/flushed at the same time.
        if (!rst_ni) begin
            active_q <= 1'b0;
            a_state_q <= IDLE; b_state_q <= IDLE;
            m_q <= '0; k_q <= '0; pitch_q <= '0;
            a_base_q <= '0; b_base_q <= '0;
            issue_k_q <= '0; a_block_q <= '0; a_row_q <= '0; b_word_q <= '0;
            a_full_q <= '0; b_full_q <= '0;
            for (int s = 0; s < 2; s++) begin
                b_cache_q[s] <= '0;
                for (int r = 0; r < ROWS; r++) a_cache_q[s][r] <= '0;
            end
        end else if (start_i) begin // Save a new reduction and mark both sides empty.
            active_q <= 1'b1;
            m_q <= m_i; k_q <= k_i; pitch_q <= a_pitch_i;
            a_base_q <= a_base_i; b_base_q <= b_base_i;
            issue_k_q <= '0; a_block_q <= '0; a_row_q <= '0; b_word_q <= '0;
            a_full_q <= '0; b_full_q <= '0;
            a_state_q <= IDLE; b_state_q <= IDLE;
        end else if (active_q) begin
            // Fill one A block by reading one word from every active row.
            case (a_state_q)
                // Do not overwrite a full slot, and do not fetch past the logical K range.
                IDLE: if ((a_block_q << 4) < 32'(k_q) && !a_full_q[a_block_q[0]]) begin
                    a_row_q <= 0; a_state_q <= REQUEST; // Start with the first active row.
                end
                REQUEST: if (a_req_ready_i) a_state_q <= RESPONSE; // Request accepted; wait for its returned word.
                RESPONSE: if (a_rsp_valid_i) begin
                    a_cache_q[a_block_q[0]][a_row_q] <= a_rsp_data_i; // Put the returned word into this row's slot.
                    if (a_row_q + 1 == 32'(m_q)) begin
                        // Last active row: the whole block can now feed the array.
                        a_full_q[a_block_q[0]] <= 1'b1;
                        a_block_q <= a_block_q + 1; a_state_q <= IDLE;
                    end else begin
                        a_row_q <= a_row_q + 1; a_state_q <= REQUEST; // This block still needs another row.
                    end
                end
                default: a_state_q <= IDLE;
            endcase
            // Fill B independently. One returned word supplies two K positions.
            case (b_state_q)
                IDLE: if ((b_word_q << 1) < 32'(k_q) && !b_full_q[b_word_q[0]])
                    b_state_q <= REQUEST;
                REQUEST: if (b_req_ready_i) b_state_q <= RESPONSE; // Keep only one outstanding B read.
                RESPONSE: if (b_rsp_valid_i) begin
                    b_cache_q[b_word_q[0]] <= b_rsp_data_i; // Save the word before marking the slot full.
                    b_full_q[b_word_q[0]] <= 1'b1;
                    b_word_q <= b_word_q + 1; b_state_q <= IDLE;
                end
                default: b_state_q <= IDLE;
            endcase
            if (take) begin
                issue_k_q <= issue_k_q + 1; // Both operands were accepted, so advance them together.
                // Free A after its 16 bytes and B after its two vectors.
                // A short final K block also frees its slots instead of using padding.
                if (issue_k_q[3:0] == 15 || vec_last_o) a_full_q[a_slot] <= 1'b0;
                if (issue_k_q[0] || vec_last_o) b_full_q[b_slot] <= 1'b0;
                if (vec_last_o) active_q <= 1'b0; // All logical K positions have been issued.
            end
        end
    end
endmodule
`default_nettype wire
