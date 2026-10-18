// 采样节拍接口骨架：仍使用 sys_clk，audio_ce 不是新时钟。
// SYS_CLK_HZ 必须由最终工程按实际时钟覆盖。
// 非整数分频应采用分数累加方式；例如 27 MHz / 48 kHz = 562.5。
// audio_ce 每次只拉高一个 sys_clk 周期，复位期间为 0。
module sample_tick_gen #(
    parameter integer SYS_CLK_HZ  = 27_000_000, // 输入 sys_clk 频率
    parameter integer SAMPLE_RATE = 48_000      // 目标采样率
)(
    input  logic sys_clk, // 系统主时钟
    input  logic rst_n,   // 低有效复位
    output logic audio_ce // 每个音频采样周期拉高一拍
);
    // TODO: 实现采样使能生成。
endmodule
