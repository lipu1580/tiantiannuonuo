//=============================================================================
// 文件   : tb_audio_core_expr_audio.sv
// 功能   : audio_core_expr 的「能不能出声」冒烟测试。
//
//   tb_audio_core_expr_cfg 只验证 cfg 总线与会话行为，不检查音频幅度；
//   tb_audio_core 验证的是旧核心。板级顶层切到 audio_core_expr 之后，
//   必须有一个用例回答最朴素的问题：**按下一个音，PCM 上到底有没有声音？**
//
//   覆盖：
//     1. 上电静音（没有 NOTE_ON 时 pcm 输出应接近 0）
//     2. NOTE_ON 后 pcm_valid 起来，峰值落在合理范围（不是 0、也不是溢出）
//     3. cfg 写 0x24=100 能读回 100（cfg 总线全链路贯通）
//     4. NOTE_OFF 后包络释放，最终回到静音
//     5. 三个波形（00/01/10）都能出声（波表真的加载成功）
//=============================================================================
`timescale 1ns/1ps

module tb_audio_core_expr_audio;

    localparam integer SAMPLE_RATE = 48_000;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    // 采样节拍：SYS_CLK_HZ = SAMPLE_RATE*8 -> 每 8 拍一个 audio_ce
    logic audio_ce;

    // 事件接口
    logic        event_valid = 1'b0;
    wire         event_ready;
    logic [1:0]  event_type  = 2'b00;
    logic [6:0]  event_note  = 7'd0;
    logic [7:0]  event_vel   = 8'd0;

    // 表情接口
    logic        expr_valid   = 1'b0;
    logic [7:0]  expression   = 8'd255;
    logic [11:0] pitch_bend   = 12'd2048;
    logic [1:0]  waveform_sel = 2'b00;

    // cfg 总线
    logic        cfg_valid = 1'b0;
    wire         cfg_ready;
    logic        cfg_write = 1'b1;
    logic [7:0]  cfg_addr  = 8'd0;
    logic [31:0] cfg_wdata = 32'd0;
    wire  [31:0] cfg_rdata;

    // PCM
    wire         pcm_valid;
    logic        pcm_ready = 1'b1;
    wire signed [15:0] pcm_left, pcm_right;

    wire [1:0] active_voice_count;
    wire [3:0] voice_active;

    int errors = 0;
    int checks = 0;

    always #5 clk = ~clk;

    sample_tick_gen #(
        .SYS_CLK_HZ  (SAMPLE_RATE * 8),
        .SAMPLE_RATE (SAMPLE_RATE)
    ) u_tick (
        .sys_clk  (clk),
        .rst_n    (rst_n),
        .audio_ce (audio_ce)
    );

    audio_core_expr #(
        .VOICE_COUNT   (4),
        .NOTE_W        (7),
        .SAMPLE_W      (16),
        .SAMPLE_RATE   (SAMPLE_RATE),
        .FX_DELAY_DEPTH(4096)
    ) dut (
        .sys_clk        (clk),
        .rst_n          (rst_n),
        .audio_ce       (audio_ce),
        .event_valid    (event_valid),
        .event_ready    (event_ready),
        .event_type     (event_type),
        .event_note_id  (event_note),
        .event_velocity (event_vel),
        .expr_valid     (expr_valid),
        .expression     (expression),
        .pitch_bend     (pitch_bend),
        .waveform_sel   (waveform_sel),
        .cfg_valid      (cfg_valid),
        .cfg_ready      (cfg_ready),
        .cfg_write      (cfg_write),
        .cfg_addr       (cfg_addr),
        .cfg_wdata      (cfg_wdata),
        .cfg_rdata      (cfg_rdata),
        .pcm_valid      (pcm_valid),
        .pcm_ready      (pcm_ready),
        .pcm_left       (pcm_left),
        .pcm_right      (pcm_right),
        .test_mode      (1'b0),
        .test_pattern   (2'd0),
        .active_voice_count (active_voice_count),
        .voice_active   (voice_active)
    );

    //-------------------------------------------------------------------------
    // 采样统计
    //-------------------------------------------------------------------------
    int peak = 0;
    int peak_l = 0;

    always @(posedge clk) begin
        if (rst_n && pcm_valid && pcm_ready) begin
            if (pcm_left  > peak_l) peak_l = pcm_left;
            if (-pcm_left > peak_l) peak_l = -pcm_left;
            if (pcm_left  > peak)   peak   = pcm_left;
        end
    end

    task automatic reset_peak;
        peak   = 0;
        peak_l = 0;
    endtask

    //-------------------------------------------------------------------------
    // 工具
    //-------------------------------------------------------------------------
    task automatic samples(input int n);
        repeat (n * 8) @(posedge clk);
    endtask

    task automatic send_event(input logic [1:0] t, input logic [6:0] note,
                              input logic [7:0] vel);
        @(negedge clk);
        event_valid = 1'b1;
        event_type  = t;
        event_note  = note;
        event_vel   = vel;
        // 等握手
        while (!event_ready) @(posedge clk);
        @(posedge clk);
        @(negedge clk);
        event_valid = 1'b0;
        event_type  = 2'b00;
        event_note  = 7'd0;
        event_vel   = 8'd0;
    endtask

    task automatic cfg_write_word(input logic [7:0] a, input logic [31:0] d);
        @(negedge clk);
        cfg_valid = 1'b1;
        cfg_write = 1'b1;
        cfg_addr  = a;
        cfg_wdata = d;
        while (!cfg_ready) @(posedge clk);
        @(posedge clk);
        @(negedge clk);
        cfg_valid = 1'b0;
    endtask

    task automatic check(input logic ok, input string msg);
        checks++;
        if (!ok) begin
            $display("FAIL [%s]", msg);
            errors++;
        end else begin
            $display("PASS [%s]", msg);
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    initial begin
        $display("========================================");
        $display(" tb_audio_core_expr_audio: 新核心出声冒烟测试");
        $display("========================================");

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        //---------------------------------------------------------------------
        // 1) 上电静音
        //---------------------------------------------------------------------
        expr_valid = 1'b1;
        reset_peak;
        samples(200);
        check(peak_l < 64, "上电无 NOTE_ON 时输出静音");

        //---------------------------------------------------------------------
        // 2) NOTE_ON -> 出声
        //---------------------------------------------------------------------
        reset_peak;
        send_event(2'b01, 7'd69, 8'd200);      // A4, 力度 200
        samples(800);
        $display("  peak=%0d  peak_l=%0d  active_voices=%0d", peak, peak_l,
                 active_voice_count);
        check(peak_l > 1000, "NOTE_ON 后 PCM 峰值 > 1000（确实出声）");
        check(peak_l < 32767, "PCM 未溢出（没有顶到满量程）");

        //---------------------------------------------------------------------
        // 3) cfg 全链路：写 0x24=100 读回 100
        //---------------------------------------------------------------------
        cfg_write_word(8'h24, 32'd100);
        @(negedge clk);
        cfg_valid = 1'b1;
        cfg_write = 1'b0;                      // 读
        cfg_addr  = 8'h24;
        repeat (2) @(posedge clk);
        check(cfg_rdata === 32'd100, "cfg 0x24 写 100 能读回 100");
        @(negedge clk);
        cfg_valid = 1'b0;
        cfg_write = 1'b1;

        // 颤音深度 100 音分不应让音频停摆
        reset_peak;
        samples(800);
        check(peak_l > 1000, "打开颤音深度 100 后仍在出声");

        // 关掉颤音
        cfg_write_word(8'h24, 32'd0);

        //---------------------------------------------------------------------
        // 4) NOTE_OFF -> 释放到静音
        //---------------------------------------------------------------------
        send_event(2'b10, 7'd69, 8'd0);
        samples(4000);
        reset_peak;
        samples(400);
        $display("  release 后 peak_l=%0d", peak_l);
        check(peak_l < 64, "NOTE_OFF 后包络释放完毕，回到静音");
        check(active_voice_count == 0, "释放后 active_voice_count 归零");

        //---------------------------------------------------------------------
        // 5) 三种波形都能出声（波表加载验证）
        //---------------------------------------------------------------------
        for (int w = 0; w < 3; w++) begin
            waveform_sel = 2'(w);
            @(posedge clk);
            reset_peak;
            send_event(2'b01, 7'd69, 8'd200);
            samples(800);
            $display("  waveform=%0d peak_l=%0d", w, peak_l);
            check(peak_l > 500, $sformatf("波形 %0d 能出声", w));
            send_event(2'b10, 7'd69, 8'd0);
            samples(4000);
        end
        waveform_sel = 2'b00;

        $display("========================================");
        if (errors == 0) begin
            $display("TEST PASSED: tb_audio_core_expr_audio (%0d checks)", checks);
        end else begin
            $display("TEST FAILED: tb_audio_core_expr_audio, %0d error(s)", errors);
        end
        $finish;
    end

    initial begin
        #5_000_000;
        $display("TEST TIMEOUT: tb_audio_core_expr_audio");
        $finish;
    end

endmodule
