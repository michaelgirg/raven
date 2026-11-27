`timescale 1ns/1ps
`default_nettype none

module raven_memory_banks #(
    parameter int ACT_BYTES = 16 * 1024,
    parameter int WGT_BYTES = 16 * 1024,
    parameter int PRM_BYTES = 4 * 1024,
    parameter int OUT0_BYTES = 8 * 1024,
    parameter string ACT0_INIT_FILE = "",
    parameter string ACT1_INIT_FILE = "",
    parameter string WGT0_INIT_FILE = "",
    parameter string WGT1_INIT_FILE = "",
    parameter string PRM_INIT_FILE = ""
) (
    input wire clk_i,
    input wire rst_ni,

    input wire act0_req_valid_i,
    output wire act0_req_ready_o,
    input wire [23:0] act0_req_addr_i,
    output wire act0_rsp_valid_o,
    input wire act0_rsp_ready_i,
    output wire [127:0] act0_rsp_data_o,
    input wire act0_w_valid_i,
    output wire act0_w_ready_o,
    input wire [23:0] act0_w_addr_i,
    input wire [127:0] act0_w_data_i,
    input wire [15:0] act0_w_strb_i,

    input wire act1_req_valid_i,
    output wire act1_req_ready_o,
    input wire [23:0] act1_req_addr_i,
    output wire act1_rsp_valid_o,
    input wire act1_rsp_ready_i,
    output wire [127:0] act1_rsp_data_o,
    input wire act1_w_valid_i,
    output wire act1_w_ready_o,
    input wire [23:0] act1_w_addr_i,
    input wire [127:0] act1_w_data_i,
    input wire [15:0] act1_w_strb_i,

    input wire wgt0_req_valid_i,
    output wire wgt0_req_ready_o,
    input wire [23:0] wgt0_req_addr_i,
    output wire wgt0_rsp_valid_o,
    input wire wgt0_rsp_ready_i,
    output wire [127:0] wgt0_rsp_data_o,
    input wire wgt0_w_valid_i,
    output wire wgt0_w_ready_o,
    input wire [23:0] wgt0_w_addr_i,
    input wire [127:0] wgt0_w_data_i,
    input wire [15:0] wgt0_w_strb_i,

    input wire wgt1_req_valid_i,
    output wire wgt1_req_ready_o,
    input wire [23:0] wgt1_req_addr_i,
    output wire wgt1_rsp_valid_o,
    input wire wgt1_rsp_ready_i,
    output wire [127:0] wgt1_rsp_data_o,
    input wire wgt1_w_valid_i,
    output wire wgt1_w_ready_o,
    input wire [23:0] wgt1_w_addr_i,
    input wire [127:0] wgt1_w_data_i,
    input wire [15:0] wgt1_w_strb_i,

    input wire prm_a_req_valid_i,
    output wire prm_a_req_ready_o,
    input wire [23:0] prm_a_req_addr_i,
    output wire prm_a_rsp_valid_o,
    input wire prm_a_rsp_ready_i,
    output wire [127:0] prm_a_rsp_data_o,
    input wire prm_b_req_valid_i,
    output wire prm_b_req_ready_o,
    input wire [23:0] prm_b_req_addr_i,
    output wire prm_b_rsp_valid_o,
    input wire prm_b_rsp_ready_i,
    output wire [127:0] prm_b_rsp_data_o,
    input wire prm_w_valid_i,
    output wire prm_w_ready_o,
    input wire [23:0] prm_w_addr_i,
    input wire [127:0] prm_w_data_i,
    input wire [15:0] prm_w_strb_i,

    input wire out0_w_valid_i,
    output wire out0_w_ready_o,
    input wire [23:0] out0_w_addr_i,
    input wire [127:0] out0_w_data_i,
    input wire [15:0] out0_w_strb_i,
    input wire out0_rd_req_valid_i,
    output wire out0_rd_req_ready_o,
    input wire [23:0] out0_rd_req_addr_i,
    output wire out0_rd_rsp_valid_o,
    input wire out0_rd_rsp_ready_i,
    output wire [127:0] out0_rd_rsp_data_o
);
    raven_bram_bank #(
        .BANK_BYTES(ACT_BYTES), .INIT_FILE(ACT0_INIT_FILE)
    ) u_act0 (
        .clk_i, .rst_ni,
        .rd_req_valid_i(act0_req_valid_i), .rd_req_ready_o(act0_req_ready_o),
        .rd_req_addr_i(act0_req_addr_i), .rd_rsp_valid_o(act0_rsp_valid_o),
        .rd_rsp_ready_i(act0_rsp_ready_i), .rd_rsp_data_o(act0_rsp_data_o),
        .w_valid_i(act0_w_valid_i), .w_ready_o(act0_w_ready_o),
        .w_addr_i(act0_w_addr_i), .w_data_i(act0_w_data_i), .w_strb_i(act0_w_strb_i)
    );

    raven_bram_bank #(
        .BANK_BYTES(ACT_BYTES), .INIT_FILE(ACT1_INIT_FILE)
    ) u_act1 (
        .clk_i, .rst_ni,
        .rd_req_valid_i(act1_req_valid_i), .rd_req_ready_o(act1_req_ready_o),
        .rd_req_addr_i(act1_req_addr_i), .rd_rsp_valid_o(act1_rsp_valid_o),
        .rd_rsp_ready_i(act1_rsp_ready_i), .rd_rsp_data_o(act1_rsp_data_o),
        .w_valid_i(act1_w_valid_i), .w_ready_o(act1_w_ready_o),
        .w_addr_i(act1_w_addr_i), .w_data_i(act1_w_data_i), .w_strb_i(act1_w_strb_i)
    );

    raven_bram_bank #(
        .BANK_BYTES(WGT_BYTES), .INIT_FILE(WGT0_INIT_FILE)
    ) u_wgt0 (
        .clk_i, .rst_ni,
        .rd_req_valid_i(wgt0_req_valid_i), .rd_req_ready_o(wgt0_req_ready_o),
        .rd_req_addr_i(wgt0_req_addr_i), .rd_rsp_valid_o(wgt0_rsp_valid_o),
        .rd_rsp_ready_i(wgt0_rsp_ready_i), .rd_rsp_data_o(wgt0_rsp_data_o),
        .w_valid_i(wgt0_w_valid_i), .w_ready_o(wgt0_w_ready_o),
        .w_addr_i(wgt0_w_addr_i), .w_data_i(wgt0_w_data_i), .w_strb_i(wgt0_w_strb_i)
    );

    raven_bram_bank #(
        .BANK_BYTES(WGT_BYTES), .INIT_FILE(WGT1_INIT_FILE)
    ) u_wgt1 (
        .clk_i, .rst_ni,
        .rd_req_valid_i(wgt1_req_valid_i), .rd_req_ready_o(wgt1_req_ready_o),
        .rd_req_addr_i(wgt1_req_addr_i), .rd_rsp_valid_o(wgt1_rsp_valid_o),
        .rd_rsp_ready_i(wgt1_rsp_ready_i), .rd_rsp_data_o(wgt1_rsp_data_o),
        .w_valid_i(wgt1_w_valid_i), .w_ready_o(wgt1_w_ready_o),
        .w_addr_i(wgt1_w_addr_i), .w_data_i(wgt1_w_data_i), .w_strb_i(wgt1_w_strb_i)
    );

    raven_bram_bank #(
        .BANK_BYTES(PRM_BYTES), .INIT_FILE(PRM_INIT_FILE)
    ) u_prm_a (
        .clk_i, .rst_ni,
        .rd_req_valid_i(prm_a_req_valid_i), .rd_req_ready_o(prm_a_req_ready_o),
        .rd_req_addr_i(prm_a_req_addr_i), .rd_rsp_valid_o(prm_a_rsp_valid_o),
        .rd_rsp_ready_i(prm_a_rsp_ready_i), .rd_rsp_data_o(prm_a_rsp_data_o),
        .w_valid_i(prm_w_valid_i), .w_ready_o(prm_w_ready_o),
        .w_addr_i(prm_w_addr_i), .w_data_i(prm_w_data_i), .w_strb_i(prm_w_strb_i)
    );

    raven_bram_bank #(
        .BANK_BYTES(PRM_BYTES), .INIT_FILE(PRM_INIT_FILE)
    ) u_prm_b (
        .clk_i, .rst_ni,
        .rd_req_valid_i(prm_b_req_valid_i), .rd_req_ready_o(prm_b_req_ready_o),
        .rd_req_addr_i(prm_b_req_addr_i), .rd_rsp_valid_o(prm_b_rsp_valid_o),
        .rd_rsp_ready_i(prm_b_rsp_ready_i), .rd_rsp_data_o(prm_b_rsp_data_o),
        .w_valid_i(prm_w_valid_i), .w_ready_o(),
        .w_addr_i(prm_w_addr_i), .w_data_i(prm_w_data_i), .w_strb_i(prm_w_strb_i)
    );

    raven_bram_bank #(
        .BANK_BYTES(OUT0_BYTES)
    ) u_out0 (
        .clk_i, .rst_ni,
        .rd_req_valid_i(out0_rd_req_valid_i), .rd_req_ready_o(out0_rd_req_ready_o),
        .rd_req_addr_i(out0_rd_req_addr_i), .rd_rsp_valid_o(out0_rd_rsp_valid_o),
        .rd_rsp_ready_i(out0_rd_rsp_ready_i), .rd_rsp_data_o(out0_rd_rsp_data_o),
        .w_valid_i(out0_w_valid_i), .w_ready_o(out0_w_ready_o),
        .w_addr_i(out0_w_addr_i), .w_data_i(out0_w_data_i), .w_strb_i(out0_w_strb_i)
    );
endmodule

`default_nettype wire
