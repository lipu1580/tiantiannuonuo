//=============================================================================
// 文件   : tb_key_debounce.sv
// 功能   : 按键消抖测试：抖动抑制、单次按下/释放脉冲、长按不重复触发。
//=============================================================================
`timescale 1ns/1ps

module tb_key_debounce;

    localparam integer KEY_COUNT      = 4;
    localparam integer PRESS_CYCLES   = 5;
    localparam integer RELEASE_CYCLES = 8;

    logic       clk = 1'b0;
    logic       rst_n = 1'b0;
    logic [3:0] key_raw;
    logic [3:0] key_down;
    logic [3:0] key_pressed;
    logic [3:0] key_released;

    int press_cnt [4];
    int release_cnt [4];
    int errors = 0;

    always #5 clk = ~clk;

    key_debounce #(
        .KEY_COUNT      (KEY_COUNT),
        .PRESS_CYCLES   (PRESS_CYCLES),
        .RELEASE_CYCLES (RELEASE_CYCLES)
    ) dut (
        .sys_clk      (clk),
        .rst_n        (rst_n),
        .key_raw      (key_raw),
        .key_down     (key_down),
        .key_pressed  (key_pressed),
        .key_released (key_released)
    );

    always_ff @(posedge clk) begin
        for (int i = 0; i < 4; i++) begin
            if (key_pressed[i])  press_cnt[i]++;
            if (key_released[i]) release_cnt[i]++;
        end
    end

    task automatic check_counts(input int p0, input int r0, input string msg);
        if (press_cnt[0] !== p0 || release_cnt[0] !== r0) begin
            $display("FAIL [%s]: press=%0d (exp %0d), release=%0d (exp %0d)",
                     msg, press_cnt[0], p0, release_cnt[0], r0);
            errors++;
        end else begin
            $display("PASS [%s]: press=%0d release=%0d", msg, press_cnt[0], r0);
        end
    endtask

    initial begin
        key_raw = 4'b0000;
        for (int i = 0; i < 4; i++) begin
            press_cnt[i]   = 0;
            release_cnt[i] = 0;
        end

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        //---------------------------------------------------------------------
        // 1) 抖动不应产生事件：每次高电平不超过 3 拍
        //---------------------------------------------------------------------
        @(negedge clk); key_raw[0] = 1'b1;
        @(negedge clk); key_raw[0] = 1'b0;
        @(negedge clk); key_raw[0] = 1'b1;
        @(negedge clk); key_raw[0] = 1'b1;
        @(negedge clk); key_raw[0] = 1'b0;
        @(negedge clk); key_raw[0] = 1'b1;
        @(negedge clk); key_raw[0] = 1'b0;
        repeat (5) @(posedge clk);
        check_counts(0, 0, "bounce rejected");

        //---------------------------------------------------------------------
        // 2) 稳定按下 10 拍 -> 恰好一次 NOTE_ON 边沿
        //---------------------------------------------------------------------
        @(negedge clk); key_raw[0] = 1'b1;
        repeat (10) @(posedge clk);
        if (key_down[0] !== 1'b1) begin
            $display("FAIL: key_down[0] should be 1 after debounce");
            errors++;
        end
        check_counts(1, 0, "press once");

        //---------------------------------------------------------------------
        // 3) 长按 100 拍 -> 不重复触发
        //---------------------------------------------------------------------
        repeat (100) @(posedge clk);
        check_counts(1, 0, "long press no repeat");

        //---------------------------------------------------------------------
        // 4) 释放抖动 -> 只产生一次释放
        //---------------------------------------------------------------------
        @(negedge clk); key_raw[0] = 1'b0;
        @(negedge clk); key_raw[0] = 1'b1;
        @(negedge clk); key_raw[0] = 1'b0;
        @(negedge clk); key_raw[0] = 1'b0;
        @(negedge clk); key_raw[0] = 1'b1;
        @(negedge clk); key_raw[0] = 1'b0;
        repeat (20) @(posedge clk);
        if (key_down[0] !== 1'b0) begin
            $display("FAIL: key_down[0] should be 0 after release");
            errors++;
        end
        check_counts(1, 1, "release once");

        //---------------------------------------------------------------------
        // 5) 另一路按键独立工作，不受 key0 影响
        //---------------------------------------------------------------------
        @(negedge clk); key_raw[2] = 1'b1;
        repeat (20) @(posedge clk);
        if (press_cnt[2] !== 1) begin
            $display("FAIL: key2 press=%0d, expected 1", press_cnt[2]);
            errors++;
        end
        if (press_cnt[0] !== 1) begin
            $display("FAIL: key0 press changed to %0d", press_cnt[0]);
            errors++;
        end

        if (errors == 0) begin
            $display("TEST PASSED: tb_key_debounce");
        end else begin
            $display("TEST FAILED: tb_key_debounce, %0d error(s)", errors);
        end
        $finish;
    end

    initial begin
        #100_000;
        $display("TEST TIMEOUT: tb_key_debounce");
        $finish;
    end

endmodule
