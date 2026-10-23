// 采样节拍接口骨架：仍使用 sys_clk，audio_ce 不是新时钟。
// SYS_CLK_HZ 必须由最终工程按实际时钟覆盖。
// 非整数分频应采用分数累加方式；例如 27 MHz / 48 kHz = 562.5。
// audio_ce 每次只拉高一个 sys_clk 周期，复位期间为 0。
`timescale 1ns/1ns
module sample_tick_gen #(
    parameter integer SYS_CLK_HZ  = 27_000_000, // 输入 sys_clk 频率
    parameter integer SAMPLE_RATE = 48_000      // 目标采样率
)(
    input  logic sys_clk, // 系统主时钟
    input  logic rst_n,   // 低有效复位
    output logic audio_ce // 每个音频采样周期拉高一拍
);
    logic [31:0] accumulator; //累加器，用于长期稳定采集率在48KHz
    always_ff @( posedge sys_clk ) begin : Bresenham
        if (!rst_n) begin
            audio_ce <= 1'b0;
            accumulator <= 32'b0;
        end else begin
            if (accumulator + SAMPLE_RATE >= SYS_CLK_HZ) begin
                accumulator <= accumulator + SAMPLE_RATE - SYS_CLK_HZ;
                audio_ce <= 1'b1;
            end else begin
                accumulator <= accumulator + SAMPLE_RATE;
                audio_ce <= 1'b0;
            end 
        end
    end
endmodule

//27000000 / 48000 = 562.5 个 sys_clk 周期
//这里出现了小数，不能每次都固定等待562个或563个时钟周期
//所以使用了Bresenham累加法使采集率在长期来看是稳定在48KHz
