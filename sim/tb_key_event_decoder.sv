//=============================================================================
// 文件   : tb_key_event_decoder.sv
// 功能   : 矩阵事件译码器单元测试。
//   覆盖：
//     1. 单键 NOTE_ON / NOTE_OFF（释放用按下时锁存的音高）
//     2. 同一拍多个键按下 -> 按键号从小到大依次送出
//     3. 背压下“NOTE_ON 未发出就松手”：NOTE_ON 不能被 NOTE_OFF 覆盖
//        （评审清单第 7 项）
//     4. ALL_NOTES_OFF 优先级最高，并且抑制被按住键的释放事件
//     5. 八度上下限与音高限幅
//     6. 波形循环（WAVEFORM_MAX_SEL=2 时 0->1->2->0）
//     7. 同键 3 个事件积压在 2 槽位队列里 -> event_overflow 置位，
//        但在队事件不被破坏
//=============================================================================
`timescale 1ns/1ps

module tb_key_event_decoder;

    logic        clk   = 1'b0;
    logic        rst_n = 1'b0;

    logic [15:0] key_pressed  = '0;
    logic [15:0] key_released = '0;
    logic [15:0] key_down     = '0;
    logic [7:0]  velocity_in  = 8'd128;

    logic        event_req_valid;
    logic        event_req_ready = 1'b1;
    logic [1:0]  event_req_type;
    logic [6:0]  event_req_note;
    logic [7:0]  event_req_velocity;

    logic signed [3:0] octave_offset;
    logic [1:0]  waveform_sel;
    logic [6:0]  base_note;
    logic [15:0] active_note_mask;
    logic        event_overflow;

    int errors = 0;
    int ev_count = 0;

    logic [1:0] log_type [0:255];
    logic [6:0] log_note [0:255];

    always #5 clk = ~clk;

    key_event_decoder #(
        .KEY_COUNT        (16),
        .NOTE_KEY_COUNT   (12),
        .BASE_NOTE        (7'd60),
        .MATRIX_MODE      (0),
        .WAVEFORM_MAX_SEL (2'd2)
    ) dut (
        .sys_clk            (clk),
        .rst_n              (rst_n),
        .key_pressed        (key_pressed),
        .key_released       (key_released),
        .key_down           (key_down),
        .velocity_in        (velocity_in),
        .event_req_valid    (event_req_valid),
        .event_req_ready    (event_req_ready),
        .event_req_type     (event_req_type),
        .event_req_note     (event_req_note),
        .event_req_velocity (event_req_velocity),
        .octave_offset      (octave_offset),
        .waveform_sel       (waveform_sel),
        .base_note          (base_note),
        .active_note_mask   (active_note_mask),
        .event_overflow     (event_overflow)
    );

    //-------------------------------------------------------------------------
    // 事件监视器
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && event_req_valid && event_req_ready) begin
            log_type[ev_count] = event_req_type;
            log_note[ev_count] = event_req_note;
            $display("[%0t] EVENT #%0d type=%0d note=%0d vel=%0d",
                     $time, ev_count, event_req_type, event_req_note,
                     event_req_velocity);
            ev_count++;
        end
    end

    //-------------------------------------------------------------------------
    // 按键激励：单拍脉冲 + 稳定状态
    //-------------------------------------------------------------------------
    task automatic press_key(input int idx);
        @(negedge clk);
        key_down[idx]    = 1'b1;
        key_pressed[idx] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        key_pressed[idx] = 1'b0;
    endtask

    task automatic release_key(input int idx);
        @(negedge clk);
        key_down[idx]     = 1'b0;
        key_released[idx] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        key_released[idx] = 1'b0;
    endtask

    task automatic check_event(input int idx, input logic [1:0] t,
                               input logic [6:0] n, input string msg);
        if (log_type[idx] !== t || log_note[idx] !== n) begin
            $display("FAIL [%s]: event%0d = (%0d,%0d), expected (%0d,%0d)",
                     msg, idx, log_type[idx], log_note[idx], t, n);
            errors++;
        end else begin
            $display("PASS [%s]: event%0d = (%0d,%0d)", msg, idx, t, n);
        end
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

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    initial begin
        int base;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        //---------------------------------------------------------------------
        // 1) 单键：NOTE_ON -> NOTE_OFF
        //---------------------------------------------------------------------
        base = ev_count;
        press_key(0);
        wait_events(base + 1, 20, "single key NOTE_ON");
        check_event(base, 2'b01, 7'd60, "K0 NOTE_ON C4");

        release_key(0);
        wait_events(base + 2, 20, "single key NOTE_OFF");
        check_event(base + 1, 2'b10, 7'd60, "K0 NOTE_OFF C4");

        //---------------------------------------------------------------------
        // 2) 同一拍多键按下 -> 按键号从小到大
        //---------------------------------------------------------------------
        base = ev_count;
        @(negedge clk);
        key_down[0]    = 1'b1; key_pressed[0] = 1'b1;
        key_down[2]    = 1'b1; key_pressed[2] = 1'b1;
        key_down[4]    = 1'b1; key_pressed[4] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        key_pressed = '0;

        wait_events(base + 3, 50, "chord NOTE_ON");
        check_event(base + 0, 2'b01, 7'd60, "chord K0 C4");
        check_event(base + 1, 2'b01, 7'd62, "chord K2 D4");
        check_event(base + 2, 2'b01, 7'd64, "chord K4 E4");

        //---------------------------------------------------------------------
        // 3) 背压下 NOTE_ON 不能被后到的 NOTE_OFF 覆盖（清单第 7 项）
        //---------------------------------------------------------------------
        // 先把和弦释放掉（ready=1，OFF 正常送出）
        release_key(0);
        release_key(2);
        release_key(4);
        repeat (20) @(posedge clk);

        //---------------------------------------------------------------------
        // 3) 背压下 NOTE_ON 不能被后到的 NOTE_OFF 覆盖（清单第 7 项）
        //---------------------------------------------------------------------
        @(negedge clk);
        event_req_ready = 1'b0;
        repeat (5) @(posedge clk);
        base = ev_count;

        press_key(5);                  // K5 -> F4 65，进 p0
        repeat (5) @(posedge clk);
        release_key(5);                // NOTE_OFF 应进 p1，而不是覆盖 NOTE_ON
        repeat (10) @(posedge clk);

        if (event_req_valid !== 1'b1 || event_req_type !== 2'b01 ||
            event_req_note !== 7'd65) begin
            $display("FAIL: NOTE_ON lost under backpressure (head=%0d note=%0d)",
                     event_req_type, event_req_note);
            errors++;
        end else begin
            $display("PASS: NOTE_ON kept at head under backpressure");
        end

        if (event_overflow !== 1'b0) begin
            $display("FAIL: 2 个事件不该溢出");
            errors++;
        end

        @(negedge clk);
        event_req_ready = 1'b1;
        wait_events(base + 2, 100, "backpressure drain");
        check_event(base + 0, 2'b01, 7'd65, "backpressure NOTE_ON");
        check_event(base + 1, 2'b10, 7'd65, "backpressure NOTE_OFF");

        //---------------------------------------------------------------------
        // 4) ALL_NOTES_OFF：优先级最高，并抑制按住键的释放事件
        //---------------------------------------------------------------------
        base = ev_count;
        press_key(6);                  // K6 -> F#4 66
        wait_events(base + 1, 20, "alloff prep");
        check_event(base, 2'b01, 7'd66, "alloff prep NOTE_ON");

        press_key(12);                 // K12 = ALL_NOTES_OFF
        wait_events(base + 2, 20, "ALL_NOTES_OFF");
        check_event(base + 1, 2'b11, 7'd0, "ALL_NOTES_OFF");

        release_key(6);                // 不应再发 NOTE_OFF
        repeat (30) @(posedge clk);
        if (ev_count != base + 2) begin
            $display("FAIL: released note after ALL_OFF produced %0d event(s)",
                     ev_count - base - 2);
            errors++;
        end else begin
            $display("PASS: ALL_OFF suppresses held-key NOTE_OFF");
        end
        release_key(12);

        //---------------------------------------------------------------------
        // 5) 八度上下限与音高限幅
        //---------------------------------------------------------------------
        repeat (10) @(posedge clk);
        for (int k = 0; k < 5; k++) begin
            press_key(13);             // 升八度，最多 +2
            release_key(13);
        end
        repeat (10) @(posedge clk);
        if (octave_offset !== 4'sd2) begin
            $display("FAIL: octave_offset=%0d, expected +2 (upper clamp)",
                     octave_offset);
            errors++;
        end else begin
            $display("PASS: octave upper clamp +2");
        end

        for (int k = 0; k < 8; k++) begin
            press_key(15);             // 降八度，最多 -2
            release_key(15);
        end
        repeat (10) @(posedge clk);
        if (octave_offset !== -4'sd2) begin
            $display("FAIL: octave_offset=%0d, expected -2 (lower clamp)",
                     octave_offset);
            errors++;
        end else begin
            $display("PASS: octave lower clamp -2");
        end

        // -2 八度时 K0 = 60 - 24 = 36
        base = ev_count;
        press_key(0);
        wait_events(base + 1, 20, "octave -2 NOTE_ON");
        check_event(base, 2'b01, 7'd36, "K0 at octave -2 -> 36");
        release_key(0);
        wait_events(base + 2, 20, "octave -2 NOTE_OFF");

        // 回到 0 八度
        for (int k = 0; k < 2; k++) begin
            press_key(13);
            release_key(13);
        end
        repeat (10) @(posedge clk);
        if (octave_offset !== 4'sd0) begin
            $display("FAIL: octave_offset=%0d, expected 0", octave_offset);
            errors++;
        end

        //---------------------------------------------------------------------
        // 6) 波形循环 0 -> 1 -> 2 -> 0（WAVEFORM_MAX_SEL=2）
        //---------------------------------------------------------------------
        if (waveform_sel !== 2'b00) begin
            $display("FAIL: waveform_sel reset value=%0d", waveform_sel);
            errors++;
        end
        press_key(14); release_key(14);
        repeat (5) @(posedge clk);
        if (waveform_sel !== 2'b01) begin
            $display("FAIL: waveform_sel=%0d after 1 press", waveform_sel);
            errors++;
        end
        press_key(14); release_key(14);
        repeat (5) @(posedge clk);
        if (waveform_sel !== 2'b10) begin
            $display("FAIL: waveform_sel=%0d after 2 presses", waveform_sel);
            errors++;
        end
        press_key(14); release_key(14);
        repeat (5) @(posedge clk);
        if (waveform_sel !== 2'b00) begin
            $display("FAIL: waveform_sel=%0d after 3 presses", waveform_sel);
            errors++;
        end else begin
            $display("PASS: waveform cycles 0->1->2->0");
        end

        //---------------------------------------------------------------------
        // 7) 同键 3 个事件积压（2 槽位）-> overflow 置位，在队事件不丢
        //---------------------------------------------------------------------
        @(negedge clk);
        event_req_ready = 1'b0;
        repeat (5) @(posedge clk);
        base = ev_count;

        press_key(7);                  // K7 -> G4 67
        repeat (3) @(posedge clk);
        release_key(7);                // OFF
        repeat (3) @(posedge clk);
        press_key(7);                  // 第三个事件：槽位满
        repeat (5) @(posedge clk);

        if (event_overflow !== 1'b1) begin
            $display("FAIL: third event for one key did not raise overflow");
            errors++;
        end else begin
            $display("PASS: slot overflow reported for a 3rd event");
        end

        if (event_req_valid !== 1'b1 || event_req_type !== 2'b01 ||
            event_req_note !== 7'd67) begin
            $display("FAIL: queued head damaged after overflow (type=%0d note=%0d)",
                     event_req_type, event_req_note);
            errors++;
        end

        @(negedge clk);
        event_req_ready = 1'b1;
        wait_events(base + 2, 100, "overflow drain");
        check_event(base + 0, 2'b01, 7'd67, "overflow NOTE_ON kept");
        check_event(base + 1, 2'b10, 7'd67, "overflow NOTE_OFF kept");

        if (errors == 0) begin
            $display("TEST PASSED: tb_key_event_decoder");
        end else begin
            $display("TEST FAILED: tb_key_event_decoder, %0d error(s)", errors);
        end
        $finish;
    end

    initial begin
        #200_000;
        $display("TEST TIMEOUT: tb_key_event_decoder");
        $finish;
    end

endmodule
