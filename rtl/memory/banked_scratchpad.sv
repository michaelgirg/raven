`timescale 1ns/1ps
`default_nettype none

package raven_scratchpad_pkg;

    typedef enum logic [2:0] {
        BANK_FREE       = 3'd0,
        BANK_DMA_FILLING= 3'd1,
        BANK_READY      = 3'd2,
        BANK_COMPUTING  = 3'd3,
        BANK_NPU_WRITING= 3'd4,
        BANK_FULL       = 3'd5,
        BANK_DRAINING   = 3'd6,
        BANK_ERROR      = 3'd7
    } bank_state_e;

    typedef enum logic [2:0] {
        CMD_ACQUIRE_FILL = 3'd0,
        CMD_COMMIT       = 3'd1,
        CMD_ACQUIRE_READ = 3'd2,
        CMD_ACQUIRE_WRITE= 3'd3,
        CMD_RELEASE      = 3'd4,
        CMD_ABORT        = 3'd5
    } bank_cmd_e;

    typedef enum logic [2:0] {
        BANK_ACT0 = 3'd0,
        BANK_ACT1 = 3'd1,
        BANK_WGT0 = 3'd2,
        BANK_WGT1 = 3'd3,
        BANK_OUT0 = 3'd4,
        BANK_PRM  = 3'd5
    } bank_id_e;

    typedef enum logic [1:0] {
        OWNER_NONE = 2'd0,
        OWNER_DMA  = 2'd1,
        OWNER_NPU  = 2'd2,
        OWNER_HOST = 2'd3
    } bank_owner_e;

    typedef enum logic [2:0] {
        RESP_OK          = 3'd0,
        RESP_BAD_BANK    = 3'd1,
        RESP_BAD_STATE   = 3'd2,
        RESP_NOT_OWNER   = 3'd3,
        RESP_BAD_RANGE   = 3'd4,
        RESP_BAD_COMMAND = 3'd5
    } bank_resp_e;

endpackage


