`timescale 1ns/1ps
`default_nettype none

module tb_raven_memory_banks_fixture #(
    parameter string ACT_INIT_FILE = "../../../tests/integration/fixtures/normal_8x16x8/act.hex",
    parameter string WGT_INIT_FILE = "../../../tests/integration/fixtures/normal_8x16x8/wgt.hex",
    parameter string PRM_INIT_FILE = "../../../tests/integration/fixtures/normal_8x16x8/prm.hex"
);
    localparam int ACT_WORDS = 16 * 1024 / 16;
    localparam int WGT_WORDS = 16 * 1024 / 16;
    localparam int PRM_WORDS = 4 * 1024 / 16;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic act0_req_valid, act0_rsp_ready;
    logic [23:0] act0_req_addr;
    wire act0_req_ready, act0_rsp_valid;
    wire [127:0] act0_rsp_data;

    logic wgt0_req_valid, wgt0_rsp_ready;
    logic [23:0] wgt0_req_addr;
    wire wgt0_req_ready, wgt0_rsp_valid;
    wire [127:0] wgt0_rsp_data;

    logic prm_a_req_valid, prm_a_rsp_ready;
    logic [23:0] prm_a_req_addr;
    wire prm_a_req_ready, prm_a_rsp_valid;
    wire [127:0] prm_a_rsp_data;

    logic prm_b_req_valid, prm_b_rsp_ready;
    logic [23:0] prm_b_req_addr;
    wire prm_b_req_ready, prm_b_rsp_valid;
    wire [127:0] prm_b_rsp_data;
    wire unused_act0_w_ready, unused_act1_req_ready, unused_act1_rsp_valid;
    wire unused_act1_w_ready, unused_wgt0_w_ready, unused_wgt1_req_ready;
    wire unused_wgt1_rsp_valid, unused_wgt1_w_ready, unused_prm_w_ready;
    wire unused_out0_w_ready, unused_out0_rd_req_ready, unused_out0_rd_rsp_valid;
    wire [127:0] unused_act1_rsp_data, unused_wgt1_rsp_data;
    wire [127:0] unused_out0_rd_rsp_data;
    logic out0_w_valid;
    wire out0_w_ready;
    logic [23:0] out0_w_addr;
    logic [127:0] out0_w_data;
    logic [15:0] out0_w_strb;
    logic out0_rd_req_valid, out0_rd_rsp_ready;
    wire out0_rd_req_ready, out0_rd_rsp_valid;
    logic [23:0] out0_rd_req_addr;
    wire [127:0] out0_rd_rsp_data;

    logic [127:0] act_expected [0:ACT_WORDS-1];
    logic [127:0] wgt_expected [0:WGT_WORDS-1];
    logic [127:0] prm_expected [0:PRM_WORDS-1];

    raven_memory_banks #(
        .ACT0_INIT_FILE(ACT_INIT_FILE),
        .WGT0_INIT_FILE(WGT_INIT_FILE),
        .PRM_INIT_FILE(PRM_INIT_FILE)
    ) dut (
        .clk_i(clk), .rst_ni(rst_n),

        .act0_req_valid_i(act0_req_valid), .act0_req_ready_o(act0_req_ready),
        .act0_req_addr_i(act0_req_addr), .act0_rsp_valid_o(act0_rsp_valid),
        .act0_rsp_ready_i(act0_rsp_ready), .act0_rsp_data_o(act0_rsp_data),
        .act0_w_valid_i(1'b0), .act0_w_ready_o(unused_act0_w_ready),
        .act0_w_addr_i(24'b0), .act0_w_data_i(128'b0),
        .act0_w_strb_i(16'b0),

        .act1_req_valid_i(1'b0), .act1_req_ready_o(unused_act1_req_ready),
        .act1_req_addr_i(24'b0), .act1_rsp_valid_o(unused_act1_rsp_valid),
        .act1_rsp_ready_i(1'b0), .act1_rsp_data_o(unused_act1_rsp_data),
        .act1_w_valid_i(1'b0), .act1_w_ready_o(unused_act1_w_ready),
        .act1_w_addr_i(24'b0), .act1_w_data_i(128'b0),
        .act1_w_strb_i(16'b0),

        .wgt0_req_valid_i(wgt0_req_valid), .wgt0_req_ready_o(wgt0_req_ready),
        .wgt0_req_addr_i(wgt0_req_addr), .wgt0_rsp_valid_o(wgt0_rsp_valid),
        .wgt0_rsp_ready_i(wgt0_rsp_ready), .wgt0_rsp_data_o(wgt0_rsp_data),
        .wgt0_w_valid_i(1'b0), .wgt0_w_ready_o(unused_wgt0_w_ready),
        .wgt0_w_addr_i(24'b0), .wgt0_w_data_i(128'b0),
        .wgt0_w_strb_i(16'b0),

        .wgt1_req_valid_i(1'b0), .wgt1_req_ready_o(unused_wgt1_req_ready),
        .wgt1_req_addr_i(24'b0), .wgt1_rsp_valid_o(unused_wgt1_rsp_valid),
        .wgt1_rsp_ready_i(1'b0), .wgt1_rsp_data_o(unused_wgt1_rsp_data),
        .wgt1_w_valid_i(1'b0), .wgt1_w_ready_o(unused_wgt1_w_ready),
        .wgt1_w_addr_i(24'b0), .wgt1_w_data_i(128'b0),
        .wgt1_w_strb_i(16'b0),

        .prm_a_req_valid_i(prm_a_req_valid), .prm_a_req_ready_o(prm_a_req_ready),
        .prm_a_req_addr_i(prm_a_req_addr), .prm_a_rsp_valid_o(prm_a_rsp_valid),
        .prm_a_rsp_ready_i(prm_a_rsp_ready), .prm_a_rsp_data_o(prm_a_rsp_data),
        .prm_b_req_valid_i(prm_b_req_valid), .prm_b_req_ready_o(prm_b_req_ready),
        .prm_b_req_addr_i(prm_b_req_addr), .prm_b_rsp_valid_o(prm_b_rsp_valid),
        .prm_b_rsp_ready_i(prm_b_rsp_ready), .prm_b_rsp_data_o(prm_b_rsp_data),
        .prm_w_valid_i(1'b0), .prm_w_ready_o(unused_prm_w_ready),
        .prm_w_addr_i(24'b0), .prm_w_data_i(128'b0),
        .prm_w_strb_i(16'b0),

        .out0_w_valid_i(out0_w_valid), .out0_w_ready_o(out0_w_ready),
        .out0_w_addr_i(out0_w_addr), .out0_w_data_i(out0_w_data),
        .out0_w_strb_i(out0_w_strb), .out0_rd_req_valid_i(out0_rd_req_valid),
        .out0_rd_req_ready_o(out0_rd_req_ready),
        .out0_rd_req_addr_i(out0_rd_req_addr), .out0_rd_rsp_valid_o(out0_rd_rsp_valid),
        .out0_rd_rsp_ready_i(out0_rd_rsp_ready), .out0_rd_rsp_data_o(out0_rd_rsp_data)
    );

    task automatic read_act0(input int word_index);
        begin
            @(negedge clk);
            act0_req_addr = 24'(word_index * 16);
            act0_req_valid = 1'b1;
            if (!act0_req_ready) $fatal(1, "ACT0 was not ready");
            @(posedge clk);
            #1;
            act0_req_valid = 1'b0;
            if (!act0_rsp_valid || act0_rsp_data !== act_expected[word_index])
                $fatal(1, "ACT0 preload mismatch at word %0d", word_index);
            act0_rsp_ready = 1'b1;
            @(posedge clk);
            #1;
            act0_rsp_ready = 1'b0;
        end
    endtask

    task automatic read_wgt0(input int word_index);
        begin
            @(negedge clk);
            wgt0_req_addr = 24'(word_index * 16);
            wgt0_req_valid = 1'b1;
            if (!wgt0_req_ready) $fatal(1, "WGT0 was not ready");
            @(posedge clk);
            #1;
            wgt0_req_valid = 1'b0;
            if (!wgt0_rsp_valid || wgt0_rsp_data !== wgt_expected[word_index])
                $fatal(1, "WGT0 preload mismatch at word %0d", word_index);
            wgt0_rsp_ready = 1'b1;
            @(posedge clk);
            #1;
            wgt0_rsp_ready = 1'b0;
        end
    endtask

    task automatic read_prm_a(input int word_index);
        begin
            @(negedge clk);
            prm_a_req_addr = 24'(word_index * 16);
            prm_a_req_valid = 1'b1;
            if (!prm_a_req_ready) $fatal(1, "PARAM A was not ready");
            @(posedge clk);
            #1;
            prm_a_req_valid = 1'b0;
            if (!prm_a_rsp_valid || prm_a_rsp_data !== prm_expected[word_index])
                $fatal(1, "PARAM A preload mismatch at word %0d", word_index);
            prm_a_rsp_ready = 1'b1;
            @(posedge clk);
            #1;
            prm_a_rsp_ready = 1'b0;
        end
    endtask

    task automatic read_prm_b(input int word_index);
        begin
            @(negedge clk);
            prm_b_req_addr = 24'(word_index * 16);
            prm_b_req_valid = 1'b1;
            if (!prm_b_req_ready) $fatal(1, "PARAM B was not ready");
            @(posedge clk);
            #1;
            prm_b_req_valid = 1'b0;
            if (!prm_b_rsp_valid || prm_b_rsp_data !== prm_expected[word_index])
                $fatal(1, "PARAM B preload mismatch at word %0d", word_index);
            prm_b_rsp_ready = 1'b1;
            @(posedge clk);
            #1;
            prm_b_rsp_ready = 1'b0;
        end
    endtask

    task automatic write_out0(input logic [127:0] data, input logic [15:0] strb);
        begin
            @(negedge clk);
            out0_w_addr = 0;
            out0_w_data = data;
            out0_w_strb = strb;
            out0_w_valid = 1;
            while (!out0_w_ready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            out0_w_valid = 0;
        end
    endtask

    task automatic read_out0(input logic [127:0] expected_data);
        begin
            @(negedge clk);
            out0_rd_req_addr = 0;
            out0_rd_req_valid = 1;
            out0_rd_rsp_ready = 0;
            while (!out0_rd_req_ready) @(negedge clk);
            @(posedge clk);
            #1;
            out0_rd_req_valid = 0;
            if (!out0_rd_rsp_valid || out0_rd_rsp_data !== expected_data)
                $fatal(1, "OUT0 strobed write/readback mismatch");
            repeat (3) begin
                @(posedge clk);
                #1;
                if (!out0_rd_rsp_valid || out0_rd_rsp_data !== expected_data)
                    $fatal(1, "OUT0 response changed under backpressure");
            end
            out0_rd_rsp_ready = 1;
            @(posedge clk);
            #1;
            out0_rd_rsp_ready = 0;
        end
    endtask

    initial begin
        $readmemh(ACT_INIT_FILE, act_expected);
        $readmemh(WGT_INIT_FILE, wgt_expected);
        $readmemh(PRM_INIT_FILE, prm_expected);

        act0_req_valid = 0; act0_rsp_ready = 0; act0_req_addr = 0;
        wgt0_req_valid = 0; wgt0_rsp_ready = 0; wgt0_req_addr = 0;
        prm_a_req_valid = 0; prm_a_rsp_ready = 0; prm_a_req_addr = 0;
        prm_b_req_valid = 0; prm_b_rsp_ready = 0; prm_b_req_addr = 0;
        out0_w_valid = 0; out0_w_addr = 0; out0_w_data = 0; out0_w_strb = 0;
        out0_rd_req_valid = 0; out0_rd_req_addr = 0; out0_rd_rsp_ready = 0;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        for (int i = 0; i < ACT_WORDS; i++) read_act0(i);
        for (int i = 0; i < WGT_WORDS; i++) read_wgt0(i);
        for (int i = 0; i < PRM_WORDS; i++) begin
            read_prm_a(i);
            read_prm_b(i);
        end

        // The two PARAM copies must serve different words concurrently.
        @(negedge clk);
        prm_a_req_addr = 0;
        prm_b_req_addr = 16;
        prm_a_req_valid = 1;
        prm_b_req_valid = 1;
        if (!prm_a_req_ready || !prm_b_req_ready)
            $fatal(1, "PARAM readers did not accept concurrent requests");
        @(posedge clk);
        #1;
        prm_a_req_valid = 0;
        prm_b_req_valid = 0;
        if (!prm_a_rsp_valid || !prm_b_rsp_valid ||
            prm_a_rsp_data !== prm_expected[0] ||
            prm_b_rsp_data !== prm_expected[1])
            $fatal(1, "Concurrent PARAM read mismatch");

        write_out0(128'hffeeddccbbaa99887766554433221100, 16'hFFFF);
        write_out0(128'h000000000000000000000000aabbccdd, 16'h000F);
        read_out0(128'hffeeddccbbaa998877665544aabbccdd);

        out0_rd_req_addr = 24'd1;
        #1;
        if (out0_rd_req_ready)
            $fatal(1, "Misaligned OUT0 read address was accepted");
        out0_rd_req_addr = 24'(8192-16);
        #1;
        if (!out0_rd_req_ready)
            $fatal(1, "Last legal OUT0 word was not accepted");
        out0_w_addr = 24'd1;
        #1;
        if (out0_w_ready)
            $fatal(1, "Misaligned OUT0 write address was accepted");

        $display("PASS BRAM FIXTURE PRELOAD: ACT0=%0d WGT0=%0d PARAM A/B=%0d words",
                 ACT_WORDS, WGT_WORDS, PRM_WORDS);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "BRAM fixture preload test timed out");
    end
endmodule

`default_nettype wire
