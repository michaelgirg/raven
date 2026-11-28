`timescale 1ns/1ps
`default_nettype none

module tb_banked_scratchpad;

    localparam int BANK_COUNT = 6;
    localparam int BANK_BYTES = 64;
    localparam int DATA_BYTES = 16;
    localparam int GEN_WIDTH  = 8;
    localparam int BANK_W     = 4;
    localparam int ADDR_W     = $clog2(BANK_BYTES);

    import raven_scratchpad_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;

    always #5 clk = ~clk;

    logic cmd_valid;
    logic cmd_ready;
    logic [2:0] cmd;
    logic [BANK_W-1:0] cmd_bank;
    logic [1:0] cmd_owner;
    logic [GEN_WIDTH-1:0] cmd_generation;
    logic [31:0] cmd_length;

    logic cmd_rsp_valid;
    logic cmd_rsp_ready;
    logic [2:0] cmd_rsp_status;
    logic [GEN_WIDTH-1:0] cmd_rsp_generation;

    logic wr_valid;
    logic wr_ready;
    logic [BANK_W-1:0] wr_bank;
    logic [1:0] wr_owner;
    logic [GEN_WIDTH-1:0] wr_generation;
    logic [ADDR_W-1:0] wr_addr;
    logic [DATA_BYTES*8-1:0] wr_data;
    logic [DATA_BYTES-1:0] wr_strb;

    logic rd_req_valid;
    logic rd_req_ready;
    logic [BANK_W-1:0] rd_bank;
    logic [1:0] rd_owner;
    logic [GEN_WIDTH-1:0] rd_generation;
    logic [ADDR_W-1:0] rd_addr;

    logic rd_rsp_valid;
    logic rd_rsp_ready;
    logic [DATA_BYTES*8-1:0] rd_data;

    bank_state_e bank_state [BANK_COUNT];
    logic [1:0] bank_owner [BANK_COUNT];
    logic [GEN_WIDTH-1:0] bank_generation [BANK_COUNT];
    logic [31:0] bank_length [BANK_COUNT];

    raven_banked_scratchpad #(
        .BANK_COUNT(BANK_COUNT),
        .BANK_BYTES(BANK_BYTES),
        .DATA_BYTES(DATA_BYTES),
        .GEN_WIDTH(GEN_WIDTH)
    ) dut (
        .clk,
        .rst,

        .cmd_valid_i(cmd_valid),
        .cmd_ready_o(cmd_ready),
        .cmd_i(cmd),
        .cmd_bank_i(cmd_bank),
        .cmd_owner_i(cmd_owner),
        .cmd_generation_i(cmd_generation),
        .cmd_length_i(cmd_length),

        .cmd_rsp_valid_o(cmd_rsp_valid),
        .cmd_rsp_ready_i(cmd_rsp_ready),
        .cmd_rsp_status_o(cmd_rsp_status),
        .cmd_rsp_generation_o(cmd_rsp_generation),

        .wr_valid_i(wr_valid),
        .wr_ready_o(wr_ready),
        .wr_bank_i(wr_bank),
        .wr_owner_i(wr_owner),
        .wr_generation_i(wr_generation),
        .wr_addr_i(wr_addr),
        .wr_data_i(wr_data),
        .wr_strb_i(wr_strb),

        .rd_req_valid_i(rd_req_valid),
        .rd_req_ready_o(rd_req_ready),
        .rd_bank_i(rd_bank),
        .rd_owner_i(rd_owner),
        .rd_generation_i(rd_generation),
        .rd_addr_i(rd_addr),

        .rd_rsp_valid_o(rd_rsp_valid),
        .rd_rsp_ready_i(rd_rsp_ready),
        .rd_data_o(rd_data),

        .bank_state_o(bank_state),
        .bank_owner_o(bank_owner),
        .bank_generation_o(bank_generation),
        .bank_length_o(bank_length)
    );

    task automatic expect_command(
        input logic [2:0] command,
        input logic [BANK_W-1:0] bank,
        input logic [1:0] owner,
        input logic [GEN_WIDTH-1:0] generation,
        input logic [31:0] length,
        input logic [2:0] expected_status,
        output logic [GEN_WIDTH-1:0] returned_generation
    );
        begin
            @(negedge clk);

            cmd         = command;
            cmd_bank    = bank;
            cmd_owner   = owner;
            cmd_generation = generation;
            cmd_length  = length;
            cmd_valid   = 1'b1;

            do @(posedge clk); while (!cmd_ready);
            #1;

            cmd_valid = 1'b0;

            if (!cmd_rsp_valid) begin
                $fatal(1, "Missing command response");
            end

            if (cmd_rsp_status !== expected_status) begin
                $fatal(
                    1,
                    "Unexpected command status: expected %0d, got %0d",
                    expected_status,
                    cmd_rsp_status
                );
            end

            returned_generation = cmd_rsp_generation;

            @(posedge clk);
            #1;
        end
    endtask

    task automatic write_word(
        input logic [BANK_W-1:0] bank,
        input logic [1:0] owner,
        input logic [GEN_WIDTH-1:0] generation,
        input logic [ADDR_W-1:0] address,
        input logic [DATA_BYTES*8-1:0] data
    );
        begin
            @(negedge clk);

            wr_bank       = bank;
            wr_owner      = owner;
            wr_generation = generation;
            wr_addr       = address;
            wr_data       = data;
            wr_strb       = '1;
            wr_valid      = 1'b1;
            do @(posedge clk); while (!wr_ready);
            @(negedge clk);

            wr_valid = 1'b0;
        end
    endtask

    task automatic read_word_with_backpressure(
        input logic [BANK_W-1:0] bank,
        input logic [1:0] owner,
        input logic [GEN_WIDTH-1:0] generation,
        input logic [ADDR_W-1:0] address,
        input logic [DATA_BYTES*8-1:0] expected_data
    );
        logic [DATA_BYTES*8-1:0] held_data;
        begin
            @(negedge clk);

            rd_bank       = bank;
            rd_owner      = owner;
            rd_generation = generation;
            rd_addr       = address;
            rd_req_valid  = 1'b1;
            rd_rsp_ready  = 1'b0;

            // Observe the request handshake before ready drops for its response.
            do @(posedge clk); while (!rd_req_ready);
            #1;

            rd_req_valid = 1'b0;

            if (!rd_rsp_valid)
                $fatal(1, "Missing read response");

            held_data = rd_data;

            repeat (2) begin
                @(posedge clk);
                #1;

                if (!rd_rsp_valid)
                    $fatal(1, "Read response disappeared during backpressure");

                if (rd_data !== held_data)
                    $fatal(1, "Read response data changed during backpressure");
            end

            if (rd_data !== expected_data)
                $fatal(1, "Read data mismatch");

            rd_rsp_ready = 1'b1;

            @(posedge clk);
            #1;

            if (rd_rsp_valid)
                $fatal(1, "Read response did not clear after acceptance");

            rd_rsp_ready = 1'b0;
        end
    endtask

    logic [GEN_WIDTH-1:0] act0_generation;
    logic [GEN_WIDTH-1:0] out0_generation, prior_out0_generation, prm_generation;
    logic [GEN_WIDTH-1:0] response_generation;
    logic [DATA_BYTES*8-1:0] test_data;

    initial begin
        #10000;
        $fatal(1, "Scratchpad test timed out");
    end

    initial begin
        cmd_valid       = 1'b0;
        cmd_rsp_ready   = 1'b1;

        wr_valid        = 1'b0;
        wr_bank         = '0;
        wr_owner        = OWNER_NONE;
        wr_generation   = '0;
        wr_addr         = '0;
        wr_data         = '0;
        wr_strb         = '0;

        rd_req_valid    = 1'b0;
        rd_rsp_ready    = 1'b0;
        rd_bank         = '0;
        rd_owner        = OWNER_NONE;
        rd_generation   = '0;
        rd_addr         = '0;

        test_data = 128'h0011_2233_4455_6677_8899_AABB_CCDD_EEFF;

        repeat (2)
            @(negedge clk);

        rst = 1'b0;

        //reset must leave all banks "FREE"
        if (bank_state[0] !== BANK_FREE ||
            bank_state[1] !== BANK_FREE) begin
            $fatal(1, "Reset did not initialize banks to FREE");
        end

        //acquiring ACT0 for DMA filling
        expect_command(
            CMD_ACQUIRE_FILL,
            BANK_ACT0,
            OWNER_DMA,
            '0,
            32'd32,
            RESP_OK,
            act0_generation
        );

        if (bank_state[0] !== BANK_DMA_FILLING)
            $fatal(1, "ACT0 did not enter DMA_FILLING");

        //write one word into ACT0
        write_word(
            BANK_ACT0,
            OWNER_DMA,
            act0_generation,
            '0,
            test_data
        );

        //committing the fill
        expect_command(
            CMD_COMMIT,
            BANK_ACT0,
            OWNER_DMA,
            act0_generation,
            32'd0,
            RESP_OK,
            act0_generation
        );

        if (bank_state[0] !== BANK_READY)
            $fatal(1, "ACT0 did not enter READY");

        //second fill attempt must fail because ACT0 should be READY
        expect_command(
            CMD_ACQUIRE_FILL,
            BANK_ACT0,
            OWNER_DMA,
            '0,
            32'd32,
            RESP_BAD_STATE,
            act0_generation
        );

        //acquiring ACT0 for compute
        expect_command(
            CMD_ACQUIRE_READ,
            BANK_ACT0,
            OWNER_DMA,
            act0_generation,
            32'd0,
            RESP_OK,
            act0_generation
        );

        if (bank_state[0] !== BANK_COMPUTING)
            $fatal(1, "ACT0 did not enter COMPUTING");

        //read the stored data while applying response backpressure
        read_word_with_backpressure(
            BANK_ACT0,
            OWNER_DMA,
            act0_generation,
            '0,
            test_data
        );

        //releasing ACT0
        expect_command(
            CMD_RELEASE,
            BANK_ACT0,
            OWNER_DMA,
            act0_generation,
            32'd0,
            RESP_OK,
            act0_generation
        );

        if (bank_state[0] !== BANK_FREE)
            $fatal(1, "ACT0 did not return to FREE");

        //the old generation cannot be accepted after release
        expect_command(
            CMD_COMMIT,
            BANK_ACT0,
            OWNER_DMA,
            act0_generation,
            32'd0,
            RESP_NOT_OWNER,
            act0_generation
        );

        // OUT0 acquires a new owner and generation from FREE.
        expect_command(CMD_ACQUIRE_WRITE, BANK_OUT0, OWNER_NONE, '0, 32'd16,
                       RESP_NOT_OWNER, response_generation);
        expect_command(CMD_ACQUIRE_WRITE, BANK_OUT0, OWNER_NPU, '0, BANK_BYTES+1,
                       RESP_BAD_RANGE, response_generation);
        if (bank_state[BANK_OUT0] !== BANK_FREE || bank_generation[BANK_OUT0] !== '0)
            $fatal(1, "Rejected OUT0 acquisition changed bank state or generation");
        expect_command(CMD_ACQUIRE_WRITE, BANK_OUT0, OWNER_NPU, '0, 32'd16,
                       RESP_OK, out0_generation);
        if (bank_state[BANK_OUT0] !== BANK_NPU_WRITING ||
            bank_owner[BANK_OUT0] !== OWNER_NPU || bank_length[BANK_OUT0] !== 32'd16 ||
            out0_generation !== GEN_WIDTH'(1) || bank_generation[BANK_OUT0] !== out0_generation)
            $fatal(1, "OUT0 did not record its write allocation");
        write_word(BANK_OUT0, OWNER_NPU, out0_generation, '0, ~test_data);
        // The standalone model does not have a host drain port yet.
        for (int lane = 0; lane < DATA_BYTES; lane++) begin
            if (dut.storage[BANK_OUT0][lane] !== ~test_data[8*lane +: 8])
                $fatal(1, "OUT0 write did not store byte %0d", lane);
        end
        expect_command(CMD_ACQUIRE_WRITE, BANK_OUT0, OWNER_HOST, '0, 32'd16,
                       RESP_BAD_STATE, response_generation);
        expect_command(CMD_RELEASE, BANK_OUT0, OWNER_NPU, out0_generation, '0,
                       RESP_OK, prior_out0_generation);
        expect_command(CMD_ACQUIRE_WRITE, BANK_OUT0, OWNER_NPU, '0, 32'd16,
                       RESP_OK, out0_generation);
        if (out0_generation !== prior_out0_generation + 1'b1)
            $fatal(1, "Reused OUT0 did not get the next generation");
        expect_command(CMD_RELEASE, BANK_OUT0, OWNER_NPU, prior_out0_generation, '0,
                       RESP_NOT_OWNER, response_generation);
        if (bank_state[BANK_OUT0] !== BANK_NPU_WRITING)
            $fatal(1, "Stale release changed the new OUT0 allocation");

        // Use literals to check the external control ABI, including the ID gap.
        if (BANK_PRM != 4'd6 || BANK_OUT1 != 4'd5)
            $fatal(1, "Unexpected PRM or optional OUT1 logical ID");
        expect_command(CMD_ACQUIRE_FILL, 4'd6, OWNER_HOST, '0, BANK_BYTES,
                       RESP_OK, prm_generation);
        expect_command(CMD_ACQUIRE_FILL, 4'd5, OWNER_HOST, '0, BANK_BYTES,
                       RESP_BAD_BANK, response_generation);
        write_word(4'd6, OWNER_HOST, prm_generation, ADDR_W'(BANK_BYTES-DATA_BYTES), test_data);
        expect_command(CMD_COMMIT, 4'd6, OWNER_HOST, prm_generation, '0,
                       RESP_OK, response_generation);
        expect_command(CMD_ACQUIRE_READ, 4'd6, OWNER_HOST, prm_generation, '0,
                       RESP_OK, response_generation);
        read_word_with_backpressure(4'd6, OWNER_HOST, prm_generation,
                                    ADDR_W'(BANK_BYTES-DATA_BYTES), test_data);

        // Reset flushes a pending response and clears both kinds of slots.
        @(negedge clk);
        rd_req_valid = 1'b1;
        @(posedge clk);
        #1;
        if (!rd_rsp_valid)
            $fatal(1, "Expected a pending PRM response before reset");
        @(negedge clk);
        rd_req_valid = 1'b0;
        rst = 1'b1;
        @(posedge clk);
        #1;
        if (rd_rsp_valid || cmd_rsp_valid)
            $fatal(1, "Reset did not flush pending responses");

        for (int slot = 0; slot < BANK_COUNT; slot++) begin
            if (bank_state[slot] !== BANK_FREE || bank_owner[slot] !== OWNER_NONE ||
                bank_generation[slot] !== '0 || bank_length[slot] !== '0)
                $fatal(1, "Reset did not clear allocation in slot %0d", slot);
        end

        $display("ALL BANKED SCRATCHPAD TESTS PASSED");
        $finish;
    end

endmodule

`default_nettype wire
