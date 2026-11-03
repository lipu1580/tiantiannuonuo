`timescale 1ns/1ns

module fx_case #(parameter int DEPTH=64, RATE=1000)(output bit done=0);
    logic sys_clk=0, rst_n=0;
    always #5 sys_clk=~sys_clk;
    logic in_valid=0, out_valid;
    logic signed [23:0] in_sample=0, out_sample;
    logic ctrl_valid=0, ctrl_ready;
    logic [1:0] ctrl_mode=0, fx_active_mode;
    logic [7:0] ctrl_wet_gain=0, ctrl_feedback_gain=0;
    logic [11:0] ctrl_delay_samples=1;
    logic ctrl_clear=0, fx_busy, fx_initialized, clear_done;
    audio_fx_chain #(.DELAY_DEPTH(DEPTH), .SAMPLE_RATE(RATE)) dut (.*);
    longint signed history[0:DEPTH-1];
    int n=0, mode=0, wet=0, feedback=0, delay_count=1;
    logic [31:0] phase=0;
    bit verify_audio=0;
    int clear_count=0, samples=0;
    int min_ch=99999, max_ch=0;
    function automatic longint signed clip(input longint signed v);
        if(v>8388607) return 8388607;
        if(v< -8388608) return -8388608;
        return v;
    endfunction
    function automatic int imin(input int a,b); return a<b?a:b; endfunction
    function automatic int imax(input int a,b); return a>b?a:b; endfunction
    function automatic longint signed past(input int d);
        return history[(n+DEPTH-d)%DEPTH];
    endfunction
    task automatic check(input bit ok, input string msg);
        if(!ok) $fatal(1,"DEPTH=%0d %s @%0t",DEPTH,msg,$time);
    endtask
    // 数学参考按样本编号索引，valid 间隙不推进时间；统一检查一拍输出。
    always @(posedge sys_clk) begin : monitor
        longint signed w, f, want;
        int d, base, span, tri_value, longest;
        bit valid_before, compare_before;
        valid_before=rst_n && in_valid;
        compare_before=verify_audio || !fx_initialized;
        want=longint'(in_sample);
        if(rst_n && clear_done) clear_count++;
        if(valid_before && verify_audio) begin
            w=0; f=0;
            case(mode)
                1: begin w=past(delay_count); f=(w*feedback)>>>8; end
                2: begin
                    base=imax(1,imin(RATE*15/1000,DEPTH/2)); span=imin(RATE*3/1000,(base-1)/2);
                    tri_value=phase[31] ? 255-int'(phase[30:23]) : int'(phase[30:23]);
                    d=base-span+tri_value*2*span/256;
                    min_ch=imin(min_ch,d); max_ch=imax(max_ch,d);
                    w=past(d);
                end
                3: begin
                    longest=imax(1,imin(RATE*43/1000,DEPTH-1));
                    w=(past(imax(1,longest*29/43))+past(imax(1,longest*37/43))+past(longest))>>>2;
                    f=w>>>1;
                end
                default: begin end
            endcase
            want=clip(longint'(in_sample)+((w*wet)>>>8));
            if(mode!=0) begin
                history[n%DEPTH]=clip(longint'(in_sample)+f);
                n=(n+1)%DEPTH;
                phase=phase+32'(64'd2147483648/RATE);
            end
            samples++;
        end
        #1;
        check(out_valid===valid_before,"valid latency / throughput");
        if(valid_before && compare_before)
            check(longint'(out_sample)==want,$sformatf("mode=%0d got=%0d expected=%0d",mode,out_sample,want));
    end
    task automatic configure(input int m,w,f,d, input bit clear_req=1);
        @(negedge sys_clk);
        verify_audio=0; in_valid=0;
        wait(ctrl_ready);
        @(negedge sys_clk);
        ctrl_mode=2'(m); ctrl_wet_gain=8'(w); ctrl_feedback_gain=8'(f);
        ctrl_delay_samples=12'(d); ctrl_clear=clear_req; ctrl_valid=1;
        @(negedge sys_clk);
        check(fx_busy,"snapshot accepted");
        ctrl_valid=0; ctrl_clear=0;
        repeat(3) @(negedge sys_clk);
        check(fx_busy,"apply waits for sample boundary");
        in_valid=1; in_sample=0;
        @(negedge sys_clk); in_valid=1; in_sample=-70000;
        wait(ctrl_ready);
        @(negedge sys_clk);
        in_valid=0;
        check(fx_initialized && fx_active_mode==2'(m),"mode applied");
        mode=m; wet=imin(w,128); feedback=imin(f,128); delay_count=imax(1,imin(d,DEPTH-1));
        foreach(history[i]) history[i]=0;
        n=0; phase=0; verify_audio=1;
    endtask
    task automatic drive(input int value, input bit valid=1);
        @(negedge sys_clk); in_sample=24'(value); in_valid=valid;
    endtask
    initial begin
        foreach(history[i]) history[i]=0;
        repeat(3) @(negedge sys_clk);
        rst_n=1;
        wait(ctrl_ready);
        @(negedge sys_clk);
        check(fx_initialized && clear_count==0,"RAM init is not clear command");
        verify_audio=1;
        drive(8388607); drive(-8388608); drive(70000); drive(-70000);
        for(int d=1; d<=DEPTH-1; d=(d==1 ? DEPTH-1 : DEPTH)) begin
            configure(1,128,128,d);
            drive(1048576);
            repeat(DEPTH*4) drive(0);
            repeat(DEPTH*3) drive(8388607); // positive saturation
            repeat(DEPTH*3) drive(-8388608); // negative saturation
            for(int i=0;i<200;i++) drive(int'($urandom),i%4!=0);
            if(DEPTH==2) break;
        end
        configure(1,255,255,0); // direct port clamps as well as cfg regs
        drive(-1048576); repeat(30) drive(0);
        configure(2,128,0,1);
        for(int i=0;i<3000;i++) drive((i%17)*10000-80000,i%5!=0);
        if(DEPTH>=32) check(max_ch>min_ch,"chorus delay must move");
        configure(3,128,0,1);
        drive(1048576); repeat(DEPTH*6) drive(0);
        for(int i=0;i<300;i++) drive(int'($urandom));
        configure(3,128,0,1); // clear nonzero reverb tail
        repeat(DEPTH*3) drive(0);
        configure(0,0,0,1,0); // mode switch automatically clears, no command pulse
        drive(-1234567);
        @(negedge sys_clk); in_valid=0;
        repeat(2) @(negedge sys_clk);
        check(clear_count==5+(DEPTH==2 ? 0 : 1),"one completion per explicit clear");
        // Reset cancels pending clear and reinitializes without a completion.
        verify_audio=0; ctrl_valid=1; ctrl_clear=1;
        @(negedge sys_clk); ctrl_valid=0; rst_n=0;
        repeat(2) @(negedge sys_clk); rst_n=1;
        wait(ctrl_ready); @(negedge sys_clk);
        check(fx_active_mode==0 && fx_initialized,"reset restores bypass");
        $display("PASS fx DEPTH=%0d samples=%0d chorus delay=%0d..%0d",DEPTH,samples,min_ch,max_ch);
        done=1;
    end
endmodule
module tb_audio_fx_chain;
    wire [3:0] done;
    fx_case #(.DEPTH(64)) regular_case(done[0]);
    fx_case #(.DEPTH(63)) odd_depth_case(done[1]);
    fx_case #(.DEPTH(2)) minimum_case(done[2]);
    fx_case #(.DEPTH(4096), .RATE(48000)) default_case(done[3]);
    initial begin wait(&done); $display("PASS tb_audio_fx_chain"); $finish; end
    initial begin #2000000; $fatal(1,"timeout"); end
endmodule
