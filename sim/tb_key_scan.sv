//=============================================================================
// 文件   : tb_key_scan.sv
// 功能   : 4x4 矩阵扫描单元测试：行扫描顺序、行驻留、按键位置映射。
// 运行   : iverilog -g2012 -Irtl/common -o build/tb_key_scan.vvp \
//              sim/tb_key_scan.sv rtl/input/key_scan.sv
//=============================================================================
`timescale 1ns/1ps

module tb_key_scan;

    logic        clk = 1'b0;
    logic        rst_n = 1'b0;
    logic [3:0]  key_row;
    logic [3:0]  key_col;
    logic [15:0] raw_key_state;
    logic [1:0]  scan_row_debug;
    logic        scan_sample_debug;

    logic [15:0] pressed;       // bit[row*4+col] = 按下

    int errors = 0;

    always #5 clk = ~clk;

    //-------------------------------------------------------------------------
    // 4x4 上拉矩阵模型：选中行拉低，按下的键把对应列拉低
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

    key_scan #(
        .SYS_CLK_HZ     (1000),
        .ROW_COUNT      (4),
        .COL_COUNT      (4),
        .ROW_DWELL_CYC  (8),
        .SETTLE_CYC     (2),
        .ROW_ACTIVE_LOW (1'b1),
        .COL_ACTIVE_LOW (1'b1)
    ) dut (
        .sys_clk           (clk),
        .rst_n             (rst_n),
        .key_row           (key_row),
        .key_col           (key_col),
        .raw_key_state     (raw_key_state),
        .scan_row_debug    (scan_row_debug),
        .scan_sample_debug (scan_sample_debug)
    );

    task automatic check_raw(input logic [15:0] exp, input string msg);
        if (raw_key_state !== exp) begin
            $display("FAIL [%s]: raw=0x%04h expected=0x%04h (time=%0t)",
                     msg, raw_key_state, exp, $time);
            errors++;
        end else begin
            $display("PASS [%s]: raw=0x%04h", msg, raw_key_state);
        end
    endtask

    task automatic wait_frame();
        // 4 行 x 8 周期，留出两帧余量
        repeat (80) @(posedge clk);
    endtask

    initial begin
        pressed = '0;

        repeat (10) @(posedge clk);
        rst_n = 1'b1;

        wait_frame();
        check_raw(16'h0000, "reset no key");

        // 单键 (0,0) -> bit0
        pressed[0*4+0] = 1'b1;
        wait_frame();
        check_raw(16'h0001, "key(0,0)");

        // 再按 (2,3) -> bit 2*4+3 = 11
        pressed[2*4+3] = 1'b1;
        wait_frame();
        check_raw(16'h0801, "key(0,0)+(2,3)");

        // 释放 (0,0)
        pressed[0*4+0] = 1'b0;
        wait_frame();
        check_raw(16'h0800, "release(0,0)");

        // 释放 (2,3)
        pressed[2*4+3] = 1'b0;
        wait_frame();
        check_raw(16'h0000, "release all");

        // 同一行多键
        pressed[1*4+0] = 1'b1;
        pressed[1*4+1] = 1'b1;
        pressed[1*4+2] = 1'b1;
        pressed[1*4+3] = 1'b1;
        wait_frame();
        check_raw(16'h00F0, "row1 all keys");

        if (errors == 0) begin
            $display("TEST PASSED: tb_key_scan");
        end else begin
            $display("TEST FAILED: tb_key_scan, %0d error(s)", errors);
        end
        $finish;
    end

    // 超时保护
    initial begin
        #200_000;
        $display("TEST TIMEOUT: tb_key_scan");
        $finish;
    end

endmodule
