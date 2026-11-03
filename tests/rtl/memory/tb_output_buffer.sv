//test bench for output buffer

`timescale 1ns/1ps

module tb_output_buffer;

    logic clk = 0;
    logic rst;

    logic wr_valid;
    logic wr_ready;
    logic [2:0] wr_row;
    logic [63:0] wr_data;

    logic rd_valid_in;
    logic rd_ready;
    logic [2:0] rd_row;

    logic rd_valid_out;
    logic rd_ready_out;
    logic [63:0] rd_data;

    logic signed [7:0] expected [0:7][0:7];

    outputBuffer dut (
        .clk(clk),
        .rst(rst),

        .wr_valid(wr_valid),
        .wr_ready(wr_ready),
        .wr_row(wr_row),
        .wr_data(wr_data),

        .rd_valid_in(rd_valid_in),
        .rd_ready(rd_ready),
        .rd_row(rd_row),

        .rd_valid_out(rd_valid_out),
        .rd_ready_out(rd_ready_out),
        .rd_data(rd_data)
    );

    always #5 clk = ~clk;

    task automatic write_row(input integer row);
        begin
            @(negedge clk);

            wr_row = row;

            for (int j = 0; j < 8; j++)
                wr_data[j*8 +: 8] = expected[row][j];

            wr_valid = 1;

            @(posedge clk);
            #1;

            if (!wr_ready)
                $fatal(1, "Output write not ready");

            @(negedge clk);
            wr_valid = 0;
        end
    endtask

    task automatic read_row(input integer row);
        begin
            @(negedge clk);

            rd_row = row;
            rd_valid_in = 1;
            rd_ready_out = 0;

            @(posedge clk);
            #1;

            if (!rd_valid_out)
                $fatal(1, "Output read response missing");

            for (int j = 0; j < 8; j++) begin
                if ($signed(rd_data[j*8 +: 8]) !== expected[row][j]) begin
                    $display("Row=%0d Column=%0d Expected=%0d Got=%0d",
                        row, j, expected[row][j],
                        $signed(rd_data[j*8 +: 8]));

                    $fatal(1, "Output data mismatch");
                end
            end

            @(negedge clk);
            //stop requesting reads and consume the response
            rd_valid_in = 0;
            rd_ready_out = 1;

            @(posedge clk);
            #1;

            if (rd_valid_out)
                $fatal(1, "Output response did not clear");
            @(negedge clk);
            rd_ready_out = 0;
        end
    endtask

    task automatic read_after_write(input integer row);
        begin
            @(negedge clk);
            rd_row = row;
            rd_valid_in = 1;
            rd_ready_out = 0;

            //a pending read must wait for this row to be written
            repeat (3) begin
                @(posedge clk);
                #1;
                if (rd_ready !== 1'b0 || rd_valid_out !== 1'b0)
                    $fatal(1, "Unwritten output row was readable");
            end

            @(negedge clk);
            wr_row = row;
            for (int j = 0; j < 8; j++)
                wr_data[j*8 +: 8] = expected[row][j];
            wr_valid = 1;

            @(posedge clk);
            if (wr_ready !== 1'b1)
                $fatal(1, "Pending unwritten read blocked its write");
            #1;
            if (rd_valid_out !== 1'b0)
                $fatal(1, "Unwritten read was accepted before the write");

            @(negedge clk);
            wr_valid = 0;
            @(posedge clk);
            if (rd_ready !== 1'b1)
                $fatal(1, "Written output row did not become readable");
            #1;
            if (rd_valid_out !== 1'b1)
                $fatal(1, "Pending output read did not complete");
            for (int j = 0; j < 8; j++) begin
                if ($signed(rd_data[j*8 +: 8]) !== expected[row][j])
                    $fatal(1, "Pending read returned stale output data");
            end

            @(negedge clk);
            rd_valid_in = 0;
            rd_ready_out = 1;
            @(posedge clk);
            #1;
            if (rd_valid_out !== 1'b0)
                $fatal(1, "Pending output response did not clear");
            @(negedge clk);
            rd_ready_out = 0;
        end
    endtask

    initial begin
        rst = 1;

        wr_valid = 0;
        wr_row = 0;
        wr_data = 0;

        rd_valid_in = 0;
        rd_row = 0;
        rd_ready_out = 0;

        //generate signed INT8 test values
        for (int i = 0; i < 8; i++) begin
            for (int j = 0; j < 8; j++) begin
                expected[i][j] = -32 + (i * 8) + j;
            end
        end

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 0;

        $display("\n--- OUTPUT BUFFER TEST ---");

        read_after_write(7);
        $display("PASS: Unwritten row waits for initialization");

        //write all eight rows
        for (int i = 0; i < 8; i++)
            write_row(i);

        $display("PASS: All eight output rows written");

        //read and verify all eight rows
        for (int i = 0; i < 8; i++)
            read_row(i);

        $display("PASS: All 64 output bytes verified");
        $display("PASS: Signed INT8 values verified");

        //overwrite row 3 with new values
        for (int j = 0; j < 8; j++)
            expected[3][j] = 100 + j;

        write_row(3);
        read_row(3);

        $display("PASS: Row overwrite verified");

        //backpressure test
        @(negedge clk);
        rd_row = 3;
        rd_valid_in = 1;
        rd_ready_out = 0;

        @(posedge clk);
        #1;

        if (!rd_valid_out)
            $fatal(1, "Output response missing");

        begin
            logic [63:0] held_data;
            held_data = rd_data;

            repeat (3) begin
                @(posedge clk);
                #1;

                if (!rd_valid_out || rd_data !== held_data)
                    $fatal(1, "Output backpressure failed");
            end
        end

        @(negedge clk);
        rd_valid_in = 0;
        rd_ready_out = 1;

        @(posedge clk);
        #1;

        if (rd_valid_out)
            $fatal(1, "Output response did not clear");

        $display("PASS: Output backpressure verified");

        //reset while an output is held, then require every row to be rewritten
        @(negedge clk);
        rd_ready_out = 0;
        rd_row = 3;
        rd_valid_in = 1;
        @(posedge clk);
        #1;
        if (rd_valid_out !== 1'b1)
            $fatal(1, "Output reset test did not create a held response");
        @(negedge clk);
        rd_valid_in = 0;
        rst = 1;
        #1;
        if (rd_valid_out !== 1'b0)
            $fatal(1, "Reset did not discard the held output");
        @(negedge clk);
        rst = 0;

        for (int i = 0; i < 8; i++) begin
            for (int j = 0; j < 8; j++)
                expected[i][j] = -100 + i*8 + j;
            read_after_write(i);
        end
        $display("PASS: Reset invalidates every row and new writes restart reads");

        //a simultaneous read and overwrite of a valid row returns the old row
        begin
            logic [63:0] old_row;
            for (int j = 0; j < 8; j++)
                old_row[j*8 +: 8] = expected[2][j];
            @(negedge clk);
            wr_row = 2;
            rd_row = 2;
            wr_valid = 1;
            rd_valid_in = 1;
            for (int j = 0; j < 8; j++) begin
                expected[2][j] = 50 + j;
                wr_data[j*8 +: 8] = expected[2][j];
            end
            @(posedge clk);
            if (wr_ready !== 1'b1 || rd_ready !== 1'b1)
                $fatal(1, "Output read/write collision was not accepted");
            #1;
            if (rd_valid_out !== 1'b1 || rd_data !== old_row)
                $fatal(1, "Output read/write collision did not return the old row");
            @(negedge clk);
            wr_valid = 0;
            rd_valid_in = 0;
            rd_ready_out = 1;
            @(posedge clk);
            #1;
            if (rd_valid_out !== 1'b0)
                $fatal(1, "Collision response did not clear");
            @(negedge clk);
            rd_ready_out = 0;
            read_row(2);
        end
        $display("PASS: Same-row read/write returns old data and stores new data");

        $display("\nALL OUTPUT BUFFER TESTS PASSED");
        $finish;
    end

endmodule
