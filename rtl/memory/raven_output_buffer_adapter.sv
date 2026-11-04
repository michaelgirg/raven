`default_nettype none
// Stage every strobed byte through outputBuffer before committing to backing memory.
// Upstream ready is deferred until the backing write is accepted: the result
// writer's stored_last event must still mean stored, not merely buffered.
module raven_output_buffer_adapter (
    input wire clk_i, rst_ni,
    input wire w_valid_i,
    output wire w_ready_o,
    input wire [23:0] w_addr_i,
    input wire [127:0] w_data_i,
    input wire [15:0] w_strb_i,
    output wire mem_w_valid_o,
    input wire mem_w_ready_i,
    output wire [23:0] mem_w_addr_o,
    output wire [127:0] mem_w_data_o,
    output wire [15:0] mem_w_strb_o
);
    typedef enum logic [2:0] {IDLE, WRITE_ROW, READ_REQ, READ_RSP, COMMIT} state_t;
    state_t state_q;
    logic [23:0] addr_q;
    logic [127:0] source_q, staged_q;
    logic [15:0] strb_q;
    logic half_q;
    wire wr_ready, rd_ready, rd_valid;
    wire [63:0] rd_data;
    wire [2:0] row = {addr_q[5:4], half_q};

    outputBuffer u_buffer (
        .clk(clk_i), .rst(!rst_ni),
        .wr_valid(rst_ni && state_q == WRITE_ROW), .wr_ready,
        .wr_row(row), .wr_data(half_q ? source_q[127:64] : source_q[63:0]),
        .rd_valid_in(rst_ni && state_q == READ_REQ), .rd_ready, .rd_row(row),
        .rd_valid_out(rd_valid), .rd_ready_out(rst_ni && state_q == READ_RSP), .rd_data
    );
    assign mem_w_valid_o = rst_ni && state_q == COMMIT;
    assign mem_w_addr_o = addr_q;
    assign mem_w_data_o = staged_q;
    assign mem_w_strb_o = strb_q;
    assign w_ready_o = rst_ni && state_q == COMMIT && mem_w_ready_i;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q <= IDLE; addr_q <= 0; source_q <= 0;
            staged_q <= 0; strb_q <= 0; half_q <= 0;
        end else begin
            case (state_q)
                // Peek at a held request; acknowledge only on the eventual commit.
                IDLE: if (w_valid_i) begin
                    addr_q <= w_addr_i; source_q <= w_data_i; strb_q <= w_strb_i;
                    staged_q <= 0; half_q <= !(|w_strb_i[7:0]); state_q <= WRITE_ROW;
                end
                WRITE_ROW: if (wr_ready) state_q <= READ_REQ;
                READ_REQ: if (rd_ready) state_q <= READ_RSP;
                READ_RSP: if (rd_valid) begin
                    if (half_q) staged_q[127:64] <= rd_data;
                    else staged_q[63:0] <= rd_data;
                    if (!half_q && |strb_q[15:8]) begin half_q <= 1; state_q <= WRITE_ROW; end
                    else state_q <= COMMIT;
                end
                COMMIT: if (mem_w_ready_i) state_q <= IDLE;
                default: state_q <= IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni || !$sampled(rst_ni))
        w_valid_i && !w_ready_o |=> w_valid_i && $stable({w_addr_i, w_data_i, w_strb_i}));
    assert property (@(posedge clk_i) disable iff (!rst_ni || !$sampled(rst_ni))
        state_q == IDLE && w_valid_i |-> w_addr_i[3:0] == 0 && w_strb_i != 0);
    assert property (@(posedge clk_i) disable iff (!rst_ni || !$sampled(rst_ni))
        mem_w_valid_o && !mem_w_ready_i |=> mem_w_valid_o && $stable({mem_w_addr_o, mem_w_data_o, mem_w_strb_o}));
    assert property (@(posedge clk_i) disable iff (!rst_ni || !$sampled(rst_ni))
        w_valid_i && w_ready_o |-> mem_w_valid_o && mem_w_ready_i);
`endif
endmodule
`default_nettype wire
