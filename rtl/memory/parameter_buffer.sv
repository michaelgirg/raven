//buffer purpose: Supplies configuration values and constants that the compute core needs while performing GEMM
`timescale 1ns/1ps

module parameterBuffer (
    input  logic        clk,
    input  logic        rst,

    //write interface
    input  logic        wr_valid,
    output logic        wr_ready,
    input  logic [5:0]  wr_addr,
    input  logic [31:0] wr_data,

    //read request interface
    input  logic        rd_valid_in,
    output logic        rd_ready,
    input  logic [2:0]  rd_channel,

    //read response interface
    output logic        rd_valid_out,
    input  logic        rd_ready_out,

    output logic signed [31:0] rd_bias,
    output logic signed [31:0] rd_multiplier,
    output logic signed [7:0]  rd_shift,
    output logic signed [7:0]  rd_zero_point,
    output logic signed [7:0]  rd_clamp_min,
    output logic signed [7:0]  rd_clamp_max
);

    //each channel parameter storage
    logic signed [31:0] bias [0:7];
    logic signed [31:0] multiplier [0:7];
    logic signed [7:0]  shift [0:7];

    //shared params
    logic signed [7:0] zero_point;
    logic signed [7:0] clamp_min;
    logic signed [7:0] clamp_max;

    //config:
    //0 = shared (entry 0)
    //1 = per channel
    logic multiplier_per_channel;
    logic shift_per_channel;

    //handshake signals
    assign wr_ready = 1'b1;
    assign rd_ready = !rd_valid_out || rd_ready_out;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            //clear parameter registers
            for (int i = 0; i < 8; i++) begin
                bias[i]       <= '0;
                multiplier[i] <= '0;
                shift[i]      <= '0;
            end

            zero_point <= '0;
            clamp_min  <= '0;
            clamp_max  <= '0;

            multiplier_per_channel <= 1'b0;
            shift_per_channel      <= 1'b0;

            rd_valid_out <= 1'b0;

            rd_bias       <= '0;
            rd_multiplier <= '0;
            rd_shift      <= '0;
            rd_zero_point <= '0;
            rd_clamp_min  <= '0;
            rd_clamp_max  <= '0;

        end else begin
            //param write ops
            if (wr_valid && wr_ready) begin
                case (wr_addr)

                    //corrected bias: addresses 0-7
                    6'd0, 6'd1, 6'd2, 6'd3,
                    6'd4, 6'd5, 6'd6, 6'd7:
                        bias[wr_addr[2:0]] <= $signed(wr_data);

                    //Q31 multiplier: addresses 8-15
                    6'd8, 6'd9, 6'd10, 6'd11,
                    6'd12, 6'd13, 6'd14, 6'd15:
                        multiplier[wr_addr[2:0]] <= $signed(wr_data);

                    //quantization shift: addresses 16-23
                    6'd16, 6'd17, 6'd18, 6'd19,
                    6'd20, 6'd21, 6'd22, 6'd23:
                        shift[wr_addr[2:0]] <= $signed(wr_data[7:0]);

                    //shared output parameters
                    6'd24: zero_point <= $signed(wr_data[7:0]);
                    6'd25: clamp_min  <= $signed(wr_data[7:0]);
                    6'd26: clamp_max  <= $signed(wr_data[7:0]);

                    //configuration registers
                    6'd27: multiplier_per_channel <= wr_data[0];
                    6'd28: shift_per_channel      <= wr_data[0];

                    default: ; //ignore invalid addresses

                endcase
            end

            //param read op
            if (rd_valid_in && rd_ready) begin
                rd_bias <= bias[rd_channel];

                //select shared or per channel multiplier
                if (multiplier_per_channel)
                    rd_multiplier <= multiplier[rd_channel];
                else
                    rd_multiplier <= multiplier[0];

                //select shared or per channel shift
                if (shift_per_channel)
                    rd_shift <= shift[rd_channel];
                else
                    rd_shift <= shift[0];

                //shared output params
                rd_zero_point <= zero_point;
                rd_clamp_min  <= clamp_min;
                rd_clamp_max  <= clamp_max;

                rd_valid_out <= 1'b1;

            end else if (rd_valid_out && rd_ready_out) begin
                rd_valid_out <= 1'b0;
            end

        end
    end

endmodule