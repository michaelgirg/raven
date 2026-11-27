`default_nettype none
// TESTBENCH ONLY: AXI4-Lite master standing in for the Vivado JTAG-to-AXI core.
//
// raven_axil_if carries one 32-bit AXI4-Lite link with a 14-bit address. axil_master_pkg
// holds tasks that drive it the way the host does through Hardware Manager, plus the
// orderings and stalls the bridge must tolerate: AW before W, W before AW, both on the same
// clock, and random delays before BREADY/RREADY.
//
// Usage: set axil_master_pkg::bus to the testbench's interface instance, call axil_idle()
// before reset is released, then use axil_write/axil_read. Signals change on the falling
// edge, so the design samples stable values on the rising edge.

interface raven_axil_if (input wire clk);
    logic [13:0] awaddr; // Write address.
    logic awvalid, awready;
    logic [31:0] wdata; // Write data.
    logic [3:0] wstrb;
    logic wvalid, wready;
    logic [1:0] bresp; // Write response.
    logic bvalid, bready;
    logic [13:0] araddr; // Read address.
    logic arvalid, arready;
    logic [31:0] rdata; // Read data.
    logic [1:0] rresp;
    logic rvalid, rready;
endinterface

package axil_master_pkg;
    localparam logic [1:0] AXI_OKAY   = 2'b00;
    localparam logic [1:0] AXI_SLVERR = 2'b10;
    localparam logic [1:0] AXI_DECERR = 2'b11;

    // How the write address and data channels are presented.
    typedef enum int { ORDER_SAME, ORDER_AW_FIRST, ORDER_W_FIRST } wr_order_e;

    virtual raven_axil_if bus; // Set by the testbench.
    int trace_fd; // Open trace file, or 0 for none.
    int unsigned max_resp_delay = 0; // Upper bound on random BREADY/RREADY delay, in clocks.
    int unsigned max_chan_gap = 3; // Upper bound on the gap between AW and W when ordered.
    int unsigned timeout_cycles = 1000; // Per-handshake watchdog.
    int unsigned writes, reads; // Completed transactions.

    function automatic string resp_name(input logic [1:0] resp);
        case (resp)
            AXI_OKAY:   return "OKAY";
            AXI_SLVERR: return "SLVERR";
            AXI_DECERR: return "DECERR";
            default:    return "EXOKAY";
        endcase
    endfunction

    // Bus idle values; call once before reset is released.
    task automatic axil_idle();
        bus.awaddr = '0; bus.awvalid = 0;
        bus.wdata = '0; bus.wstrb = '0; bus.wvalid = 0;
        bus.bready = 0;
        bus.araddr = '0; bus.arvalid = 0;
        bus.rready = 0;
    endtask

    task automatic axil_open_trace(input string path);
        if (trace_fd != 0) $fclose(trace_fd);
        trace_fd = $fopen(path, "w");
        if (trace_fd == 0) $fatal(1, "Cannot open trace %s", path);
    endtask

    task automatic axil_close_trace();
        if (trace_fd != 0) $fclose(trace_fd);
        trace_fd = 0;
    endtask

    task automatic wait_clocks(input int unsigned n);
        repeat (n) @(negedge bus.clk);
    endtask

    // Single channels. Each presents on a falling edge and returns on the falling edge
    // after the rising edge where the handshake happened.

    task automatic axil_send_aw(input logic [13:0] addr);
        int unsigned waited = 0;
        @(negedge bus.clk);
        bus.awaddr = addr; bus.awvalid = 1;
        do begin
            @(posedge bus.clk);
            if (++waited > timeout_cycles) $fatal(1, "AW %04h never accepted", addr);
        end while (bus.awready !== 1'b1);
        @(negedge bus.clk);
        bus.awvalid = 0;
    endtask

    task automatic axil_send_w(input logic [31:0] data, input logic [3:0] strb);
        int unsigned waited = 0;
        @(negedge bus.clk);
        bus.wdata = data; bus.wstrb = strb; bus.wvalid = 1;
        do begin
            @(posedge bus.clk);
            if (++waited > timeout_cycles) $fatal(1, "W %08h never accepted", data);
        end while (bus.wready !== 1'b1);
        @(negedge bus.clk);
        bus.wvalid = 0;
    endtask

    task automatic axil_send_ar(input logic [13:0] addr);
        int unsigned waited = 0;
        @(negedge bus.clk);
        bus.araddr = addr; bus.arvalid = 1;
        do begin
            @(posedge bus.clk);
            if (++waited > timeout_cycles) $fatal(1, "AR %04h never accepted", addr);
        end while (bus.arready !== 1'b1);
        @(negedge bus.clk);
        bus.arvalid = 0;
    endtask

    task automatic axil_get_b(output logic [1:0] resp);
        int unsigned waited = 0;
        if (max_resp_delay != 0) wait_clocks($urandom_range(max_resp_delay));
        @(negedge bus.clk);
        bus.bready = 1;
        do begin
            @(posedge bus.clk);
            if (++waited > timeout_cycles) $fatal(1, "No write response");
        end while (bus.bvalid !== 1'b1);
        resp = bus.bresp;
        @(negedge bus.clk);
        bus.bready = 0;
    endtask

    task automatic axil_get_r(output logic [31:0] data, output logic [1:0] resp);
        int unsigned waited = 0;
        if (max_resp_delay != 0) wait_clocks($urandom_range(max_resp_delay));
        @(negedge bus.clk);
        bus.rready = 1;
        do begin
            @(posedge bus.clk);
            if (++waited > timeout_cycles) $fatal(1, "No read response");
        end while (bus.rvalid !== 1'b1);
        data = bus.rdata; resp = bus.rresp;
        @(negedge bus.clk);
        bus.rready = 0;
    endtask

    // Complete transactions.

    task automatic axil_write(input logic [13:0] addr, input logic [31:0] data,
                              input logic [3:0] strb, input wr_order_e order,
                              output logic [1:0] resp);
        case (order)
            ORDER_SAME: fork
                axil_send_aw(addr);
                axil_send_w(data, strb);
            join
            ORDER_AW_FIRST: begin
                axil_send_aw(addr);
                wait_clocks($urandom_range(max_chan_gap));
                axil_send_w(data, strb);
            end
            ORDER_W_FIRST: begin
                axil_send_w(data, strb);
                wait_clocks($urandom_range(max_chan_gap));
                axil_send_aw(addr);
            end
        endcase
        axil_get_b(resp);
        writes++;
        if (trace_fd != 0) $fdisplay(trace_fd, "W %04h %08h %01h %s", addr, data, strb, resp_name(resp));
    endtask

    task automatic axil_read(input logic [13:0] addr, output logic [31:0] data,
                             output logic [1:0] resp);
        axil_send_ar(addr);
        axil_get_r(data, resp);
        reads++;
        if (trace_fd != 0) $fdisplay(trace_fd, "R %04h %08h %s", addr, data, resp_name(resp));
    endtask

    // Convenience forms for the common case: full strobes, same-clock channels, and a
    // fatal error on any response other than OKAY.

    task automatic axil_write32(input logic [13:0] addr, input logic [31:0] data);
        logic [1:0] resp;
        axil_write(addr, data, 4'hF, ORDER_SAME, resp);
        if (resp !== AXI_OKAY) $fatal(1, "Write %04h returned %s", addr, resp_name(resp));
    endtask

    task automatic axil_read32(input logic [13:0] addr, output logic [31:0] data);
        logic [1:0] resp;
        axil_read(addr, data, resp);
        if (resp !== AXI_OKAY) $fatal(1, "Read %04h returned %s", addr, resp_name(resp));
    endtask
endpackage
`default_nettype wire
