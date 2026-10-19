module dds_oscillator #(
    parameter integer PHASE_W  = 32, // 相位累加器位宽
    parameter integer SAMPLE_W = 16, // 波形样本位宽
    parameter integer WAVE_ADDR_W = 10 // 波表地址位宽
)(
    input  logic                         sys_clk, // 系统主时钟
    input  logic                         rst_n,   // 低有效复位
    input  logic                         audio_ce, // 推进一次相位并请求新样本
    input  logic [PHASE_W-1:0]           phase_increment, // 每个采样周期增加的相位
    input  logic [1:0]                   waveform_sel, // 波形类型
    output logic signed [SAMPLE_W-1:0]   waveform_sample, // 当前有符号波形值
    output logic                         waveform_valid // 波形值有效脉冲
);
    // audio_ce 请求更新相位；结果就绪后 waveform_valid 脉冲一个 sys_clk 周期。
    // TODO: 保证每个 audio_ce 对应一个输出，且在下一个采样请求前完成。
endmodule
