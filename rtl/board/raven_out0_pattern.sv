`default_nettype none
// Deterministic OUT0 read responder for board bring-up (B7 of docs/plans/nahjay_board_prototype.md).
//
// Stands in for the OUT0 bank's logical read port until the real memory adapter exists,
// so the AXI bridge, block design and JTAG path can be tested on the board. Byte n of the
// response to a request at aligned offset a is ((a + n) mod 256) ^ 8'h5A. In other words,
// OUT0 byte p always reads as p[7:0] ^ 8'h5A, and every byte inside a word and every lane
// differs, so alignment or lane-select mistakes are visible in a single read.
//
// Implements the bank read contract: one outstanding request, the response is held until
// accepted, and local_rst_ni drops any pending request or response.
module raven_out0_pattern #(
    parameter int LATENCY = 1 // Extra clocks between request acceptance and response (0-255).
) (
    input wire clk_i, // Board clock.
    input wire local_rst_ni, // Datapath/bank reset, active low, synchronous.
    input wire req_valid_i, // Read request presented.
    output wire req_ready_o, // Request accepted.
    input wire [12:0] req_addr_i, // 16-byte-aligned OUT0 byte offset.
    output logic rsp_valid_o, // Response presented.
    input wire rsp_ready_i, // Response accepted.
    output logic [127:0] rsp_data_o // Byte addr+n in bits [8*n +: 8].
);
    localparam logic [7:0] PATTERN_KEY = 8'h5A;

    logic pending_q; // A request is accepted and its response is not yet presented.
    logic [7:0] wait_q; // Clocks left before the response.
    logic [12:0] addr_q; // Address of the pending request.

    assign req_ready_o = local_rst_ni && !pending_q && !rsp_valid_o;

    function automatic logic [127:0] pattern_word(input logic [12:0] addr);
        logic [127:0] word;
        for (int n = 0; n < 16; n++) word[8*n +: 8] = 8'(addr + 13'(n)) ^ PATTERN_KEY;
        return word;
    endfunction

    always_ff @(posedge clk_i) begin
        if (!local_rst_ni) begin
            pending_q <= 0; wait_q <= '0; addr_q <= '0;
            rsp_valid_o <= 0; rsp_data_o <= '0;
        end else begin
            if (rsp_valid_o && rsp_ready_i) rsp_valid_o <= 0;
            if (pending_q) begin
                if (wait_q == 0) begin
                    rsp_valid_o <= 1; rsp_data_o <= pattern_word(addr_q); pending_q <= 0;
                end else wait_q <= wait_q - 1;
            end
            if (req_valid_i && req_ready_o) begin
                pending_q <= 1; wait_q <= 8'(LATENCY); addr_q <= req_addr_i;
            end
        end
    end

`ifndef SYNTHESIS
    initial assert (LATENCY >= 0 && LATENCY <= 255) else $fatal(1, "LATENCY must be 0-255");
    // Requests are word aligned.
    always @(posedge clk_i)
        if (local_rst_ni && req_valid_i && req_ready_o)
            assert (req_addr_i[3:0] == 0) else $fatal(1, "Unaligned OUT0 read request %h", req_addr_i);
    // The response holds until accepted.
    assert property (@(posedge clk_i) disable iff (!local_rst_ni)
        rsp_valid_o && !rsp_ready_i |=> rsp_valid_o && $stable(rsp_data_o));
`endif
endmodule
`default_nettype wire
