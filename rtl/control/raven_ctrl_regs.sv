`default_nettype none
// Pre-alpha NPU register block: a stand-in for the generated raven_csr.
//
// A small synchronous register bus replaces AXI4-Lite (D1). Every accepted access gets
// exactly one response on the next clock (reg_rvalid_o), for writes as well as reads, so
// the bus never waits on the FSM. Offsets and fields match RISCV_Research.md §6.2.
//
// This block owns the staging registers, IRQ_ENABLE/IRQ_STATUS and the W1S action
// pulses. Sequence numbers, errors and counters live in raven_ctrl and are read back
// through status_i.
module raven_ctrl_regs
    import raven_ctrl_pkg::*;
#(
    parameter int ROWS = 8, // Physical array rows, reported in HW_CONFIG.
    parameter int COLS = 8  // Physical array columns, reported in HW_CONFIG.
) (
    input wire clk_i, rst_ni, // Active-low reset is checked on the rising clock edge.
    // Register bus.
    input wire reg_valid_i, // Is there an access this clock?
    output wire reg_ready_o, // Can the block accept it? High whenever out of reset.
    input wire reg_write_i, // 1 = write, 0 = read.
    input wire [11:0] reg_addr_i, // Byte offset inside the NPU window.
    input wire [31:0] reg_wdata_i, // Write data (full word; no byte strobes).
    output logic [31:0] reg_rdata_o, // Read data, valid with reg_rvalid_o (0 for writes).
    output logic reg_rvalid_o, // One-clock response for every accepted access.
    output logic reg_error_o, // Unmapped or unaligned access, valid with reg_rvalid_o.
    // Actions and staging toward the control FSM.
    output logic start_o, // CTRL.START, one-clock pulse.
    output logic soft_reset_o, // CTRL.SOFT_RESET, one-clock pulse.
    output logic clear_err_o, // CTRL.CLEAR_ERR, one-clock pulse.
    output logic cnt_clear_o, // CTRL.CNT_CLEAR, one-clock pulse.
    output cmd_t stage_o, // Current staging registers.
    // State reported by the control FSM.
    input wire ctrl_status_t status_i, // Sequence, error, state and counter values.
    input wire irq_done_set_i, // Set IRQ_STATUS.DONE (wins over a same-clock W1C).
    input wire irq_err_set_i, // Set IRQ_STATUS.ERROR (wins over a same-clock W1C).
    output wire npu_irq_o // OR of (IRQ_STATUS & IRQ_ENABLE).
);
    logic [31:0] irq_enable_q, irq_status_q; // Only bits [1:0] are implemented.
    cmd_t stage_q; // Staging registers.

    wire access = reg_valid_i && reg_ready_o;
    wire do_write = access && reg_write_i;
    // Unaligned or past-the-map offsets are errors; reserved holes inside the map are not.
    wire bad_addr = |reg_addr_i[1:0] || reg_addr_i >= REG_MAP_END;
    wire ctrl_write = do_write && !bad_addr && reg_addr_i == REG_CTRL;

    assign reg_ready_o = rst_ni;
    assign stage_o = stage_q;
    assign npu_irq_o = |(irq_status_q & irq_enable_q);

    // HW_CONFIG: rows, cols, bank count, log2 KiB, queue depth.
    wire [31:0] hw_config = {4'd0, NPU_QUEUE_DEPTH, NPU_LOG2_KIB, NPU_BANK_COUNT,
                             8'(COLS), 8'(ROWS)};
    // STATUS: queue depth 0 means "full" and "occupancy 1" exactly while a command is active.
    wire [31:0] status_word = {status_i.exec_seq, 3'd0, !status_i.busy,
                               2'd0, status_i.busy, status_i.state,
                               !status_i.busy, status_i.busy,
                               status_i.error, status_i.halted, status_i.busy};

    // Read value for an offset. Reserved holes and write-only CTRL read 0.
    function automatic logic [31:0] read_mux(input logic [11:0] addr);
        case (addr)
            REG_ID:            return NPU_ID;
            REG_VERSION:       return NPU_VERSION;
            REG_HW_CONFIG:     return hw_config;
            REG_HW_LIMITS:     return {NPU_OPCODE_MAP, NPU_MAX_DIM};
            REG_STATUS:        return status_word;
            REG_IRQ_ENABLE:    return irq_enable_q;
            REG_IRQ_STATUS:    return irq_status_q;
            REG_NEXT_SEQ:      return 32'(status_i.next_seq);
            REG_DONE_SEQ:      return 32'(status_i.done_seq);
            REG_ERR_CODE:      return status_i.err_code;
            REG_ERR_INFO:      return status_i.err_info;
            REG_OPCODE:        return stage_q.opcode;
            REG_OP_FLAGS:      return stage_q.op_flags;
            REG_SRC_A:         return stage_q.src_a;
            REG_SRC_B:         return stage_q.src_b;
            REG_P0:            return stage_q.p0;
            REG_P1:            return stage_q.p1;
            REG_P2:            return stage_q.p2;
            REG_P3:            return stage_q.p3;
            REG_P4:            return stage_q.p4;
            REG_P5:            return stage_q.p5;
            REG_DST:           return stage_q.dst;
            REG_PARAM:         return stage_q.param;
            REG_Q_ZP:          return stage_q.q_zp;
            REG_Q_MULT:        return stage_q.q_mult;
            REG_Q_SHIFT:       return stage_q.q_shift;
            REG_Q_CLAMP:       return stage_q.q_clamp;
            REG_CYC_TOTAL_LO:  return status_i.cyc_total[31:0];
            REG_CYC_TOTAL_HI:  return status_i.cyc_total[63:32];
            REG_CYC_BUSY_LO:   return status_i.cyc_busy[31:0];
            REG_CYC_BUSY_HI:   return status_i.cyc_busy[63:32];
            REG_CYC_STALL_IN:  return status_i.cyc_stall_in;
            REG_CYC_STALL_OUT: return status_i.cyc_stall_out;
            REG_CMD_COUNT:     return status_i.cmd_count;
            REG_HW_FEATURES:   return NPU_HW_FEATURES;
            default:           return 32'd0;
        endcase
    endfunction

    // Staging reset value: everything 0 except Q_CLAMP.
    function automatic cmd_t stage_reset();
        cmd_t s = '0;
        s.q_clamp = Q_CLAMP_RESET;
        return s;
    endfunction

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            reg_rdata_o <= 0; reg_rvalid_o <= 0; reg_error_o <= 0;
            start_o <= 0; soft_reset_o <= 0; clear_err_o <= 0; cnt_clear_o <= 0;
            irq_enable_q <= 0; irq_status_q <= 0;
            stage_q <= stage_reset();
        end else begin
            // Response for the access accepted on this clock.
            reg_rvalid_o <= access;
            reg_error_o <= access && bad_addr;
            reg_rdata_o <= access && !reg_write_i && !bad_addr ? read_mux(reg_addr_i) : 32'd0;
            // W1S actions last exactly one clock. ABORT and ZERO_LOCAL are ignored (D11).
            start_o      <= ctrl_write && reg_wdata_i[CTRL_START];
            soft_reset_o <= ctrl_write && reg_wdata_i[CTRL_SOFT_RESET];
            clear_err_o  <= ctrl_write && reg_wdata_i[CTRL_CLEAR_ERR];
            cnt_clear_o  <= ctrl_write && reg_wdata_i[CTRL_CNT_CLEAR];

            if (do_write && !bad_addr) begin
                case (reg_addr_i)
                    REG_IRQ_ENABLE: irq_enable_q <= reg_wdata_i & IRQ_MASK;
                    REG_OPCODE:     stage_q.opcode   <= reg_wdata_i;
                    REG_OP_FLAGS:   stage_q.op_flags <= reg_wdata_i;
                    REG_SRC_A:      stage_q.src_a    <= reg_wdata_i;
                    REG_SRC_B:      stage_q.src_b    <= reg_wdata_i;
                    REG_P0:         stage_q.p0       <= reg_wdata_i;
                    REG_P1:         stage_q.p1       <= reg_wdata_i;
                    REG_P2:         stage_q.p2       <= reg_wdata_i;
                    REG_P3:         stage_q.p3       <= reg_wdata_i;
                    REG_P4:         stage_q.p4       <= reg_wdata_i;
                    REG_P5:         stage_q.p5       <= reg_wdata_i;
                    REG_DST:        stage_q.dst      <= reg_wdata_i;
                    REG_PARAM:      stage_q.param    <= reg_wdata_i;
                    REG_Q_ZP:       stage_q.q_zp     <= reg_wdata_i;
                    REG_Q_MULT:     stage_q.q_mult   <= reg_wdata_i;
                    REG_Q_SHIFT:    stage_q.q_shift  <= reg_wdata_i;
                    REG_Q_CLAMP:    stage_q.q_clamp  <= reg_wdata_i;
                    default: ; // RO registers and reserved holes ignore writes.
                endcase
            end

            // IRQ_STATUS: hardware set wins over a same-clock W1C.
            begin
                logic [31:0] w1c;
                w1c = do_write && !bad_addr && reg_addr_i == REG_IRQ_STATUS
                      ? reg_wdata_i & IRQ_MASK : 32'd0;
                irq_status_q <= (irq_status_q & ~w1c)
                                | (32'(irq_done_set_i) << IRQ_DONE)
                                | (32'(irq_err_set_i) << IRQ_ERROR);
            end

            // SOFT_RESET clears staging and pending IRQs on the clock its pulse appears.
            // IRQ_ENABLE is configuration and survives.
            if (soft_reset_o) begin
                stage_q <= stage_reset();
                irq_status_q <= 0;
            end
        end
    end

`ifndef SYNTHESIS
    // Each W1S action is a single-clock pulse.
    assert property (@(posedge clk_i) disable iff (!rst_ni) start_o |=> !start_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni) soft_reset_o |=> !soft_reset_o);
    // A response appears exactly one clock after each accepted access.
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        reg_valid_i && reg_ready_o |=> reg_rvalid_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        !(reg_valid_i && reg_ready_o) |=> !reg_rvalid_o);
`endif
endmodule
`default_nettype wire
