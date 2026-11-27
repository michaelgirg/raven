`timescale 1ns/1ps
`default_nettype none

module raven_bram_bank #(
    parameter int BANK_BYTES = 16 * 1024,
    parameter string INIT_FILE = ""
) (
    input wire clk_i,
    input wire rst_ni,

    input wire rd_req_valid_i,
    output wire rd_req_ready_o,
    input wire [23:0] rd_req_addr_i,
    output wire rd_rsp_valid_o,
    input wire rd_rsp_ready_i,
    output wire [127:0] rd_rsp_data_o,

    input wire w_valid_i,
    output wire w_ready_o,
    input wire [23:0] w_addr_i,
    input wire [127:0] w_data_i,
    input wire [15:0] w_strb_i
);
    localparam int DATA_BYTES = 16;
    localparam int ADDR_W = $clog2(BANK_BYTES);
    localparam int WORDS = BANK_BYTES / DATA_BYTES;
    localparam int WORD_ADDR_W = $clog2(WORDS);

    logic [DATA_BYTES*8-1:0] mem [0:WORDS-1];
    logic [DATA_BYTES*8-1:0] rd_data_q;
    logic rd_valid_q;
    wire rd_addr_valid = rd_req_addr_i[3:0] == 4'b0 &&
                         rd_req_addr_i < BANK_BYTES;
    wire w_addr_valid = w_addr_i[3:0] == 4'b0 &&
                        w_addr_i < BANK_BYTES;
    wire [WORD_ADDR_W-1:0] rd_word_addr =
        WORD_ADDR_W'(rd_req_addr_i[ADDR_W-1:4]);
    wire [WORD_ADDR_W-1:0] w_word_addr =
        WORD_ADDR_W'(w_addr_i[ADDR_W-1:4]);

    assign rd_req_ready_o = rst_ni &&
                            (!rd_valid_q || rd_rsp_ready_i) &&
                            rd_addr_valid;
    assign rd_rsp_valid_o = rst_ni && rd_valid_q;
    assign rd_rsp_data_o = rd_data_q;
    assign w_ready_o = rst_ni && w_addr_valid;

    initial begin
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

`ifndef SYNTHESIS
    initial begin
        if (BANK_BYTES < DATA_BYTES ||
            BANK_BYTES % DATA_BYTES != 0 ||
            (BANK_BYTES & (BANK_BYTES - 1)) != 0)
            $fatal(1, "raven_bram_bank requires a power-of-two byte capacity and 16-byte words");
    end
`endif

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            rd_valid_q <= 1'b0;
            rd_data_q <= '0;
        end else begin
            if (rd_rsp_valid_o && rd_rsp_ready_i)
                rd_valid_q <= 1'b0;

            if (rd_req_valid_i && rd_req_ready_o) begin
                rd_valid_q <= 1'b1;
                rd_data_q <= mem[rd_word_addr];
            end

            if (w_valid_i && w_ready_o && w_addr_valid) begin
                for (int lane = 0; lane < DATA_BYTES; lane++) begin
                    if (w_strb_i[lane])
                        mem[w_word_addr][lane*8 +: 8] <= w_data_i[lane*8 +: 8];
                end
            end
        end
    end

`ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        rd_req_valid_i |-> rd_addr_valid)
        else $fatal(1, "BRAM read address must be aligned and in range");
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        w_valid_i |-> w_addr_valid)
        else $fatal(1, "BRAM write address must be aligned and in range");
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        rd_rsp_valid_o && !rd_rsp_ready_i |=> rd_rsp_valid_o &&
        $stable(rd_rsp_data_o))
        else $fatal(1, "BRAM read response changed while stalled");
`endif
endmodule

`default_nettype wire
