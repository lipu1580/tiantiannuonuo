//=============================================================================
// 文件   : tb_input_top.sv
// 功能   : 成员 2 顶层系统级仿真。
//   覆盖：
//     1. test_mode 固定事件源
//     2. ADC(ADS7830) -> FSR 力度
//     3. 单键 NOTE_ON/NOTE_OFF
//     4. 四键和弦
//     5. event_ready 背压
//     6. ALL_NOTES_OFF 与释放抑制
//     7. 八度切换
//     8. 波形切换
//=============================================================================
`timescale 1ns/1ps

module tb_input_top;

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

    logic       expr_valid;
    logic [7:0] expression;
    logic [11:0] pitch_bend;
    logic [1:0] waveform_sel;

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
    logic signed [3:0] octave_debug;
    logic        key_ghost_debug;
    logic        key_conflict_debug;
    logic        adc_timeout_debug;

    logic [15:0] pressed;       // bit[row*4+col] = 按下

    int errors = 0;
    int ev_count = 0;

    logic [1:0] evt_type [0:255];
    logic [6:0] evt_note [0:255];
    logic [7:0] evt_vel  [0:255];

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
        .TRIG_REL_SAMP    (3)
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
        .octave_debug   (octave_debug),
        .key_ghost_debug  (key_ghost_debug),
        .key_conflict_debug (key_conflict_debug),
        .adc_timeout_debug  (adc_timeout_debug)
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

    // 功能键短按：必须覆盖至少 2~3 个完整扫描帧（4 行 x 10 拍），
    // 否则按键所在的第 3 行可能根本没被扫描到。
    task automatic tap_key(input int idx);
        @(negedge clk);
        pressed[idx] = 1'b1;
        repeat (100) @(posedge clk);
        @(negedge clk);
        pressed[idx] = 1'b0;
        repeat (100) @(posedge clk);
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

    task automatic check_velocity(input int idx, input int lo, input int hi,
                                  input string msg);
        if (int'(evt_vel[idx]) < lo || int'(evt_vel[idx]) > hi) begin
            $display("FAIL [%s]: velocity=%0d, expected %0d..%0d",
                     msg, evt_vel[idx], lo, hi);
            errors++;
        end else begin
            $display("PASS [%s]: velocity=%0d", msg, evt_vel[idx]);
        end
    endtask

    //-------------------------------------------------------------------------
    // 主测试流程
    //-------------------------------------------------------------------------
    initial begin
        int base;
        int exp_expr;

        pressed = '0;
        u_model.adc_val[0] = 8'h40;   // FSR   = 64
        u_model.adc_val[1] = 8'hC0;   // POT   = 192 -> pitch_bend = 3072
        u_model.adc_val[2] = 8'h00;   // 5 路 FSR 触发电平先置 0，避免 X 传播
        u_model.adc_val[3] = 8'h00;
        u_model.adc_val[4] = 8'h00;
        u_model.adc_val[5] = 8'h00;
        u_model.adc_val[6] = 8'h00;
        u_model.adc_val[7] = 8'h00;

        repeat (10) @(posedge clk);
        rst_n = 1'b1;

        //---------------------------------------------------------------------
        // 1) test_mode 固定事件源
        //---------------------------------------------------------------------
        test_mode = 1'b1;
        wait_events(4, 2000, "test_mode first 4 events");
        check_event(0, 2'b01, 7'd60, "test_mode C4");
        check_event(1, 2'b01, 7'd64, "test_mode E4");
        check_event(2, 2'b01, 7'd67, "test_mode G4");
        check_event(3, 2'b01, 7'd72, "test_mode C5");
        check_velocity(0, 180, 180, "test_mode velocity");

        test_mode = 1'b0;
        ev_count = 0;
        repeat (20) @(posedge clk);

        //---------------------------------------------------------------------
        // 2) 等 ADC/FSR 稳定
        //    现在 7 通道轮询：CH2~CH6 FSR 触发、CH0 FSR 表情、CH1 POT；
        //    一轮约 (400 + 转换时间) * 7，留足 12000 拍。
        //---------------------------------------------------------------------
        repeat (12000) @(posedge clk);
        if (fsr_filtered < 8'd55 || fsr_filtered > 8'd70) begin
            $display("FAIL: fsr_filtered=%0d, expected ~64 (ADC/I2C broken?)",
                     fsr_filtered);
            errors++;
        end else begin
            $display("PASS: fsr_filtered=%0d, fsr_raw=%0d", fsr_filtered, fsr_raw);
        end
        if (dut.pressure_valid !== 1'b1) begin
            $display("FAIL: pressure_valid should be 1 for FSR=64");
            errors++;
        end

        //---------------------------------------------------------------------
        // 3) 单键：按下 -> NOTE_ON，长按不重复，释放 -> NOTE_OFF
        //---------------------------------------------------------------------
        base = ev_count;
        press_key(0);                       // K0 -> C4
        wait_events(base + 1, 500, "single key NOTE_ON");
        check_event(base, 2'b01, 7'd60, "single key NOTE_ON");
        check_velocity(base, 50, 70, "single key FSR velocity");

        repeat (100) @(posedge clk);
        if (ev_count != base + 1) begin
            $display("FAIL: long press generated %0d extra events",
                     ev_count - base - 1);
            errors++;
        end

        release_key(0);
        wait_events(base + 2, 500, "single key NOTE_OFF");
        check_event(base + 1, 2'b10, 7'd60, "single key NOTE_OFF");
        repeat (20) @(posedge clk);

        //---------------------------------------------------------------------
        // 4) 四键和弦
        //---------------------------------------------------------------------
        base = ev_count;
        press_key(0);
        press_key(2);
        press_key(4);
        press_key(7);
        wait_events(base + 4, 1000, "chord NOTE_ON");
        check_event(base + 0, 2'b01, 7'd60, "chord key0");
        check_event(base + 1, 2'b01, 7'd62, "chord key2");
        check_event(base + 2, 2'b01, 7'd64, "chord key4");
        check_event(base + 3, 2'b01, 7'd67, "chord key7");

        release_key(0);
        release_key(2);
        release_key(4);
        release_key(7);
        wait_events(base + 8, 1000, "chord NOTE_OFF");
        check_event(base + 4, 2'b10, 7'd60, "chord off key0");
        check_event(base + 5, 2'b10, 7'd62, "chord off key2");
        check_event(base + 6, 2'b10, 7'd64, "chord off key4");
        check_event(base + 7, 2'b10, 7'd67, "chord off key7");
        repeat (20) @(posedge clk);

        //---------------------------------------------------------------------
        // 5) 背压：event_ready=0 时字段保持，事件不丢
        //---------------------------------------------------------------------
        event_ready = 1'b0;
        base = ev_count;
        press_key(5);                       // K5 -> F4 (65)

        // 事件尚未被接受，evt 数组还没有记录，检查 DUT 端口
        begin : chk_bp
            int guard;
            guard = 0;
            while (!event_valid && guard < 500) begin
                @(posedge clk);
                guard++;
            end
            if (!event_valid) begin
                $display("FAIL: no event_valid under backpressure");
                errors++;
            end else if (event_type !== 2'b01 || event_note_id !== 7'd65) begin
                $display("FAIL: backpressure fields (%0d,%0d), expected (1,65)",
                         event_type, event_note_id);
                errors++;
            end else begin
                $display("PASS: backpressure event held (note 65)");
            end
        end

        // 保持 100 拍，字段必须稳定
        repeat (100) @(posedge clk);
        if (!event_valid || event_type !== 2'b01 || event_note_id !== 7'd65) begin
            $display("FAIL: backpressure fields changed while stalled");
            errors++;
        end

        @(negedge clk);
        event_ready = 1'b1;
        wait_events(base + 1, 500, "backpressure event accepted");
        check_event(base, 2'b01, 7'd65, "backpressure accepted");
        release_key(5);
        wait_events(base + 2, 500, "backpressure NOTE_OFF");
        check_event(base + 1, 2'b10, 7'd65, "backpressure NOTE_OFF");
        repeat (20) @(posedge clk);

        //---------------------------------------------------------------------
        // 6) ALL_NOTES_OFF：按住 K0 时按下 K12，释放 K0 不应再发 NOTE_OFF
        //---------------------------------------------------------------------
        base = ev_count;
        press_key(0);
        wait_events(base + 1, 500, "alloff prep NOTE_ON");
        check_event(base, 2'b01, 7'd60, "alloff prep NOTE_ON");

        press_key(12);                      // K12 = ALL_NOTES_OFF
        wait_events(base + 2, 500, "ALL_NOTES_OFF");
        check_event(base + 1, 2'b11, 7'd0, "ALL_NOTES_OFF");

        release_key(0);
        repeat (300) @(posedge clk);
        if (ev_count != base + 2) begin
            $display("FAIL: suppressed release produced extra event(s): %0d",
                     ev_count - base - 2);
            for (int i = base + 2; i < ev_count; i++) begin
                $display("  extra: type=%0d note=%0d", evt_type[i], evt_note[i]);
            end
            errors++;
        end else begin
            $display("PASS: NOTE_OFF suppressed after ALL_NOTES_OFF");
        end
        release_key(12);
        repeat (50) @(posedge clk);

        //---------------------------------------------------------------------
        // 7) 八度切换
        //---------------------------------------------------------------------
        // +1 八度：K0 -> C5(72)
        base = ev_count;
        tap_key(13);
        repeat (30) @(posedge clk);
        press_key(0);
        wait_events(base + 1, 500, "octave +1 NOTE_ON");
        check_event(base, 2'b01, 7'd72, "octave +1 NOTE_ON");
        release_key(0);
        wait_events(base + 2, 500, "octave +1 NOTE_OFF");
        check_event(base + 1, 2'b10, 7'd72, "octave +1 NOTE_OFF");
        repeat (30) @(posedge clk);

        // 回到 0，再到 -1 八度：K0 -> C3(48)
        base = ev_count;
        tap_key(15);                        // +1 -> 0
        repeat (20) @(posedge clk);
        tap_key(15);                        // 0 -> -1
        repeat (20) @(posedge clk);
        if (octave_debug !== -4'sd1) begin
            $display("FAIL: octave_debug=%0d, expected -1", octave_debug);
            errors++;
        end
        press_key(0);
        wait_events(base + 1, 500, "octave -1 NOTE_ON");
        check_event(base, 2'b01, 7'd48, "octave -1 NOTE_ON");
        release_key(0);
        wait_events(base + 2, 500, "octave -1 NOTE_OFF");
        check_event(base + 1, 2'b10, 7'd48, "octave -1 NOTE_OFF");
        repeat (30) @(posedge clk);

        // 恢复 0 八度
        tap_key(13);
        repeat (30) @(posedge clk);
        if (octave_debug !== 4'sd0) begin
            $display("FAIL: octave_debug=%0d, expected 0 after restore",
                     octave_debug);
            errors++;
        end

        //---------------------------------------------------------------------
        // 8) 波形切换
        //   成员 1 的 waveform_rom 目前只实现正弦波，切到 1/2 会静音。
        //   因此输入侧默认 WAVEFORM_MAX_SEL=0：按 K14 不改变 waveform_sel，
        //   避免一次误按把整件乐器切静音（评审清单第 8 项）。
        //   完整的 0->1->2->0 循环由 tb_matrix_config（显式置 2）覆盖。
        //---------------------------------------------------------------------
        repeat (30) @(posedge clk);
        if (waveform_sel !== 2'b00) begin
            $display("FAIL: initial waveform_sel=%0d", waveform_sel);
            errors++;
        end

        tap_key(14);
        repeat (30) @(posedge clk);
        if (waveform_sel !== 2'b00) begin
            $display("FAIL: waveform_sel=%0d after K14, expected 0 (只实现正弦)",
                     waveform_sel);
            errors++;
        end else begin
            $display("PASS: waveform key keeps sine (未实现的波形不会静音)");
        end

        //---------------------------------------------------------------------
        // 9) FSR 触发集成：P0(CH2) 电平 -> NOTE_ON -> 松手 NOTE_OFF
        //---------------------------------------------------------------------
        base = ev_count;
        u_model.adc_val[2] = 8'd150;   // P0 电平，超过阈值 20

        wait_events(base + 1, 20000, "trig P0 NOTE_ON");
        check_event(base, 2'b01, 7'd60, "trig P0 NOTE_ON C4");
        check_velocity(base, 170, 200, "trig P0 velocity");

        // 松手：连续 3 个样本低于释放阈值才会产生 NOTE_OFF
        u_model.adc_val[2] = 8'd0;

        wait_events(base + 2, 60000, "trig P0 NOTE_OFF");
        check_event(base + 1, 2'b10, 7'd60, "trig P0 NOTE_OFF C4");

        //---------------------------------------------------------------------
        // 10) 背压协议（F-17）
        //    FIFO 满时，事件只能停在译码器/skid 里等待，
        //    不能向 event_queue 发出 "valid=1 && ready=0"（会被误判为 overflow）。
        //---------------------------------------------------------------------
        event_ready = 1'b0;
        repeat (5) @(posedge clk);

        // 4 个键 × (ON + OFF) = 8 个事件，刚好填满 FIFO
        for (int k = 0; k < 4; k++) begin
            tap_key(k);
        end

        // 再按第 5 个键：事件只能在等待，不能误报溢出
        base = ev_count;
        press_key(4);
        repeat (300) @(posedge clk);

        if (input_overflow !== 1'b0) begin
            $display("FAIL: false overflow while FIFO full (F-17)");
            errors++;
        end else begin
            $display("PASS: no false overflow under FIFO backpressure");
        end

        // 顶层所见事件仍应是 FIFO 队首，字段稳定
        if (!event_valid) begin
            $display("FAIL: FIFO should still present its head event");
            errors++;
        end

        event_ready = 1'b1;                  // 释放背压
        release_key(4);
        repeat (2500) @(posedge clk);        // 排空全部事件

        if (input_overflow !== 1'b0) begin
            $display("FAIL: overflow after draining (%0d events)", ev_count);
            errors++;
        end

        //---------------------------------------------------------------------
        // 11) 测试模式切换：不得撤销下游未接收的事件，切换时补 ALL_NOTES_OFF
        //     （评审清单第 5 项）
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
                $display("FAIL: mode switch did not emit ALL_NOTES_OFF");
                errors++;
            end else begin
                $display("PASS: mode switch emits ALL_NOTES_OFF");
            end
        end

        repeat (200) @(posedge clk);
        if (!event_valid || event_type !== 2'b11 || event_note_id !== 7'd0) begin
            $display("FAIL: synthetic ALL_OFF not held (valid=%b type=%0d note=%0d)",
                     event_valid, event_type, event_note_id);
            errors++;
        end else begin
            $display("PASS: synthetic ALL_OFF held stable under backpressure");
        end

        @(negedge clk);
        event_ready = 1'b1;
        wait_events(base + 2, 3000, "stub restarted after mode switch");
        check_event(base,     2'b11, 7'd0,  "mode switch ALL_OFF");
        check_event(base + 1, 2'b01, 7'd60, "stub first event after switch");

        // 回到真实输入：切换时同样要经过 ALL_OFF
        base = ev_count;
        @(negedge clk);
        test_mode = 1'b0;
        wait_events(base + 1, 3000, "mode switch back ALL_OFF");
        check_event(base, 2'b11, 7'd0, "switch back ALL_OFF");
        repeat (100) @(posedge clk);

        //---------------------------------------------------------------------
        // 12) 矩阵组合告警（无二极管矩阵的固有限制，评审清单第 18 项）
        //     K0=(r0,c0)、K4=(r1,c0) 同列跨行 -> key_conflict_debug=1
        //     再按 K1=(r0,c1) 组成 L 形三键 -> key_ghost_debug=1
        //     两路告警只是提示，不改变事件输出。
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
        // 13) 最终检查
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

        // expression 映射：应抬升到 EXPR_MIN..255，松手不能为 0
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

        if (errors == 0) begin
            $display("TEST PASSED: tb_input_top");
        end else begin
            $display("TEST FAILED: tb_input_top, %0d error(s)", errors);
        end
        $finish;
    end

    initial begin
        #2_000_000;
        $display("TEST TIMEOUT: tb_input_top");
        $finish;
    end

endmodule
