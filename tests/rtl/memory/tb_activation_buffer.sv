
`timescale 1ns/1ps

module tb_activation_buffer;

    logic clk;
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

    activationBuffer dut (
        .clk(clk),
        .rst(rst),

        .wr_valid(wr_valid),
        .wr_ready(wr_ready),
        .wr_bank(wr_bank),
        .wr_data(wr_data),

        .rd_valid_in(rd_valid_in),
        .rd_ready(rd_ready),
        .rd_k(rd_k),

        .rd_valid_out(rd_valid_out),
        .rd_ready_out(rd_ready_out),
        .rd_data(rd_data)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    logic signed [7:0] expected [0:7][0:15];

    //write one 128-bit bank
    task automatic write_bank(input logic [2:0] bank);
        begin
            @(negedge clk);

            wr_bank = bank;

            for (int j = 0; j < 16; j++) begin
                wr_data[j*8 +: 8] = expected[bank][j];
            end

            wr_valid = 1'b1;

            //wait until the write can be accepted
            while (!wr_ready)
                @(negedge clk);

            //write is accepted at the next rising edge
          	@(posedge clk);
            @(negedge clk);
            wr_valid = 1'b0;
        end
    endtask

    //read one K position across all eight banks
    task automatic read_k(input logic [3:0] k);
        begin
            @(negedge clk);

            rd_k = k;
            rd_valid_in = 1'b1;

            while (!rd_ready)
                @(negedge clk);

            //read is accepted at the next rising edge
            @(posedge clk);
            @(negedge clk);
            rd_valid_in = 1'b0;
        end
    endtask

    //compare the eight output values against expected values
    task automatic check_output(input logic [3:0] k);
        begin
            if (!rd_valid_out) begin
                $error("FAIL: rd_valid_out was not asserted");
                $fatal;
            end

            for (int i = 0; i < 8; i++) begin
                if ($signed(rd_data[i*8 +: 8]) !== expected[i][k]) begin
                    $error("FAIL: Bank %0d, K %0d: Expected %0d, Got %0d", i, k, expected[i][k], $signed(rd_data[i*8 +: 8]));
                    $fatal;
                end
            end

            $display("PASS: Read K=%0d returned all 8 expected values", k);
        end
    endtask

    initial begin
        rst = 1'b1;

        wr_valid = 1'b0;
        wr_bank = '0;
        wr_data = '0;

        rd_valid_in = 1'b0;
        rd_k = '0;
        rd_ready_out = 1'b0;

        $display("--------------------------------");
        $display("Starting activation buffer tests");
        $display("--------------------------------");

        //reset
        repeat (2) @(negedge clk);
        rst = 1'b0;

        //reset behavior
        if (rd_valid_out !== 1'b0) begin
            $fatal(1, "FAIL: Reset did not clear rd_valid_out");
        end

        $display("PASS: Reset");

        //expected data and all eight banks
        for (int i = 0; i < 8; i++) begin

            for (int j = 0; j < 16; j++) begin
                //unique signed test values: -64 through 63
                expected[i][j] = (i * 16 + j) - 64;
            end

            write_bank(i);
        end

        $display("PASS: All eight banks written");

        //read and verify all 16 K positions
        for (int k = 0; k < 16; k++) begin

            read_k(k);

            check_output(k);

            //consume output before requesting the next read
            rd_ready_out = 1'b1;

            @(posedge clk);
            @(negedge clk);

            rd_ready_out = 1'b0;

        end

        $display("PASS: All 16 K positions verified");

        //output backpressure
        $display("Testing output backpressure");

        read_k(3);

        //save and verify output while receiver is not ready
        for (int i = 0; i < 8; i++) begin
            if ($signed(rd_data[i*8 +: 8]) !== expected[i][3]) begin
                $fatal(
                    1,
                    "FAIL: Initial backpressure mismatch at bank %0d",
                    i
                );
            end
        end

        //keep receiver stalled for three clock cycles
        repeat (3) begin
            @(posedge clk);
            #1;

            if (!rd_valid_out)
                $fatal(1, "FAIL: rd_valid_out dropped during backpressure");

            for (int i = 0; i < 8; i++) begin
                if ($signed(rd_data[i*8 +: 8]) !== expected[i][3]) begin
                    $fatal(
                        1,
                        "FAIL: rd_data changed during backpressure at bank %0d",
                        i
                    );
                end
            end
        end

        $display("PASS: Backpressure holds valid data");

        //release output
        @(negedge clk);
        rd_ready_out = 1'b1;

        @(posedge clk);
        @(negedge clk);

        rd_ready_out = 1'b0;

        if (rd_valid_out !== 1'b0)
            $fatal(1, "FAIL: Output valid did not clear after consumption");

        $display("PASS: Output consumed successfully");

        //discard a held response and reload before restarting reads
        read_k(3);
        if (rd_valid_out !== 1'b1)
            $fatal(1, "Activation reset test did not create a held response");
        @(negedge clk);
        rst = 1;
        #1;
        if (rd_valid_out !== 1'b0 || rd_data !== 64'd0)
            $fatal(1, "Reset did not discard the held activation response");
        @(negedge clk);
        rst = 0;
        for (int i = 0; i < 8; i++) begin
            for (int j = 0; j < 16; j++)
                expected[i][j] = (i * 16 + j) - 32;
            write_bank(i);
        end
        for (int k = 0; k < 16; k++) begin
            read_k(k);
            check_output(k);
            rd_ready_out = 1;
            @(posedge clk);
            @(negedge clk);
            rd_ready_out = 0;
        end
        $display("PASS: Reset discards held activation data and fresh writes restart reads");

        $display("--------------------------------");
        $display("ALL ACTIVATION BUFFER TESTS PASSED");
        $display("--------------------------------");
        $finish;
    end

endmodule
