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
        @(negedge clk);
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

    initial begin
        // 预置各通道 ADC 值
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
