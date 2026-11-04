`default_nettype none
// One outstanding 128-bit bank read, staged through a real tile buffer.
// KIND 0: activationBuffer, 1: weightBuffer, 2: parameterBuffer.
// Full bank addresses go to backing memory; low address bits select a reused
// staging slot. Every request refills that slot before returning its contents.
module raven_read_buffer_adapter #(
    parameter int KIND = 0
) (
    input wire clk_i, rst_ni,
    input wire req_valid_i,
    output wire req_ready_o,
    input wire [23:0] req_addr_i,
    output wire rsp_valid_o,
    input wire rsp_ready_i,
    output wire [127:0] rsp_data_o,
    output wire mem_req_valid_o,
    input wire mem_req_ready_i,
    output wire [23:0] mem_req_addr_o,
    input wire mem_rsp_valid_i,
    output wire mem_rsp_ready_o,
    input wire [127:0] mem_rsp_data_i
);
    typedef enum logic [3:0] {MODE_MULT, MODE_SHIFT, IDLE, FETCH_REQ,
        FETCH_RSP, WRITE_SLOT, READ_REQ, READ_RSP, RESPONSE} state_t;
    state_t state_q;
    logic [23:0] addr_q;
    logic [127:0] word_q;
    logic [1:0] write_step_q;
    logic [3:0] read_step_q;
    wire native_wr_ready, native_rd_ready, native_rsp_valid;
    wire [127:0] native_data;
    wire native_rd_valid = rst_ni && state_q == READ_REQ;
    wire native_rsp_ready = rst_ni && state_q == READ_RSP;
    wire native_wr_valid = rst_ni && (state_q == WRITE_SLOT ||
        (KIND == 2 && state_q inside {MODE_MULT, MODE_SHIFT}));

    assign req_ready_o = rst_ni && state_q == IDLE;
    assign rsp_valid_o = rst_ni && state_q == RESPONSE;
    assign rsp_data_o = word_q;
    assign mem_req_valid_o = rst_ni && state_q == FETCH_REQ;
    assign mem_req_addr_o = addr_q;
    assign mem_rsp_ready_o = rst_ni && state_q == FETCH_RSP;

    generate
        if (KIND == 0) begin : g_activation
            wire [63:0] data;
            activationBuffer u_buffer (
                .clk(clk_i), .rst(!rst_ni),
                .wr_valid(native_wr_valid), .wr_ready(native_wr_ready),
                .wr_bank(addr_q[6:4]), .wr_data(word_q),
                .rd_valid_in(native_rd_valid), .rd_ready(native_rd_ready), .rd_k(read_step_q),
                .rd_valid_out(native_rsp_valid), .rd_ready_out(native_rsp_ready), .rd_data(data)
            );
            assign native_data = {120'd0, data[8*addr_q[6:4] +: 8]};
        end else if (KIND == 1) begin : g_weight
            wire [63:0] data;
            weightBuffer u_buffer (
                .clk(clk_i), .rst(!rst_ni),
                .wr_valid(native_wr_valid), .wr_ready(native_wr_ready),
                .wr_bank(addr_q[6:3] + 4'(write_step_q)),
                .wr_data(write_step_q == 0 ? word_q[63:0] : word_q[127:64]),
                .rd_valid_in(native_rd_valid), .rd_ready(native_rd_ready),
                .rd_k(addr_q[6:3] + read_step_q),
                .rd_valid_out(native_rsp_valid), .rd_ready_out(native_rsp_ready), .rd_data(data)
            );
            assign native_data = {64'd0, data};
        end else begin : g_parameter
            logic [5:0] wr_addr;
            logic [31:0] wr_data;
            wire signed [31:0] bias, mult;
            wire signed [7:0] shift;
            always @* begin
                wr_addr = 6'(addr_q[6:4]); wr_data = word_q[31:0];
                if (state_q == MODE_MULT) begin wr_addr = 27; wr_data = 1; end
                else if (state_q == MODE_SHIFT) begin wr_addr = 28; wr_data = 1; end
                else if (write_step_q == 1) begin
                    wr_addr = 8 + 6'(addr_q[6:4]); wr_data = word_q[63:32];
                end else if (write_step_q == 2) begin
                    wr_addr = 16 + 6'(addr_q[6:4]); wr_data = {24'd0, word_q[71:64]};
                end
            end
            parameterBuffer u_buffer (
                .clk(clk_i), .rst(!rst_ni),
                .wr_valid(native_wr_valid), .wr_ready(native_wr_ready), .wr_addr, .wr_data,
                .rd_valid_in(native_rd_valid), .rd_ready(native_rd_ready), .rd_channel(addr_q[6:4]),
                .rd_valid_out(native_rsp_valid), .rd_ready_out(native_rsp_ready),
                .rd_bias(bias), .rd_multiplier(mult), .rd_shift(shift),
                .rd_zero_point(), .rd_clamp_min(), .rd_clamp_max()
            );
            // Global zero-point/clamp values remain command fields, not PARAM records.
            assign native_data = {word_q[127:72], shift, mult, bias};
        end
    endgenerate

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q <= KIND == 2 ? MODE_MULT : IDLE;
            addr_q <= 0; word_q <= 0; write_step_q <= 0; read_step_q <= 0;
        end else begin
            case (state_q)
                MODE_MULT: if (native_wr_ready) state_q <= MODE_SHIFT;
                MODE_SHIFT: if (native_wr_ready) state_q <= IDLE;
                IDLE: if (req_valid_i) begin addr_q <= req_addr_i; state_q <= FETCH_REQ; end
                FETCH_REQ: if (mem_req_ready_i) state_q <= FETCH_RSP;
                FETCH_RSP: if (mem_rsp_valid_i) begin
                    word_q <= mem_rsp_data_i; write_step_q <= 0; read_step_q <= 0;
                    state_q <= WRITE_SLOT;
                end
                WRITE_SLOT: if (native_wr_ready) begin
                    if ((KIND == 0) || (KIND == 1 && write_step_q == 1) ||
                            (KIND == 2 && write_step_q == 2)) state_q <= READ_REQ;
                    else write_step_q <= write_step_q + 1;
                end
                READ_REQ: if (native_rd_ready) state_q <= READ_RSP;
                READ_RSP: if (native_rsp_valid) begin
                    if (KIND == 0) word_q[8*read_step_q +: 8] <= native_data[7:0];
                    else if (KIND == 1) word_q[64*read_step_q +: 64] <= native_data[63:0];
                    else word_q <= native_data;
                    if ((KIND == 0 && read_step_q == 15) ||
                            (KIND == 1 && read_step_q == 1) || KIND == 2) state_q <= RESPONSE;
                    else begin read_step_q <= read_step_q + 1; state_q <= READ_REQ; end
                end
                RESPONSE: if (rsp_ready_i) state_q <= IDLE;
                default: state_q <= KIND == 2 ? MODE_MULT : IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial assert (KIND inside {0, 1, 2}) else $fatal(1, "Unsupported read-buffer kind");
    assert property (@(posedge clk_i) disable iff (!rst_ni || !$sampled(rst_ni))
        req_valid_i && req_ready_o |-> req_addr_i[3:0] == 0);
    assert property (@(posedge clk_i) disable iff (!rst_ni || !$sampled(rst_ni))
        mem_req_valid_o && !mem_req_ready_i |=> mem_req_valid_o && $stable(mem_req_addr_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni || !$sampled(rst_ni))
        rsp_valid_o && !rsp_ready_i |=> rsp_valid_o && $stable(rsp_data_o));
`endif
endmodule
`default_nettype wire
