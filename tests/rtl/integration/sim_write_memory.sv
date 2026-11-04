`default_nettype none
// TESTBENCH ONLY: a byte-strobed write model of Taylor's future OUT bank write port.
//
// 128-bit words, one write per accepted handshake, committed on that clock (D5: accepted =
// committed). With stalls_i set, w_ready_o drops on pseudo-random clocks. Contents start
// as the guard byte 0xA5 and are not cleared by reset, so a test can tell untouched bytes
// from written ones. The testbench reads mem directly or calls the tasks below.
module sim_write_memory #(
    parameter int BYTES = 8192, // Bank capacity.
    parameter int SEED = 1, // Stall pattern seed.
    parameter logic [7:0] GUARD = 8'hA5 // Fill value for untouched bytes.
) (
    input wire clk_i, rst_ni, stalls_i, // Clock, active-low reset, random write stalls.
    input wire w_valid_i, // Is a write presented?
    output wire w_ready_o, // The write is accepted (and committed) this clock.
    input wire [23:0] w_addr_i, // 16-byte-aligned word address.
    input wire [127:0] w_data_i, // Write data, byte lane b at [8*b+7:8*b].
    input wire [15:0] w_strb_i, // Byte-lane enables.
    output logic [31:0] writes_o, // Writes accepted since reset.
    output logic [31:0] last_write_cycle_o // Cycle count of the most recent accepted write.
);
    localparam int WORDS = BYTES / 16;
    localparam int INDEX_W = $clog2(WORDS);
    logic [127:0] mem [WORDS];
    logic [31:0] random_q, cycle_q;

    assign w_ready_o = rst_ni && (!stalls_i || random_q[0]);

    // Refill every byte with the guard value.
    task automatic fill_guard();
        for (int w = 0; w < WORDS; w++) mem[w] = {16{GUARD}};
    endtask

    function automatic logic [7:0] read_byte(input int addr);
        return mem[addr / 16][8 * (addr % 16) +: 8];
    endfunction

    // Write the whole bank, one byte per line in hex, for offline inspection.
    task automatic dump_bytes(input string path);
        int fd;
        fd = $fopen(path, "w");
        if (fd == 0) $fatal(1, "Cannot open %s", path);
        for (int a = 0; a < BYTES; a++) $fdisplay(fd, "%02h", read_byte(a));
        $fclose(fd);
    endtask

    initial fill_guard();

    // Plain always, not always_ff: fill_guard() also writes mem from the testbench.
    always @(posedge clk_i) begin
        if (!rst_ni) begin
            random_q <= SEED; writes_o <= 0; cycle_q <= 0; last_write_cycle_o <= 0;
        end else begin
            random_q <= {random_q[30:0], random_q[31]^random_q[21]^random_q[1]^random_q[0]};
            cycle_q <= cycle_q + 1;
            if (w_valid_i && w_ready_o) begin
                assert (w_addr_i[3:0] == 0 && 32'(w_addr_i) + 16 <= BYTES && w_strb_i != 0)
                    else $fatal(1, "OUT write outside owned aligned bank or empty strobe: %h/%h", w_addr_i, w_strb_i);
                for (int b = 0; b < 16; b++)
                    if (w_strb_i[b]) mem[INDEX_W'(w_addr_i >> 4)][8*b +: 8] <= w_data_i[8*b +: 8];
                writes_o <= writes_o + 1;
                last_write_cycle_o <= cycle_q;
            end
        end
    end

    // Soft reset can release after this clock's input sample.
    assert property (@(posedge clk_i) disable iff (!rst_ni || !$sampled(rst_ni))
        w_valid_i && !w_ready_o |=> w_valid_i && $stable({w_addr_i, w_data_i, w_strb_i}));
endmodule
`default_nettype wire