module raven_banked_scratchpad #(
    parameter int BANK_COUNT = 6,
    parameter int BANK_BYTES = 256,
    parameter int DATA_BYTES = 16,
    parameter int GEN_WIDTH  = 8
) (
    input logic clk,
    input logic rst,

    //bank management command interface
    input  logic cmd_valid_i,
    output logic cmd_ready_o,
    input  logic [2:0] cmd_i,
    input  logic [$clog2(BANK_COUNT)-1:0] cmd_bank_i,
    input logic [1:0] cmd_owner_i,
    input logic [GEN_WIDTH-1:0] cmd_generation_i,
    input logic [31:0] cmd_length_i,

    output logic cmd_rsp_valid_o,
    input  logic cmd_rsp_ready_i,
    output logic [2:0] cmd_rsp_status_o,
    output logic [GEN_WIDTH-1:0] cmd_rsp_generation_o,

    //generic write interface
    input  logic wr_valid_i,
    output logic wr_ready_o,
    input logic [$clog2(BANK_COUNT)-1:0] wr_bank_i,
    input logic [1:0] wr_owner_i,
    input logic [GEN_WIDTH-1:0] wr_generation_i,
    input logic [$clog2(BANK_BYTES)-1:0] wr_addr_i,
    input logic [DATA_BYTES*8-1:0] wr_data_i,
    input logic [DATA_BYTES-1:0] wr_strb_i,

    //generic read request interface
    input logic rd_req_valid_i,
    output logic rd_req_ready_o,
    input logic [$clog2(BANK_COUNT)-1:0] rd_bank_i,
    input logic [1:0] rd_owner_i,
    input logic [GEN_WIDTH-1:0] rd_generation_i,
    input logic [$clog2(BANK_BYTES)-1:0] rd_addr_i,

    //generic read response interface
    output logic rd_rsp_valid_o,
    input logic rd_rsp_ready_i,
    output logic [DATA_BYTES*8-1:0] rd_data_o,

    //debug/status visibility
    output raven_scratchpad_pkg::bank_state_e bank_state_o [BANK_COUNT],
    output logic [1:0] bank_owner_o [BANK_COUNT],
    output logic [GEN_WIDTH-1:0] bank_generation_o [BANK_COUNT],
    output logic [31:0] bank_length_o [BANK_COUNT]
);

    import raven_scratchpad_pkg::*;

    localparam int BANK_IDX_W = $clog2(BANK_COUNT);
    localparam int ADDR_W     = $clog2(BANK_BYTES);

    logic [7:0] storage [BANK_COUNT][BANK_BYTES];

    bank_state_e bank_state [BANK_COUNT];
    bank_owner_e bank_owner [BANK_COUNT];
    logic [GEN_WIDTH-1:0] bank_generation [BANK_COUNT];
    logic [31:0] bank_length [BANK_COUNT];

    logic [DATA_BYTES*8-1:0] rd_data_q;

    assign cmd_ready_o = !cmd_rsp_valid_o || cmd_rsp_ready_i;

    assign wr_ready_o =
        wr_valid_i &&
        (wr_bank_i < BANK_COUNT) &&
        (wr_addr_i + DATA_BYTES <= BANK_BYTES);

    assign rd_req_ready_o =
        !rd_rsp_valid_o ||
        rd_rsp_ready_i;

    genvar g;
    generate
        for (g = 0; g < BANK_COUNT; g++) begin : gen_status
            assign bank_state_o[g]      = bank_state[g];
            assign bank_owner_o[g]      = bank_owner[g];
            assign bank_generation_o[g] = bank_generation[g];
            assign bank_length_o[g]     = bank_length[g];
        end
    endgenerate

    function automatic logic valid_bank(
        input logic [BANK_IDX_W-1:0] bank
    );
        return bank < BANK_COUNT;
    endfunction

    function automatic logic valid_owner(
        input logic [1:0] owner
    );
        return owner != OWNER_NONE;
    endfunction

    function automatic logic owns_bank(
        input logic [BANK_IDX_W-1:0] bank,
        input logic [1:0] owner,
        input logic [GEN_WIDTH-1:0] generation
    );
        return valid_bank(bank) &&
               bank_owner[bank] == owner &&
               bank_generation[bank] == generation;
    endfunction

    function automatic logic valid_access(
        input logic [BANK_IDX_W-1:0] bank,
        input logic [1:0] owner,
        input logic [GEN_WIDTH-1:0] generation,
        input logic [ADDR_W-1:0] address
    );
        return valid_bank(bank) &&
               valid_owner(owner) &&
               owns_bank(bank, owner, generation) &&
               (address + DATA_BYTES <= BANK_BYTES);
    endfunction

    task automatic respond(
        input bank_resp_e response,
        input logic [GEN_WIDTH-1:0] generation
    );
        begin
            cmd_rsp_valid_o      <= 1'b1;
            cmd_rsp_status_o     <= response;
            cmd_rsp_generation_o <= generation;
        end
    endtask

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            cmd_rsp_valid_o      <= 1'b0;
            cmd_rsp_status_o     <= RESP_OK;
            cmd_rsp_generation_o <= '0;
            rd_rsp_valid_o       <= 1'b0;
            rd_data_q            <= '0;

            for (int i = 0; i < BANK_COUNT; i++) begin
                bank_state[i]      <= BANK_FREE;
                bank_owner[i]      <= OWNER_NONE;
                bank_generation[i] <= '0;
                bank_length[i]     <= '0;
            end
        end else begin

            //clear completed command response
            if (cmd_rsp_valid_o && cmd_rsp_ready_i)
                cmd_rsp_valid_o <= 1'b0;

            //clear consumed read response
            if (rd_rsp_valid_o && rd_rsp_ready_i)
                rd_rsp_valid_o <= 1'b0;

            //bank-management commands
            if (cmd_valid_i && cmd_ready_o) begin
                if (!valid_bank(cmd_bank_i)) begin
                    respond(RESP_BAD_BANK, '0);
                end else begin
                    case (cmd_i)

                        CMD_ACQUIRE_FILL: begin
                            if (bank_state[cmd_bank_i] != BANK_FREE) begin
                                respond(RESP_BAD_STATE, bank_generation[cmd_bank_i]);
                            end else if (!valid_owner(cmd_owner_i)) begin
                                respond(RESP_NOT_OWNER, '0);
                            end else if (cmd_length_i > BANK_BYTES) begin
                                respond(RESP_BAD_RANGE, '0);
                            end else begin
                                bank_generation[cmd_bank_i] <=
                                    bank_generation[cmd_bank_i] + 1'b1;
                                bank_owner[cmd_bank_i] <= cmd_owner_i;
                                bank_state[cmd_bank_i] <= BANK_DMA_FILLING;
                                bank_length[cmd_bank_i] <= cmd_length_i;

                                respond(
                                    RESP_OK,
                                    bank_generation[cmd_bank_i] + 1'b1
                                );
                            end
                        end

                        CMD_COMMIT: begin
                            if (!owns_bank(
                                    cmd_bank_i,
                                    cmd_owner_i,
                                    cmd_generation_i
                                )) begin
                                respond(RESP_NOT_OWNER, bank_generation[cmd_bank_i]);
                            end else if (bank_state[cmd_bank_i] != BANK_DMA_FILLING) begin
                                respond(RESP_BAD_STATE, bank_generation[cmd_bank_i]);
                            end else begin
                                bank_state[cmd_bank_i] <= BANK_READY;
                                respond(RESP_OK, bank_generation[cmd_bank_i]);
                            end
                        end

                        CMD_ACQUIRE_READ: begin
                            if (!owns_bank(
                                    cmd_bank_i,
                                    cmd_owner_i,
                                    cmd_generation_i
                                )) begin
                                respond(RESP_NOT_OWNER, bank_generation[cmd_bank_i]);
                            end else if (bank_state[cmd_bank_i] != BANK_READY) begin
                                respond(RESP_BAD_STATE, bank_generation[cmd_bank_i]);
                            end else begin
                                bank_state[cmd_bank_i] <= BANK_COMPUTING;
                                respond(RESP_OK, bank_generation[cmd_bank_i]);
                            end
                        end

                        CMD_ACQUIRE_WRITE: begin
                            if (!owns_bank(
                                    cmd_bank_i,
                                    cmd_owner_i,
                                    cmd_generation_i
                                )) begin
                                respond(RESP_NOT_OWNER, bank_generation[cmd_bank_i]);
                            end else if (bank_state[cmd_bank_i] != BANK_FREE) begin
                                respond(RESP_BAD_STATE, bank_generation[cmd_bank_i]);
                            end else begin
                                bank_generation[cmd_bank_i] <=
                                    bank_generation[cmd_bank_i] + 1'b1;
                                bank_owner[cmd_bank_i] <= cmd_owner_i;
                                bank_state[cmd_bank_i] <= BANK_NPU_WRITING;
                                bank_length[cmd_bank_i] <= cmd_length_i;

                                respond(
                                    RESP_OK,
                                    bank_generation[cmd_bank_i] + 1'b1
                                );
                            end
                        end

                        CMD_RELEASE: begin
                            if (!owns_bank(
                                    cmd_bank_i,
                                    cmd_owner_i,
                                    cmd_generation_i
                                )) begin
                                respond(RESP_NOT_OWNER, bank_generation[cmd_bank_i]);
                            end else begin
                                bank_state[cmd_bank_i] <= BANK_FREE;
                                bank_owner[cmd_bank_i] <= OWNER_NONE;
                                bank_length[cmd_bank_i] <= '0;
                                respond(RESP_OK, bank_generation[cmd_bank_i]);
                            end
                        end

                        CMD_ABORT: begin
                            if (!owns_bank(
                                    cmd_bank_i,
                                    cmd_owner_i,
                                    cmd_generation_i
                                )) begin
                                respond(RESP_NOT_OWNER, bank_generation[cmd_bank_i]);
                            end else begin
                                bank_state[cmd_bank_i] <= BANK_ERROR;
                                respond(RESP_OK, bank_generation[cmd_bank_i]);
                            end
                        end

                        default: begin
                            respond(RESP_BAD_COMMAND, '0);
                        end

                    endcase
                end
            end

            //generic writes
            if (wr_valid_i && wr_ready_o) begin
                if (valid_access(
                        wr_bank_i,
                        wr_owner_i,
                        wr_generation_i,
                        wr_addr_i
                    ) &&
                    ((bank_state[wr_bank_i] == BANK_DMA_FILLING) ||
                     (bank_state[wr_bank_i] == BANK_NPU_WRITING))) begin

                    for (int b = 0; b < DATA_BYTES; b++) begin
                        if (wr_strb_i[b])
                            storage[wr_bank_i][wr_addr_i + b]
                                <= wr_data_i[b*8 +: 8];
                    end
                end
            end

            //generic sync reads
            if (rd_req_valid_i && rd_req_ready_o) begin
                if (valid_access(
                        rd_bank_i,
                        rd_owner_i,
                        rd_generation_i,
                        rd_addr_i
                    ) &&
                    (bank_state[rd_bank_i] == BANK_COMPUTING)) begin

                    for (int b = 0; b < DATA_BYTES; b++) begin
                        rd_data_q[b*8 +: 8]
                            <= storage[rd_bank_i][rd_addr_i + b];
                    end

                    rd_rsp_valid_o <= 1'b1;
                end
            end
        end
    end

    assign rd_data_o = rd_data_q;

endmodule

`default_nettype wire