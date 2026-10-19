// Member 3 audio-output wrapper: PCM stream -> I2S -> MAX98357A.
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
    output logic i2s_bclk,
    output logic i2s_lrclk,
    output logic i2s_din,
    output logic underrun,
    output logic overflow
);
    logic sink_valid;
    logic sink_ready;
    logic signed [SAMPLE_W-1:0] sink_left;
    logic signed [SAMPLE_W-1:0] sink_right;

    pcm_sink #(
        .SAMPLE_W(SAMPLE_W),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_pcm_sink (
        .sys_clk(sys_clk),
        .rst_n(rst_n),
        .in_left(pcm_left),
        .in_right(pcm_right),
        .in_valid(pcm_valid),
        .in_ready(pcm_ready),
        .out_left(sink_left),
        .out_right(sink_right),
        .out_valid(sink_valid),
        .out_ready(sink_ready),
        .overflow(overflow)
    );

    i2s_tx #(
        .SYS_CLK_HZ(SYS_CLK_HZ),
        .SAMPLE_RATE(SAMPLE_RATE),
        .SAMPLE_W(SAMPLE_W),
        .SLOT_W(32)
    ) u_i2s_tx (
        .sys_clk(sys_clk),
        .rst_n(rst_n),
        .pcm_left(sink_left),
        .pcm_right(sink_right),
        .pcm_valid(sink_valid),
        .pcm_ready(sink_ready),
        .i2s_bclk(i2s_bclk),
        .i2s_lrclk(i2s_lrclk),
        .i2s_din(i2s_din),
        .underrun(underrun)
    );
endmodule
