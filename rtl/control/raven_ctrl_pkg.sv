`default_nettype none
// Shared constants for the pre-alpha control block.
//
// Register offsets and field layouts follow RISCV_Research.md §6.2 exactly for the
// implemented subset, so firmware and traces stay valid when the generated raven_csr
// replaces raven_ctrl_regs. Opcodes, flags, bank IDs and error codes follow §6.3-§6.8.
package raven_ctrl_pkg;
    // Register offsets (byte addresses inside the NPU window).
    localparam logic [11:0] REG_ID            = 12'h000;
    localparam logic [11:0] REG_VERSION       = 12'h004;
    localparam logic [11:0] REG_HW_CONFIG     = 12'h008;
    localparam logic [11:0] REG_HW_LIMITS     = 12'h00C;
    localparam logic [11:0] REG_CTRL          = 12'h010;
    localparam logic [11:0] REG_STATUS        = 12'h014;
    localparam logic [11:0] REG_IRQ_ENABLE    = 12'h018;
    localparam logic [11:0] REG_IRQ_STATUS    = 12'h01C;
    localparam logic [11:0] REG_NEXT_SEQ      = 12'h020;
    localparam logic [11:0] REG_DONE_SEQ      = 12'h024;
    localparam logic [11:0] REG_ERR_CODE      = 12'h028;
    localparam logic [11:0] REG_ERR_INFO      = 12'h02C;
    localparam logic [11:0] REG_OPCODE        = 12'h030;
    localparam logic [11:0] REG_OP_FLAGS      = 12'h034;
    localparam logic [11:0] REG_SRC_A         = 12'h038;
    localparam logic [11:0] REG_SRC_B         = 12'h03C;
    localparam logic [11:0] REG_P0            = 12'h040;
    localparam logic [11:0] REG_P1            = 12'h044;
    localparam logic [11:0] REG_P2            = 12'h048;
    localparam logic [11:0] REG_P3            = 12'h04C;
    localparam logic [11:0] REG_P4            = 12'h050;
    localparam logic [11:0] REG_P5            = 12'h054;
    localparam logic [11:0] REG_DST           = 12'h058;
    localparam logic [11:0] REG_PARAM         = 12'h05C;
    localparam logic [11:0] REG_Q_ZP          = 12'h060;
    localparam logic [11:0] REG_Q_MULT        = 12'h064;
    localparam logic [11:0] REG_Q_SHIFT       = 12'h068;
    localparam logic [11:0] REG_Q_CLAMP       = 12'h06C;
    localparam logic [11:0] REG_CYC_TOTAL_LO  = 12'h080;
    localparam logic [11:0] REG_CYC_TOTAL_HI  = 12'h084;
    localparam logic [11:0] REG_CYC_BUSY_LO   = 12'h088;
    localparam logic [11:0] REG_CYC_BUSY_HI   = 12'h08C;
    localparam logic [11:0] REG_CYC_STALL_IN  = 12'h094;
    localparam logic [11:0] REG_CYC_STALL_OUT = 12'h098;
    localparam logic [11:0] REG_CMD_COUNT     = 12'h0AC;
    localparam logic [11:0] REG_HW_FEATURES   = 12'h0B0;
    // First offset past the map. Offsets at or above it are unmapped and raise reg_error_o.
    localparam logic [11:0] REG_MAP_END       = 12'h0B8;

    // Constant identification values.
    localparam logic [31:0] NPU_ID          = 32'h5241_564E; // ASCII "RAVN".
    localparam logic [31:0] NPU_VERSION     = 32'h0000_0001; // Major 0, minor 0, build 1.
    localparam logic [3:0]  NPU_BANK_COUNT  = 4'd6;          // ACT0/1, WGT0/1, OUT0, PRM (OUT1 absent).
    localparam logic [3:0]  NPU_LOG2_KIB    = 4'd4;          // Nominal 16 KiB ACT/WGT banks.
    localparam logic [3:0]  NPU_QUEUE_DEPTH = 4'd1;          // D2: one command at a time.
    localparam logic [15:0] NPU_OPCODE_MAP  = 16'h0005;      // D3: NOP (bit 0) and GEMM (bit 2).
    localparam logic [15:0] NPU_MAX_DIM     = 16'd8;         // M and N limit of the resident tile.
    localparam logic [31:0] NPU_HW_FEATURES = 32'h0000_0000; // No test opcodes, no ACT writes, no OUT1.

    // CTRL (0x010) W1S action bits. ABORT [2] and ZERO_LOCAL [5] are ignored in pre-alpha (D11).
    localparam int CTRL_START      = 0;
    localparam int CTRL_SOFT_RESET = 1;
    localparam int CTRL_ABORT      = 2;
    localparam int CTRL_CLEAR_ERR  = 3;
    localparam int CTRL_CNT_CLEAR  = 4;
    localparam int CTRL_ZERO_LOCAL = 5;

    // STATUS (0x014) fields.
    localparam int STATUS_BUSY      = 0;
    localparam int STATUS_HALTED    = 1;
    localparam int STATUS_ERROR     = 2;
    localparam int STATUS_Q_FULL    = 3;
    localparam int STATUS_Q_EMPTY   = 4;
    localparam int STATUS_FSM_LSB   = 5;  // [8:5]
    localparam int STATUS_OCC_LSB   = 9;  // [11:9]
    localparam int STATUS_QUIESCENT = 12;
    localparam int STATUS_SEQ_LSB   = 16; // [31:16]

    // IRQ_ENABLE / IRQ_STATUS bits.
    localparam int IRQ_DONE  = 0;
    localparam int IRQ_ERROR = 1;
    localparam logic [31:0] IRQ_MASK = 32'h0000_0003;

    // Opcodes (§6.3). Only NOP and GEMM are supported (D3).
    localparam logic [7:0] OP_NOP  = 8'h00;
    localparam logic [7:0] OP_GEMM = 8'h02;

    // OP_FLAGS (0x034) bits.
    localparam int FLAG_ACC_INIT      = 0;
    localparam int FLAG_ACC_LAST      = 1;
    localparam int FLAG_REQUANT_EN    = 2;
    localparam int FLAG_RELU_EN       = 3;
    localparam int FLAG_PER_CHANNEL   = 6;
    localparam int FLAG_SRC_A_CB      = 7;
    localparam int FLAG_RELEASE_A     = 8;
    localparam int FLAG_RELEASE_B     = 9;
    localparam int FLAG_RELEASE_PARAM = 10;
    localparam int FLAG_DST_ACCUM     = 11;
    // §5.2 of the plan: GEMM must set every required flag and may set only optional ones.
    localparam logic [31:0] GEMM_FLAGS_REQUIRED = (32'd1 << FLAG_ACC_INIT)
                                                | (32'd1 << FLAG_ACC_LAST)
                                                | (32'd1 << FLAG_REQUANT_EN);
    localparam logic [31:0] GEMM_FLAGS_ALLOWED  = GEMM_FLAGS_REQUIRED
                                                | (32'd1 << FLAG_RELU_EN)
                                                | (32'd1 << FLAG_PER_CHANNEL)
                                                | (32'd1 << FLAG_RELEASE_A)
                                                | (32'd1 << FLAG_RELEASE_B)
                                                | (32'd1 << FLAG_RELEASE_PARAM);
    localparam logic [31:0] OP_FLAGS_RSVD_MASK  = 32'hFFFF_F000; // [31:12]

    // Scratchpad reference {BANK_ID[31:28], rsvd[27:24], BYTE_OFFSET[23:0]} (§6.4).
    localparam logic [31:0] REF_RSVD_MASK = 32'h0F00_0000;
    localparam logic [3:0] BANK_ACT0 = 4'd0;
    localparam logic [3:0] BANK_ACT1 = 4'd1;
    localparam logic [3:0] BANK_WGT0 = 4'd2;
    localparam logic [3:0] BANK_WGT1 = 4'd3;
    localparam logic [3:0] BANK_OUT0 = 4'd4;
    localparam logic [3:0] BANK_OUT1 = 4'd5; // Absent in pre-alpha (HW_FEATURES[3] = 0).
    localparam logic [3:0] BANK_PRM  = 4'd6;

    // Bank capacities in bytes. OUT0 uses the contract's 8 KiB lower bound.
    localparam int ACT_BYTES  = 16384;
    localparam int WGT_BYTES  = 16384;
    localparam int PRM_BYTES  = 4096;
    localparam int OUT0_BYTES = 8192;

    // Staging register reset values.
    localparam logic [31:0] Q_CLAMP_RESET = 32'h0000_7F80; // max 127, min -128.

    // Error codes (§6.8). Codes 0x02, 0x03 and 0x08 match raven_gemm_core.
    localparam logic [7:0] ERR_NONE        = 8'h00;
    localparam logic [7:0] ERR_ILLEGAL_OP  = 8'h01;
    localparam logic [7:0] ERR_BAD_DIM     = 8'h02;
    localparam logic [7:0] ERR_BANK_RANGE  = 8'h03;
    localparam logic [7:0] ERR_BANK_STATE  = 8'h04;
    localparam logic [7:0] ERR_DEP_TIMEOUT = 8'h05;
    localparam logic [7:0] ERR_Q_OVERFLOW  = 8'h06;
    localparam logic [7:0] ERR_RSVD        = 8'h07;
    localparam logic [7:0] ERR_ACC_RANGE   = 8'h08;
    localparam logic [7:0] ERR_UNIT        = 8'h09;
    localparam logic [7:0] ERR_ABORTED     = 8'h0A;
    localparam logic [7:0] ERR_BAD_FLAGS   = 8'h0B;

    // Control FSM states, using the 4-bit STATUS.FSM codes of §5.1 (D4).
    // FETCH (1) and WAIT_DEP (3) exist in the full design and are never entered here.
    typedef enum logic [3:0] {
        FSM_IDLE     = 4'd0,
        FSM_FETCH    = 4'd1,
        FSM_CHECK    = 4'd2,
        FSM_WAIT_DEP = 4'd3,
        FSM_ISSUE    = 4'd4,
        FSM_RUN      = 4'd5,
        FSM_DRAIN    = 4'd6,
        FSM_RETIRE   = 4'd7,
        FSM_ERROR    = 4'd8,
        FSM_HALTED   = 4'd9
    } fsm_state_e;

    // The staging register set, snapshotted whole at START.
    typedef struct packed {
        logic [31:0] opcode;
        logic [31:0] op_flags;
        logic [31:0] src_a;
        logic [31:0] src_b;
        logic [31:0] p0;
        logic [31:0] p1;
        logic [31:0] p2;
        logic [31:0] p3;
        logic [31:0] p4;
        logic [31:0] p5;
        logic [31:0] dst;
        logic [31:0] param;
        logic [31:0] q_zp;
        logic [31:0] q_mult;
        logic [31:0] q_shift;
        logic [31:0] q_clamp;
    } cmd_t;

    // Everything the FSM reports back through the register block.
    typedef struct packed {
        logic        busy;          // A command is between CHECK and RETIRE.
        logic        halted;        // FSM is in HALTED.
        logic        error;         // ERR_CODE holds an unacknowledged error.
        fsm_state_e  state;         // STATUS.FSM.
        logic [15:0] exec_seq;      // Sequence of the executing (or last) command.
        logic [15:0] next_seq;      // NEXT_SEQ.
        logic [15:0] done_seq;      // DONE_SEQ.
        logic [31:0] err_code;      // ERR_CODE: {seq, 8'b0, code}.
        logic [31:0] err_info;      // ERR_INFO: offending register offset, or 0.
        logic [63:0] cyc_total;     // CYC_TOTAL.
        logic [63:0] cyc_busy;      // CYC_BUSY.
        logic [31:0] cyc_stall_in;  // CYC_STALL_IN.
        logic [31:0] cyc_stall_out; // CYC_STALL_OUT.
        logic [31:0] cmd_count;     // CMD_COUNT.
    } ctrl_status_t;

    // Field helpers for scratchpad references.
    function automatic logic [3:0] ref_bank(input logic [31:0] r);
        return r[31:28];
    endfunction
    function automatic logic [23:0] ref_offset(input logic [31:0] r);
        return r[23:0];
    endfunction
endpackage
`default_nettype wire
