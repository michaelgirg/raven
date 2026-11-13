`default_nettype none
// Pre-alpha single-command control FSM.
//
// One command at a time (queue depth 0, D2), a subset of the RISCV_Research.md §5.1 FSM:
//   IDLE -> CHECK -> ISSUE -> RUN -> DRAIN -> RETIRE -> IDLE
//              \-> RETIRE (NOP)          \-> HALTED (after START while busy, D10)
//              \-> ERROR -> HALTED   <- core error in RUN/DRAIN
//   HALTED -> IDLE only through SOFT_RESET (D9, D11).
//
// START snapshots the staging registers, so firmware may rewrite them while a command
// runs. CHECK rejects everything control can see before the core is touched (D12); the
// core's own rejection is the backstop. A command retires only after the core finished
// without error and the result writer's last byte was accepted by the OUT bank (D5).
module raven_ctrl
    import raven_ctrl_pkg::*;
#(
    parameter int ROWS = 8, // Physical array rows: the M limit.
    parameter int COLS = 8, // Physical array columns: the N limit.
    parameter int OUT_BYTES = OUT0_BYTES // OUT0 capacity for the destination span check.
) (
    input wire clk_i, rst_ni, // Active-low reset is checked on the rising clock edge.
    // Actions and staging from the register block.
    input wire start_i, // CTRL.START pulse.
    input wire soft_reset_i, // CTRL.SOFT_RESET pulse.
    input wire clear_err_i, // CTRL.CLEAR_ERR pulse.
    input wire cnt_clear_i, // CTRL.CNT_CLEAR pulse.
    input wire cmd_t stage_i, // Staging registers, sampled on START.
    // State back to the register block.
    output ctrl_status_t status_o, // Sequence, error, state and counter values.
    output logic irq_done_set_o, // One-clock pulse: set IRQ_STATUS.DONE.
    output logic irq_err_set_o, // One-clock pulse: set IRQ_STATUS.ERROR.
    output wire local_rst_no, // rst_ni with SOFT_RESET applied, for every datapath block and bank port.
    output wire cmd_t cmd_o, // Snapshot of the executing command, for routing and the output path.
    // Compute core command handshake.
    output wire core_cmd_valid_o, // Launch the snapshot command (ISSUE only).
    input wire core_cmd_ready_i, // Core can accept the command.
    output wire [15:0] core_cmd_m_o, core_cmd_n_o, core_cmd_k_o, core_cmd_a_pitch_o, // M/N/K and A row pitch.
    output wire [23:0] core_cmd_a_base_o, core_cmd_b_base_o, core_cmd_param_base_o, // Bank-local byte offsets.
    // Compute core completion.
    input wire core_compute_done_i, // Last product committed.
    input wire core_result_done_i, // Every INT32 result accepted, or the command was rejected.
    input wire core_error_i, // Command rejected; code on core_error_code_i.
    input wire memory_error_i, // Staging parity failure: abort this command.
    input wire [31:0] memory_error_info_i, // Faulting {bank, reserved zero, byte offset}.
    input wire [7:0] core_error_code_i, // Core error code, held until the next command.
    input wire [31:0] core_input_stall_cycles_i, // Core's per-command operand stall count.
    // Output path.
    output wire op_cfg_load_o, // One-clock pulse on the launch handshake: load requant/writer config.
    input wire stored_last_i, // Writer: last INT8 byte accepted by the OUT bank.
    input wire out_stall_i // Requant or writer held off a valid result this clock.
);
    fsm_state_e state_q; // Current FSM state.
    cmd_t cmd_q; // Snapshot of the executing command.
    logic [15:0] seq_q, next_seq_q, done_seq_q; // Executing, next and last-retired sequence numbers.
    logic error_q; // STATUS.ERROR: an error is latched and not yet cleared.
    logic [7:0] err_code_q; // ERR_CODE[7:0].
    logic [15:0] err_seq_q; // ERR_CODE[31:16].
    logic [31:0] err_info_q; // Register offset, core zero, or the faulting memory reference.
    logic halt_pending_q; // START while busy: finish this command, then HALT (D10).
    logic result_done_q, stored_q; // The two retirement events, which may arrive in either order.
    logic [63:0] cyc_total_q, cyc_busy_q; // Performance counters.
    logic [31:0] cyc_stall_in_q, cyc_stall_out_q, cmd_count_q;

    // Decoded snapshot fields (§6.4 GEMM packing).
    wire [7:0] opcode = cmd_q.opcode[7:0];
    wire [31:0] flags = cmd_q.op_flags;
    wire [15:0] m = cmd_q.p0[15:0];
    wire [15:0] n = cmd_q.p0[31:16];
    wire [15:0] k = cmd_q.p1[15:0];
    wire [15:0] out_pitch = cmd_q.p4[15:0];
    wire [23:0] dst_off = ref_offset(cmd_q.dst);
    // Exclusive end of the INT8 output region, in 64 bits so it cannot wrap.
    wire [63:0] dst_end = 64'(dst_off) + (m == 0 ? 64'd0 : 64'(m) - 1) * 64'(out_pitch) + 64'(n);
    wire src_a_ok = ref_bank(cmd_q.src_a) inside {BANK_ACT0, BANK_ACT1};
    wire src_b_ok = ref_bank(cmd_q.src_b) inside {BANK_WGT0, BANK_WGT1};

    // CHECK: first failing rule wins, in the plan's priority order. ERR_INFO is the
    // offset of the offending register. NOP skips everything after the opcode check.
    // K has no control-side upper limit: its bank span is checked by the core.
    logic [7:0] chk_code;
    logic [11:0] chk_info;
    always_comb begin
        chk_code = ERR_NONE; chk_info = 12'h000;
        if (opcode != OP_NOP && opcode != OP_GEMM) begin
            chk_code = ERR_ILLEGAL_OP; chk_info = REG_OPCODE;
        end else if (opcode == OP_NOP) begin
            chk_code = ERR_NONE;
        // 2. Reserved bits.
        end else if (|cmd_q.opcode[31:8]) begin
            chk_code = ERR_RSVD; chk_info = REG_OPCODE;
        end else if (|(flags & OP_FLAGS_RSVD_MASK)) begin
            chk_code = ERR_RSVD; chk_info = REG_OP_FLAGS;
        end else if (|(cmd_q.src_a & REF_RSVD_MASK)) begin
            chk_code = ERR_RSVD; chk_info = REG_SRC_A;
        end else if (|(cmd_q.src_b & REF_RSVD_MASK)) begin
            chk_code = ERR_RSVD; chk_info = REG_SRC_B;
        end else if (|cmd_q.p1[31:16]) begin
            chk_code = ERR_RSVD; chk_info = REG_P1;
        end else if (|cmd_q.p2[31:16]) begin
            chk_code = ERR_RSVD; chk_info = REG_P2;
        end else if (|cmd_q.p4[31:16]) begin
            chk_code = ERR_RSVD; chk_info = REG_P4;
        end else if (|cmd_q.p5) begin
            chk_code = ERR_RSVD; chk_info = REG_P5;
        end else if (|(cmd_q.dst & REF_RSVD_MASK)) begin
            chk_code = ERR_RSVD; chk_info = REG_DST;
        end else if (|(cmd_q.param & REF_RSVD_MASK)) begin
            chk_code = ERR_RSVD; chk_info = REG_PARAM;
        // 3. Flags: all required, nothing outside the allowed set.
        end else if ((flags & GEMM_FLAGS_REQUIRED) != GEMM_FLAGS_REQUIRED
                     || |(flags & ~GEMM_FLAGS_ALLOWED)) begin
            chk_code = ERR_BAD_FLAGS; chk_info = REG_OP_FLAGS;
        // 4. Bank IDs and bank types (D8).
        end else if (!src_a_ok) begin
            chk_code = ERR_BANK_RANGE; chk_info = REG_SRC_A;
        end else if (!src_b_ok) begin
            chk_code = ERR_BANK_RANGE; chk_info = REG_SRC_B;
        end else if (ref_bank(cmd_q.dst) != BANK_OUT0) begin
            chk_code = ERR_BANK_RANGE; chk_info = REG_DST;
        end else if (ref_bank(cmd_q.param) != BANK_PRM) begin
            chk_code = ERR_BANK_RANGE; chk_info = REG_PARAM;
        // 5. Dimensions.
        end else if (m == 0 || 32'(m) > ROWS || n == 0 || 32'(n) > COLS) begin
            chk_code = ERR_BAD_DIM; chk_info = REG_P0;
        end else if (k == 0) begin
            chk_code = ERR_BAD_DIM; chk_info = REG_P1;
        end else if (out_pitch < n) begin
            chk_code = ERR_BAD_DIM; chk_info = REG_P4;
        // 6. Destination alignment and span.
        end else if (|dst_off[3:0] || dst_end > 64'(OUT_BYTES)) begin
            chk_code = ERR_BANK_RANGE; chk_info = REG_DST;
        end
    end

    // Core codes that already match §6.8 pass through; anything else is a unit error.
    function automatic logic [7:0] map_core_error(input logic [7:0] code);
        return code inside {ERR_BAD_DIM, ERR_BANK_RANGE, ERR_ACC_RANGE} ? code : ERR_UNIT;
    endfunction

    wire busy = !(state_q inside {FSM_IDLE, FSM_HALTED});
    wire launch = state_q == FSM_ISSUE && core_cmd_ready_i;
    // Retirement events, including ones arriving on this clock.
    wire result_seen = result_done_q || (core_result_done_i && !core_error_i);
    wire stored_seen = stored_q || stored_last_i;
    // The active command fails on this clock; a simultaneous extra START must not hide its code.
    wire raising_error = (state_q == FSM_CHECK && chk_code != ERR_NONE)
                         || (state_q inside {FSM_RUN, FSM_DRAIN} && (core_error_i || memory_error_i));

    assign local_rst_no = rst_ni && !soft_reset_i;
    assign cmd_o = cmd_q;
    assign core_cmd_valid_o = state_q == FSM_ISSUE;
    assign core_cmd_m_o = m;
    assign core_cmd_n_o = n;
    assign core_cmd_k_o = k;
    assign core_cmd_a_pitch_o = cmd_q.p2[15:0];
    assign core_cmd_a_base_o = ref_offset(cmd_q.src_a);
    assign core_cmd_b_base_o = ref_offset(cmd_q.src_b);
    assign core_cmd_param_base_o = ref_offset(cmd_q.param);
    assign op_cfg_load_o = launch;

    always_comb begin
        status_o = '0;
        status_o.busy = busy;
        status_o.halted = state_q == FSM_HALTED;
        status_o.error = error_q;
        status_o.state = state_q;
        status_o.exec_seq = seq_q;
        status_o.next_seq = next_seq_q;
        status_o.done_seq = done_seq_q;
        status_o.err_code = {err_seq_q, 8'd0, err_code_q};
        status_o.err_info = 32'(err_info_q);
        status_o.cyc_total = cyc_total_q;
        status_o.cyc_busy = cyc_busy_q;
        status_o.cyc_stall_in = cyc_stall_in_q;
        status_o.cyc_stall_out = cyc_stall_out_q;
        status_o.cmd_count = cmd_count_q;
    end

    always_ff @(posedge clk_i) begin
        // Hardware reset and SOFT_RESET clear everything except the staging registers,
        // which the register block clears itself.
        if (!local_rst_no) begin
            state_q <= FSM_IDLE; cmd_q <= '0;
            seq_q <= 0; next_seq_q <= 0; done_seq_q <= 16'hFFFF;
            error_q <= 0; err_code_q <= ERR_NONE; err_seq_q <= 0; err_info_q <= 0;
            halt_pending_q <= 0; result_done_q <= 0; stored_q <= 0;
            irq_done_set_o <= 0; irq_err_set_o <= 0;
            cyc_total_q <= 0; cyc_busy_q <= 0;
            cyc_stall_in_q <= 0; cyc_stall_out_q <= 0; cmd_count_q <= 0;
        end else begin
            irq_done_set_o <= 0; irq_err_set_o <= 0;
            cyc_total_q <= cyc_total_q + 1;
            if (state_q inside {FSM_RUN, FSM_DRAIN}) begin
                cyc_busy_q <= cyc_busy_q + 1;
                if (out_stall_i) cyc_stall_out_q <= cyc_stall_out_q + 1;
                if (core_result_done_i && !core_error_i) result_done_q <= 1;
                if (stored_last_i) stored_q <= 1;
            end
            // CLEAR_ERR clears diagnostics only; the FSM stays where it is (D9).
            // A new error on the same clock is written below and wins.
            if (clear_err_i) begin
                error_q <= 0; err_code_q <= ERR_NONE; err_seq_q <= 0; err_info_q <= 0;
            end

            case (state_q)
                FSM_IDLE: if (start_i) begin
                    cmd_q <= stage_i;
                    seq_q <= next_seq_q; next_seq_q <= next_seq_q + 1;
                    result_done_q <= 0; stored_q <= 0;
                    state_q <= FSM_CHECK;
                end
                FSM_CHECK: begin
                    if (chk_code != ERR_NONE) begin
                        error_q <= 1; err_code_q <= chk_code; err_seq_q <= seq_q; err_info_q <= chk_info;
                        irq_err_set_o <= 1;
                        state_q <= FSM_ERROR;
                    end else if (opcode == OP_NOP) state_q <= FSM_RETIRE;
                    else state_q <= FSM_ISSUE;
                end
                // Exactly one handshake: ISSUE is left on the clock the core accepts.
                FSM_ISSUE: if (core_cmd_ready_i) state_q <= FSM_RUN;
                FSM_RUN, FSM_DRAIN: begin
                    if (memory_error_i) begin
                        if (!error_q || clear_err_i) begin
                            err_code_q <= ERR_UNIT; err_seq_q <= seq_q; err_info_q <= memory_error_info_i;
                        end
                        error_q <= 1; irq_err_set_o <= 1;
                        state_q <= FSM_ERROR;
                    end else if (core_error_i) begin
                        // Keep an earlier, still-latched error (START-while-busy) visible.
                        if (!error_q || clear_err_i) begin
                            err_code_q <= map_core_error(core_error_code_i);
                            err_seq_q <= seq_q; err_info_q <= 0;
                        end
                        error_q <= 1; irq_err_set_o <= 1;
                        state_q <= FSM_ERROR;
                    end else if (state_q == FSM_RUN) begin
                        if (core_compute_done_i) state_q <= FSM_DRAIN;
                    end else if (result_seen && stored_seen) state_q <= FSM_RETIRE;
                end
                FSM_RETIRE: begin
                    done_seq_q <= seq_q;
                    cmd_count_q <= cmd_count_q + 1;
                    // A NOP never launched, so the core's counter belongs to an older command.
                    if (opcode == OP_GEMM) cyc_stall_in_q <= cyc_stall_in_q + core_input_stall_cycles_i;
                    irq_done_set_o <= 1;
                    state_q <= halt_pending_q ? FSM_HALTED : FSM_IDLE;
                end
                FSM_ERROR: state_q <= FSM_HALTED;
                FSM_HALTED: ; // START is ignored: no launch, no sequence consumed. Leave via SOFT_RESET.
                default: state_q <= FSM_HALTED;
            endcase

            // START while a command is active (D10): no launch, no sequence consumed, the
            // error is latched now and the active command still retires before HALTED.
            // ERR_CODE carries the sequence the rejected START would have received and
            // ERR_INFO points at CTRL. Only the first such START is recorded, and none while
            // the active command is itself failing.
            if (start_i && busy && state_q != FSM_ERROR && !halt_pending_q && !raising_error) begin
                halt_pending_q <= 1;
                error_q <= 1; err_code_q <= ERR_Q_OVERFLOW; err_seq_q <= next_seq_q; err_info_q <= REG_CTRL;
                irq_err_set_o <= 1;
            end

            // CNT_CLEAR restarts every performance counter, winning over this clock's increments.
            if (cnt_clear_i) begin
                cyc_total_q <= 0; cyc_busy_q <= 0;
                cyc_stall_in_q <= 0; cyc_stall_out_q <= 0; cmd_count_q <= 0;
            end
        end
    end

`ifndef SYNTHESIS
    // The core sees a command only in ISSUE, and only one handshake per START.
    assert property (@(posedge clk_i) disable iff (!local_rst_no)
        core_cmd_valid_o |-> state_q == FSM_ISSUE);
    assert property (@(posedge clk_i) disable iff (!local_rst_no)
        core_cmd_valid_o && core_cmd_ready_i |=> !core_cmd_valid_o);
    // DONE_SEQ moves only when a command retires.
    assert property (@(posedge clk_i) disable iff (!local_rst_no)
        state_q != FSM_RETIRE && !soft_reset_i |=> $stable(done_seq_q));
    // The FSM never enters the queue-only states.
    assert property (@(posedge clk_i) disable iff (!local_rst_no)
        !(state_q inside {FSM_FETCH, FSM_WAIT_DEP}));
`endif
endmodule
`default_nettype wire
