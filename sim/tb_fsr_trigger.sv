//=============================================================================
// 文件   : tb_fsr_trigger.sv
// 功能   : 5 路 FSR 触发单元测试（替代原 tb_piezo_peak）。
//   覆盖：
//     1. 低于阈值不触发
//     2. 阈值以上触发 NOTE_ON + 力度映射
//     3. 按住期间不重复触发
//     4. 连续 N 个样本低于释放阈值 -> NOTE_OFF
//     5. 防重复触发窗口
//     6. 5 路独立音符映射（+0/+2/+4/+7/+9）
//     7. 兜底 NOTE_OFF（长时间无样本）
//     8. ALL_NOTES_OFF 清除
//
// 仿真参数：
//   SYS_CLK_HZ=1000 -> 1 拍 = 1 ms
//   RETRIGGER_MS=30 -> 30 拍；NOTE_OFF_MS=200 -> 200 拍
//   RELEASE_SAMPLES=3 -> 连续 3 个样本低于阈值才松开
//=============================================================================
`timescale 1ns/1ps

module tb_fsr_trigger;

    localparam logic [2:0] CH_BASE = 3'd2;

    logic       clk = 1'b0;
    logic       rst_n = 1'b0;

    logic       sample_valid = 1'b0;
    logic [2:0] sample_channel = 3'd0;
    logic [7:0] sample_data = 8'd0;

    logic [6:0] base_note = 7'd60;   // C4
    logic       all_off = 1'b0;

    logic [4:0] hit_debug;
    logic [4:0] active_debug;
    logic [39:0] level_debug;
    logic        event_overflow;

    logic       event_req_valid;
    logic       event_req_ready = 1'b1;
    logic [1:0] event_req_type;
    logic [6:0] event_req_note;
    logic [7:0] event_req_velocity;

    int errors = 0;
    int ev_count = 0;

    logic [1:0] evt_type [0:127];
    logic [6:0] evt_note [0:127];
    logic [7:0] evt_vel  [0:127];

    always #5 clk = ~clk;

    fsr_trigger #(
        .NUM_TRIG        (5),
        .SYS_CLK_HZ      (1000),
        .THRESHOLD       (8'd20),
        .RELEASE_HYST    (4),
        .RELEASE_SAMPLES (3),
        .RETRIGGER_MS    (30),
        .NOTE_OFF_MS     (200),
        .VEL_FULL_SCALE  (8'd200)
    ) dut (
        .sys_clk            (clk),
        .rst_n              (rst_n),
        .sample_valid       (sample_valid),
        .sample_channel     (sample_channel),
        .sample_data        (sample_data),
        .trig_ch_base       (CH_BASE),
        .base_note          (base_note),
        .all_off            (all_off),
        .event_req_valid    (event_req_valid),
        .event_req_ready    (event_req_ready),
        .event_req_type     (event_req_type),
        .event_req_note     (event_req_note),
        .event_req_velocity (event_req_velocity),
        .hit_debug          (hit_debug),
        .active_debug       (active_debug),
        .level_debug        (level_debug),
        .event_overflow     (event_overflow)
    );

    //-------------------------------------------------------------------------
    // 事件监视器
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && event_req_valid && event_req_ready) begin
            evt_type[ev_count] = event_req_type;
            evt_note[ev_count] = event_req_note;
            evt_vel[ev_count]  = event_req_velocity;
            $display("[%0t] EVENT #%0d type=%0d note=%0d vel=%0d",
                     $time, ev_count, event_req_type, event_req_note,
                     event_req_velocity);
            ev_count++;
        end
    end

    //-------------------------------------------------------------------------
    // 辅助任务
    //-------------------------------------------------------------------------
    task automatic send_sample(input logic [2:0] ch, input logic [7:0] data);
        @(negedge clk);
        sample_valid   = 1'b1;
        sample_channel = ch;
        sample_data    = data;
        @(negedge clk);
        sample_valid   = 1'b0;
    endtask

    // 连续发 n 个同样的样本
    task automatic send_burst(input logic [2:0] ch, input logic [7:0] data,
                              input int n);
        for (int k = 0; k < n; k++) begin
            send_sample(ch, data);
            repeat (2) @(posedge clk);
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

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        //---------------------------------------------------------------------
        // 1) 低于阈值不触发
        //---------------------------------------------------------------------
        base = ev_count;
        send_burst(CH_BASE, 8'd5, 3);
        repeat (10) @(posedge clk);
        if (ev_count != base) begin
            $display("FAIL: low level triggered %0d event(s)", ev_count - base);
            errors++;
        end else begin
            $display("PASS: low level rejected");
        end

        //---------------------------------------------------------------------
        // 2) 阈值以上 -> NOTE_ON（C4）
        //    vel = (150-20)*255/(200-20) = 184
        //---------------------------------------------------------------------
        send_sample(CH_BASE, 8'd150);
        wait_events(base + 1, 50, "P0 NOTE_ON");
        check_event(base, 2'b01, 7'd60, "P0 NOTE_ON C4");
        check_velocity(base, 170, 200, "P0 velocity");

        //---------------------------------------------------------------------
        // 3) 按住不放（持续高于阈值）-> 不重复触发
        //---------------------------------------------------------------------
        send_burst(CH_BASE, 8'd150, 5);
        repeat (10) @(posedge clk);
        if (ev_count != base + 1) begin
            $display("FAIL: hold caused %0d extra events", ev_count - base - 1);
            errors++;
        end else begin
            $display("PASS: hold does not retrigger");
        end

        //---------------------------------------------------------------------
        // 4) 连续 3 个样本低于释放阈值 -> NOTE_OFF
        //---------------------------------------------------------------------
        send_burst(CH_BASE, 8'd0, 3);
        wait_events(base + 2, 50, "P0 NOTE_OFF");
        check_event(base + 1, 2'b10, 7'd60, "P0 NOTE_OFF C4");

        //---------------------------------------------------------------------
        // 5) 防重复触发窗口
        //    先完成一次“触发 -> 快速松开”，此时仍在窗口内
        //---------------------------------------------------------------------
        repeat (40) @(posedge clk);          // 等上一轮窗口结束
        base = ev_count;

        send_sample(CH_BASE, 8'd150);        // 触发 #base
        wait_events(base + 1, 50, "P0 window trigger");
        send_burst(CH_BASE, 8'd0, 3);        // 立即松开 -> #base+1
        wait_events(base + 2, 50, "P0 window release");

        send_sample(CH_BASE, 8'd150);        // 距触发不足 30 拍，应被挡住
        repeat (10) @(posedge clk);
        if (ev_count != base + 2) begin
            $display("FAIL: retrigger window not enforced (%0d extra)",
                     ev_count - base - 2);
            errors++;
        end else begin
            $display("PASS: retrigger window blocks early trigger");
        end

        //---------------------------------------------------------------------
        // 5b) 窗口到期但手指仍压着（电平一直是 150）-> 不能自动重新触发
        //     旧实现在 retrig_timer 到期时无条件 armed<=1，长按就会每
        //     RETRIGGER_MS 重复发一次 NOTE_ON（评审清单第 3 项）。
        //---------------------------------------------------------------------
        repeat (40) @(posedge clk);          // 窗口肯定已经结束
        send_burst(CH_BASE, 8'd150, 5);      // 仍然保持按压
        repeat (20) @(posedge clk);
        if (ev_count != base + 2) begin
            $display("FAIL: sustained press re-armed after window (%0d extra)",
                     ev_count - base - 2);
            errors++;
        end else begin
            $display("PASS: sustained press does not re-arm after window");
        end

        // 真实松开后才允许再次触发
        send_burst(CH_BASE, 8'd0, 3);
        repeat (10) @(posedge clk);
        send_sample(CH_BASE, 8'd150);
        wait_events(base + 3, 50, "P0 retrigger after real release");
        check_event(base + 2, 2'b01, 7'd60, "P0 retrigger C4");
        send_burst(CH_BASE, 8'd0, 3);        // 松开
        wait_events(base + 4, 50, "P0 NOTE_OFF after retrigger");
        check_event(base + 3, 2'b10, 7'd60, "P0 NOTE_OFF after retrigger");

        //---------------------------------------------------------------------
        // 5c) 长按期间切换根音：NOTE_OFF 必须用触发时锁存的音符（C4），
        //     不能因为根音变成 D4 就漏掉 C4 的 OFF（评审清单第 3 项后半）
        //---------------------------------------------------------------------
        repeat (40) @(posedge clk);
        base = ev_count;
        send_sample(CH_BASE, 8'd150);            // C4
        wait_events(base + 1, 50, "base change NOTE_ON");
        check_event(base, 2'b01, 7'd60, "base change NOTE_ON C4");

        @(negedge clk);
        base_note = 7'd62;                       // D4
        repeat (50) @(posedge clk);              // 长按，跨过防重复窗口
        send_burst(CH_BASE, 8'd150, 3);          // 仍在按压
        if (ev_count != base + 1) begin
            $display("FAIL: root change while held produced %0d extra event(s)",
                     ev_count - base - 1);
            errors++;
        end else begin
            $display("PASS: root change while held does not retrigger");
        end

        send_burst(CH_BASE, 8'd0, 3);            // 松开
        wait_events(base + 2, 50, "base change NOTE_OFF");
        check_event(base + 1, 2'b10, 7'd60, "base change NOTE_OFF keeps C4");
        @(negedge clk);
        base_note = 7'd60;                       // 还原根音 C4
        repeat (20) @(posedge clk);

        //---------------------------------------------------------------------
        // 6) 5 路独立音符映射：+0/+2/+4/+7/+9
        //---------------------------------------------------------------------
        base = ev_count;
        send_sample(CH_BASE + 3'd1, 8'd200);   // P1 -> 62
        send_sample(CH_BASE + 3'd2, 8'd200);   // P2 -> 64
        send_sample(CH_BASE + 3'd3, 8'd200);   // P3 -> 67
        send_sample(CH_BASE + 3'd4, 8'd200);   // P4 -> 69
        wait_events(base + 4, 200, "P1..P4 NOTE_ON");
        check_event(base + 0, 2'b01, 7'd62, "P1 D4");
        check_event(base + 1, 2'b01, 7'd64, "P2 E4");
        check_event(base + 2, 2'b01, 7'd67, "P3 G4");
        check_event(base + 3, 2'b01, 7'd69, "P4 A4");
        check_velocity(base + 0, 250, 255, "P1 velocity full scale");

        // 释放 4 路
        for (int k = 1; k <= 4; k++) begin
            send_burst(CH_BASE + 3'(k), 8'd0, 3);
        end
        wait_events(base + 8, 200, "P1..P4 NOTE_OFF");

        //---------------------------------------------------------------------
        // 7) 兜底 NOTE_OFF：触发后不再送样本，NOTE_OFF_MS=200 拍后自动释放
        //---------------------------------------------------------------------
        repeat (40) @(posedge clk);          // 等防重复窗口结束
        base = ev_count;
        send_sample(CH_BASE, 8'd150);
        wait_events(base + 1, 50, "safety NOTE_ON");
        // 之后完全不发样本
        wait_events(base + 2, 400, "safety timeout NOTE_OFF");
        check_event(base + 1, 2'b10, 7'd60, "safety timeout NOTE_OFF");

        //---------------------------------------------------------------------
        // 8) ALL_NOTES_OFF：清掉活跃状态，之后松手不再产生 NOTE_OFF
        //---------------------------------------------------------------------
        repeat (40) @(posedge clk);
        base = ev_count;
        send_sample(CH_BASE + 3'd2, 8'd150);   // P2 -> 64
        wait_events(base + 1, 50, "ALL_OFF pre NOTE_ON");
        check_event(base, 2'b01, 7'd64, "ALL_OFF pre NOTE_ON E4");

        @(negedge clk);
        all_off = 1'b1;
        @(negedge clk);
        all_off = 1'b0;
        repeat (10) @(posedge clk);

        send_burst(CH_BASE + 3'd2, 8'd0, 3);   // 松手
        repeat (30) @(posedge clk);
        if (ev_count != base + 1) begin
            $display("FAIL: ALL_OFF did not suppress NOTE_OFF (%0d extra)",
                     ev_count - base - 1);
            errors++;
        end else begin
            $display("PASS: ALL_OFF clears active state");
        end

        if (active_debug !== 5'b0) begin
            $display("FAIL: active_debug=%b, expected all 0", active_debug);
            errors++;
        end

        //---------------------------------------------------------------------
        // 8b) ALL_NOTES_OFF 之后手指仍压着：不能立刻重新发声
        //     旧实现在 all_off 时把 armed 全部置 1，下一个高电平样本就会
        //     重新触发 NOTE_ON —— 按了“全部释放”却停不下来（清单第 4 项）。
        //---------------------------------------------------------------------
        repeat (40) @(posedge clk);
        base = ev_count;
        send_sample(CH_BASE + 3'd3, 8'd150);   // P3 -> 67
        wait_events(base + 1, 50, "ALL_OFF hold pre NOTE_ON");
        check_event(base, 2'b01, 7'd67, "ALL_OFF hold pre NOTE_ON G4");

        @(negedge clk);
        all_off = 1'b1;
        @(negedge clk);
        all_off = 1'b0;

        // 手指没有松开：持续送高电平样本，必须保持静音
        send_burst(CH_BASE + 3'd3, 8'd150, 10);
        repeat (60) @(posedge clk);
        if (ev_count != base + 1) begin
            $display("FAIL: held FSR re-triggered after ALL_NOTES_OFF (%0d extra)",
                     ev_count - base - 1);
            errors++;
        end else begin
            $display("PASS: held FSR stays silent after ALL_NOTES_OFF");
        end

        // 松开后重新按下：应该能正常触发
        send_burst(CH_BASE + 3'd3, 8'd0, 3);
        repeat (10) @(posedge clk);
        send_sample(CH_BASE + 3'd3, 8'd150);
        wait_events(base + 2, 60, "ALL_OFF then re-press NOTE_ON");
        check_event(base + 1, 2'b01, 7'd67, "ALL_OFF then re-press G4");
        send_burst(CH_BASE + 3'd3, 8'd0, 3);
        wait_events(base + 3, 60, "ALL_OFF then re-press NOTE_OFF");
        check_event(base + 2, 2'b10, 7'd67, "ALL_OFF then re-press NOTE_OFF");
        repeat (20) @(posedge clk);

        //---------------------------------------------------------------------
        // 9) 背压：event_req_ready=0 时 NOTE_ON 与 NOTE_OFF 都不能被覆盖
        //    （评审清单第 7 项：单槽位会丢失尚未发出的 NOTE_ON）
        //---------------------------------------------------------------------
        event_req_ready = 1'b0;
        repeat (5) @(posedge clk);
        base = ev_count;

        send_sample(CH_BASE, 8'd150);            // NOTE_ON 进 p0
        repeat (5) @(posedge clk);
        send_burst(CH_BASE, 8'd0, 3);            // 松开 -> NOTE_OFF 进 p1
        repeat (10) @(posedge clk);

        if (event_req_valid !== 1'b1 ||
            event_req_type !== 2'b01 || event_req_note !== 7'd60) begin
            $display("FAIL: pending NOTE_ON lost under backpressure (t=%0d n=%0d)",
                     event_req_type, event_req_note);
            errors++;
        end else begin
            $display("PASS: NOTE_ON still at head under backpressure");
        end

        if (event_overflow !== 1'b0) begin
            $display("FAIL: 2 个事件不该溢出 (event_overflow=1)");
            errors++;
        end

        @(negedge clk);
        event_req_ready = 1'b1;                  // 放开背压，两个事件依次送出
        wait_events(base + 2, 200, "backpressure drain");
        check_event(base, 2'b01, 7'd60, "backpressure NOTE_ON");
        check_event(base + 1, 2'b10, 7'd60, "backpressure NOTE_OFF");
        repeat (20) @(posedge clk);

        //---------------------------------------------------------------------
        // 汇总
        //---------------------------------------------------------------------
        if (errors == 0) begin
            $display("TEST PASSED: tb_fsr_trigger");
        end else begin
            $display("TEST FAILED: tb_fsr_trigger, %0d error(s)", errors);
        end
        $finish;
    end

    initial begin
        #200_000;
        $display("TEST TIMEOUT: tb_fsr_trigger");
        $finish;
    end

endmodule
