`timescale 1ns/1ns

// 普通配置总线集成测试；0x3C 命令和 0x44 状态由后续效果控制 TB 验证。
// 公共端口驱动，不 force DUT；参考模型按协议检查握手前/后的组合读回。
module core_cfg_test_case #(
    parameter int DEPTH = 4096
)(output bit done = 0);
    logic sys_clk = 0, rst_n = 0;
    always #5 sys_clk = ~sys_clk;
    logic audio_ce = 0;
    logic event_valid = 0, event_ready;
    logic [1:0] event_type = 0;
    logic [6:0] event_note_id = 69;
    logic [7:0] event_velocity = 200;
    logic expr_valid = 0;
    logic [7:0] expression = 255;
    logic [11:0] pitch_bend = 2048;
    logic [1:0] waveform_sel = 0;
    logic cfg_valid = 0, cfg_ready, cfg_write = 0;
    logic [7:0] cfg_addr = 0;
    logic [31:0] cfg_wdata = 0, cfg_rdata;
    logic pcm_valid, pcm_ready = 1;
    logic signed [15:0] pcm_left, pcm_right;
    logic test_mode = 0;
    logic [1:0] test_pattern = 0;
    logic [2:0] active_voice_count;
    logic [3:0] voice_active;
    audio_core_expr #(.FX_DELAY_DEPTH(DEPTH)) dut (.*);

    logic [31:0] expected [0:5];
    int checks = 0;
    int writes = 0;
    string phase = "reset";

    task automatic check(input logic ok, input string message);
        checks++;
        if (ok !== 1'b1)
            $fatal(1, "DEPTH=%0d [%s] @%0t %s", DEPTH, phase, $time, message);
    endtask

    function automatic int index_of(input logic [7:0] addr);
        if (addr >= 8'h24 && addr <= 8'h38 && addr[1:0] == 0)
            return (int'(addr) - 'h24) / 4;
        return -1;
    endfunction

    function automatic logic [31:0] clamp(input int idx, input logic [31:0] value);
        int unsigned lo, hi;
        lo = 0;
        case (idx)
            0: hi = 100;
            1: begin lo = 256; hi = 2048; end
            2: hi = 3;
            3, 5: hi = 128;
            4: begin lo = 1; hi = DEPTH-1; end
            default: hi = 0;
        endcase
        if (value < lo) return lo;
        if (value > hi) return hi;
        return value;
    endfunction

    task automatic check_read;
        int idx;
        logic [31:0] want;
        idx = index_of(cfg_addr);
        want = idx < 0 ? 32'd0 : expected[idx];
        // 效果控制尚未实现，不把两个未来功能地址的当前占位值作为协议。
        if (cfg_addr != 8'h3C && cfg_addr != 8'h44)
            check(cfg_rdata === want,
                  $sformatf("addr=%02h read=%08h expected=%08h", cfg_addr, cfg_rdata, want));
    endtask

    // 连续调用意味着相邻上升沿都有请求，valid 不会被自动拉低。
    task automatic cycle(input bit valid, input bit write_req,
                         input logic [7:0] addr, input logic [31:0] data);
        int idx;
        @(negedge sys_clk);
        cfg_valid = valid; cfg_write = write_req; cfg_addr = addr; cfg_wdata = data;
        #1;
        check(cfg_ready === rst_n, "ordinary access ready must equal rst_n");
        check_read();
        @(posedge sys_clk);
        check_read(); // 上升沿前的已提交值，包括写握手当拍。
        idx = index_of(addr);
        if (rst_n && valid && cfg_ready && write_req && idx >= 0) begin
            expected[idx] = clamp(idx, data);
            writes++;
        end
        #1;
        check_read(); // NBA 后必须已更新，无额外一拍延迟。
    endtask

    task automatic read_all;
        for (int i = 0; i < 6; i++)
            cycle(1, 0, 8'('h24 + i*4), 32'hFFFFFFFF);
    endtask

    task automatic reset_core;
        @(negedge sys_clk);
        rst_n = 0;
        cfg_valid = 1; cfg_write = 1; cfg_addr = 8'h24; cfg_wdata = 77;
        event_valid = 0; expr_valid = 0; audio_ce = 0;
        repeat (3) begin
            @(posedge sys_clk);
            check(cfg_ready === 1'b0, "reset must suppress cfg_ready");
            #1;
        end
        expected[0] = 0; expected[1] = 1280; expected[2] = 0;
        expected[3] = 0; expected[4] = DEPTH-1 < 1920 ? DEPTH-1 : 1920;
        expected[5] = 0;
        check_read();
        @(negedge sys_clk);
        cfg_valid = 0; rst_n = 1;
        read_all();
    endtask

    initial begin : tests
        logic [31:0] values [0:14];
        values = '{0, 1, 3, 4, 100, 101, 128, 129, 255, 256,
                   2048, 2049, 32'h00010000, 32'h80000000, 32'hFFFFFFFF};
        reset_core();
        phase = "all registers / full unsigned clamp / isolation";
        for (int i = 0; i < 6; i++) begin
            foreach (values[j]) begin
                cycle(1, 1, 8'('h24 + i*4), values[j]);
                read_all();
            end
        end
        cycle(1, 1, 8'h34, 32'(DEPTH-1)); read_all();
        cycle(1, 1, 8'h34, 32'(DEPTH)); read_all();

        phase = "back-to-back writes / same-address overwrite";
        for (int i = 0; i < 6; i++)
            cycle(1, 1, 8'('h24 + i*4), 32'(i+20));
        for (int i = 0; i < 20; i++)
            cycle(1, 1, 8'h24, 32'(i));
        read_all();
        // 保留 Q8.8 的小数部分和 Q0.8 原始编码。
        cycle(1, 1, 8'h28, 32'h0580);
        cycle(1, 1, 8'h30, 65);
        cycle(1, 1, 8'h38, 33);
        read_all();

        phase = "valid=0 / read must not write / combinational read";
        for (int i = 0; i < 6; i++) begin
            cycle(0, 1, 8'('h24 + i*4), 32'hFFFFFFFF);
            cycle(1, 0, 8'('h24 + i*4), 32'hFFFFFFFF);
            read_all();
        end
        // 一个时钟周期内改变多个地址：读回不能依赖 valid 或时钟沿。
        @(negedge sys_clk);
        cfg_valid = 0; cfg_write = 0;
        cfg_addr = 8'h28; #1; check_read();
        cfg_addr = 8'h30; #1; check_read();
        cfg_addr = 8'h38; #1; check_read();

        phase = "reserved / unallocated / unaligned address isolation";
        for (int addr = 0; addr < 256; addr++) begin
            if (index_of(8'(addr)) < 0 && addr != 'h3C && addr != 'h44) begin
                cycle(1, 1, 8'(addr), 32'hFFFFFFFF);
                cycle(1, 0, 8'(addr), 0);
                read_all();
                check(dut.expression_reg == 255 && dut.pitch_bend_reg == 2048 &&
                      dut.waveform_sel_reg == 0, "ignored writes changed expression fields");
            end
        end

        phase = "simultaneous config / event / expression";
        @(negedge sys_clk);
        cfg_valid = 0;
        expr_valid = 1; expression = 123; pitch_bend = 2500; waveform_sel = 2;
        event_valid = 1; event_type = 1;
        cfg_valid = 1; cfg_write = 1; cfg_addr = 8'h24; cfg_wdata = 50;
        #1;
        check(cfg_ready && event_ready, "independent interfaces must accept concurrently");
        @(posedge sys_clk);
        expected[0] = 50;
        #1;
        check_read();
        check(dut.expression_reg == 123 && dut.pitch_bend_reg == 2500 &&
              dut.waveform_sel_reg == 2, "concurrent expression lost");
        @(negedge sys_clk);
        cfg_valid = 0; event_valid = 0; expr_valid = 0;
        repeat (8) @(negedge sys_clk);
        // ADSR 在采样边界应用已保存的 NOTE_ON。
        audio_ce = 1;
        @(negedge sys_clk); audio_ce = 0;
        check(active_voice_count == 1, "concurrent NOTE_ON lost");
        read_all();

        phase = "PCM stalled / audio_ce independent";
        pcm_ready = 0;
        // 产生真实的 PCM valid，再在输出阻塞期间访问配置。
        repeat (2) begin
            @(negedge sys_clk); audio_ce = 1;
            @(negedge sys_clk); audio_ce = 0;
            repeat (10) @(negedge sys_clk);
        end
        check(pcm_valid && !pcm_ready, "PCM stall was not exercised");
        for (int i = 0; i < 6; i++)
            cycle(1, 1, 8'('h24 + i*4), 32'(i+60));
        read_all();
        check(pcm_valid, "config access unexpectedly cleared PCM FIFO");

        phase = "reset after writes with pending request";
        reset_core();
        $display("PASS core ordinary cfg DEPTH=%0d checks=%0d writes=%0d", DEPTH, checks, writes);
        done = 1;
    end
endmodule

module tb_audio_core_expr_cfg;
    wire [1:0] done;
    core_cfg_test_case #(.DEPTH(4096)) normal_depth (.done(done[0]));
    core_cfg_test_case #(.DEPTH(1024)) small_depth (.done(done[1]));
    initial begin
        wait (&done);
        $display("PASS tb_audio_core_expr_cfg (ordinary parameters only; fx_clear/status deferred)");
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "tb_audio_core_expr_cfg timeout");
    end
endmodule
