`timescale 1ns/1ps
`default_nettype none
module tb_raven_gemm_core #(
    parameter int ROWS=8,
    parameter int COLS=8
);
    logic clk;
    initial begin clk=0; forever #5 clk=~clk; end
    logic rst_n=0, cmd_valid=0, stalls=0;
    logic [15:0] m=0,n=0,k=0,pitch=0;
    logic [23:0] abase=0,bbase=0,pbase=0;
    wire cmd_ready, busy, compute_done, result_done, error;
    wire [7:0] error_code;
    wire av,ar,asv,asr,bv,br,bsv,bsr,pv,pr,psv,psr;
    wire [23:0] aa,ba,pa;
    wire [127:0] ad,bd,pd;
    wire rv,rl;
    logic rr;
    wire signed [31:0] rd;
    wire [15:0] row,col;
    wire [31:0] index_out,cycles,steps,stall_in,stall_out;
    wire [31:0] a_reads,b_reads,p_reads;
    logic [31:0] expected [64];
    int received, expected_error=0, compute_events, case_id=0;
    int expected_m, expected_n;
    int force_stall;
    bit checking=0;
    bit demo_only;
    logic [31:0] random_q;
    string fixtures, wave_path;

    raven_gemm_core #(.ROWS(ROWS),.COLS(COLS)) dut (
        .clk_i(clk),.rst_ni(rst_n),.cmd_valid_i(cmd_valid),.cmd_ready_o(cmd_ready),
        .cmd_m_i(m),.cmd_n_i(n),.cmd_k_i(k),.cmd_a_pitch_i(pitch),
        .cmd_a_base_i(abase),.cmd_b_base_i(bbase),.cmd_param_base_i(pbase),
        .a_req_valid_o(av),.a_req_ready_i(ar),.a_req_addr_o(aa),
        .a_rsp_valid_i(asv),.a_rsp_ready_o(asr),.a_rsp_data_i(ad),
        .b_req_valid_o(bv),.b_req_ready_i(br),.b_req_addr_o(ba),
        .b_rsp_valid_i(bsv),.b_rsp_ready_o(bsr),.b_rsp_data_i(bd),
        .p_req_valid_o(pv),.p_req_ready_i(pr),.p_req_addr_o(pa),
        .p_rsp_valid_i(psv),.p_rsp_ready_o(psr),.p_rsp_data_i(pd),
        .result_valid_o(rv),.result_ready_i(rr),.result_data_o(rd),
        .result_row_o(row),.result_col_o(col),.result_index_o(index_out),.result_last_o(rl),
        .busy_o(busy),.compute_done_o(compute_done),.result_done_o(result_done),
        .error_o(error),.error_code_o(error_code),.cycles_o(cycles),.issued_steps_o(steps),
        .input_stall_cycles_o(stall_in),.output_stall_cycles_o(stall_out)
    );
    sim_read_memory #(.SEED(32'h1bdc21)) amem(
        .clk_i(clk),.rst_ni(rst_n),.stalls_i(stalls),.req_valid_i(av),.req_ready_o(ar),
        .req_addr_i(aa),.rsp_valid_o(asv),.rsp_ready_i(asr),.rsp_data_o(ad),.reads_o(a_reads));
    sim_read_memory #(.SEED(32'h7c3289)) bmem(
        .clk_i(clk),.rst_ni(rst_n),.stalls_i(stalls),.req_valid_i(bv),.req_ready_o(br),
        .req_addr_i(ba),.rsp_valid_o(bsv),.rsp_ready_i(bsr),.rsp_data_o(bd),.reads_o(b_reads));
    sim_read_memory #(.BYTES(4096),.SEED(32'h9a98f1)) pmem(
        .clk_i(clk),.rst_ni(rst_n),.stalls_i(stalls),.req_valid_i(pv),.req_ready_o(pr),
        .req_addr_i(pa),.rsp_valid_o(psv),.rsp_ready_i(psr),.rsp_data_o(pd),.reads_o(p_reads));

    // Blocking assignments are intentional in this simulation-only scoreboard
    // and falling-edge stimulus driver; synthesizable RTL uses always_ff/NBA.
    /* verilator lint_off BLKSEQ */
    // Observe the public result interface only; no internal DUT force/deposit.
    always @(posedge clk) if (rst_n && checking) begin
        if (busy) assert (!cmd_ready) else $fatal(1,"Command accepted while busy");
        if (compute_done) compute_events++;
        if (rv && rr) begin
            assert (expected_error==0) else $fatal(1,"Invalid tile emitted output");
            assert (received<expected_m*expected_n && index_out==32'(received)
                    && int'(row)==received/expected_n && int'(col)==received%expected_n)
                else $fatal(1,"Result tags/order failed, case %0d element %0d",case_id,received);
            assert (rd==$signed(expected[received]))
                else $fatal(1,"Case %0d element %0d actual %0d expected %0d",case_id,received,rd,$signed(expected[received]));
            assert (rl==(received==expected_m*expected_n-1)) else $fatal(1,"Bad last marker");
            assert (compute_events==1) else $fatal(1,"Result preceded final MAC commitment");
            if (demo_only) begin
                $write("%9d",rd);
                if (int'(col)+1==expected_n) $write("\n");
            end
            received++;
        end
    end
    always @(negedge clk) begin
        random_q={random_q[30:0],random_q[31]^random_q[21]^random_q[1]^random_q[0]};
        if (rv && force_stall>0) begin rr=0; force_stall--; end
        else rr=!stalls || random_q[0];
    end
    /* verilator lint_on BLKSEQ */
    task automatic reset_design;
        checking=0; cmd_valid=0; rst_n=0;
        repeat(3) @(negedge clk);
        rst_n=1; repeat(3) @(negedge clk);
        assert (!busy && cmd_ready && !rv && !result_done && !error)
            else $fatal(1,"Reset did not return idle");
    endtask
    task automatic load_fixture(input int id);
        string case_path;
        // Explicit decimal digits avoid simulator-dependent %02d space padding.
        case_path=$sformatf("%s/case_%0d%0d",fixtures,id/10,id%10);
        $readmemh({case_path,"/a.hex"},amem.mem);
        $readmemh({case_path,"/b.hex"},bmem.mem);
        $readmemh({case_path,"/param.hex"},pmem.mem);
        $readmemh({case_path,"/expected.hex"},expected);
    endtask
    task automatic submit;
        assert (cmd_ready) else $fatal(1,"Submit before idle");
        cmd_valid=1; @(negedge clk); cmd_valid=0;
    endtask
    task automatic wait_done;
        int watchdog;
        watchdog=0;
        while (!result_done && watchdog<100000) begin @(negedge clk); watchdog++; end
        assert (result_done) else $fatal(1,"Timeout in case %0d",case_id);
    endtask

    initial begin : tests
        int fd, got, mi,ni,ki,ap,ab,bb,pb,err,stall_mode;
        int reads_before, completed_cases;
        rr=0; random_q=32'h1a25b389; force_stall=0; received=0; compute_events=0;
        demo_only=$test$plusargs("DEMO_ONLY");
        if (!$value$plusargs("FIXTURES=%s",fixtures)) $fatal(1,"Missing FIXTURES directory");
        if ($value$plusargs("WAVE=%s",wave_path)) begin $dumpfile(wave_path); $dumpvars(0,tb_raven_gemm_core); end
        reset_design();
        fd=$fopen({fixtures,"/cases.txt"},"r");
        assert(fd!=0) else $fatal(1,"Cannot open case manifest");
        completed_cases=0;
        while (!$feof(fd)) begin
            got=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d\n",case_id,mi,ni,ki,ap,ab,bb,pb,err,stall_mode);
            // EOF after the final complete record is legal; partial records are not.
            if (got!=10) begin
                assert (got==-1 && $feof(fd)) else $fatal(1,"Malformed/truncated fixture manifest");
                break;
            end
            assert (case_id==completed_cases) else $fatal(1,"Missing, duplicate or reordered fixture ID");
            assert (ap>=0 && ap<=65535 && ab>=0 && ab<=16777215
                    && bb>=0 && bb<=16777215 && pb>=0 && pb<=16777215
                    && (stall_mode==0 || stall_mode==1))
                else $fatal(1,"Malformed fixture metadata");
            load_fixture(case_id);
            m=16'(mi); n=16'(ni); k=16'(ki); pitch=16'(ap);
            abase=24'(ab); bbase=24'(bb); pbase=24'(pb);
            expected_m=mi; expected_n=ni; expected_error=err; stalls=1'(stall_mode); received=0; compute_events=0;
            force_stall=6; checking=1;
            reads_before=int'(a_reads+b_reads+p_reads);
            if (demo_only) $display("INT32 result matrix (each element checked against Python oracle):");
            submit();
            // Mutating the command bus while busy must not change the latched tile.
            cmd_valid=1; m=16'hffff; n=16'hffff; k=16'hffff; pitch=1;
            abase=24'hffffff; bbase=24'hffffff; pbase=24'hffffff;
            wait_done(); cmd_valid=0;
            assert (int'(error_code)==err && error==(err!=0)) else $fatal(1,"Bad error response case %0d",case_id);
            if (err==0) begin
                assert (received==mi*ni && steps==32'(ki)) else $fatal(1,"Missing results/reduction steps");
                assert (compute_events==1 && stall_in>0 && stall_out>=6) else $fatal(1,"Completion/stall accounting failed");
            end else begin
                assert (received==0) else $fatal(1,"Rejected tile emitted results");
                if (err!=8) assert (int'(a_reads+b_reads+p_reads)==reads_before)
                    else $fatal(1,"Rejected fields caused memory accesses");
            end
            $display("PASS GEMM %0dx%0d case %0d M=%0d N=%0d K=%0d error=%0d cycles=%0d in_stall=%0d out_stall=%0d",
                     ROWS,COLS,case_id,mi,ni,ki,err,cycles,stall_in,stall_out);
            checking=0; completed_cases++;
            @(negedge clk);
            assert (!result_done && !error && !busy) else $fatal(1,"Completion was not a pulse");
            if (demo_only) break;
        end
        $fclose(fd);
        assert (completed_cases==(demo_only ? 1 : 42))
            else $fatal(1,"Expected %0d fixtures, completed %0d",demo_only ? 1 : 42,completed_cases);
        // Cancel with a coordinated reset in parameter loading, compute, and blocked output.
        for (int phase=0;phase<(demo_only ? 0 : 3);phase++) begin
            reset_design(); load_fixture(0);
            m=16'(ROWS); n=16'(COLS); k=16; pitch=16; abase=0; bbase=0; pbase=0;
            stalls=1; force_stall=100; expected_error=0; expected_m=ROWS; expected_n=COLS;
            submit();
            begin : wait_phase
                int timeout_cycles;
                timeout_cycles=0;
                while (!(phase==0 ? pv : phase==1 ? steps>0 : rv) && timeout_cycles<10000) begin
                    @(negedge clk); timeout_cycles++;
                end
                assert (timeout_cycles<10000) else $fatal(1,"Reset phase not reached");
            end
            reset_design();
            repeat(15) @(negedge clk);
            assert (!busy && !rv && !result_done) else $fatal(1,"Late response after reset");
            // A fresh command must work after each canceled operation.
            load_fixture(0); received=0; compute_events=0; force_stall=6; checking=1;
            submit(); wait_done();
            assert (!error && received==ROWS*COLS) else $fatal(1,"Restart after reset failed");
            checking=0; @(negedge clk);
        end
        $display("PASS CORE %0dx%0d: %0d fixtures and %0d in-flight reset/restart phases",ROWS,COLS,completed_cases,demo_only ? 0 : 3);
        $finish;
    end
    initial begin #100000000; $fatal(1,"Global simulation timeout"); end
endmodule
`default_nettype wire
