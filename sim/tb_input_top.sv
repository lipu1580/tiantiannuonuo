//=============================================================================
// 文件   : tb_input_top.sv
// 归属   : 成员 2
// 功能   : 输入顶层系统级仿真（第 2 轮）。
//
//   与第 1 轮的区别：键盘不再发声，只选根音/波形/效果；
//   音符全部由 FSR 触发产生；新增 cfg 总线的端到端验证。
//
//   覆盖：
//     1. test_mode 固定事件源仍可用（含切换时合成的 ALL_NOTES_OFF）
//     2. ADC(ADS7830) -> FSR 表情 / 电位器滑音
//     3. A8/A9：按满 16 个键 3 轮 -> 0 个 ALL_NOTES_OFF、0 个音符事件
//     4. 根音键改变 base_note，FSR 触发音跟着变
//     5. 波形键直选（0/1/2）
//     6. 效果键 -> cfg 序列（旁路 2 笔 / 延迟 5 笔 / 混响 3 笔）
//     7. K15 短按 -> 合唱 3 笔；长按 -> 0x24 颤音
//     8. cfg 背压：cfg_ready=0 时 valid/addr/wdata 保持
//     9. 矩阵组合告警不回归
//=============================================================================
`timescale 1ns/1ps

module tb_input_top;

    // 短按/长按门槛：仿真里用 200 拍（真实 27 MHz 下是 600 ms）
    localparam int TAP_HOLD_CYC = 200;

    logic       clk = 1'b0;
    logic       rst_n = 1'b0;

    logic [3:0] key_row;
    logic [3:0] key_col;

    logic       adc_scl;
    logic       adc_sda_oe;
    logic       adc_sda_i;
    wire        sda;

    logic       event_valid;
    logic       event_ready = 1'b1;
    logic [1:0] event_type;
    logic [6:0] event_note_id;
    logic [7:0] event_velocity;

    logic        expr_valid;
    logic [7:0]  expression;
    logic [11:0] pitch_bend;
    logic [1:0]  waveform_sel;

    logic        cfg_valid;
    logic        cfg_write;
    logic [7:0]  cfg_addr;
    logic [31:0] cfg_wdata;
    logic        cfg_ready = 1'b1;

    logic       test_mode = 1'b0;
    logic [1:0] test_pattern = 2'd0;

    logic [15:0] key_down;
    logic [7:0]  fsr_raw;
    logic [7:0]  fsr_filtered;
    logic [3:0]  input_state;
    logic        adc_busy;
    logic        adc_valid;
    logic        adc_bus_error;
    logic        input_overflow;
    logic [6:0]  base_note_debug;
    logic        key_ghost_debug;
    logic        key_conflict_debug;
    logic        adc_timeout_debug;

    logic [15:0] pressed;       // bit[row*4+col] = 按下

    int errors = 0;
    int ev_count = 0;

    logic [1:0] evt_type [0:255];
    logic [6:0] evt_note [0:255];
    logic [7:0] evt_vel  [0:255];

    // cfg 事务记录
    localparam logic [7:0] A_VIB  = 8'h24;
    localparam logic [7:0] A_MODE = 8'h2C;
    localparam logic [7:0] A_WET  = 8'h30;
    localparam logic [7:0] A_DLY  = 8'h34;
    localparam logic [7:0] A_FB   = 8'h38;

    logic [7:0]  cfg_a [0:63];
    logic [31:0] cfg_d [0:63];
    int          cfg_cnt = 0;

    always #5 clk = ~clk;

    //-------------------------------------------------------------------------
    // 开漏 I2C 总线 + 上拉 + ADS7830 从机模型
    //-------------------------------------------------------------------------
    assign sda = adc_sda_oe ? 1'b0 : 1'bz;
    pullup(sda);
    assign adc_sda_i = sda;

    ads7830_model u_model (
        .scl (adc_scl),
        .sda (sda)
    );

    //-------------------------------------------------------------------------
    // 4x4 矩阵模型
    //-------------------------------------------------------------------------
    always_comb begin
        for (int c = 0; c < 4; c++) begin
            key_col[c] = 1'b1;
            for (int r = 0; r < 4; r++) begin
                if (pressed[r*4+c] && (key_row[r] == 1'b0)) begin
                    key_col[c] = 1'b0;
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // DUT
    //-------------------------------------------------------------------------
    input_top #(
        .SYS_CLK_HZ       (1000),
        .ROW_DWELL_CYC    (8),
        .PRESS_CYCLES     (3),
        .RELEASE_CYCLES   (5),
        .I2C_QUARTER_DIV  (2),
        .SAMPLE_INTERVAL  (400),
        .FSR_CHANNEL      (3'd0),
        .POT_CHANNEL      (3'd1),
        .EVENT_FIFO_DEPTH (8),
        .TRIG_OFF_MS      (100),
        .TRIG_RETRIG_MS   (20),
        .TRIG_REL_SAMP    (3),
        .TAP_HOLD_MS      (TAP_HOLD_CYC)
    ) dut (
        .sys_clk        (clk),
        .rst_n          (rst_n),
        .key_row        (key_row),
        .key_col        (key_col),
        .adc_scl        (adc_scl),
        .adc_sda_oe     (adc_sda_oe),
        .adc_sda_i      (adc_sda_i),
        .event_valid    (event_valid),
        .event_ready    (event_ready),
        .event_type     (event_type),
        .event_note_id  (event_note_id),
        .event_velocity (event_velocity),
        .expr_valid     (expr_valid),
        .expression     (expression),
        .pitch_bend     (pitch_bend),
        .waveform_sel   (waveform_sel),
        .cfg_valid      (cfg_valid),
        .cfg_write      (cfg_write),
        .cfg_addr       (cfg_addr),
        .cfg_wdata      (cfg_wdata),
        .cfg_ready      (cfg_ready),
        .cfg_rdata      (32'd0),
        .test_mode      (test_mode),
        .test_pattern   (test_pattern),
        .key_down       (key_down),
        .fsr_raw        (fsr_raw),
        .fsr_filtered   (fsr_filtered),
        .input_state    (input_state),
        .adc_busy       (adc_busy),
        .adc_valid      (adc_valid),
        .adc_bus_error  (adc_bus_error),
        .input_overflow (input_overflow),
        .key_ghost_debug  (key_ghost_debug),
        .key_conflict_debug (key_conflict_debug),
        .adc_timeout_debug  (adc_timeout_debug),
        .piezo_peak_rst     (),
        .piezo_hit_debug    (),
        .piezo_active_debug (),
        .base_note_debug    (base_note_debug)
    );

    //-------------------------------------------------------------------------
    // 事件监视器
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && event_valid && event_ready) begin
            evt_type[ev_count] = event_type;
            evt_note[ev_count] = event_note_id;
            evt_vel[ev_count]  = event_velocity;
            $display("[%0t] EVENT #%0d type=%0d note=%0d vel=%0d",
                     $time, ev_count, event_type, event_note_id, event_velocity);
            ev_count++;
        end
    end

    //-------------------------------------------------------------------------
    // cfg 事务监视器
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && cfg_valid && cfg_ready) begin
            cfg_a[cfg_cnt] = cfg_addr;
            cfg_d[cfg_cnt] = cfg_wdata;
            $display("[%0t] CFG   #%0d addr=0x%02h data=%0d",
                     $time, cfg_cnt, cfg_addr, cfg_wdata);
            cfg_cnt++;
        end
    end

    //-------------------------------------------------------------------------
    // 辅助任务
    //-------------------------------------------------------------------------
    task automatic press_key(input int idx);
        @(negedge clk);
        pressed[idx] = 1'b1;
    endtask

    task automatic release_key(input int idx);
        @(negedge clk);
        pressed[idx] = 1'b0;
    endtask

    // 短按：按住 hold_cyc 拍再松开，然后等消抖 + 判决
    task automatic tap_key(input int idx, input int hold_cyc = 100);
        @(negedge clk);
        pressed[idx] = 1'b1;
        repeat (hold_cyc) @(posedge clk);
        @(negedge clk);
        pressed[idx] = 1'b0;
        repeat (40) @(posedge clk);
    endtask

    task automatic wait_events(input int target, input int timeout,
                               input string msg);
        int guard;
        guard = 0;
        while (ev_count < target && guard < timeout) begin
            @(posedge clk);
            guard++;
        end
        if (ev_count < target) begin
            $display("FAIL [%s]: only %0d events, expected %0d",
                     msg, ev_count, target);
            errors++;
        end
    endtask

    task automatic check_event(input int idx, input logic [1:0] t,
                              input logic [6:0] n, input string msg);
        if (evt_type[idx] !== t || evt_note[idx] !== n) begin
            $display("FAIL [%s]: event%0d = (t=%0d,n=%0d), expected (t=%0d,n=%0d)",
                     msg, idx, evt_type[idx], evt_note[idx], t, n);
            errors++;
        end else begin
            $display("PASS [%s]: event%0d = (t=%0d,n=%0d,v=%0d)",
                     msg, idx, t, n, evt_vel[idx]);
        end
    endtask

    task automatic clear_cfg;
        cfg_cnt = 0;
    endtask

    task automatic chk_cfg(input int idx, input logic [7:0] a, input logic [31:0] d,
                           input string msg);
        if (idx >= cfg_cnt) begin
            $display("FAIL [%s]: 缺少第 %0d 笔 cfg", msg, idx);
            errors++;
        end else if (cfg_a[idx] !== a || cfg_d[idx] !== d) begin
            $display("FAIL [%s]: 第 %0d 笔 = 0x%02h<-%0d, 期望 0x%02h<-%0d",
                     msg, idx, cfg_a[idx], cfg_d[idx], a, d);
            errors++;
        end else begin
            $display("PASS [%s]: 第 %0d 笔 = 0x%02h<-%0d", msg, idx, a, d);
        end
    endtask

    task automatic chk_cfg_cnt(input int exp, input string msg);
        if (cfg_cnt != exp) begin
            $display("FAIL [%s]: %0d 笔 cfg, 期望 %0d 笔", msg, cfg_cnt, exp);
            errors++;
        end else begin
            $display("PASS [%s]: %0d 笔 cfg", msg, cfg_cnt);
        end
    endtask

    //-------------------------------------------------------------------------
    // 主测试流程
    //-------------------------------------------------------------------------
    initial begin
        int base;
        int exp_expr;
        int all_off_cnt;
        int note_ev_cnt;

        pressed = '0;
        u_model.adc_val[0] = 8'h40;   // FSR 表情 = 64
        u_model.adc_val[1] = 8'hC0;   // POT      = 192 -> pitch_bend ≈ 3072
        for (int i = 2; i < 8; i++) u_model.adc_val[i] = 8'h00;

        repeat (10) @(posedge clk);
        rst_n = 1'b1;

        $display("========================================");
        $display(" tb_input_top: 第 2 轮输入顶层");
        $display("========================================");

        //---------------------------------------------------------------------
        // 1) test_mode 固定事件源
        //---------------------------------------------------------------------
        test_mode = 1'b1;
        wait_events(4, 2000, "test_mode first 4 events");
        check_event(0, 2'b01, 7'd60, "test_mode C4");
        check_event(1, 2'b01, 7'd64, "test_mode E4");
        check_event(2, 2'b01, 7'd67, "test_mode G4");
        check_event(3, 2'b01, 7'd72, "test_mode C5");

        test_mode = 1'b0;
        ev_count = 0;
        repeat (50) @(posedge clk);

        //---------------------------------------------------------------------
        // 2) 等 ADC/FSR 稳定（7 通道轮询，留足 12000 拍）
        //---------------------------------------------------------------------
        repeat (12000) @(posedge clk);
        if (fsr_filtered < 8'd55 || fsr_filtered > 8'd70) begin
            $display("FAIL: fsr_filtered=%0d, expected ~64 (ADC/I2C broken?)",
                     fsr_filtered);
            errors++;
        end else begin
            $display("PASS: fsr_filtered=%0d, fsr_raw=%0d", fsr_filtered, fsr_raw);
        end

        //---------------------------------------------------------------------
        // 3) A8 / A9：按满 16 个键 3 轮
        //     -> 不产生 ALL_NOTES_OFF，也不产生任何音符事件
        //---------------------------------------------------------------------
        all_off_cnt   = 0;
        note_ev_cnt   = 0;
        base          = ev_count;
        clear_cfg;

        for (int round = 0; round < 3; round++) begin
            for (int k = 0; k < 16; k++) begin
                tap_key(k, 100);
            end
        end
        repeat (300) @(posedge clk);

        for (int i = base; i < ev_count; i++) begin
            if (evt_type[i] == 2'b11) all_off_cnt++;
            else                     note_ev_cnt++;
        end

        if (all_off_cnt != 0) begin
            $display("FAIL [A8]: 按满 16 键仍产生 %0d 个 ALL_NOTES_OFF", all_off_cnt);
            errors++;
        end else begin
            $display("PASS [A8]: 48 次按键 -> 0 个 ALL_NOTES_OFF");
        end
        if (note_ev_cnt != 0) begin
            $display("FAIL [A9]: 键盘产生了 %0d 个音符事件", note_ev_cnt);
            errors++;
        end else begin
            $display("PASS [A9]: 键盘不产生任何 NOTE_ON/NOTE_OFF");
        end

        //---------------------------------------------------------------------
        // 4) 根音选择 + FSR 触发跟随根音
        //---------------------------------------------------------------------
        tap_key(9, 100);                    // K9 -> A (音级 9 -> 69)
        repeat (30) @(posedge clk);
        if (base_note_debug !== 7'd69) begin
            $display("FAIL [根音 K9]: base_note_debug=%0d, 期望 69", base_note_debug);
            errors++;
        end else begin
            $display("PASS [根音 K9]: base_note_debug=69");
        end

        base = ev_count;
        u_model.adc_val[2] = 8'd150;        // P0 触发（高于阈值 20）
        wait_events(base + 1, 20000, "trig P0 NOTE_ON");
        check_event(base, 2'b01, 7'd69, "trig P0 用新根音 A4(69)");

        u_model.adc_val[2] = 8'd0;          // 松手
        wait_events(base + 2, 60000, "trig P0 NOTE_OFF");
        check_event(base + 1, 2'b10, 7'd69, "trig P0 NOTE_OFF A4(69)");
        repeat (100) @(posedge clk);

        // 换根音再触发一次，确认是新根音
        tap_key(0, 100);                    // K0 -> C (60)
        repeat (30) @(posedge clk);
        base = ev_count;
        u_model.adc_val[3] = 8'd120;        // P1 触发
        wait_events(base + 1, 20000, "trig P1 NOTE_ON");
        check_event(base, 2'b01, 7'd62, "trig P1 用根音 C4+2 = D4(62)");
        u_model.adc_val[3] = 8'd0;
        wait_events(base + 2, 60000, "trig P1 NOTE_OFF");
        check_event(base + 1, 2'b10, 7'd62, "trig P1 NOTE_OFF D4(62)");
        repeat (100) @(posedge clk);

        //---------------------------------------------------------------------
        // 5) 波形直选（通过 expression_mapper 输出）
        //---------------------------------------------------------------------
        tap_key(7, 100);
        repeat (30) @(posedge clk);
        if (waveform_sel !== 2'd1) begin
            $display("FAIL [波形 K7]: waveform_sel=%0d, 期望 1", waveform_sel);
            errors++;
        end else begin
            $display("PASS [波形 K7]: waveform_sel=1 (管风琴)");
        end

        tap_key(11, 100);
        repeat (30) @(posedge clk);
        if (waveform_sel !== 2'd2) begin
            $display("FAIL [波形 K11]: waveform_sel=%0d, 期望 2", waveform_sel);
            errors++;
        end else begin
            $display("PASS [波形 K11]: waveform_sel=2 (拨弦)");
        end

        tap_key(3, 100);
        repeat (30) @(posedge clk);
        if (waveform_sel !== 2'd0) begin
            $display("FAIL [波形 K3]: waveform_sel=%0d, 期望 0", waveform_sel);
            errors++;
        end else begin
            $display("PASS [波形 K3]: waveform_sel=0 (正弦)");
        end

        //---------------------------------------------------------------------
        // 6) 效果键 -> cfg 序列（cfg_ready 恒 1，序列瞬间跑完）
        //---------------------------------------------------------------------
        clear_cfg;
        tap_key(12, 100);                   // K12 旁路
        repeat (40) @(posedge clk);
        chk_cfg_cnt(2, "K12 旁路笔数");
        chk_cfg(0, A_WET,  32'd0, "K12 旁路");
        chk_cfg(1, A_MODE, 32'd0, "K12 旁路");

        clear_cfg;
        tap_key(13, 100);                   // K13 延迟
        repeat (40) @(posedge clk);
        chk_cfg_cnt(5, "K13 延迟笔数");
        chk_cfg(0, A_WET,  32'd0,    "K13 延迟");
        chk_cfg(1, A_DLY,  32'd1920, "K13 延迟");
        chk_cfg(2, A_FB,   32'd64,   "K13 延迟");
        chk_cfg(3, A_MODE, 32'd1,    "K13 延迟");
        chk_cfg(4, A_WET,  32'd64,   "K13 延迟");

        clear_cfg;
        tap_key(14, 100);                   // K14 混响 = 3
        repeat (40) @(posedge clk);
        chk_cfg_cnt(3, "K14 混响笔数");
        chk_cfg(0, A_WET,  32'd0,  "K14 混响");
        chk_cfg(1, A_MODE, 32'd3,  "K14 混响");
        chk_cfg(2, A_WET,  32'd64, "K14 混响");

        //---------------------------------------------------------------------
        // 7) K15：短按 = 合唱(2)；长按 = 颤音
        //---------------------------------------------------------------------
        clear_cfg;
        tap_key(15, TAP_HOLD_CYC / 2);      // 短按（< 门槛）
        repeat (40) @(posedge clk);
        chk_cfg_cnt(3, "K15 短按 合唱笔数");
        chk_cfg(0, A_WET,  32'd0,  "K15 短按 合唱");
        chk_cfg(1, A_MODE, 32'd2,  "K15 短按 合唱");
        chk_cfg(2, A_WET,  32'd64, "K15 短按 合唱");

        clear_cfg;
        tap_key(15, TAP_HOLD_CYC * 2);      // 长按（> 门槛）
        repeat (60) @(posedge clk);
        chk_cfg_cnt(1, "K15 长按 只发颤音");
        chk_cfg(0, A_VIB, 32'd25, "K15 长按 颤音 25 音分");

        clear_cfg;
        tap_key(15, TAP_HOLD_CYC * 2);      // 再长按一次 -> 50
        repeat (60) @(posedge clk);
        chk_cfg_cnt(1, "K15 长按第 2 次");
        chk_cfg(0, A_VIB, 32'd50, "K15 长按第 2 次 颤音 50 音分");

        //---------------------------------------------------------------------
        // 8) cfg 背压：cfg_ready=0 时字段必须保持
        //---------------------------------------------------------------------
        clear_cfg;
        cfg_ready = 1'b0;
        repeat (5) @(posedge clk);
        tap_key(13, 100);                   // 触发延迟序列，被卡在第 0 笔
        repeat (200) @(posedge clk);

        if (cfg_cnt != 0) begin
            $display("FAIL [cfg 背压]: ready=0 期间仍完成 %0d 笔握手", cfg_cnt);
            errors++;
        end else if (!cfg_valid) begin
            $display("FAIL [cfg 背压]: ready=0 时 cfg_valid 应为 1");
            errors++;
        end else begin
            logic [7:0]  a0;
            logic [31:0] d0;
            a0 = cfg_addr;  d0 = cfg_wdata;
            repeat (100) @(posedge clk);
            if (cfg_addr !== a0 || cfg_wdata !== d0) begin
                $display("FAIL [cfg 背压]: addr/data 变化了");
                errors++;
            end else begin
                $display("PASS [cfg 背压]: 0x%02h<-%0d 稳定保持", a0, d0);
            end
        end

        cfg_ready = 1'b1;
        repeat (200) @(posedge clk);
        chk_cfg_cnt(5, "背压解除后延迟序列跑完");

        //---------------------------------------------------------------------
        // 9) 测试模式切换：合成 ALL_NOTES_OFF（这是输入侧唯一的 ALL_OFF 来源）
        //---------------------------------------------------------------------
        base = ev_count;
        @(negedge clk);
        event_ready = 1'b0;
        test_mode   = 1'b1;

        begin : chk_mode_switch
            int guard;
            guard = 0;
            while (!(event_valid && event_type == 2'b11) && guard < 5000) begin
                @(posedge clk);
                guard++;
            end
            if (!(event_valid && event_type == 2'b11)) begin
                $display("FAIL: 模式切换未发出合成 ALL_NOTES_OFF");
                errors++;
            end else begin
                $display("PASS: 模式切换发出合成 ALL_NOTES_OFF");
            end
        end

        @(negedge clk);
        event_ready = 1'b1;
        wait_events(base + 2, 3000, "stub restarted after mode switch");
        check_event(base,     2'b11, 7'd0,  "mode switch ALL_OFF");
        check_event(base + 1, 2'b01, 7'd60, "stub first event after switch");

        base = ev_count;
        @(negedge clk);
        test_mode = 1'b0;
        wait_events(base + 1, 3000, "mode switch back ALL_OFF");
        check_event(base, 2'b11, 7'd0, "switch back ALL_OFF");
        repeat (100) @(posedge clk);

        //---------------------------------------------------------------------
        // 10) 矩阵组合告警不回归
        //---------------------------------------------------------------------
        press_key(0);
        press_key(4);
        repeat (200) @(posedge clk);
        if (key_conflict_debug !== 1'b1) begin
            $display("FAIL: key_conflict_debug=0 for same-column two keys");
            errors++;
        end else begin
            $display("PASS: same-column keys flagged (row_conflict)");
        end

        press_key(1);
        repeat (200) @(posedge clk);
        if (key_ghost_debug !== 1'b1) begin
            $display("FAIL: key_ghost_debug=0 for L-shaped three keys");
            errors++;
        end else begin
            $display("PASS: L-shaped combo flagged (ghost_detect)");
        end

        release_key(0);
        release_key(1);
        release_key(4);
        repeat (400) @(posedge clk);
        if (key_ghost_debug !== 1'b0 || key_conflict_debug !== 1'b0) begin
            $display("FAIL: matrix flags not cleared (ghost=%b conflict=%b)",
                     key_ghost_debug, key_conflict_debug);
            errors++;
        end

        //---------------------------------------------------------------------
        // 11) 最终检查
        //---------------------------------------------------------------------
        if (adc_timeout_debug !== 1'b0) begin
            $display("FAIL: adc_timeout_debug asserted");
            errors++;
        end
        if (input_overflow !== 1'b0) begin
            $display("FAIL: input_overflow asserted");
            errors++;
        end
        if (adc_bus_error !== 1'b0) begin
            $display("FAIL: adc_bus_error asserted");
            errors++;
        end
        if (pitch_bend < 12'd2900 || pitch_bend > 12'd3200) begin
            $display("FAIL: pitch_bend=%0d, expected ~3072 (POT=192)", pitch_bend);
            errors++;
        end else begin
            $display("PASS: pitch_bend=%0d (POT=192)", pitch_bend);
        end
        if (expr_valid !== 1'b1) begin
            $display("FAIL: expr_valid should be 1 after ADC sampling");
            errors++;
        end

        exp_expr = 96 + ((int'(fsr_filtered) * 159) >> 8);
        if (int'(expression) < 96) begin
            $display("FAIL: expression=%0d below EXPR_MIN=96", expression);
            errors++;
        end else if (int'(expression) < exp_expr - 2 ||
                     int'(expression) > exp_expr + 2) begin
            $display("FAIL: expression=%0d, expected ~%0d (fsr_filtered=%0d)",
                     expression, exp_expr, fsr_filtered);
            errors++;
        end else begin
            $display("PASS: expression=%0d (fsr_filtered=%0d)",
                     expression, fsr_filtered);
        end

        $display("========================================");
        if (errors == 0) begin
            $display("TEST PASSED: tb_input_top");
        end else begin
            $display("TEST FAILED: tb_input_top, %0d error(s)", errors);
        end
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TEST TIMEOUT: tb_input_top");
        $finish;
    end

endmodule
