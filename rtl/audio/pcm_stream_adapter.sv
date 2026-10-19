module pcm_stream_adapter #(
    parameter integer INPUT_W  = 24, // 混音输入位宽
    parameter integer SAMPLE_W = 16, // PCM 输出位宽
    parameter integer FIFO_DEPTH = 4 // 缓冲样本数
)(
    input  logic                         sys_clk, // 系统主时钟
    input  logic                         rst_n,   // 低有效复位
    input  logic                         sample_valid, // 输入混音样本有效
    input  logic signed [INPUT_W-1:0]    mixed_sample, // 单声道有符号混音样本

    output logic                         pcm_valid, // PCM 有效；与 pcm_ready 同为 1 时完成传输
    input  logic                         pcm_ready, // 下游可接收 PCM
    output logic signed [SAMPLE_W-1:0]   pcm_left, // 左声道 PCM 样本
    output logic signed [SAMPLE_W-1:0]   pcm_right, // 右声道 PCM 样本
    output logic                         overflow // 缓冲满时发生过丢样
);
    // sample_valid 接 mixer.mixed_valid，不能在 audio_ce 提前读取未完成的样本。
    // INPUT_W >= SAMPLE_W；约定保留高 SAMPLE_W 位，左右声道复制。
    // FIFO 满且本周期无出队时丢弃新输入，overflow 置 1 并保持至复位。
    // 满载时若同周期成功出队，仍应接收新样本；不覆盖被阻塞的队首。
    // pcm_valid && !pcm_ready 时，pcm_valid/pcm_left/pcm_right 必须保持。
endmodule
