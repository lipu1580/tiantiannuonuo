//=============================================================================
// 文件   : tb_piezo_peak.sv
// 功能   : 5 路压电峰值/触发单元测试。
//
// 【已弃用】触发源已改为 FSR，对应测试见 tb_fsr_trigger.sv；
//           本文件不再包含在 Makefile 的 TBS 列表中。
//   覆盖：
//     1. 5 路独立触发与音符映射（+0/+2/+4/+7/+9）
//     2. 峰值 -> velocity 映射
//     3. 自动 NOTE_OFF
//     4. 防重复触发窗口
//     5. ALL_NOTES_OFF 清除活跃状态
//     6. peak_rst 放电脉冲
//
// 为了仿真快速，把 SYS_CLK_HZ 设为 1000，NOTE_OFF_MS=50 -> 50 拍，
// RETRIGGER_MS=20 -> 20 拍，PEAK_RST_CYCLES=5 拍。
//=============================================================================
`timescale 1ns/1ps

module tb_piezo_peak;

    logic       clk = 1'b0;
    logic       rst_n = 1'b0;

    logic       sample_valid = 1'b0;
    logic [2:0] sample_channel = 3'd0;
    logic [7:0] sample_data = 8'd0;

    logic [6:0] base_note = 7'd60;   // C4
    logic       all_off = 1'b0;

    logic [4:0] peak_rst;
    logic [4:0] hit_debug;
    logic [4:0] active_debug;

    logic       event_req_valid;
    logic       event_req_ready = 1'b1;
    logic [1:0] event_req_type;
    logic [6:0] event_req_note;
    logic [7:0] event_req_velocity;

    int errors = 0;
    int ev_count = 0;

    logic [1:0] evt_type [0:63];
    logic [6:0] evt_note [0:63];
    logic [7:0] evt_vel  [0:63];

    logic [4:0] rst_seen = '0;

    always #5 clk = ~clk;

    piezo_peak #(
        .NUM_PIEZO        (5),
        .SYS_CLK_HZ       (1000),
        .THRESHOLD        (8'd20),
        .NOTE_OFF_MS      (50),
        .RETRIGGER_MS     (20),
        .PEAK_RST_CYCLES  (5)
    ) dut (
        .sys_clk            (clk),
        .rst_n              (rst_n),
        .sample_valid       (sample_valid),
        .sample_channel     (sample_channel),
        .sample_data        (sample_data),
        .piezo_ch_base      (3'd2),
        .base_note          (base_note),
        .all_off            (all_off),
        .peak_rst           (peak_rst),
        .event_req_valid    (event_req_valid),
        .event_req_ready    (event_req_ready),
        .event_req_type     (event_req_type),
        .event_req_note     (event_req_note),
        .event_req_velocity (event_req_velocity),
        .hit_debug          (hit_debug),
        .active_debug       (active_debug)
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

    // 记录 peak_rst 是否出现过
    always @(posedge clk) begin
        if (rst_n) begin
            rst_seen <= rst_seen | peak_rst;
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
    // 主测试
    //-------------------------------------------------------------------------
    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        //---------------------------------------------------------------------
        // 1) P0 (CH2) 轻击：NOTE_ON C4 + 自动 NOTE_OFF
        //---------------------------------------------------------------------
        send_sample(3'd2, 8'd100);
        wait_events(1, 100, "P0 NOTE_ON");
        check_event(0, 2'b01, 7'd60, "P0 NOTE_ON C4");
        check_velocity(0, 75, 95, "P0 light velocity");

        if (rst_seen[0] !== 1'b1) begin
            $display("FAIL: P0 peak_rst not pulsed");
            errors++;
        end else begin
            $display("PASS: P0 peak_rst pulsed");
        end

        wait_events(2, 200, "P0 auto NOTE_OFF");
        check_event(1, 2'b10, 7'd60, "P0 auto NOTE_OFF");

        //---------------------------------------------------------------------
        // 2) 防重复触发：5 拍内第二次击打应被忽略
        //---------------------------------------------------------------------
        send_sample(3'd2, 8'd100);
        wait_events(3, 100, "P0 retrigger first");
        check_event(2, 2'b01, 7'd60, "P0 retrigger first");

        send_sample(3'd2, 8'd150);   // 仍在 20 拍防重复窗口内
        repeat (10) @(posedge clk);
        if (ev_count != 3) begin
            $display("FAIL: retrigger guard failed, ev_count=%0d", ev_count);
            errors++;
        end else begin
            $display("PASS: retrigger guard ignored second hit");
        end

        wait_events(4, 200, "P0 retrigger auto OFF");
        check_event(3, 2'b10, 7'd60, "P0 retrigger auto OFF");

        // 防重复窗口结束后再次触发
        send_sample(3'd2, 8'd150);
        wait_events(5, 100, "P0 after guard NOTE_ON");
        check_event(4, 2'b01, 7'd60, "P0 after guard NOTE_ON");
        check_velocity(4, 120, 150, "P0 hard velocity");
        wait_events(6, 200, "P0 after guard NOTE_OFF");
        check_event(5, 2'b10, 7'd60, "P0 after guard NOTE_OFF");

        //---------------------------------------------------------------------
        // 3) P1 (CH3) -> D4 (62)
        //---------------------------------------------------------------------
        send_sample(3'd3, 8'd150);
        wait_events(7, 100, "P1 NOTE_ON");
        check_event(6, 2'b01, 7'd62, "P1 NOTE_ON D4");
        wait_events(8, 200, "P1 NOTE_OFF");
        check_event(7, 2'b10, 7'd62, "P1 NOTE_OFF D4");

        //---------------------------------------------------------------------
        // 4) P3 (CH5) -> G4 (67)
        //---------------------------------------------------------------------
        send_sample(3'd5, 8'd200);
        wait_events(9, 100, "P3 NOTE_ON");
        check_event(8, 2'b01, 7'd67, "P3 NOTE_ON G4");
        check_velocity(8, 190, 220, "P3 hard velocity");
        wait_events(10, 200, "P3 NOTE_OFF");
        check_event(9, 2'b10, 7'd67, "P3 NOTE_OFF G4");

        //---------------------------------------------------------------------
        // 5) P4 (CH6) -> A4 (69)
        //---------------------------------------------------------------------
        send_sample(3'd6, 8'd80);
        wait_events(11, 100, "P4 NOTE_ON");
        check_event(10, 2'b01, 7'd69, "P4 NOTE_ON A4");
        wait_events(12, 200, "P4 NOTE_OFF");
        check_event(11, 2'b10, 7'd69, "P4 NOTE_OFF A4");

        //---------------------------------------------------------------------
        // 6) ALL_NOTES_OFF：清除活跃状态，不再产生 NOTE_OFF
        //---------------------------------------------------------------------
        send_sample(3'd4, 8'd200);   // P2 -> E4
        wait_events(13, 100, "P2 NOTE_ON before ALL_OFF");
        check_event(12, 2'b01, 7'd64, "P2 NOTE_ON E4");

        repeat (5) @(posedge clk);
        @(negedge clk);
        all_off = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        all_off = 1'b0;

        repeat (80) @(posedge clk);
        if (ev_count != 13) begin
            $display("FAIL: ALL_OFF did not clear NOTE_OFF, ev_count=%0d",
                     ev_count);
            errors++;
        end else begin
            $display("PASS: ALL_OFF cleared active piezo notes");
        end

        if (active_debug !== 5'b00000) begin
            $display("FAIL: active_debug=%b after ALL_OFF", active_debug);
            errors++;
        end

        //---------------------------------------------------------------------
        // 7) 5 路 peak_rst 都至少出现过一次
        //    以上用到了 P0~P4 中除 P2 放电外都应出现；P2 也采过样。
        //---------------------------------------------------------------------
        if (rst_seen !== 5'b11111) begin
            $display("FAIL: not all peak_rst pulses seen, rst_seen=%b", rst_seen);
            errors++;
        end else begin
            $display("PASS: all 5 peak_rst pulses observed");
        end

        //---------------------------------------------------------------------
        // 8) hit_debug 应反映最近一次峰值
        //---------------------------------------------------------------------
        if (hit_debug[0] !== 1'b1) begin
            $display("FAIL: hit_debug[0]=%b, expected 1", hit_debug[0]);
            errors++;
        end else begin
            $display("PASS: hit_debug[0] reflects peak");
        end

        if (errors == 0) begin
            $display("TEST PASSED: tb_piezo_peak");
        end else begin
            $display("TEST FAILED: tb_piezo_peak, %0d error(s)", errors);
        end
        $finish;
    end

    initial begin
        #200_000;
        $display("TEST TIMEOUT: tb_piezo_peak");
        $finish;
    end

endmodule
