`default_nettype none
// INT8 result writer: requant output -> byte writes into the OUT bank.
//
// Each accepted INT8 element at (row, col) is written to byte
//   addr = dst_offset + row * out_pitch + col
// as one 128-bit, byte-strobed write: the word address is addr rounded down to 16 bytes,
// the byte is replicated across all lanes, and only lane addr[3:0] is strobed.
// One-entry elastic register: the write holds stable under backpressure. stored_last_o
// pulses on the clock the final element's write is accepted, which is the "output stored"
// event control waits for before retiring (D5). Destination range is checked by control.
module raven_result_writer #(
    parameter int ADDR_W = 24 // Width of the byte offset inside the OUT bank.
) (
    input wire clk_i, rst_ni, // Active-low reset is checked on the rising clock edge.
    // Per-command configuration, sampled on cfg_load_i.
    input wire cfg_load_i, // One-clock pulse when the command launches.
    input wire [ADDR_W-1:0] cfg_dst_offset_i, // Byte offset of output element (0, 0); 16-byte aligned.
    input wire [15:0] cfg_out_pitch_i, // Bytes between output rows (P4).
    // INT8 results from the requant.
    input wire in_valid_i, // Is an INT8 result presented?
    output wire in_ready_o, // Can the writer take it this clock?
    input wire [7:0] in_data_i, // Requantized INT8 value.
    input wire [15:0] in_row_i, in_col_i, // Position of this element inside the tile.
    input wire in_last_i, // Final element of the command.
    // OUT bank write port.
    output wire w_valid_o, // Is a write presented?
    input wire w_ready_i, // Bank accepts (and commits) the write this clock.
    output logic [ADDR_W-1:0] w_addr_o, // 16-byte-aligned word address.
    output logic [127:0] w_data_o, // INT8 value replicated into every byte lane.
    output logic [15:0] w_strb_o, // One-hot byte strobe for lane addr[3:0].
    // Status.
    output wire stored_last_o, // One-clock pulse: the final element's write was accepted.
    output wire stall_o, // A write is presented but not accepted this clock.
    output logic [31:0] writes_o // Writes accepted since reset.
);
    logic [ADDR_W-1:0] dst_offset_q; // Configuration of the active command.
    logic [15:0] out_pitch_q;
    logic w_valid_q, last_q; // Write register state.

    // Byte address of the incoming element, computed wide so the range assertion can see overflow.
    wire [31:0] byte_addr = 32'(dst_offset_q) + 32'(in_row_i) * 32'(out_pitch_q) + 32'(in_col_i);

    assign in_ready_o = rst_ni && (!w_valid_q || w_ready_i);
    assign w_valid_o = w_valid_q;
    assign stored_last_o = w_valid_q && w_ready_i && last_q;
    assign stall_o = w_valid_q && !w_ready_i;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            dst_offset_q <= '0; out_pitch_q <= '0;
            w_valid_q <= 0; last_q <= 0;
            w_addr_o <= '0; w_data_o <= '0; w_strb_o <= '0;
            writes_o <= 0;
        end else begin
            if (cfg_load_i) begin
                dst_offset_q <= cfg_dst_offset_i;
                out_pitch_q <= cfg_out_pitch_i;
            end
            if (w_valid_q && w_ready_i) writes_o <= writes_o + 1;
            if (in_valid_i && in_ready_o) begin
                w_valid_q <= 1;
                w_addr_o <= ADDR_W'({byte_addr[31:4], 4'b0000});
                w_data_o <= {16{in_data_i}};
                w_strb_o <= 16'd1 << byte_addr[3:0];
                last_q <= in_last_i;
            end else if (w_valid_q && w_ready_i) begin
                w_valid_q <= 0;
            end
        end
    end

`ifndef SYNTHESIS
    // Soft reset can release after this clock's input sample.
    // A presented write holds stable until the bank accepts it.
    assert property (@(posedge clk_i) disable iff (!rst_ni || !$sampled(rst_ni))
        w_valid_o && !w_ready_i |=> w_valid_o && $stable({w_addr_o, w_data_o, w_strb_o, last_q}));
    // Control's span check keeps every element inside the bank-local address range.
    assert property (@(posedge clk_i) disable iff (!rst_ni || !$sampled(rst_ni))
        in_valid_i && in_ready_o |-> byte_addr < (32'd1 << ADDR_W));
    // Configuration never changes under an element in flight.
    assert property (@(posedge clk_i) disable iff (!rst_ni || !$sampled(rst_ni))
        cfg_load_i |-> !w_valid_q);
`endif
endmodule
`default_nettype wire
