//=============================================================================
// 文件   : tb_adc_ads7830.sv
// 功能   : ADS7830 I2C 驱动测试：地址/命令时序、多通道读取、ACK 错误路径。
//=============================================================================
`timescale 1ns/1ps

module tb_adc_ads7830;

    logic       clk = 1'b0;
    logic       rst_n = 1'b0;

    logic       sample_req = 1'b0;
    logic [2:0] adc_channel_req = 3'd0;
    logic       sample_busy;
    logic       sample_valid;
    logic [7:0] sample_data;
    logic [2:0] sample_channel;
    logic       bus_error;

    logic       adc_scl;
    logic       adc_sda_oe;
    logic       adc_sda_i;
    wire        sda;

    int errors = 0;

    always #5 clk = ~clk;

    // 开漏总线 + 上拉
    assign sda = adc_sda_oe ? 1'b0 : 1'bz;
    pullup(sda);
    assign adc_sda_i = sda;

    ads7830_model u_model (
        .scl (adc_scl),
        .sda (sda)
    );

    adc_ads7830 #(
        .SYS_CLK_HZ  (1000),
        .I2C_HZ      (100_000),
        .QUARTER_DIV (2)
    ) dut (
        .sys_clk         (clk),
        .rst_n           (rst_n),
        .sample_req      (sample_req),
        .adc_channel_req (adc_channel_req),
        .sample_busy     (sample_busy),
        .sample_valid    (sample_valid),
        .sample_data     (sample_data),
        .sample_channel  (sample_channel),
        .bus_error       (bus_error),
        .adc_scl         (adc_scl),
        .adc_sda_oe      (adc_sda_oe),
        .adc_sda_i       (adc_sda_i)
    );

    //-------------------------------------------------------------------------
    // 请求一次采样并等待结果
    //-------------------------------------------------------------------------
    task automatic do_sample(input logic [2:0] ch, input logic [7:0] exp,
                             input string msg);
        int timeout;
        logic got;
        logic [7:0] got_data;
        logic [2:0] got_ch;

        @(negedge clk);
        sample_req      = 1'b1;
        adc_channel_req = ch;
        // 请求电平要覆盖至少一个 quarter tick（QDIV=2 -> 2 个时钟），
        // 否则状态机可能正好错过这个脉冲。
        repeat (4) @(negedge clk);
        sample_req      = 1'b0;

        got      = 1'b0;
        got_data = 8'h00;
        got_ch   = 3'd0;

        for (timeout = 0; timeout < 20000; timeout++) begin
            @(posedge clk);
            if (sample_valid) begin
                got      = 1'b1;
                got_data = sample_data;
                got_ch   = sample_channel;
                timeout  = 20000;
            end
        end

        if (!got) begin
            $display("FAIL [%s]: timeout waiting sample_valid", msg);
            errors++;
        end else if (got_data !== exp || got_ch !== ch) begin
            $display("FAIL [%s]: data=0x%02h ch=%0d, expected 0x%02h ch=%0d",
                     msg, got_data, got_ch, exp, ch);
            errors++;
        end else if (bus_error) begin
            $display("FAIL [%s]: bus_error asserted", msg);
            errors++;
        end else begin
            $display("PASS [%s]: data=0x%02h ch=%0d", msg, got_data, got_ch);
        end
    endtask

    //-------------------------------------------------------------------------
    // 发起一次请求，期望“不产生样本且报总线错误”
    //   用于 NACK / SDA 钳死 / 超时等错误路径。
    //-------------------------------------------------------------------------
    task automatic expect_fault(input logic [2:0] ch, input string msg);
        int  guard;
        logic got_valid;
        logic got_error;

        @(negedge clk);
        sample_req      = 1'b1;
        adc_channel_req = ch;
        repeat (4) @(negedge clk);
        sample_req      = 1'b0;

        got_valid = 1'b0;
        got_error = 1'b0;

        for (guard = 0; guard < 6000; guard++) begin
            @(posedge clk);
            if (sample_valid) got_valid = 1'b1;
            if (bus_error)    got_error = 1'b1;
            if (got_valid)    guard = 6000;
        end

        if (got_valid) begin
            $display("FAIL [%s]: fake sample_valid (data=0x%02h ch=%0d)", 
                     msg, sample_data, sample_channel);
            errors++;
        end else if (!got_error) begin
            $display("FAIL [%s]: no bus_error reported", msg);
            errors++;
        end else begin
            $display("PASS [%s]: bus_error raised, no sample produced", msg);
        end

        // 等状态机回到空闲再继续
        repeat (20) @(posedge clk);
    endtask

    initial begin
        // 预置各通道 ADC 值：每个通道给不同的值，才能验证通道编码是否正确。
        // 旧的模型 + 旧的驱动把 C2:C0 直接当通道号，两边错得一样，所以
        // “请求 CH n 读到 adc_val[n]”这件事其实没被真正验证过。
        u_model.adc_val[0] = 8'hA5;
        u_model.adc_val[1] = 8'h3C;
        u_model.adc_val[2] = 8'h00;
        u_model.adc_val[3] = 8'h5A;
        u_model.adc_val[4] = 8'hFF;
        u_model.adc_val[5] = 8'h81;
        u_model.adc_val[6] = 8'h7E;
        u_model.adc_val[7] = 8'h01;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        do_sample(3'd0, 8'hA5, "channel 0");
        do_sample(3'd1, 8'h3C, "channel 1");
        do_sample(3'd3, 8'h5A, "channel 3");
        do_sample(3'd4, 8'hFF, "channel 4");
        do_sample(3'd7, 8'h01, "channel 7");
        do_sample(3'd0, 8'hA5, "channel 0 repeat");

        //---------------------------------------------------------------------
        // 通道编码全覆盖：0~7 逐个请求，必须各拿到自己通道的值
        //   ADS7830 单端编码不是二进制顺序，漏掉其中任何一对都会串位：
        //   CH1<->CH2、CH3<->CH4、CH5<->CH6 是两两互换的高风险区。
        //---------------------------------------------------------------------
        do_sample(3'd0, 8'hA5, "enc CH0");
        do_sample(3'd1, 8'h3C, "enc CH1");
        do_sample(3'd2, 8'h00, "enc CH2");
        do_sample(3'd3, 8'h5A, "enc CH3");
        do_sample(3'd4, 8'hFF, "enc CH4");
        do_sample(3'd5, 8'h81, "enc CH5");
        do_sample(3'd6, 8'h7E, "enc CH6");
        do_sample(3'd7, 8'h01, "enc CH7");

        //---------------------------------------------------------------------
        // 错误路径 1：从机不应答（NACK）
        //   必须报 bus_error，且不能产生 sample_valid。
        //---------------------------------------------------------------------
        u_model.nack_en = 1'b1;
        expect_fault(3'd1, "NACK path");
        u_model.nack_en = 1'b0;

        // 恢复后应重新正常工作
        do_sample(3'd1, 8'h3C, "after NACK recovery");

        //---------------------------------------------------------------------
        // 错误路径 2：SDA 被持续拉低（总线钳死）
        //   旧实现在这种情况会给出 sample_valid=1、data=0、bus_error=0 —— 
        //   伪造的成功采样。现在必须报错且不出样本。
        //---------------------------------------------------------------------
        u_model.stuck_low = 1'b1;
        expect_fault(3'd2, "SDA stuck low");
        // 撤销故障并让从机模型恢复正常（相当于排除短路/重新上电从机）
        u_model.stuck_low = 1'b0;
        u_model.drive_en  = 1'b0;
        u_model.active    = 1'b0;

        // 总线恢复后必须能继续采样
        do_sample(3'd2, 8'h00, "after stuck-low recovery");
        do_sample(3'd5, 8'h81, "after stuck-low recovery CH5");

        if (errors == 0) begin
            $display("TEST PASSED: tb_adc_ads7830");
        end else begin
            $display("TEST FAILED: tb_adc_ads7830, %0d error(s)", errors);
        end
        $finish;
    end

    initial begin
        #500_000;
        $display("TEST TIMEOUT: tb_adc_ads7830");
        $finish;
    end

endmodule
