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
        .PIEZO_OFF_MS     (100),
        .PIEZO_RETRIG_MS  (20)
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
        .octave_debug   (octave_debug)
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

        pressed = '0;
        u_model.adc_val[0] = 8'h40;   // FSR   = 64
        u_model.adc_val[1] = 8'hC0;   // POT   = 192 -> pitch_bend = 3072
        u_model.adc_val[2] = 8'h00;   // 5 路压电峰值先置 0，避免 X 传播
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
        //    现在 7 通道轮询：CH2~CH6 压电、CH0 FSR、CH1 POT；
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
        // 8) 波形切换：K14 循环 0 -> 1 -> 2 -> 0
        //---------------------------------------------------------------------
        repeat (30) @(posedge clk);
        if (waveform_sel !== 2'b00) begin
            $display("FAIL: initial waveform_sel=%0d", waveform_sel);
            errors++;
        end

        tap_key(14);
        repeat (30) @(posedge clk);
        if (waveform_sel !== 2'b01) begin
            $display("FAIL: waveform_sel=%0d after 1 press, expected 1",
                     waveform_sel);
            errors++;
        end

        tap_key(14);
        repeat (30) @(posedge clk);
        if (waveform_sel !== 2'b10) begin
            $display("FAIL: waveform_sel=%0d after 2 presses, expected 2",
                     waveform_sel);
            errors++;
        end

        tap_key(14);
        repeat (30) @(posedge clk);
        if (waveform_sel !== 2'b00) begin
            $display("FAIL: waveform_sel=%0d after 3 presses, expected 0",
                     waveform_sel);
            errors++;
        end else begin
            $display("PASS: waveform cycles 0->1->2->0");
        end

        //---------------------------------------------------------------------
        // 9) 压电集成：P0(CH2) 峰值 -> NOTE_ON -> 自动 NOTE_OFF
        //---------------------------------------------------------------------
        base = ev_count;
        u_model.adc_val[2] = 8'd150;   // P0 峰值，超过阈值 20

        wait_events(base + 1, 20000, "piezo P0 NOTE_ON");
        check_event(base, 2'b01, 7'd60, "piezo P0 NOTE_ON C4");
        check_velocity(base, 100, 160, "piezo P0 velocity");

        // 峰值模型是“常值”，触发后清零，防止下一轮扫描重复触发
        u_model.adc_val[2] = 8'd0;

        wait_events(base + 2, 20000, "piezo P0 auto NOTE_OFF");
        check_event(base + 1, 2'b10, 7'd60, "piezo P0 auto NOTE_OFF");

        //---------------------------------------------------------------------
        // 10) 最终检查
        //---------------------------------------------------------------------
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
