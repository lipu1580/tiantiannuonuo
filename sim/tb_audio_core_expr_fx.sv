`timescale 1ns/1ns

// 使用真实 core/voice/mixer/FX/PCM；不 force 内部信号。
module tb_audio_core_expr_fx;
    logic sys_clk = 0, rst_n = 0;
    always #5 sys_clk = ~sys_clk;
    logic audio_ce = 0, audio_enable = 0;
    int sample_divider = 0;
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
    audio_core_expr #(.FX_DELAY_DEPTH(64)) dut (.*);
    int clear_submitted = 0, clear_completed = 0, pcm_count = 0, nonzero_count = 0;
    logic [31:0] status;
    logic signed [15:0] expected_pcm[$];
    logic stalled_snapshot = 0, stalled_pcm = 0;
    logic expected_fx_valid = 0;
    logic [31:0] saved_snapshot;
    logic signed [15:0] saved_pcm;

    task automatic check(input logic ok, input string message);
        if (ok !== 1'b1) $fatal(1, "%s @%0t", message, $time);
    endtask

    always @(negedge sys_clk) begin
        if (!rst_n || !audio_enable) begin
            audio_ce = 0;
            sample_divider = 0;
        end else begin
            audio_ce = (sample_divider == 0);
            sample_divider = (sample_divider + 1) % 32;
        end
    end

    // 音频参考队列从 FX 输出采样并独立限幅，验证 PCM 转换、FIFO 不被 clear。
    // 效果算法由 tb_audio_fx_chain 的数学参考模型验证。
    always @(posedge sys_clk) begin : monitor
        logic signed [15:0] want;
        if (!rst_n) begin
            expected_pcm.delete();
            expected_fx_valid = 0;
            stalled_snapshot = 0;
            stalled_pcm = 0;
        end else begin
            if (stalled_snapshot)
                check(dut.snapshot_valid && dut.snapshot === saved_snapshot,
                      "snapshot changed while waiting for FX");
            stalled_snapshot = dut.snapshot_valid && !dut.ctrl_ready;
            saved_snapshot = dut.snapshot;
            if (stalled_pcm)
                check(pcm_valid && pcm_left === saved_pcm && pcm_right === saved_pcm,
                      "PCM changed while stalled");
            stalled_pcm = pcm_valid && !pcm_ready;
            saved_pcm = pcm_left;
            if (pcm_valid && pcm_ready) begin
                check(expected_pcm.size() > 0, "unexpected PCM output");
                want = expected_pcm.pop_front();
                check(pcm_left === want && pcm_right === want, "PCM sample mismatch");
                pcm_count++;
                if (want != 0) nonzero_count++;
            end
            check(dut.fx_valid === expected_fx_valid, "FX valid must have one cycle latency");
            expected_fx_valid = dut.mixed_valid;
            if (dut.fx_valid) begin
                check(expected_pcm.size() < 4, "test must not overflow PCM FIFO");
                if (dut.fx_sample > 32767) want = 32767;
                else if (dut.fx_sample < -32768) want = -32768;
                else want = 16'(dut.fx_sample);
                expected_pcm.push_back(want);
            end
            if (dut.ctrl_hs && dut.snapshot[30]) clear_submitted++;
            if (dut.fx_clear_done) clear_completed++;
        end
    end

    task automatic request(input bit write_req, input logic [7:0] addr,
                           input logic [31:0] data);
        bit accepted;
        accepted = 0;
        @(negedge sys_clk);
        cfg_valid = 1; cfg_write = write_req; cfg_addr = addr; cfg_wdata = data;
        for (int i = 0; i < 100 && !accepted; i++) begin
            @(posedge sys_clk);
            accepted = cfg_ready;
        end
        check(accepted, "configuration request timeout");
        #1;
        @(negedge sys_clk);
        cfg_valid = 0;
    endtask

    task automatic read_status;
        request(0, 8'h44, 0);
        status = cfg_rdata;
        check(status[31:5] == 0, "reserved status bits");
    endtask

    task automatic wait_settled(input logic [1:0] mode_id);
        bit settled;
        settled = 0;
        for (int i = 0; i < 100 && !settled; i++) begin
            read_status();
            settled = !status[0] && status[1] && !status[4] && status[3:2] == mode_id;
        end
        check(settled, "FX did not settle to final target");
    endtask

    initial begin
        repeat (3) @(negedge sys_clk);
        rst_n = 1;
        repeat (65) @(negedge sys_clk);
        read_status();
        check(status == 32'h2 && clear_completed == 0, "initialized reset status");
        // 已提交的 A 等待样本，B 快照阻塞时仍继续接受并合并最新目标 C。
        request(1, 8'h30, 64);
        repeat (5) @(negedge sys_clk);
        check(dut.fx_busy, "accepted control must wait for audio sample");
        request(1, 8'h30, 96);
        request(1, 8'h2C, 2);
        request(1, 8'h34, 99);
        request(1, 8'h38, 64);
        request(1, 8'h30, 128);
        request(1, 8'h2C, 3);
        read_status();
        check(status[0] && status[4], "busy FX must retain later pending targets");
        // 使用非零真实声部验证音频经过完整链路。
        @(negedge sys_clk);
        event_valid = 1; event_type = 1;
        @(posedge sys_clk);
        check(event_ready, "NOTE_ON acceptance");
        @(negedge sys_clk);
        event_valid = 0;
        audio_enable = 1;
        wait_settled(3);
        check(dut.audio_fx_chain.active_wet_gain == 128 &&
              dut.audio_fx_chain.active_feedback_gain == 64 &&
              dut.audio_fx_chain.active_delay_samples == 63,
              "latest accepted target was lost");

        // 第二笔写入恰好与生成第一份快照同拍，dirty 必须保留新更新。
        @(negedge sys_clk);
        cfg_valid = 1; cfg_write = 1; cfg_addr = 8'h30; cfg_wdata = 33;
        @(negedge sys_clk);
        cfg_wdata = 77;
        @(negedge sys_clk);
        cfg_valid = 0;
        wait_settled(3);
        check(dut.audio_fx_chain.active_wet_gain == 77,
              "write concurrent with snapshot creation was lost");

        // 单独 clear 也必须提交；没有新样本时保持未完成，状态读取不被阻塞。
        audio_enable = 0;
        repeat (40) @(negedge sys_clk);
        request(1, 8'h3C, 1);
        repeat (6) @(negedge sys_clk);
        request(0, 8'h3C, 0);
        check(cfg_rdata == 1 && clear_submitted == 1 && clear_completed == 0,
              "standalone clear must be submitted exactly once and await sample");
        read_status();
        check(status[0] && !status[4], "executing clear is busy, not pending");
        // clear 未完成时普通写入正常接收，但新快照不得重复携带同一 clear。
        request(1, 8'h30, 80);
        request(1, 8'h30, 90);
        request(1, 8'h3C, 32'hfffffffe);
        read_status();
        check(status[4], "ordinary update during clear must remain pending");

        // 第二条 clear 保持阻塞请求，第一条完成后必须自动获得握手。
        @(negedge sys_clk);
        cfg_valid = 1; cfg_write = 1; cfg_addr = 8'h3C; cfg_wdata = 1;
        repeat (5) begin
            @(posedge sys_clk);
            check(!cfg_ready, "second clear must be backpressured");
        end
        #1; audio_enable = 1;
        begin : accept_second_clear
            bit accepted;
            accepted = 0;
            for (int i = 0; i < 150 && !accepted; i++) begin
                @(posedge sys_clk);
                accepted = cfg_ready;
            end
            check(accepted, "blocked clear did not resume after completion");
        end
        @(negedge sys_clk);
        cfg_valid = 0;
        wait_settled(3);
        request(0, 8'h3C, 0);
        check(cfg_rdata == 0 && clear_submitted == 2 && clear_completed == 2,
              "each accepted clear must complete once");
        check(dut.audio_fx_chain.active_wet_gain == 90 &&
              dut.audio_fx_chain.active_feedback_gain == 64 &&
              dut.audio_fx_chain.active_delay_samples == 63,
              "clear must preserve final parameter targets");
        repeat (100) @(negedge sys_clk);
        check(clear_submitted == 2 && clear_completed == 2, "clear must not repeat");

        // PCM 被阻塞时清理仍不清空队列，队首保持。
        pcm_ready = 0;
        repeat (35) @(negedge sys_clk);
        check(pcm_valid, "exercise actual PCM backpressure");
        request(1, 8'h3C, 1);
        wait_settled(3);
        check(pcm_valid, "clear must not flush PCM FIFO");
        pcm_ready = 1;
        request(1, 8'h44, 32'hffffffff);
        wait_settled(3);
        check(clear_submitted == 3 && clear_completed == 3, "third clear count");
        request(1, 8'h2C, 0);
        wait_settled(0);
        audio_enable = 0;
        repeat (40) @(negedge sys_clk);
        check(expected_pcm.size() == 0 && nonzero_count > 0, "audio drain and nonzero coverage");

        // 复位撤销尚未应用的命令，不留下 clear 或 pending。
        request(1, 8'h3C, 1);
        repeat (5) @(negedge sys_clk);
        rst_n = 0;
        repeat (3) @(negedge sys_clk);
        rst_n = 1;
        repeat (65) @(negedge sys_clk);
        read_status();
        check(status == 32'h2, "reset must cancel pending command and targets");
        request(0, 8'h3C, 0);
        check(cfg_rdata == 0 && clear_completed == 3, "reset is not a clear completion");
        $display("PASS tb_audio_core_expr_fx: snapshots, latest target, clear once/backpressure, reset; PCM=%0d nonzero=%0d",
                 pcm_count, nonzero_count);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "tb_audio_core_expr_fx timeout");
    end
endmodule
