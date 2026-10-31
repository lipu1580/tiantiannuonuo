// pcm_ready 是输出，反馈给成员一；PCM 数据及 pcm_valid 由成员一驱动。
// 必须与 audio_core 使用同一 sys_clk 和同步采样率约定。
module audio_out_top #(
    parameter integer SYS_CLK_HZ = 27_000_000,
    parameter integer SAMPLE_RATE = 48_000,
    parameter integer SAMPLE_W = 16,
    parameter integer FIFO_DEPTH = 8
)(
    input  logic sys_clk,
    input  logic rst_n,
    input  logic signed [SAMPLE_W-1:0] pcm_left,
    input  logic signed [SAMPLE_W-1:0] pcm_right,
    input  logic pcm_valid,
    output logic pcm_ready,
    output logic i2s_bclk,  // 接 MAX98357A BCLK
    output logic i2s_lrclk, // 接 MAX98357A LRC / WS
    output logic i2s_din,   // 接 MAX98357A DIN
    output logic underrun, // 播放开始后的缺样，复位清除
    output logic overflow  // 输入握手协议违规，非正常背压；复位清除
);
    logic sink_valid, sink_ready;
    logic signed [SAMPLE_W-1:0] sink_left, sink_right;

    pcm_sink #(
        .SAMPLE_W(SAMPLE_W), .FIFO_DEPTH(FIFO_DEPTH)
    ) u_pcm_sink (
        .sys_clk(sys_clk), .rst_n(rst_n),
        .in_left(pcm_left), .in_right(pcm_right),
        .in_valid(pcm_valid), .in_ready(pcm_ready),
        .out_left(sink_left), .out_right(sink_right),
        .out_valid(sink_valid), .out_ready(sink_ready),
        .overflow(overflow)
    );

    i2s_tx #(
        .SYS_CLK_HZ(SYS_CLK_HZ), .SAMPLE_RATE(SAMPLE_RATE),
        .SAMPLE_W(SAMPLE_W), .SLOT_W(32)
    ) u_i2s_tx (
        .sys_clk(sys_clk), .rst_n(rst_n),
        .pcm_left(sink_left), .pcm_right(sink_right),
        .pcm_valid(sink_valid), .pcm_ready(sink_ready),
        .i2s_bclk(i2s_bclk), .i2s_lrclk(i2s_lrclk),
        .i2s_din(i2s_din), .underrun(underrun)
    );
endmodule
