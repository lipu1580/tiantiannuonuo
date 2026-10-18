module mixer #(
    parameter integer VOICE_COUNT = 4, // 输入声部数量
    parameter integer VOICE_W     = 24, // 单路声部位宽
    parameter integer OUTPUT_W    = 24  // 混音结果位宽
)(
    input  logic                              sys_clk, // 系统主时钟
    input  logic                              rst_n,   // 低有效复位
    input  logic                              audio_ce, // 采样边界/更新使能
    input  logic                              sample_valid, // 全部声部样本已对齐有效
    input  logic signed [VOICE_W-1:0]         voice_sample [0:VOICE_COUNT-1], // 各声部样本数组
    input  logic [7:0]                        master_gain, // 总音量，0~255
    output logic signed [OUTPUT_W-1:0]        mixed_sample, // 混音后的有符号样本
    output logic                              mixed_valid // 混音结果有效脉冲
);
    // sample_valid 是全部 voice.sample_valid 的对齐结果，可同时采集所有声部样本。
    // audio_ce 只标记采样边界，不能代替上游结果有效信号。
    // mixed_valid 随混音结果脉冲一个 sys_clk 周期，内部累加需扩位并限幅。
endmodule
