`default_nettype none
// Pre-alpha NPU top: control + GEMM core + requant + result writer, with bank routing.
//
//   reg bus -> raven_ctrl_regs <-> raven_ctrl --cmd--> raven_gemm_core --INT32-->
//   raven_requant (PRM port B, Quan's raven_requantize_clamp) --INT8--> raven_result_writer --> OUT0
//
// The memories stay outside (D6): ACT0/ACT1/WGT0/WGT1 read ports, two PRM read ports and
// an OUT0 write port are top-level ports, so testbench models now and Taylor's banks later
// attach to the same wires. The core's A port is routed to ACT0 or ACT1 and its B port to
// WGT0 or WGT1 by the snapshot's BANK_IDs (D8); control has already rejected any other ID.
// The datapath and every bank port run on local_rst_no = rst_ni && !SOFT_RESET (D11).
module raven_npu_top
    import raven_ctrl_pkg::*;
#(
    parameter int ROWS = 8, // Physical array rows.
    parameter int COLS = 8 // Physical array columns.
) (
    input wire clk_i, rst_ni, // Active-low reset is checked on the rising clock edge.
    // Register bus (D1).
    input wire reg_valid_i, // Is there an access this clock?
    output wire reg_ready_o, // Can the block accept it?
    input wire reg_write_i, // 1 = write, 0 = read.
    input wire [11:0] reg_addr_i, // Byte offset inside the NPU window.
    input wire [31:0] reg_wdata_i, // Write data.
    output wire [31:0] reg_rdata_o, // Read data, valid with reg_rvalid_o.
    output wire reg_rvalid_o, // One-clock response for every accepted access.
    output wire reg_error_o, // Unmapped or unaligned access.
    output wire npu_irq_o, // OR of (IRQ_STATUS & IRQ_ENABLE).
    output wire local_rst_no, // Reset for the bank responders: rst_ni with SOFT_RESET applied.
    // ACT0 / ACT1 read ports (core A operand).
    output wire act0_req_valid_o, act1_req_valid_o, // Read request.
    input wire act0_req_ready_i, act1_req_ready_i, // Bank accepts the request.
    output wire [23:0] act0_req_addr_o, act1_req_addr_o, // 16-byte-aligned byte offset.
    input wire act0_rsp_valid_i, act1_rsp_valid_i, // Read data presented.
    output wire act0_rsp_ready_o, act1_rsp_ready_o, // Read data accepted.
    input wire [127:0] act0_rsp_data_i, act1_rsp_data_i, // One 16-byte word.
    // WGT0 / WGT1 read ports (core B operand).
    output wire wgt0_req_valid_o, wgt1_req_valid_o,
    input wire wgt0_req_ready_i, wgt1_req_ready_i,
    output wire [23:0] wgt0_req_addr_o, wgt1_req_addr_o,
    input wire wgt0_rsp_valid_i, wgt1_rsp_valid_i,
    output wire wgt0_rsp_ready_o, wgt1_rsp_ready_o,
    input wire [127:0] wgt0_rsp_data_i, wgt1_rsp_data_i,
    // PRM read port A (core: corrected bias) and port B (requant: multiplier/shift, D7).
    output wire prm_a_req_valid_o, prm_b_req_valid_o,
    input wire prm_a_req_ready_i, prm_b_req_ready_i,
    output wire [23:0] prm_a_req_addr_o, prm_b_req_addr_o,
    input wire prm_a_rsp_valid_i, prm_b_rsp_valid_i,
    output wire prm_a_rsp_ready_o, prm_b_rsp_ready_o,
    input wire [127:0] prm_a_rsp_data_i, prm_b_rsp_data_i,
    // OUT0 write port.
    output wire out0_w_valid_o, // Write presented.
    input wire out0_w_ready_i, // Bank accepts (and commits) the write.
    output wire [23:0] out0_w_addr_o, // 16-byte-aligned word address.
    output wire [127:0] out0_w_data_o, // INT8 value replicated into every lane.
    output wire [15:0] out0_w_strb_o // One-hot byte strobe.
);
    // Register block <-> control.
    wire start, soft_reset, clear_err, cnt_clear, irq_done_set, irq_err_set;
    cmd_t stage, cmd;
    ctrl_status_t status;

    // Control <-> core.
    wire core_cmd_valid, core_cmd_ready;
    wire [15:0] core_m, core_n, core_k, core_a_pitch;
    wire [23:0] core_a_base, core_b_base, core_param_base;
    wire core_compute_done, core_result_done, core_error;
    wire [7:0] core_error_code;
    wire [31:0] core_input_stall;
    wire core_busy;

    // Core operand ports before bank routing.
    wire a_req_valid, a_req_ready, a_rsp_valid, a_rsp_ready;
    wire b_req_valid, b_req_ready, b_rsp_valid, b_rsp_ready;
    wire [23:0] a_req_addr, b_req_addr;
    wire [127:0] a_rsp_data, b_rsp_data;

    // Output path.
    wire res_valid, res_ready, res_last;
    wire signed [31:0] res_data;
    wire [15:0] res_row, res_col;
    wire q_valid, q_ready, q_last;
    wire [7:0] q_data;
    wire [15:0] q_row, q_col;
    wire cfg_load, stored_last, writer_stall;
    logic requant_cfg_pending_q;
    wire requant_cfg_load = requant_cfg_pending_q && prm_a_req_valid_o;
    wire requant_in_ready;

    // The core requests its first bias only after command validation succeeds.
    // Wait for that phase before starting the independent PARAM loader.
    always_ff @(posedge clk_i) begin
        if (!local_rst_no) requant_cfg_pending_q <= 0;
        else if (cfg_load) requant_cfg_pending_q <= 1;
        else if (core_error || requant_cfg_load) requant_cfg_pending_q <= 0;
    end
    assign res_ready = requant_in_ready && !requant_cfg_pending_q;

    raven_ctrl_regs #(.ROWS(ROWS), .COLS(COLS)) u_regs (
        .clk_i, .rst_ni,
        .reg_valid_i, .reg_ready_o, .reg_write_i, .reg_addr_i, .reg_wdata_i,
        .reg_rdata_o, .reg_rvalid_o, .reg_error_o,
        .start_o(start), .soft_reset_o(soft_reset), .clear_err_o(clear_err), .cnt_clear_o(cnt_clear),
        .stage_o(stage), .status_i(status),
        .irq_done_set_i(irq_done_set), .irq_err_set_i(irq_err_set), .npu_irq_o
    );

    raven_ctrl #(.ROWS(ROWS), .COLS(COLS), .OUT_BYTES(OUT0_BYTES)) u_ctrl (
        .clk_i, .rst_ni,
        .start_i(start), .soft_reset_i(soft_reset), .clear_err_i(clear_err), .cnt_clear_i(cnt_clear),
        .stage_i(stage), .status_o(status),
        .irq_done_set_o(irq_done_set), .irq_err_set_o(irq_err_set),
        .local_rst_no, .cmd_o(cmd),
        .core_cmd_valid_o(core_cmd_valid), .core_cmd_ready_i(core_cmd_ready),
        .core_cmd_m_o(core_m), .core_cmd_n_o(core_n), .core_cmd_k_o(core_k), .core_cmd_a_pitch_o(core_a_pitch),
        .core_cmd_a_base_o(core_a_base), .core_cmd_b_base_o(core_b_base), .core_cmd_param_base_o(core_param_base),
        .core_compute_done_i(core_compute_done), .core_result_done_i(core_result_done),
        .core_error_i(core_error), .core_error_code_i(core_error_code),
        .core_input_stall_cycles_i(core_input_stall),
        .op_cfg_load_o(cfg_load), .stored_last_i(stored_last),
        .out_stall_i((res_valid && !res_ready) || writer_stall)
    );

    raven_gemm_core #(
        .ROWS(ROWS), .COLS(COLS), .ADDR_W(24),
        .ACT_BYTES(ACT_BYTES), .WGT_BYTES(WGT_BYTES), .PRM_BYTES(PRM_BYTES)
    ) u_core (
        .clk_i, .rst_ni(local_rst_no),
        .cmd_valid_i(core_cmd_valid), .cmd_ready_o(core_cmd_ready),
        .cmd_m_i(core_m), .cmd_n_i(core_n), .cmd_k_i(core_k), .cmd_a_pitch_i(core_a_pitch),
        .cmd_a_base_i(core_a_base), .cmd_b_base_i(core_b_base), .cmd_param_base_i(core_param_base),
        .a_req_valid_o(a_req_valid), .a_req_ready_i(a_req_ready), .a_req_addr_o(a_req_addr),
        .a_rsp_valid_i(a_rsp_valid), .a_rsp_ready_o(a_rsp_ready), .a_rsp_data_i(a_rsp_data),
        .b_req_valid_o(b_req_valid), .b_req_ready_i(b_req_ready), .b_req_addr_o(b_req_addr),
        .b_rsp_valid_i(b_rsp_valid), .b_rsp_ready_o(b_rsp_ready), .b_rsp_data_i(b_rsp_data),
        .p_req_valid_o(prm_a_req_valid_o), .p_req_ready_i(prm_a_req_ready_i), .p_req_addr_o(prm_a_req_addr_o),
        .p_rsp_valid_i(prm_a_rsp_valid_i), .p_rsp_ready_o(prm_a_rsp_ready_o), .p_rsp_data_i(prm_a_rsp_data_i),
        .result_valid_o(res_valid), .result_ready_i(res_ready), .result_data_o(res_data),
        .result_row_o(res_row), .result_col_o(res_col), .result_index_o(), .result_last_o(res_last),
        .busy_o(core_busy), .compute_done_o(core_compute_done), .result_done_o(core_result_done),
        .error_o(core_error), .error_code_o(core_error_code),
        .cycles_o(), .issued_steps_o(), .input_stall_cycles_o(core_input_stall), .output_stall_cycles_o()
    );

    // Bank routing (D8). The snapshot holds the selection for the whole command.
    wire sel_act1 = ref_bank(cmd.src_a) == BANK_ACT1;
    wire sel_wgt1 = ref_bank(cmd.src_b) == BANK_WGT1;

    assign act0_req_valid_o = a_req_valid && !sel_act1;
    assign act1_req_valid_o = a_req_valid && sel_act1;
    assign act0_req_addr_o = a_req_addr;
    assign act1_req_addr_o = a_req_addr;
    assign a_req_ready = sel_act1 ? act1_req_ready_i : act0_req_ready_i;
    assign a_rsp_valid = sel_act1 ? act1_rsp_valid_i : act0_rsp_valid_i;
    assign a_rsp_data = sel_act1 ? act1_rsp_data_i : act0_rsp_data_i;
    assign act0_rsp_ready_o = a_rsp_ready && !sel_act1;
    assign act1_rsp_ready_o = a_rsp_ready && sel_act1;

    assign wgt0_req_valid_o = b_req_valid && !sel_wgt1;
    assign wgt1_req_valid_o = b_req_valid && sel_wgt1;
    assign wgt0_req_addr_o = b_req_addr;
    assign wgt1_req_addr_o = b_req_addr;
    assign b_req_ready = sel_wgt1 ? wgt1_req_ready_i : wgt0_req_ready_i;
    assign b_rsp_valid = sel_wgt1 ? wgt1_rsp_valid_i : wgt0_rsp_valid_i;
    assign b_rsp_data = sel_wgt1 ? wgt1_rsp_data_i : wgt0_rsp_data_i;
    assign wgt0_rsp_ready_o = b_rsp_ready && !sel_wgt1;
    assign wgt1_rsp_ready_o = b_rsp_ready && sel_wgt1;

    raven_requant #(.COLS(COLS), .ADDR_W(24)) u_requant (
        .clk_i, .rst_ni(local_rst_no),
        .cfg_load_i(requant_cfg_load),
        .cfg_per_channel_i(cmd.op_flags[FLAG_PER_CHANNEL]),
        .cfg_n_i(cmd.p0[31:16]),
        .cfg_param_base_i(ref_offset(cmd.param)),
        .cfg_mult_i(cmd.q_mult),
        .cfg_shift_i(cmd.q_shift[7:0]),
        .cfg_out_zp_i(cmd.q_zp[23:16]),
        .cfg_clamp_min_i(cmd.q_clamp[7:0]), .cfg_clamp_max_i(cmd.q_clamp[15:8]),
        .cfg_relu_i(cmd.op_flags[FLAG_RELU_EN]),
        .in_valid_i(res_valid && !requant_cfg_pending_q), .in_ready_o(requant_in_ready), .in_data_i(res_data),
        .in_row_i(res_row), .in_col_i(res_col), .in_last_i(res_last),
        .p_req_valid_o(prm_b_req_valid_o), .p_req_ready_i(prm_b_req_ready_i), .p_req_addr_o(prm_b_req_addr_o),
        .p_rsp_valid_i(prm_b_rsp_valid_i), .p_rsp_ready_o(prm_b_rsp_ready_o), .p_rsp_data_i(prm_b_rsp_data_i),
        .out_valid_o(q_valid), .out_ready_i(q_ready), .out_data_o(q_data),
        .out_row_o(q_row), .out_col_o(q_col), .out_last_o(q_last)
    );

    raven_result_writer #(.ADDR_W(24)) u_writer (
        .clk_i, .rst_ni(local_rst_no),
        .cfg_load_i(cfg_load),
        .cfg_dst_offset_i(ref_offset(cmd.dst)), .cfg_out_pitch_i(cmd.p4[15:0]),
        .in_valid_i(q_valid), .in_ready_o(q_ready), .in_data_i(q_data),
        .in_row_i(q_row), .in_col_i(q_col), .in_last_i(q_last),
        .w_valid_o(out0_w_valid_o), .w_ready_i(out0_w_ready_i), .w_addr_o(out0_w_addr_o),
        .w_data_o(out0_w_data_o), .w_strb_o(out0_w_strb_o),
        .stored_last_o(stored_last), .stall_o(writer_stall), .writes_o()
    );

`ifndef SYNTHESIS
    // Only the selected bank of each pair ever sees a request.
    assert property (@(posedge clk_i) disable iff (!local_rst_no)
        !(act0_req_valid_o && act1_req_valid_o) && !(wgt0_req_valid_o && wgt1_req_valid_o));
    // Bank routing never changes while the core is busy with a command.
    assert property (@(posedge clk_i) disable iff (!local_rst_no)
        core_busy |=> $stable({sel_act1, sel_wgt1}));
`endif
endmodule
`default_nettype wire
