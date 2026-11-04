`timescale 1ns/1ps

// Fixture-driven test for Taylor's activationBuffer (8 banks x 16 INT8).
// Each a.hex line contains one 128-bit bank packed little-endian by byte.
module tb_activation_buffer_golden;
    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst;
    logic wr_valid;
    logic wr_ready;
    logic [2:0] wr_bank;
    logic [127:0] wr_data;
    logic rd_valid_in;
    logic rd_ready;
    logic [3:0] rd_k;
    logic rd_valid_out;
    logic rd_ready_out;
    logic [63:0] rd_data;

    logic [127:0] expected_banks [0:7];
    string ahex;
    string case_name;
    integer valid_m, valid_k;

    activationBuffer dut (
        .clk(clk), .rst(rst),
        .wr_valid(wr_valid), .wr_ready(wr_ready),
        .wr_bank(wr_bank), .wr_data(wr_data),
        .rd_valid_in(rd_valid_in), .rd_ready(rd_ready), .rd_k(rd_k),
        .rd_valid_out(rd_valid_out), .rd_ready_out(rd_ready_out),
        .rd_data(rd_data)
    );

    initial begin
        #100000;
        $fatal(1, "TIMEOUT activation buffer golden test");
    end

    initial begin
        if (!$value$plusargs("AHEX=%s", ahex))
            $fatal(1, "Missing +AHEX=<absolute path to a.hex>");
        if (!$value$plusargs("CASE=%s", case_name))
            case_name = "unknown";
        if (!$value$plusargs("VALID_M=%d", valid_m)) valid_m = 8;
        if (!$value$plusargs("VALID_K=%d", valid_k)) valid_k = 16;
        if (valid_m < 1 || valid_m > 8 || valid_k < 1 || valid_k > 16)
            $fatal(1, "Invalid valid tile dimensions M=%0d K=%0d", valid_m, valid_k);
        $readmemh(ahex, expected_banks);

        rst = 1'b1;
        wr_valid = 1'b0;
        wr_bank = '0;
        wr_data = '0;
        rd_valid_in = 1'b0;
        rd_k = '0;
        rd_ready_out = 1'b0;
        repeat (3) @(negedge clk);
        rst = 1'b0;

        // Load the eight 16-byte activation rows via the real write interface.
        for (int bank = 0; bank < 8; bank++) begin
            @(negedge clk);
            wr_bank = 3'(bank);
            wr_data = expected_banks[bank];
            wr_valid = 1'b1;
            if (wr_ready !== 1'b1)
                $fatal(1, "Write not ready: bank=%0d", bank);
            @(posedge clk); // accepted here
            @(negedge clk);
            wr_valid = 1'b0;
        end

        // Read each K position across all banks; hold under backpressure.
        for (int k = 0; k < 16; k++) begin
            @(negedge clk);
            rd_k = 4'(k);
            rd_valid_in = 1'b1;
            rd_ready_out = 1'b0;
            if (rd_ready !== 1'b1)
                $fatal(1, "Read not ready: k=%0d", k);
            @(posedge clk); // read accepted here
            @(negedge clk);
            rd_valid_in = 1'b0;

            // Verify valid/read data immediately and for two stalled cycles.
            for (int stall_cycle = 0; stall_cycle < 3; stall_cycle++) begin
                if (rd_valid_out !== 1'b1)
                    $fatal(1, "Output valid dropped: k=%0d stall=%0d", k, stall_cycle);
                if (wr_ready !== 1'b0)
                    $fatal(1, "Write ready asserted during pending output: k=%0d", k);
                for (int bank = 0; bank < 8; bank++) begin
                    if (rd_data[bank*8 +: 8] !== expected_banks[bank][k*8 +: 8]) begin
                        $fatal(1,
                            "MISMATCH bank=%0d k=%0d expected=%0d actual=%0d",
                            bank, k,
                            $signed(expected_banks[bank][k*8 +: 8]),
                            $signed(rd_data[bank*8 +: 8]));
                    end
                end
                if (stall_cycle < 2) begin
                    @(posedge clk);
                    @(negedge clk);
                end
            end
            rd_ready_out = 1'b1;
            @(posedge clk); // output consumed here
            @(negedge clk);
            if (rd_valid_out !== 1'b0)
                $fatal(1, "Output valid did not clear after handshake: k=%0d", k);
            rd_ready_out = 1'b0;
        end

        $display("PASS ACTIVATION GOLDEN: 128/128 INT8 values matched (%s); output stalls verified", case_name);
        $display("VALID TILE: %0d/%0d meaningful activation values, %0d padded physical positions checked", valid_m*valid_k, valid_m*valid_k, 128-valid_m*valid_k);
        $finish;
    end
endmodule
