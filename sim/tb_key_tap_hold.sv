//=============================================================================
// 文件   : tb_key_tap_hold.sv
// 功能   : 短按 / 长按互斥判决（验收项 A4b）。
//
//   仿真参数：SYS_CLK_HZ=1000、HOLD_MS=10 -> HOLD_CYC = 10 拍。
//   这样"600 ms"在仿真里就是 10 拍，测边界很方便。
//
//   覆盖：
//     1. 按住 5 拍松开  -> 只出 tap
//     2. 按住 10 拍（正好到点） -> 到点出 hold，松手不再出 tap
//     3. 按住 30 拍（很久） -> 仍然只出一次 hold
//     4. 复位中按键 -> 不出任何脉冲
//     5. 上电时 key_down 恒 0 -> 也不能凭空出 tap
//=============================================================================
`timescale 1ns/1ps

module tb_key_tap_hold;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic key_down = 1'b0;
    logic tap_pulse;
    logic hold_pulse;

    int errors = 0;
    int checks = 0;
    int tap_cnt  = 0;
    int hold_cnt = 0;

    always #5 clk = ~clk;

    key_tap_hold #(
        .SYS_CLK_HZ (1000),
        .HOLD_MS    (10)
    ) dut (
        .sys_clk    (clk),
        .rst_n      (rst_n),
        .key_down   (key_down),
        .tap_pulse  (tap_pulse),
        .hold_pulse (hold_pulse)
    );

    // 脉冲计数
    always @(posedge clk) begin
        if (rst_n) begin
            if (tap_pulse)  tap_cnt++;
            if (hold_pulse) hold_cnt++;
        end
    end

    task automatic clear_cnt;
        tap_cnt  = 0;
        hold_cnt = 0;
    endtask

    task automatic press_n(input int n);
        @(negedge clk);
        key_down = 1'b1;
        repeat (n) @(posedge clk);
        @(negedge clk);
        key_down = 1'b0;
        repeat (3) @(posedge clk);   // 留出脉冲观察窗口
    endtask

    task automatic expect_pulses(input int exp_tap, input int exp_hold,
                                 input string msg);
        checks++;
        if (tap_cnt !== exp_tap || hold_cnt !== exp_hold) begin
            $display("FAIL [%s]: tap=%0d hold=%0d, expected tap=%0d hold=%0d",
                     msg, tap_cnt, hold_cnt, exp_tap, exp_hold);
            errors++;
        end else begin
            $display("PASS [%s]: tap=%0d hold=%0d", msg, tap_cnt, hold_cnt);
        end
    endtask

    initial begin
        $display("========================================");
        $display(" tb_key_tap_hold: 短按/长按互斥（阈值 10 拍）");
        $display("========================================");

        //-------------------------------------------------------------
        // 0) 上电时 key_down 恒 0，不能凭空出 tap（armed 保护）
        //-------------------------------------------------------------
        key_down = 1'b0;
        repeat (20) @(posedge clk);
        clear_cnt;
        repeat (20) @(posedge clk);
        expect_pulses(0, 0, "idle 不出脉冲");

        //-------------------------------------------------------------
        // 1) 复位中按键：不出任何脉冲
        //-------------------------------------------------------------
        rst_n = 1'b0;
        key_down = 1'b1;
        repeat (30) @(posedge clk);
        if (tap_cnt != 0 || hold_cnt != 0) begin
            $display("FAIL [复位中按键]: tap=%0d hold=%0d, expected 0/0",
                     tap_cnt, hold_cnt);
            errors++;
        end else begin
            $display("PASS [复位中按键]: 无脉冲");
        end
        checks++;
        key_down = 1'b0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);
        clear_cnt;

        //-------------------------------------------------------------
        // 2) 按住 5 拍（< 阈值 10）松开 -> 短按
        //-------------------------------------------------------------
        press_n(5);
        expect_pulses(1, 0, "500ms 松开 -> 只出短按");

        //-------------------------------------------------------------
        // 3) 按住 10 拍（正好到点）-> 长按；松手不再补短按
        //-------------------------------------------------------------
        clear_cnt;
        press_n(10);
        expect_pulses(0, 1, "到点 -> 只出长按，松手不补短按");

        //-------------------------------------------------------------
        // 4) 按住 30 拍（很久）-> 仍然只出一次长按，不周期重复
        //-------------------------------------------------------------
        clear_cnt;
        press_n(30);
        expect_pulses(0, 1, "按住很久 -> 只出一次长按");

        //-------------------------------------------------------------
        // 5) 边界：按住 9 拍 -> 短按；按住 11 拍 -> 长按
        //-------------------------------------------------------------
        clear_cnt;
        press_n(9);
        expect_pulses(1, 0, "9 拍 -> 短按");

        clear_cnt;
        press_n(11);
        expect_pulses(0, 1, "11 拍 -> 长按");

        //-------------------------------------------------------------
        // 6) 连续两次短按、两次长按都能正常计数
        //-------------------------------------------------------------
        clear_cnt;
        press_n(3);
        press_n(3);
        expect_pulses(2, 0, "两次短按");

        clear_cnt;
        press_n(15);
        press_n(15);
        expect_pulses(0, 2, "两次长按");

        //-------------------------------------------------------------
        // 7) 重复按键后计时器必须清零：先长按，再短按，仍应出 tap
        //-------------------------------------------------------------
        clear_cnt;
        press_n(15);      // 长按
        press_n(4);       // 短按
        expect_pulses(1, 1, "长按后短按：计数已清零");

        $display("========================================");
        if (errors == 0) begin
            $display("TEST PASSED: tb_key_tap_hold (%0d checks)", checks);
        end else begin
            $display("TEST FAILED: tb_key_tap_hold, %0d error(s)", errors);
        end
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
