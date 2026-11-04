`timescale 1ns/1ps

// Checks the real Taylor outputBuffer RTL with fixture data supplied by Python.
module tb_output_buffer_golden;
    logic clk = 0;
    always #5 clk = ~clk;

    logic rst = 1;
    logic wr_valid = 0;
    logic wr_ready;
    logic [2:0] wr_row = '0;
    logic [63:0] wr_data = '0;
    logic rd_valid_in = 0;
    logic rd_ready;
    logic [2:0] rd_row = '0;
    logic rd_valid_out;
    logic rd_ready_out = 0;
    logic [63:0] rd_data;

    outputBuffer dut (
        .clk(clk), .rst(rst),
        .wr_valid(wr_valid), .wr_ready(wr_ready),
        .wr_row(wr_row), .wr_data(wr_data),
        .rd_valid_in(rd_valid_in), .rd_ready(rd_ready),
        .rd_row(rd_row), .rd_valid_out(rd_valid_out),
        .rd_ready_out(rd_ready_out), .rd_data(rd_data)
    );

    logic [7:0] expected_bytes [0:63];
    string output_file, case_name;
    integer valid_count = 64;
    integer compared = 0;

    task automatic check_row(input integer row);
        for (int col = 0; col < 8; col++) begin
            if (rd_data[col*8 +: 8] !== expected_bytes[row*8 + col])
                $fatal(1, "OUTPUT MISMATCH row=%0d col=%0d expected=%0d actual=%0d",
                       row, col, $signed(expected_bytes[row*8+col]),
                       $signed(rd_data[col*8 +: 8]));
        end
    endtask

    task automatic write_row(input integer row);
        @(negedge clk);
        wr_row = row[2:0];
        for (int col = 0; col < 8; col++)
            wr_data[col*8 +: 8] = expected_bytes[row*8 + col];
        wr_valid = 1'b1;
        #1;
        if (wr_ready !== 1'b1)
            $fatal(1, "Write not ready for row=%0d", row);
        @(posedge clk);
        #1;
        @(negedge clk);
        wr_valid = 1'b0;
    endtask

    task automatic read_row(input integer row);
        @(negedge clk);
        rd_row = row[2:0];
        rd_valid_in = 1'b1;
        rd_ready_out = 1'b0;
        #1;
        if (rd_ready !== 1'b1)
            $fatal(1, "Read request not ready for row=%0d", row);
        @(posedge clk);
        #1;
        if (rd_valid_out !== 1'b1)
            $fatal(1, "No output response row=%0d", row);
        check_row(row);

        // Hold the response stalled and require stable values and valid.
        @(negedge clk);
        rd_valid_in = 1'b0;
        repeat (3) begin
            @(posedge clk);
            #1;
            if (rd_valid_out !== 1'b1)
                $fatal(1, "Output valid dropped during stall row=%0d", row);
            check_row(row);
        end

        @(negedge clk);
        rd_ready_out = 1'b1;
        @(posedge clk);
        #1;
        if (rd_valid_out !== 1'b0)
            $fatal(1, "Output valid did not clear after accept row=%0d", row);
        @(negedge clk);
        rd_ready_out = 1'b0;
        compared += 8;
    endtask

    initial begin
        if (!$value$plusargs("OUTPUT_HEX=%s", output_file))
            $fatal(1, "Missing +OUTPUT_HEX=<file>");
        if (!$value$plusargs("CASE=%s", case_name))
            case_name = "unknown";
        if (!$value$plusargs("VALID_COUNT=%d", valid_count))
            valid_count = 64;
        $readmemh(output_file, expected_bytes);
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // Uninitialized row cannot be read after reset.
        @(negedge clk);
        rd_row = 3'd0;
        rd_valid_in = 1'b1;
        #1;
        if (rd_ready !== 1'b0 || rd_valid_out !== 1'b0)
            $fatal(1, "Unwritten output row should not be readable");
        @(negedge clk);
        rd_valid_in = 1'b0;

        for (int row = 0; row < 8; row++)
            write_row(row);
        for (int row = 0; row < 8; row++)
            read_row(row);

        if (compared != 64)
            $fatal(1, "Unexpected compared byte count %0d", compared);
        $display("PASS OUTPUT GOLDEN: 64/64 INT8 positions matched (%s); %0d/%0d valid values; output stalls verified",
                 case_name, valid_count, valid_count);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "Timeout in output-buffer golden test");
    end
endmodule
