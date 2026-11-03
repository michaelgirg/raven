//buffer prupose: Collects and stores the results produced by the compute core


`timescale 1ns/1ps

module outputBuffer (
    input  logic        clk,
    input  logic        rst,

    //write interface
    input  logic        wr_valid,
    output logic        wr_ready,
    input  logic [2:0]  wr_row,
    input  logic [63:0] wr_data,

    //read request interface
    input  logic        rd_valid_in,
    output logic        rd_ready,
    input  logic [2:0]  rd_row,

    //read response interface
    output logic        rd_valid_out,
    input  logic        rd_ready_out,
    output logic [63:0] rd_data
);

    //64 byte addressable storage locations
    logic signed [7:0] mem [0:63];

    //track which output rows have been written
    logic [7:0] row_valid;

    //unwritten rows wait until a write initializes them after reset
    assign rd_ready = row_valid[rd_row] && (!rd_valid_out || rd_ready_out);

    //allow writes unless a read response is pending
    assign wr_ready = !rd_valid_out;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            rd_valid_out <= 1'b0;
            rd_data      <= 64'd0;

            //clear row validity, not the storage array
            row_valid <= 8'b0;

        end else begin
            //write op
            if (wr_valid && wr_ready) begin
                for (int i = 0; i < 8; i++) begin
                    mem[(wr_row * 8) + i] <=
                        $signed(wr_data[i*8 +: 8]);
                end

                row_valid[wr_row] <= 1'b1;
            end
            //read op
            if (rd_valid_in && rd_ready) begin

                //read one complete output row
                for (int i = 0; i < 8; i++) begin
                    rd_data[i*8 +: 8] <=
                        mem[(rd_row * 8) + i];
                end

                rd_valid_out <= 1'b1;

            end else if (rd_valid_out && rd_ready_out) begin
                rd_valid_out <= 1'b0;
            end

        end
    end

endmodule
