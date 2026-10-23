//=============================================================================
// 文件   : tb_input_event_stub.sv
// 功能   : 固定演示事件源测试：序列顺序、握手背压、pattern 切换。
//=============================================================================
`timescale 1ns/1ps

module tb_input_event_stub;

    logic       clk = 1'b0;
    logic       rst_n = 1'b0;
    logic [1:0] test_pattern = 2'd0;

    logic       event_valid;
    logic       event_ready = 1'b0;
    logic [1:0] event_type;
    logic [6:0] event_note_id;
    logic [7:0] event_velocity;

    int errors = 0;
    int ev_idx = 0;

    // 期望序列（pattern 0）
    logic [1:0] exp_type [0:8];
    logic [6:0] exp_note [0:8];
    logic [7:0] exp_vel  [0:8];

    always #5 clk = ~clk;

    input_event_stub #(
        .SYS_CLK_HZ (1000)
    ) dut (
        .sys_clk       (clk),
        .rst_n         (rst_n),
        .test_pattern  (test_pattern),
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
            $display("[%0t] EVENT #%0d type=%0d note=%0d vel=%0d",
                     $time, ev_idx, event_type, event_note_id, event_velocity);
            if (ev_idx < 9) begin
                if (event_type !== exp_type[ev_idx] ||
                    event_note_id !== exp_note[ev_idx] ||
                    event_velocity !== exp_vel[ev_idx]) begin
                    $display("FAIL: event #%0d mismatch: got (%0d,%0d,%0d), exp (%0d,%0d,%0d)",
                             ev_idx, event_type, event_note_id, event_velocity,
                             exp_type[ev_idx], exp_note[ev_idx], exp_vel[ev_idx]);
                    errors++;
                end
            end
            ev_idx++;
        end
    end

    initial begin
        // pattern 0 期望值
        exp_type[0] = 2'b01; exp_note[0] = 7'd60; exp_vel[0] = 8'd180;
        exp_type[1] = 2'b01; exp_note[1] = 7'd64; exp_vel[1] = 8'd180;
        exp_type[2] = 2'b01; exp_note[2] = 7'd67; exp_vel[2] = 8'd180;
        exp_type[3] = 2'b01; exp_note[3] = 7'd72; exp_vel[3] = 8'd180;
        exp_type[4] = 2'b10; exp_note[4] = 7'd60; exp_vel[4] = 8'd0;
        exp_type[5] = 2'b10; exp_note[5] = 7'd64; exp_vel[5] = 8'd0;
        exp_type[6] = 2'b10; exp_note[6] = 7'd67; exp_vel[6] = 8'd0;
        exp_type[7] = 2'b10; exp_note[7] = 7'd72; exp_vel[7] = 8'd0;
        exp_type[8] = 2'b11; exp_note[8] = 7'd0;  exp_vel[8] = 8'd0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        //---------------------------------------------------------------------
        // 等待第一个事件，并检验背压期间字段稳定
        //---------------------------------------------------------------------
        begin : wait_first
            int guard;
            guard = 0;
            while (!event_valid && guard < 5000) begin
                @(posedge clk);
                guard++;
            end
            if (!event_valid) begin
                $display("FAIL: timeout waiting first event");
                errors++;
            end
        end

        if (event_type !== 2'b01 || event_note_id !== 7'd60 ||
            event_velocity !== 8'd180) begin
            $display("FAIL: first event fields wrong before ready");
            errors++;
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
        // 等待 pattern 0 的 9 个事件
        //---------------------------------------------------------------------
        begin : wait_all
            int guard;
            guard = 0;
            while (ev_idx < 9 && guard < 5000) begin
                @(posedge clk);
                guard++;
            end
            if (ev_idx < 9) begin
                $display("FAIL: only %0d/9 events received", ev_idx);
                errors++;
            end
        end

        //---------------------------------------------------------------------
        // 切换到 pattern 2，应该从 0 ms 重新开始
        //---------------------------------------------------------------------
        @(negedge clk);
        test_pattern = 2'd2;
        ev_idx = 0;

        // pattern 2 第一项：200 ms -> NOTE_ON 69 velocity 200
        exp_type[0] = 2'b01; exp_note[0] = 7'd69; exp_vel[0] = 8'd200;
        exp_type[1] = 2'b10; exp_note[1] = 7'd69; exp_vel[1] = 8'd0;

        begin : wait_pattern2
            int guard;
            guard = 0;
            while (ev_idx < 1 && guard < 5000) begin
                @(posedge clk);
                guard++;
            end
            if (ev_idx < 1) begin
                $display("FAIL: pattern 2 did not restart");
                errors++;
            end else begin
                $display("PASS: pattern 2 restarted and produced note 69");
            end
        end

        if (errors == 0) begin
            $display("TEST PASSED: tb_input_event_stub");
        end else begin
            $display("TEST FAILED: tb_input_event_stub, %0d error(s)", errors);
        end
        $finish;
    end

    initial begin
        #100_000;
        $display("TEST TIMEOUT: tb_input_event_stub");
        $finish;
    end

endmodule
