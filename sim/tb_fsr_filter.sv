//=============================================================================
// 文件   : tb_fsr_filter.sv
// 功能   : FSR 滤波/门限/力度映射测试。
//=============================================================================
`timescale 1ns/1ps

module tb_fsr_filter;

    logic       clk = 1'b0;
    logic       rst_n = 1'b0;
    logic       sample_valid = 1'b0;
    logic [2:0] sample_channel = 3'd0;
    logic [7:0] sample_data = 8'd0;

    logic [7:0] fsr_raw;
    logic [7:0] fsr_filtered;
    logic [7:0] velocity;
    logic       pressure_valid;
    logic       ready;

    int errors = 0;

    always #5 clk = ~clk;

    fsr_filter #(
        .FILTER_SHIFT (2),
        .NOISE_GATE   (8'd6),
        .GATE_HYST    (2)
    ) dut (
        .sys_clk        (clk),
        .rst_n          (rst_n),
        .sample_valid   (sample_valid),
        .sample_channel (sample_channel),
        .sample_data    (sample_data),
        .fsr_channel    (3'd0),
        .fsr_raw        (fsr_raw),
        .fsr_filtered   (fsr_filtered),
        .velocity       (velocity),
        .pressure_valid (pressure_valid),
        .ready          (ready)
    );

    task automatic send_sample(input logic [2:0] ch, input logic [7:0] data);
        @(negedge clk);
        sample_valid   = 1'b1;
        sample_channel = ch;
        sample_data    = data;
        @(negedge clk);
        sample_valid   = 1'b0;
    endtask

    task automatic check_u8(input logic [7:0] act, input logic [7:0] exp,
                            input string msg);
        if (act !== exp) begin
            $display("FAIL [%s]: got %0d, expected %0d", msg, act, exp);
            errors++;
        end else begin
            $display("PASS [%s]: %0d", msg, act);
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        //---------------------------------------------------------------------
        // 无压力
        //---------------------------------------------------------------------
        send_sample(3'd0, 8'd0);
        send_sample(3'd0, 8'd0);
        check_u8(fsr_filtered, 8'd0, "idle filtered");
        check_u8(velocity, 8'd0, "idle velocity");
        if (pressure_valid !== 1'b0) begin
            $display("FAIL: pressure_valid should be 0 when idle");
            errors++;
        end

        //---------------------------------------------------------------------
        // 静止噪声：在门限以下来回抖动，不得产生力度或压力有效
        //---------------------------------------------------------------------
        for (int i = 0; i < 20; i++) begin
            send_sample(3'd0, (i % 2) ? 8'd5 : 8'd2);
        end
        if (pressure_valid !== 1'b0) begin
            $display("FAIL: noise below gate triggered pressure_valid");
            errors++;
        end
        check_u8(velocity, 8'd0, "noise does not produce velocity");

        //---------------------------------------------------------------------
        // 第一次压力样本直接装载
        //---------------------------------------------------------------------
        send_sample(3'd0, 8'd200);
        check_u8(fsr_raw, 8'd200, "raw=200");
        check_u8(fsr_filtered, 8'd200, "filtered=200");
        if (pressure_valid !== 1'b1) begin
            $display("FAIL: pressure_valid should be 1 at 200");
            errors++;
        end
        if (velocity < 8'd190 || velocity > 8'd205) begin
            $display("FAIL: velocity=%0d, expected ~198", velocity);
            errors++;
        end else begin
            $display("PASS: velocity=%0d (~198)", velocity);
        end

        //---------------------------------------------------------------------
        // 非 FSR 通道必须被忽略
        //---------------------------------------------------------------------
        send_sample(3'd1, 8'd255);
        check_u8(fsr_filtered, 8'd200, "non-FSR channel ignored");
        check_u8(fsr_raw, 8'd200, "raw unchanged on other channel");

        //---------------------------------------------------------------------
        // 稳定压力保持
        //---------------------------------------------------------------------
        repeat (4) send_sample(3'd0, 8'd200);
        check_u8(fsr_filtered, 8'd200, "stable pressure");

        //---------------------------------------------------------------------
        // 释放：指数衰减到 0，最终压力无效
        //---------------------------------------------------------------------
        repeat (20) send_sample(3'd0, 8'd0);
        if (fsr_filtered > 8'd2) begin
            $display("FAIL: filtered=%0d after release, expected ~0", fsr_filtered);
            errors++;
        end else begin
            $display("PASS: filtered=%0d after release", fsr_filtered);
        end
        if (pressure_valid !== 1'b0) begin
            $display("FAIL: pressure_valid should be 0 after release");
            errors++;
        end
        check_u8(velocity, 8'd0, "velocity 0 after release");

        //---------------------------------------------------------------------
        // 轻按/中按/重按映射
        //---------------------------------------------------------------------
        send_sample(3'd0, 8'd40);
        repeat (9) send_sample(3'd0, 8'd40);
        if (velocity < 8'd20 || velocity > 8'd45) begin
            $display("FAIL: light press velocity=%0d", velocity);
            errors++;
        end else begin
            $display("PASS: light press velocity=%0d", velocity);
        end

        repeat (12) send_sample(3'd0, 8'd120);
        if (velocity < 8'd100 || velocity > 8'd135) begin
            $display("FAIL: medium press velocity=%0d", velocity);
            errors++;
        end else begin
            $display("PASS: medium press velocity=%0d", velocity);
        end

        repeat (16) send_sample(3'd0, 8'd240);
        if (velocity < 8'd235) begin
            $display("FAIL: heavy press velocity=%0d", velocity);
            errors++;
        end else begin
            $display("PASS: heavy press velocity=%0d", velocity);
        end

        if (errors == 0) begin
            $display("TEST PASSED: tb_fsr_filter");
        end else begin
            $display("TEST FAILED: tb_fsr_filter, %0d error(s)", errors);
        end
        $finish;
    end

    initial begin
        #100_000;
        $display("TEST TIMEOUT: tb_fsr_filter");
        $finish;
    end

endmodule
