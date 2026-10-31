//=============================================================================
// 文件   : tb_input_event_stub.sv
// 功能   : 固定演示事件源测试。
//   覆盖：
//     1. pattern 0 的 9 个事件顺序/字段
//     2. 背压期间事件字段保持（不撤销、不改写）
//     3. 背压期间切换 test_pattern：未接收事件必须保留（评审清单第 6 项），
//        之后先补 ALL_NOTES_OFF 再按新序列运行
//     4. restart 输入（input_top 在切换事件源时使用）
//=============================================================================
`timescale 1ns/1ps

module tb_input_event_stub;

    logic       clk = 1'b0;
    logic       rst_n = 1'b0;
    logic [1:0] test_pattern = 2'd0;
    logic       restart = 1'b0;

    logic       event_valid;
    logic       event_ready = 1'b0;
    logic [1:0] event_type;
    logic [6:0] event_note_id;
    logic [7:0] event_velocity;

    int errors = 0;
    int ev_count = 0;

    logic [1:0] log_type [0:255];
    logic [6:0] log_note [0:255];
    logic [7:0] log_vel  [0:255];

    always #5 clk = ~clk;

    input_event_stub #(
        .SYS_CLK_HZ (1000)
    ) dut (
        .sys_clk       (clk),
        .rst_n         (rst_n),
        .test_pattern  (test_pattern),
        .restart       (restart),
        .event_valid   (event_valid),
        .event_ready   (event_ready),
        .event_type    (event_type),
        .event_note_id (event_note_id),
        .event_velocity(event_velocity)
    );

    //-------------------------------------------------------------------------
    // 事件监视器
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && event_valid && event_ready) begin
            log_type[ev_count] = event_type;
            log_note[ev_count] = event_note_id;
            log_vel[ev_count]  = event_velocity;
            $display("[%0t] EVENT #%0d type=%0d note=%0d vel=%0d",
                     $time, ev_count, event_type, event_note_id, event_velocity);
            ev_count++;
        end
    end

    //-------------------------------------------------------------------------
    // 辅助任务
    //-------------------------------------------------------------------------
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

    task automatic wait_valid(input int timeout, input string msg);
        int guard;
        guard = 0;
        while (!event_valid && guard < timeout) begin
            @(posedge clk);
            guard++;
        end
        if (!event_valid) begin
            $display("FAIL [%s]: event_valid never asserted", msg);
            errors++;
        end
    endtask

    task automatic check_event(input int idx, input logic [1:0] t,
                               input logic [6:0] n, input logic [7:0] v,
                               input string msg);
        if (log_type[idx] !== t || log_note[idx] !== n || log_vel[idx] !== v) begin
            $display("FAIL [%s]: event%0d = (%0d,%0d,%0d), expected (%0d,%0d,%0d)",
                     msg, idx, log_type[idx], log_note[idx], log_vel[idx],
                     t, n, v);
            errors++;
        end else begin
            $display("PASS [%s]: event%0d = (%0d,%0d,%0d)", msg, idx, t, n, v);
        end
    endtask

    initial begin
        logic [1:0] held_type;
        logic [6:0] held_note;
        logic [7:0] held_vel;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        //---------------------------------------------------------------------
        // 1) 第一个事件在背压下必须保持稳定
        //---------------------------------------------------------------------
        wait_valid(5000, "first event");
        if (event_type !== 2'b01 || event_note_id !== 7'd60 ||
            event_velocity !== 8'd180) begin
            $display("FAIL: first event fields wrong before ready (%0d,%0d,%0d)",
                     event_type, event_note_id, event_velocity);
            errors++;
        end else begin
            $display("PASS: first event = NOTE_ON 60 vel 180");
        end

        repeat (50) @(posedge clk);
        if (!event_valid || event_type !== 2'b01 || event_note_id !== 7'd60) begin
            $display("FAIL: event changed during backpressure");
            errors++;
        end else begin
            $display("PASS: event held stable for 50 cycles under backpressure");
        end

        // 接受第一个事件，然后放开背压
        @(negedge clk);
        event_ready = 1'b1;

        //---------------------------------------------------------------------
        // 2) pattern 0 的 9 个事件顺序
        //---------------------------------------------------------------------
        wait_events(9, 20000, "pattern 0 sequence");

        check_event(0, 2'b01, 7'd60, 8'd180, "pattern0 #0 C4");
        check_event(1, 2'b01, 7'd64, 8'd180, "pattern0 #1 E4");
        check_event(2, 2'b01, 7'd67, 8'd180, "pattern0 #2 G4");
        check_event(3, 2'b01, 7'd72, 8'd180, "pattern0 #3 C5");
        check_event(4, 2'b10, 7'd60, 8'd0,   "pattern0 #4 C4 off");
        check_event(5, 2'b10, 7'd64, 8'd0,   "pattern0 #5 E4 off");
        check_event(6, 2'b10, 7'd67, 8'd0,   "pattern0 #6 G4 off");
        check_event(7, 2'b10, 7'd72, 8'd0,   "pattern0 #7 C5 off");
        check_event(8, 2'b11, 7'd0,  8'd0,   "pattern0 #8 ALL_OFF");

        //---------------------------------------------------------------------
        // 3) 背压期间切换 pattern：未接收事件不能被撤销（清单第 6 项）
        //---------------------------------------------------------------------
        @(negedge clk);
        event_ready = 1'b0;

        wait_valid(20000, "next pattern0 event");
        held_type = event_type;
        held_note = event_note_id;
        held_vel  = event_velocity;
        $display("       pending event before switch: (%0d,%0d,%0d)",
                 held_type, held_note, held_vel);

        repeat (10) @(posedge clk);
        @(negedge clk);
        test_pattern = 2'd2;                 // 背压中切换序列
        repeat (30) @(posedge clk);

        if (!event_valid) begin
            $display("FAIL: pattern switch revoked the pending event");
            errors++;
        end else if (event_type !== held_type || event_note_id !== held_note ||
                     event_velocity !== held_vel) begin
            $display("FAIL: pattern switch changed pending fields: (%0d,%0d,%0d) -> (%0d,%0d,%0d)",
                     held_type, held_note, held_vel,
                     event_type, event_note_id, event_velocity);
            errors++;
        end else begin
            $display("PASS: pending event survived pattern switch");
        end

        // 放开背压：先把上一段序列的 ALL_NOTES_OFF 送完，再按新序列运行
        @(negedge clk);
        event_ready = 1'b1;
        wait_events(12, 20000, "restart ALL_OFF + pattern2 first event");

        check_event(9,  held_type, held_note, held_vel, "pending event delivered");
        check_event(10, 2'b11, 7'd0,  8'd0,   "restart ALL_NOTES_OFF");
        check_event(11, 2'b01, 7'd69, 8'd200, "pattern2 first event A4");

        //---------------------------------------------------------------------
        // 4) restart 输入：立即复位序列（input_top 切换事件源时使用）
        //---------------------------------------------------------------------
        @(negedge clk);
        event_ready = 1'b0;
        wait_valid(20000, "event before restart");
        repeat (5) @(posedge clk);
        @(negedge clk);
        restart = 1'b1;
        @(negedge clk);
        restart = 1'b0;
        repeat (5) @(posedge clk);
        if (event_valid) begin
            $display("FAIL: restart did not clear the pending event");
            errors++;
        end else begin
            $display("PASS: restart clears pending event and rewinds sequence");
        end
        @(negedge clk);
        event_ready = 1'b1;

        if (errors == 0) begin
            $display("TEST PASSED: tb_input_event_stub");
        end else begin
            $display("TEST FAILED: tb_input_event_stub, %0d error(s)", errors);
        end
        $finish;
    end

    initial begin
        #2_000_000;
        $display("TEST TIMEOUT: tb_input_event_stub");
        $finish;
    end

endmodule
