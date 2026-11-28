`timescale 1ns/1ps
`default_nettype none

module tb_banked_scratchpad_preload;
    localparam int BANK_COUNT = 6;
    localparam int BANK_BYTES = 64;
    localparam int DATA_BYTES = 16;

    import raven_scratchpad_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic cmd_valid, cmd_ready;
    logic [2:0] cmd;
    logic [3:0] cmd_bank;
    logic [1:0] cmd_owner;
    logic [7:0] cmd_generation;
    logic [31:0] cmd_length;
    logic cmd_rsp_valid, cmd_rsp_ready;
    logic [2:0] cmd_rsp_status;
    logic [7:0] cmd_rsp_generation;

    logic wr_valid, wr_ready;
    logic [3:0] wr_bank;
    logic [1:0] wr_owner;
    logic [7:0] wr_generation;
    logic [5:0] wr_addr;
    logic [127:0] wr_data;
    logic [15:0] wr_strb;

    logic rd_req_valid, rd_req_ready;
    logic [3:0] rd_bank;
    logic [1:0] rd_owner;
    logic [7:0] rd_generation;
    logic [5:0] rd_addr;
    logic rd_rsp_valid, rd_rsp_ready;
    logic [127:0] rd_data;

    bank_state_e bank_state [BANK_COUNT];
    logic [1:0] bank_owner [BANK_COUNT];
    logic [7:0] bank_generation [BANK_COUNT];
    logic [31:0] bank_length [BANK_COUNT];

    raven_banked_scratchpad #(
        .BANK_COUNT(BANK_COUNT),
        .BANK_BYTES(BANK_BYTES),
        .DATA_BYTES(DATA_BYTES),
        .ACT0_INIT_FILE("../../../../tests/rtl/memory/banked_scratchpad_fixture.hex")
    ) dut (
        .clk, .rst,
        .cmd_valid_i(cmd_valid), .cmd_ready_o(cmd_ready),
        .cmd_i(cmd), .cmd_bank_i(cmd_bank),
        .cmd_owner_i(cmd_owner), .cmd_generation_i(cmd_generation),
        .cmd_length_i(cmd_length),
        .cmd_rsp_valid_o(cmd_rsp_valid), .cmd_rsp_ready_i(cmd_rsp_ready),
        .cmd_rsp_status_o(cmd_rsp_status),
        .cmd_rsp_generation_o(cmd_rsp_generation),
        .wr_valid_i(wr_valid), .wr_ready_o(wr_ready),
        .wr_bank_i(wr_bank), .wr_owner_i(wr_owner),
        .wr_generation_i(wr_generation), .wr_addr_i(wr_addr),
        .wr_data_i(wr_data), .wr_strb_i(wr_strb),
        .rd_req_valid_i(rd_req_valid), .rd_req_ready_o(rd_req_ready),
        .rd_bank_i(rd_bank), .rd_owner_i(rd_owner),
        .rd_generation_i(rd_generation), .rd_addr_i(rd_addr),
        .rd_rsp_valid_o(rd_rsp_valid), .rd_rsp_ready_i(rd_rsp_ready),
        .rd_data_o(rd_data),
        .bank_state_o(bank_state), .bank_owner_o(bank_owner),
        .bank_generation_o(bank_generation), .bank_length_o(bank_length)
    );

    task automatic issue_command(
        input logic [2:0] command,
        input logic [3:0] bank,
        input logic [1:0] owner,
        input logic [7:0] generation,
        input logic [31:0] length,
        input logic [2:0] expected_status
    );
        begin
            @(negedge clk);
            cmd_valid = 1'b1;
            cmd = command;
            cmd_bank = bank;
            cmd_owner = owner;
            cmd_generation = generation;
            cmd_length = length;
            do @(posedge clk); while (!cmd_ready);
            #1;
            cmd_valid = 1'b0;
            if (cmd_rsp_valid !== 1'b1 || cmd_rsp_status !== expected_status)
                $fatal(1, "Unexpected preload command response");
        end
    endtask

    initial begin
        cmd_valid = 0; cmd_rsp_ready = 1;
        cmd = 0; cmd_bank = 0; cmd_owner = 0;
        cmd_generation = 0; cmd_length = 0;
        wr_valid = 0; wr_bank = 0; wr_owner = 0;
        wr_generation = 0; wr_addr = 0; wr_data = 0; wr_strb = 0;
        rd_req_valid = 0; rd_rsp_ready = 0;
        rd_bank = 0; rd_owner = 0; rd_generation = 0; rd_addr = 0;

        repeat (3) @(negedge clk);
        rst = 0;
        #1;

        if (bank_state[BANK_ACT0] !== BANK_READY ||
            bank_owner[BANK_ACT0] !== OWNER_DMA ||
            bank_generation[BANK_ACT0] !== 8'd1 ||
            bank_length[BANK_ACT0] !== BANK_BYTES)
            $fatal(1, "ACT0 fixture state was not initialized");

        issue_command(CMD_ACQUIRE_READ, BANK_ACT0, OWNER_DMA, 8'd1, 0,
                      RESP_OK);

        rd_req_valid = 1;
        rd_bank = BANK_ACT0;
        rd_owner = OWNER_DMA;
        rd_generation = 8'd1;
        rd_addr = 0;
        rd_rsp_ready = 0;
        do @(posedge clk); while (!rd_req_ready);
        #1;
        rd_req_valid = 0;

        if (rd_rsp_valid !== 1'b1 ||
            rd_data !== 128'h00112233445566778899aabbccddeeff)
            $fatal(1, "ACT0 fixture word 0 mismatch");

        rd_rsp_ready = 1;
        @(posedge clk);
        #1;
        rd_rsp_ready = 0;

        rd_req_valid = 1;
        rd_addr = 16;
        do @(posedge clk); while (!rd_req_ready);
        #1;
        rd_req_valid = 0;

        if (rd_rsp_valid !== 1'b1 ||
            rd_data !== 128'hffeeddccbbaa99887766554433221100)
            $fatal(1, "ACT0 fixture word 1 mismatch");

        $display("ALL BANKED SCRATCHPAD PRELOAD TESTS PASSED");
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "Scratchpad preload test timed out");
    end
endmodule

`default_nettype wire
