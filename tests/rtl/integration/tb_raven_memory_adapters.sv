`timescale 1ns/1ps
`default_nettype none
// Exercise the public adapter contracts independently of the GEMM frontend.
module tb_raven_read_buffer_adapter #(parameter int KIND = 0);
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic req_valid = 0, rsp_ready = 0, mem_req_ready = 0, mem_rsp_valid = 0;
    logic [23:0] addr = 0;
    logic [127:0] mem_data = 0;
    wire req_ready, rsp_valid, mem_req_valid, mem_rsp_ready;
    wire [23:0] mem_addr;
    wire [127:0] rsp_data;
    int requests = 0, responses = 0, checks = 0;
    raven_read_buffer_adapter #(.KIND(KIND)) dut (
        .clk_i(clk), .rst_ni(rst_n), .req_valid_i(req_valid), .req_ready_o(req_ready), .req_addr_i(addr),
        .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready), .rsp_data_o(rsp_data),
        .mem_req_valid_o(mem_req_valid), .mem_req_ready_i(mem_req_ready), .mem_req_addr_o(mem_addr),
        .mem_rsp_valid_i(mem_rsp_valid), .mem_rsp_ready_o(mem_rsp_ready), .mem_rsp_data_i(mem_data)
    );
    always @(posedge clk) if (rst_n) begin
        if (mem_req_valid && mem_req_ready) requests++;
        if (rsp_valid && rsp_ready) responses++;
    end
    function automatic logic [127:0] pattern(input int tag);
        for (int lane = 0; lane < 16; lane++) pattern[8*lane +: 8] = 8'(tag*37 + lane*19);
    endfunction
    task automatic check(input bit good, input string message);
        checks++;
        if (!good) $fatal(1, "read kind %0d: %s", KIND, message);
    endtask
    task automatic tick(input int count = 1);
        repeat (count) @(negedge clk);
    endtask
    task automatic reset_adapter;
        rst_n = 0; req_valid = 0; rsp_ready = 0; mem_req_ready = 0; mem_rsp_valid = 0;
        tick(3);
        check(!rsp_valid && !mem_req_valid, "reset must cancel pending traffic");
        rst_n = 1; tick(4);
        check(req_ready, "ready after reset and parameter-mode initialization");
    endtask
    task automatic start_read(input logic [23:0] address);
        check(req_ready, "request slot ready");
        addr = address; req_valid = 1; tick(); req_valid = 0;
        check(mem_req_valid && mem_addr == address, "full address preserved");
    endtask
    task automatic fetch_word(input logic [127:0] data);
        mem_req_ready = 1; tick(); mem_req_ready = 0;
        tick(3);
        mem_data = data; mem_rsp_valid = 1;
        check(mem_rsp_ready, "backing response accepted");
        tick(); mem_rsp_valid = 0;
    endtask
    task automatic wait_response;
        int cycles;
        cycles = 0;
        while (!rsp_valid && cycles < 100) begin tick(); cycles++; end
        check(rsp_valid, "bounded response completion");
    endtask
    task automatic complete_read(input logic [23:0] address, input int tag);
        int old_requests, old_responses;
        old_requests = requests; old_responses = responses;
        start_read(address);
        repeat (4) begin
            tick(); check(mem_req_valid && mem_addr == address && !req_ready,
                          "held backing request and one outstanding transaction");
        end
        fetch_word(pattern(tag));
        wait_response();
        repeat (5) begin
            check(rsp_data === pattern(tag) && !req_ready, "held response matches all sixteen bytes");
            tick();
        end
        rsp_ready = 1; tick(); rsp_ready = 0;
        tick(3);
        check(!rsp_valid && req_ready, "response retired without a duplicate");
        check(requests == old_requests+1 && responses == old_responses+1, "exactly one fetch and response");
    endtask
    initial begin
        tick(); reset_adapter();
        // Cover every native slot, reuse it with a different upper address, and
        // retain arbitrary reserved PARAM bytes alongside bias/multiplier/shift.
        for (int slot = 0; slot < 8; slot++) begin
            complete_read(24'h000100 + 24'(slot*16), slot+1);
            complete_read(24'h000f00 + 24'(slot*16), slot+21);
        end
        start_read(24'h000230); tick(3); reset_adapter();
        complete_read(24'h000230, 41);
        start_read(24'h000340); mem_req_ready = 1; tick(); mem_req_ready = 0;
        tick(3); reset_adapter();
        complete_read(24'h000340, 42);
        start_read(24'h000450); fetch_word(pattern(43)); tick(); reset_adapter();
        complete_read(24'h000450, 44);
        start_read(24'h000560); fetch_word(pattern(45)); wait_response(); reset_adapter();
        complete_read(24'h000560, 46);
        $display("READ ADAPTER PASS kind=%0d checks=%0d", KIND, checks);
        $finish;
    end
    initial begin #200000; $fatal(1, "read adapter watchdog"); end
endmodule

module tb_raven_output_buffer_adapter;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic valid = 0, mem_ready = 0;
    logic [23:0] addr = 0;
    logic [127:0] data = 0;
    logic [15:0] strb = 0;
    wire ready, mem_valid;
    wire [23:0] mem_addr;
    wire [127:0] mem_data;
    wire [15:0] mem_strb;
    int accepted = 0, committed = 0, checks = 0;
    raven_output_buffer_adapter dut (
        .clk_i(clk), .rst_ni(rst_n), .w_valid_i(valid), .w_ready_o(ready),
        .w_addr_i(addr), .w_data_i(data), .w_strb_i(strb),
        .mem_w_valid_o(mem_valid), .mem_w_ready_i(mem_ready),
        .mem_w_addr_o(mem_addr), .mem_w_data_o(mem_data), .mem_w_strb_o(mem_strb)
    );
    always @(posedge clk) if (rst_n) begin
        if (valid && ready) accepted++;
        if (mem_valid && mem_ready) committed++;
        if ((valid && ready) != (mem_valid && mem_ready)) $fatal(1, "acceptance must equal backing commit");
    end
    task automatic check(input bit good, input string message);
        checks++;
        if (!good) $fatal(1, "output adapter: %s", message);
    endtask
    task automatic tick(input int count = 1);
        repeat (count) @(negedge clk);
    endtask
    task automatic reset_adapter;
        rst_n = 0; valid = 0; mem_ready = 0;
        tick(3); check(!ready && !mem_valid, "reset cancels uncommitted write");
        rst_n = 1; tick(2);
    endtask
    task automatic start_write(input logic [23:0] address, input logic [15:0] mask, input int tag);
        addr = address; strb = mask;
        for (int lane = 0; lane < 16; lane++) data[8*lane +: 8] = 8'(tag*31 + lane*17);
        valid = 1;
    endtask
    task automatic wait_commit;
        int cycles;
        cycles = 0;
        while (!mem_valid && cycles < 40) begin
            check(!ready, "no upstream acknowledgement while staging"); tick(); cycles++;
        end
        check(mem_valid, "bounded write staging");
    endtask
    task automatic complete_write(input logic [23:0] address, input logic [15:0] mask, input int tag);
        int old_accepted, old_committed;
        logic [127:0] observed, expected;
        old_accepted = accepted; old_committed = committed;
        start_write(address, mask, tag); wait_commit();
        repeat (5) begin
            check(!ready && mem_valid && mem_addr == address && mem_strb == mask,
                  "backing stall holds address, strobes and completion");
            for (int lane = 0; lane < 16; lane++) if (mask[lane])
                check(mem_data[8*lane +: 8] === data[8*lane +: 8], "strobed byte traverses output buffer");
            tick();
        end
        // Model byte-enable storage independently; unstrobed bytes are guards.
        observed = {16{8'ha5}}; expected = observed;
        for (int lane = 0; lane < 16; lane++) begin
            if (mem_strb[lane]) observed[8*lane +: 8] = mem_data[8*lane +: 8];
            if (mask[lane]) expected[8*lane +: 8] = data[8*lane +: 8];
        end
        check(observed === expected, "byte-enable storage preserves guards");
        mem_ready = 1; tick(); valid = 0; mem_ready = 0;
        tick(3);
        check(accepted == old_accepted+1 && committed == old_committed+1 && !mem_valid,
              "exactly one acknowledgement and committed write");
    endtask
    initial begin
        tick(); reset_adapter();
        for (int lane = 0; lane < 16; lane++)
            complete_write(24'h001e00 + 24'(16*(lane%8)), 16'b1 << lane, lane+1);
        complete_write(24'h001ff0, 16'hffff, 31);
        complete_write(24'h001ff0, 16'h8101, 32);
        complete_write(24'h000000, 16'h5aa5, 33);
        start_write(24'h000110, 16'hffff, 41); tick(2); reset_adapter();
        complete_write(24'h000110, 16'hffff, 42);
        start_write(24'h000220, 16'h0080, 43); wait_commit(); tick(3); reset_adapter();
        complete_write(24'h000220, 16'h8000, 44);
        check(accepted == 21 && committed == 21, "reset attempts did not commit");
        $display("OUTPUT ADAPTER PASS checks=%0d", checks);
        $finish;
    end
    initial begin #100000; $fatal(1, "output adapter watchdog"); end
endmodule
`default_nettype wire
