//buffer purpose: handlesweight matrix dimensions and how the compute core consumes it
`timescale 1ns/1ps

module weightBuffer (
    input  logic         clk,
    input  logic         rst,

    //write interface: 64 bits = 8 signed INT8 weights
    input  logic         wr_valid,
    output logic         wr_ready,
    input  logic [3:0]   wr_bank,
    input  logic [63:0]  wr_data,

    //compute read interface
    input  logic         rd_valid_in,
    output logic         rd_ready,
    input  logic [3:0]   rd_k,

    output logic         rd_valid_out,
    input  logic         rd_ready_out,
    output logic [63:0]  rd_data
);

    //16 rows, each containing 8 signed INT8 weights
    logic signed [7:0] mem [0:15][0:7];

    //handshake logic
    assign rd_ready = !rd_valid_out || rd_ready_out;
    assign wr_ready = !rd_valid_in && !rd_valid_out;

    //synchronous write and read logic
    always_ff @(posedge clk or posedge rst) begin

        if (rst) begin
            rd_valid_out <= 1'b0;
            rd_data <= 64'd0;

        end else begin

            //write one row of eight weights
            if (wr_valid && wr_ready) begin
                for (int j = 0; j < 8; j++) begin
                    mem[wr_bank][j] <= wr_data[j*8 +: 8];
                end
            end

            //read eight weights from selected row
            if (rd_valid_in && rd_ready) begin
                for (int j = 0; j < 8; j++) begin
                    rd_data[j*8 +: 8] <= mem[rd_k][j];
                end

                rd_valid_out <= 1'b1;

            end else if (rd_valid_out && rd_ready_out) begin
                rd_valid_out <= 1'b0;
            end
        end
    end

endmodule