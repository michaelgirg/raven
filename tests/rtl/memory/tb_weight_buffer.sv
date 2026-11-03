
`timescale 1ns/1ps

module tb_weight_buffer;

    logic clk = 0;
    logic rst;

    logic wr_valid;
    logic wr_ready;
    logic [3:0] wr_bank;
    logic [63:0] wr_data;

    logic rd_valid_in;
    logic rd_ready;
    logic [3:0] rd_k;

    logic rd_valid_out;
    logic rd_ready_out;
    logic [63:0] rd_data;

    logic signed [7:0] expected [0:15][0:7];

    //for backpressure testing
    logic [63:0] held_data;

    weightBuffer dut (
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

    always #5 clk = ~clk;


    //1complete weight bank
    task automatic write_bank(input integer bank);
        begin
            @(negedge clk);

            wr_bank = bank;

            for (int j = 0; j < 8; j++) begin
                wr_data[j*8 +: 8] = expected[bank][j];
            end

            wr_valid = 1;

            if (!wr_ready)
                $fatal(1, "Weight write not ready");

            @(posedge clk);
            #1;

            @(negedge clk);
            wr_valid = 0;
        end
    endtask

    //reading and verify one K position
    task automatic read_k(input integer k);
        begin
            @(negedge clk);

            rd_k = k;
            rd_valid_in = 1;
            rd_ready_out = 0;

            if (!rd_ready)
                $fatal(1, "Weight read not ready");

            @(posedge clk);
            #1;

            if (!rd_valid_out)
                $fatal(1, "Weight read response missing for K=%0d", k);

            //verify all eight output channel values
            for (int j = 0; j < 8; j++) begin

                if ($signed(rd_data[j*8 +: 8]) !== expected[k][j]) begin

                    $display(
                        "K=%0d Channel=%0d Expected=%0d Got=%0d",
                        k,
                        j,
                        expected[k][j],
                        $signed(rd_data[j*8 +: 8])
                    );

                    $fatal(1, "Weight data mismatch");
                end

            end

            //consume the response
            @(negedge clk);

            rd_valid_in = 0;
            rd_ready_out = 1;

            @(posedge clk);
            #1;

            if (rd_valid_out)
                $fatal(1, "Weight response did not clear");

            @(negedge clk);
            rd_ready_out = 0;
        end
    endtask

    initial begin

        rst = 1;

        wr_valid = 0;
        wr_bank = 0;
        wr_data = 0;

        rd_valid_in = 0;
        rd_k = 0;
        rd_ready_out = 0;

        held_data = 0;

        //values range from -64 through +63
        for (int i = 0; i < 16; i++) begin
            for (int j = 0; j < 8; j++) begin
                expected[i][j] = -64 + (i * 8) + j;
            end
        end

        //reset
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 0;

        $display("\n--- WEIGHT BUFFER TEST ---");

        //test 1: Write all 16 banks
        for (int i = 0; i < 16; i++) begin
            write_bank(i);
        end

        $display("PASS: All 16 weight banks written");


        //test 2: Read all 16 K positions
        for (int k = 0; k < 16; k++) begin
            read_k(k);
        end

        $display("PASS: All 16 K positions verified");
        $display("PASS: All 128 signed INT8 values verified");


        //test 3: Backpressure
        @(negedge clk);

        rd_k = 3;
        rd_valid_in = 1;
        rd_ready_out = 0;

        @(posedge clk);
        #1;

        if (!rd_valid_out)
            $fatal(1, "Weight response missing during backpressure test");

        held_data = rd_data;

        //holding response for three clock cycles
        repeat (3) begin
            @(posedge clk);
            #1;

            if (!rd_valid_out || rd_data !== held_data)
                $fatal(1, "Weight backpressure failed");
        end

        //consume response
        @(negedge clk);

        rd_valid_in = 0;
        rd_ready_out = 1;

        @(posedge clk);
        #1;

        if (rd_valid_out)
            $fatal(1, "Weight response did not clear after backpressure");

        @(negedge clk);
        rd_ready_out = 0;

        $display("PASS: Backpressure holds output data");
        $display("PASS: Response consumed successfully");

        //test 4: Rewrite a bank
        @(negedge clk);

        for (int j = 0; j < 8; j++) begin
            expected[5][j] = 100 + j;
        end

        write_bank(5);
        read_k(5);

        $display("PASS: Weight bank overwrite verified");

        //discard a held response, reload a bank and check the new values
        @(negedge clk);
        rd_k = 5;
        rd_valid_in = 1;
        rd_ready_out = 0;
        @(posedge clk);
        #1;
        if (rd_valid_out !== 1'b1)
            $fatal(1, "Weight reset test did not create a held response");
        @(negedge clk);
        rd_valid_in = 0;
        rst = 1;
        #1;
        if (rd_valid_out !== 1'b0 || rd_data !== 64'd0)
            $fatal(1, "Reset did not discard the held weight response");
        @(negedge clk);
        rst = 0;
        for (int j = 0; j < 8; j++)
            expected[5][j] = -100 - j;
        write_bank(5);
        read_k(5);
        $display("PASS: Reset discards held weight data and fresh writes restart reads");

        $display("\nALL WEIGHT BUFFER TESTS PASSED");

        $finish;

    end

endmodule
