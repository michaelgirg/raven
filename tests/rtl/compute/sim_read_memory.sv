`default_nettype none
// TESTBENCH ONLY: a latency/backpressure model of Taylor's future read port.
module sim_read_memory #(
    parameter int BYTES = 16384,
    parameter int SEED = 1
) (
    input wire clk_i, rst_ni, stalls_i,
    input wire req_valid_i,
    output wire req_ready_o,
    input wire [23:0] req_addr_i,
    output logic rsp_valid_o,
    input wire rsp_ready_i,
    output logic [127:0] rsp_data_o,
    output logic [31:0] reads_o
);
    logic [127:0] mem [BYTES/16];
    localparam int INDEX_W = $clog2(BYTES/16);
    logic pending_q;
    int delay_q;
    logic [127:0] pending_data_q;
    logic [31:0] random_q;
    assign req_ready_o = rst_ni && !pending_q && !rsp_valid_o
                         && (!stalls_i || random_q[0]);
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            pending_q <= 0; delay_q <= 0; pending_data_q <= 0;
            rsp_valid_o <= 0; rsp_data_o <= 0; reads_o <= 0; random_q <= SEED;
        end else begin
            random_q <= {random_q[30:0],random_q[31]^random_q[21]^random_q[1]^random_q[0]};
            if (rsp_valid_o && rsp_ready_i) rsp_valid_o <= 0;
            if (pending_q) begin
                if (delay_q == 0) begin
                    rsp_valid_o <= 1; rsp_data_o <= pending_data_q; pending_q <= 0;
                end else delay_q <= delay_q - 1;
            end
            if (req_valid_i && req_ready_o) begin
                assert (req_addr_i[3:0] == 0 && 32'(req_addr_i)+16 <= BYTES)
                    else $fatal(1,"Memory request outside owned aligned bank: %h", req_addr_i);
                pending_data_q <= mem[INDEX_W'(req_addr_i >> 4)];
                pending_q <= 1; delay_q <= stalls_i ? int'(random_q[3:1]) : 0;
                reads_o <= reads_o + 1;
            end
        end
    end
    // Soft reset can release after this clock's input sample.
    assert property (@(posedge clk_i) disable iff (!rst_ni || !$sampled(rst_ni))
        req_valid_i && !req_ready_o |=> req_valid_i && $stable(req_addr_i));
    assert property (@(posedge clk_i) disable iff (!rst_ni || !$sampled(rst_ni))
        rsp_valid_o && !rsp_ready_i |=> rsp_valid_o && $stable(rsp_data_o));
endmodule
`default_nettype wire
