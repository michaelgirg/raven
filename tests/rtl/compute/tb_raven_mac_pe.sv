`timescale 1ns/1ps
`default_nettype none
module tb_raven_mac_pe;
    logic clk;
    initial begin clk=0; forever #5 clk=~clk; end
    logic rst_n=0, init=0, valid=0, last=0;
    logic signed [31:0] seed=0;
    logic signed [7:0] a=0,b=0;
    wire signed [31:0] sum;
    wire committed, overflow;
    int cases = 0;
    raven_mac_pe dut(.clk_i(clk),.rst_ni(rst_n),.init_i(init),.seed_i(seed),
        .step_valid_i(valid),.step_last_i(last),.a_i(a),.b_i(b),
        .sum_o(sum),.last_committed_o(committed),.overflow_o(overflow));
    task automatic tick;
        @(posedge clk); #1;
    endtask
    task automatic initialize(input logic signed [31:0] value);
        @(negedge clk); init=1; seed=value; valid=0; last=0;
        tick(); @(negedge clk); init=0;
    endtask
    initial begin
        tick(); tick(); @(negedge clk); rst_n=1;
        // Exhaustively check signed multiplication and sign extension.
        for (int x=-128; x<128; x++) begin
            for (int y=-128; y<128; y++) begin
                initialize(0);
                a=8'(x); b=8'(y); valid=1; last=1;
                tick(); @(negedge clk); valid=0; last=0;
                tick();
                assert (sum == x*y && committed && !overflow)
                    else $fatal(1,"PE signed product %0d * %0d = %0d",x,y,sum);
                cases++;
            end
        end
        initialize(-1234);
        for (int k=0;k<97;k++) begin
            a=-8'sd128; b=8'sd127; valid=1; last=(k==96);
            tick(); @(negedge clk); valid=0; last=0;
            // Bubbles must not repeat the prior product.
            tick(); @(negedge clk);
        end
        assert (sum == -1234+97*(-128*127) && !overflow)
            else $fatal(1,"PE bias/bubble accumulation failed");
        initialize(32'sh7fff_ffff); a=1; b=1; valid=1; last=1;
        tick(); @(negedge clk); valid=0; tick();
        assert (overflow) else $fatal(1,"Positive overflow not detected");
        initialize(32'sh8000_0000); a=-1; b=1; valid=1; last=1;
        tick(); @(negedge clk); valid=0; tick();
        assert (overflow) else $fatal(1,"Negative overflow not detected");
        // An intermediate overflow still invalidates the reduction if a later
        // product brings the stored sum back into the signed INT32 range.
        initialize(32'sh7fff_ffff); a=1; b=1; valid=1; last=0;
        tick(); @(negedge clk); a=-1; last=0;
        tick();
        assert (overflow && !committed) else $fatal(1,"Intermediate overflow not recorded");
        // A third product makes the final addition non-overflowing. This catches
        // an implementation that replaces the flag with only the latest carry.
        @(negedge clk); a=-1; last=1; tick();
        @(negedge clk); valid=0; last=0; tick();
        assert (sum==32'sh7fff_fffe && overflow && committed)
            else $fatal(1,"Overflow did not remain sticky after the sum recovered");
        initialize(123); tick();
        assert (sum==123 && !overflow && !committed)
            else $fatal(1,"Initialization did not clear sticky overflow");
        $display("PASS PE sticky overflow and seed restart");
        initialize(0); a=12; b=13; valid=1; last=1;
        tick(); @(negedge clk); rst_n=0; valid=0; tick();
        @(negedge clk); rst_n=1; tick(); tick();
        assert (sum==0 && !committed && !overflow) else $fatal(1,"Reset did not flush PE");
        $display("PASS PE: %0d signed products, bias/bubbles, both overflow directions, in-flight reset",cases);
        $finish;
    end
endmodule
`default_nettype wire
