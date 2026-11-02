`timescale 1ns/1ns

// 混音后单声道效果器接口草案：仅声明 parameter 和端口，尚未实现功能。
// 路径：mixer -> audio_fx_chain -> pcm_stream_adapter。
// 公共 cfg 总线在 audio_core_expr 内统一译码，本模块接收完整参数快照。
module audio_fx_chain #(
    parameter integer SAMPLE_W = 24,       // 内部输入/输出位宽，保持原 PCM 数值标度
    parameter integer SAMPLE_RATE = 48_000, // 每秒有效输入样本数
    parameter integer DELAY_DEPTH = 4096    // 延迟模式缓冲容量，单位：样本
)(
    input  logic                       sys_clk,
    input  logic                       rst_n,             // 低有效，同步复位

    // 音频接口没有 ready：每个 in_valid 接受一个样本，之后输出一次 out_valid。
    // in_valid 接 mixer.mixed_valid，不直接接 audio_ce；内部必须满足采样吞吐。
    input  logic                       in_valid,
    input  logic signed [SAMPLE_W-1:0] in_sample,
    output logic                       out_valid,
    output logic signed [SAMPLE_W-1:0] out_sample,

    // 控制快照：ctrl_valid && ctrl_ready 时接受全部字段。
    // 阻塞时保持 valid 及字段；接受后在后续输入样本边界应用。
    input  logic                       ctrl_valid,
    output logic                       ctrl_ready,
    input  logic [1:0]                ctrl_mode,          // 0 旁路，1 延迟，2 合唱，3 混响
    input  logic [7:0]                ctrl_wet_gain,      // Q0.8，0～128
    input  logic [11:0]               ctrl_delay_samples, // 1～DELAY_DEPTH-1，仅延迟模式使用
    input  logic [7:0]                ctrl_feedback_gain, // Q0.8，0～128，仅延迟模式使用
    input  logic                       ctrl_clear,         // 随一次握手接受的清尾音命令

    // 忙于初始化/切换/清理时 ctrl_ready=0；音频样本仍须持续处理。
    output logic                       fx_busy,
    output logic                       fx_initialized,     // 当前效果工作存储已就绪
    output logic [1:0]                fx_active_mode      // 当前已完成应用的模式
);

    // 仅接口骨架：无旁路、RAM、效果算法或控制状态机，输出尚无驱动。
endmodule
