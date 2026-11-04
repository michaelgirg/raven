`default_nettype none
// TESTBENCH ONLY: the command driver standing in for the future RISC-V processor.
//
// raven_reg_bus_if carries the D1 register bus. raven_tb_driver_pkg holds tasks that mirror
// the firmware API of RISCV_Research.md §8.2 (raven_init, raven_set_op, raven_start,
// raven_wait, ...) and return the same raven_status_t codes, so a test sequence written
// here carries over to C. Every register access is logged as "W|R offset value" to the
// open trace file; those traces seed tests/traces/ later.
//
// Usage: set raven_tb_driver_pkg::bus to the testbench's interface instance before calling.

// Register bus between the driver and raven_npu_top. The driver changes signals on the
// falling edge, so the design samples stable values on the rising edge.
interface raven_reg_bus_if (input wire clk);
    logic valid; // Is there an access this clock?
    logic ready; // Can the block accept it?
    logic write; // 1 = write, 0 = read.
    logic [11:0] addr; // Byte offset inside the NPU window.
    logic [31:0] wdata; // Write data.
    logic [31:0] rdata; // Read data, valid with rvalid.
    logic rvalid; // One-clock response for every accepted access.
    logic error; // Unmapped or unaligned access.
endinterface

package raven_tb_driver_pkg;
    import raven_ctrl_pkg::*;

    // raven_status_t (RISCV_Research.md §8.2).
    typedef enum int {
        RAVEN_OK = 0, RAVEN_E_TIMEOUT = -1, RAVEN_E_BOUNDS = -2, RAVEN_E_HW = -3,
        RAVEN_E_BUSY = -4, RAVEN_E_VERSION = -7
    } raven_status_t;

    virtual raven_reg_bus_if bus; // Set by the testbench.
    int trace_fd; // Open trace file, or 0 for none.
    bit last_bus_error; // reg_error_o of the most recent access.
    logic [15:0] sw_next_seq; // Software's copy of NEXT_SEQ, checked on every START.
    int unsigned accesses; // Register accesses since time zero.

    // Bus idle values; call once before reset is released.
    task automatic npu_bus_idle();
        bus.valid = 0; bus.write = 0; bus.addr = '0; bus.wdata = '0;
    endtask

    // Start logging register traffic to path (closing any previous trace).
    task automatic raven_open_trace(input string path);
        if (trace_fd != 0) $fclose(trace_fd);
        trace_fd = $fopen(path, "w");
        if (trace_fd == 0) $fatal(1, "Cannot open trace %s", path);
    endtask

    task automatic raven_close_trace();
        if (trace_fd != 0) $fclose(trace_fd);
        trace_fd = 0;
    endtask

    // One access: drive on the falling edge, wait for acceptance, take the one-clock response.
    task automatic npu_access(input bit write, input logic [11:0] offset, input logic [31:0] wdata,
                              output logic [31:0] rdata, output bit error);
        int waited = 0;
        @(negedge bus.clk);
        bus.valid = 1; bus.write = write; bus.addr = offset; bus.wdata = write ? wdata : '0;
        @(posedge bus.clk);
        while (!bus.ready) begin
            if (++waited > 1000) $fatal(1, "Register bus never accepted access to %03h", offset);
            @(posedge bus.clk);
        end
        @(negedge bus.clk);
        bus.valid = 0;
        if (bus.rvalid !== 1'b1) $fatal(1, "No register response for %03h", offset);
        rdata = bus.rdata; error = bus.error;
        last_bus_error = error; accesses++;
        // Fixed formats: some simulators pad an empty %s argument with spaces.
        if (trace_fd != 0) begin
            if (error) $fdisplay(trace_fd, "%s %03h %08h ERR", write ? "W" : "R", offset, write ? wdata : rdata);
            else $fdisplay(trace_fd, "%s %03h %08h", write ? "W" : "R", offset, write ? wdata : rdata);
        end
    endtask

    task automatic npu_write32(input logic [11:0] offset, input logic [31:0] value);
        logic [31:0] unused;
        bit error;
        npu_access(1, offset, value, unused, error);
    endtask

    task automatic npu_read32(input logic [11:0] offset, output logic [31:0] value);
        bit error;
        npu_access(0, offset, '0, value, error);
    endtask

    // ID/VERSION check and IRQ setup. Assumes the NPU is freshly reset.
    task automatic raven_init(output raven_status_t status);
        logic [31:0] v;
        status = RAVEN_OK;
        npu_read32(REG_ID, v);
        if (v != NPU_ID) begin status = RAVEN_E_VERSION; return; end
        npu_read32(REG_VERSION, v);
        if (v != NPU_VERSION) begin status = RAVEN_E_VERSION; return; end
        npu_write32(REG_IRQ_ENABLE, IRQ_MASK);
        npu_read32(REG_NEXT_SEQ, v);
        sw_next_seq = v[15:0];
    endtask

    // raven_set_op for a prepared command: write every staging register listed in path
    // ("offset value" hex pairs, as emitted by export_fixtures.py).
    task automatic raven_set_op_from_file(input string path);
        int fd, got;
        logic [31:0] offset, value;
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "Cannot open command file %s", path);
        forever begin
            got = $fscanf(fd, "%h %h\n", offset, value);
            if (got != 2) break;
            npu_write32(offset[11:0], value);
        end
        $fclose(fd);
    endtask

    // Submit the staged command. Refuses (RAVEN_E_BUSY) when the queue is full, and fails
    // (RAVEN_E_HW) if hardware NEXT_SEQ disagrees with software's count.
    task automatic raven_start(output logic [15:0] seq, output raven_status_t status);
        logic [31:0] st, next;
        npu_read32(REG_STATUS, st);
        if (st[STATUS_Q_FULL]) begin status = RAVEN_E_BUSY; return; end
        npu_read32(REG_NEXT_SEQ, next);
        if (next[15:0] != sw_next_seq) begin status = RAVEN_E_HW; return; end
        npu_write32(REG_CTRL, 32'd1 << CTRL_START);
        seq = sw_next_seq;
        sw_next_seq++;
        status = RAVEN_OK;
    endtask

    // Poll until seq retires (RAVEN_OK), an error is reported (RAVEN_E_HW, err = ERR_CODE),
    // or timeout_cycles clocks pass (RAVEN_E_TIMEOUT).
    task automatic raven_wait(input logic [15:0] seq, input int timeout_cycles,
                              output logic [31:0] err, output raven_status_t status);
        logic [31:0] st, done;
        int cycles = 0;
        err = 0;
        forever begin
            npu_read32(REG_STATUS, st);
            if (st[STATUS_ERROR]) begin
                npu_read32(REG_ERR_CODE, err);
                status = RAVEN_E_HW;
                return;
            end
            npu_read32(REG_DONE_SEQ, done);
            if (done[15:0] == seq && !st[STATUS_BUSY]) begin status = RAVEN_OK; return; end
            cycles += 4; // Two accesses of two clocks each.
            if (cycles >= timeout_cycles) begin status = RAVEN_E_TIMEOUT; return; end
        end
    endtask

    // SOFT_RESET returns the NPU to IDLE with NEXT_SEQ = 0 (D11).
    task automatic raven_soft_reset();
        npu_write32(REG_CTRL, 32'd1 << CTRL_SOFT_RESET);
        sw_next_seq = 0;
    endtask

    task automatic raven_clear_err();
        npu_write32(REG_CTRL, 32'd1 << CTRL_CLEAR_ERR);
    endtask

    // Software resynchronization after a hardware reset the driver did not issue.
    task automatic raven_resync();
        logic [31:0] v;
        npu_read32(REG_NEXT_SEQ, v);
        sw_next_seq = v[15:0];
    endtask
endpackage
`default_nettype wire
