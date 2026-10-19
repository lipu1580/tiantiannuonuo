//=============================================================================
// 文件   : ads7830_model.sv
// 功能   : ADS7830 I2C 从机行为模型（仅用于仿真）。
// 说明   :
//   - 支持：地址写 0x90、命令字、Repeated START、地址读 0x91、读 1 字节。
//   - 命令字高 3 位通道号：ch = cmd[6:4]，与 RTL 中 0x84|(ch<<4) 一致。
//   - adc_val[] 可由 testbench 通过层次化路径预置。
//   - SDA 为开漏：内部只驱动 0，释放时依赖外部上拉。
//=============================================================================
`timescale 1ns/1ps

module ads7830_model #(
    parameter logic [6:0] ADDR = 7'h48
)(
    input  logic scl,
    inout  wire  sda
);

    reg         drive_en = 1'b0;    // 1 = 拉低 SDA
    reg [7:0]   adc_val  [0:7];

    assign sda = drive_en ? 1'b0 : 1'bz;

    reg         active   = 1'b0;
    reg [4:0]   bit_cnt  = 5'd0;
    reg [7:0]   sh       = 8'd0;
    reg [7:0]   data_out = 8'd0;
    reg [7:0]   address_w;
    reg [7:0]   address_r;
    integer     byte_idx = 0;

    initial begin
        address_w = {ADDR, 1'b0};
        address_r = {ADDR, 1'b1};
    end

    //-------------------------------------------------------------------------
    // START / STOP 检测
    //-------------------------------------------------------------------------
    always @(negedge sda) begin
        if (scl === 1'b1) begin
            if (!active) begin
                byte_idx = 0;
                $display("[%0t] ADS7830 START", $time);
            end else begin
                $display("[%0t] ADS7830 REPEATED START", $time);
            end
            bit_cnt  = 0;
            active   = 1'b1;
            drive_en = 1'b0;
        end
    end

    always @(posedge sda) begin
        if (scl === 1'b1) begin
            active   = 1'b0;
            drive_en = 1'b0;
            byte_idx = 0;
            $display("[%0t] ADS7830 STOP", $time);
        end
    end

    //-------------------------------------------------------------------------
    // SCL 上升沿：采样主机数据 / 完成一个字节
    //-------------------------------------------------------------------------
    always @(posedge scl) begin
        if (active) begin
            if (bit_cnt < 8) begin
                sh      = {sh[6:0], sda};
                bit_cnt = bit_cnt + 1;
            end else begin
                // 第 9 个时钟（ACK）结束，一个字节传输完成
                bit_cnt = 0;
                $display("[%0t] ADS7830 byte[%0d]=0x%02h", $time, byte_idx, sh);

                if (byte_idx == 1) begin
                    // 命令字：{1,ch[2:0],0,1,00}
                    data_out = adc_val[sh[6:4]];
                    $display("         cmd=0x%02h ch=%0d -> data=0x%02h",
                             sh, sh[6:4], data_out);
                end

                byte_idx = byte_idx + 1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // SCL 下降沿：写字节的 ACK / 读字节的数据位
    //-------------------------------------------------------------------------
    always @(negedge scl) begin
        if (active) begin
            if (bit_cnt == 8) begin
                if (byte_idx <= 2) begin
                    drive_en = 1'b1;        // 从机 ACK：拉低
                end else begin
                    drive_en = 1'b0;        // 读数据阶段由主机 ACK/NACK
                end
            end else if (byte_idx == 3) begin
                drive_en = ~data_out[7];    // 0 拉低，1 释放
                data_out = {data_out[6:0], 1'b0};
            end else begin
                drive_en = 1'b0;
            end
        end
    end

endmodule
