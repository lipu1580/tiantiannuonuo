//=============================================================================
// 文件   : tb_expression_mapper.sv
// 功能   : 电位器映射单元测试。
//   覆盖：
//     1. 复位输出 2048（不弯音）
//     2. 中心死区：中心 ±2 LSB 内输出保持 2048（F-06）
//     3. 死区外线性映射与两端限幅
//     4. expr_valid / pot_raw
//     5. waveform_sel：test_mode 强制正弦，否则跟随按键
//=============================================================================
`timescale 1ns/1ps

module tb_expression_mapper;

    localparam integer POT_CH = 1;
    localparam integer CENTER = 128;
    localparam integer SPAN   = 16;
    localparam integer DZ     = 2;

    logic        clk = 1'b0;
    logic        rst_n = 1'b0;

    logic        sample_valid = 1'b0;
    logic [2:0]  sample_channel = 3'd0;
    logic [7:0]  sample_data = 8'd0;

    logic [1:0]  waveform_key_sel = 2'b00;
    logic        test_mode = 1'b0;

    logic [11:0] pitch_bend;
    logic [7:0]  pot_raw;
    logic        expr_valid;
    logic [1:0]  waveform_sel;

    int errors = 0;

    always #5 clk = ~clk;

    expression_mapper #(
        .FILTER_SHIFT    (2),
        .CENTER_RAW      (CENTER),
        .BEND_SPAN       (SPAN),
        .CENTER_DEADZONE (DZ)
    ) dut (
        .sys_clk        (clk),
        .rst_n          (rst_n),
        .sample_valid   (sample_valid),
        .sample_channel (sample_channel),
        .sample_data    (sample_data),
        .pot_channel    (3'(POT_CH)),
        .waveform_key_sel (waveform_key_sel),
        .test_mode      (test_mode),
        .pitch_bend     (pitch_bend),
        .pot_raw        (pot_raw),
        .expr_valid     (expr_valid),
        .waveform_sel   (waveform_sel)
    );

    // 每个测试点之间复位，让首个样本直接装载，避免滤波爬升影响期望值
    task automatic check_point(input logic [7:0] raw, input int expected,
                               input string msg);
        @(negedge clk);
        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        @(negedge clk);
        sample_valid   = 1'b1;
        sample_channel = 3'(POT_CH);
        sample_data    = raw;

        @(posedge clk);
        #1;

        if (int'(pitch_bend) != expected) begin
            $display("FAIL [%s]: raw=%0d pitch_bend=%0d, expected %0d",
                     msg, raw, pitch_bend, expected);
            errors++;
        end else begin
            $display("PASS [%s]: raw=%0d pitch_bend=%0d", msg, raw, pitch_bend);
        end

        if (int'(pot_raw) != int'(raw)) begin
            $display("FAIL [%s]: pot_raw=%0d, expected %0d", msg, pot_raw, raw);
            errors++;
        end

        @(negedge clk);
        sample_valid = 1'b0;
        repeat (2) @(posedge clk);
    endtask

    initial begin
        repeat (3) @(posedge clk);

        // 1) 复位默认值
        if (pitch_bend !== 12'd2048) begin
            $display("FAIL: reset pitch_bend=%0d, expected 2048", pitch_bend);
            errors++;
        end else begin
            $display("PASS: reset pitch_bend=2048");
        end
        if (expr_valid !== 1'b0) begin
            $display("FAIL: expr_valid should be 0 before first sample");
            errors++;
        end

        // 2) 中心死区（±2 LSB）
        check_point(8'd128, 2048, "center");
        check_point(8'd129, 2048, "center+1 in deadzone");
        check_point(8'd130, 2048, "center+2 in deadzone");
        check_point(8'd126, 2048, "center-2 in deadzone");

        // 3) 死区外线性映射
        check_point(8'd131, 2048 + 3 * 16, "center+3");
        check_point(8'd125, 2048 - 3 * 16, "center-3");
        check_point(8'd192, 2048 + 64 * 16, "raw 192");
        check_point(8'd64,  2048 - 64 * 16, "raw 64");

        // 4) 两端限幅
        check_point(8'd0,   0,    "raw 0");
        check_point(8'd255, 4080, "raw 255");

        // 5) expr_valid 在首次采样后置 1
        if (expr_valid !== 1'b1) begin
            $display("FAIL: expr_valid should be 1 after sampling");
            errors++;
        end else begin
            $display("PASS: expr_valid=1 after sampling");
        end

        // 6) waveform_sel
        test_mode       = 1'b1;
        waveform_key_sel = 2'b10;
        repeat (2) @(posedge clk);
        if (waveform_sel !== 2'b00) begin
            $display("FAIL: test_mode should force sine, got %b", waveform_sel);
            errors++;
        end else begin
            $display("PASS: test_mode forces sine");
        end

        test_mode       = 1'b0;
        waveform_key_sel = 2'b10;
        repeat (2) @(posedge clk);
        if (waveform_sel !== 2'b10) begin
            $display("FAIL: waveform_sel should follow key, got %b", waveform_sel);
            errors++;
        end else begin
            $display("PASS: waveform_sel follows key");
        end

        if (errors == 0) begin
            $display("TEST PASSED: tb_expression_mapper");
        end else begin
            $display("TEST FAILED: tb_expression_mapper, %0d error(s)", errors);
        end
        $finish;
    end

    initial begin
        #100_000;
        $display("TEST TIMEOUT: tb_expression_mapper");
        $finish;
    end

endmodule
