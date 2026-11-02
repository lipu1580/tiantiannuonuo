`timescale 1ns/1ns

// 扩展音频核心接口草案：仅声明 parameter 和端口，尚未实现功能。
// 协议见根目录《成员1_扩展音频接口协议.md》。旧 audio_core 接口保持不变。
module audio_core_expr #(
    parameter integer VOICE_COUNT = 4,             // 复音声部数量
    parameter integer NOTE_W = 7,                  // MIDI 音符编号位宽
    parameter integer SAMPLE_W = 16,               // 对外 PCM 样本位宽
    parameter integer SAMPLE_RATE = 48_000,        // 采样率，须与 audio_ce 一致
    parameter integer PHASE_W = 32,                // DDS 相位位宽
    parameter integer VOICE_W = 24,                // 内部声部样本位宽
    parameter integer WAVE_ADDR_W = 10,            // 波表地址位宽
    parameter integer PCM_FIFO_DEPTH = 4,          // PCM 输出 FIFO 深度
    parameter logic [7:0] MASTER_GAIN = 8'd255,     // 固定主音量，本轮不接配置总线
    parameter logic [15:0] ATTACK_STEP = 16'd500,   // 固定 ADSR 起音步长
    parameter logic [15:0] DECAY_STEP = 16'd30,     // 固定 ADSR 衰减步长
    parameter logic [15:0] SUSTAIN_LEVEL = 16'd42000,// 固定 ADSR 延音电平
    parameter logic [15:0] RELEASE_STEP = 16'd40,   // 固定 ADSR 释放步长
    parameter integer INPUT_W = 24,                // PCM 适配器输入位宽；本轮等于 OUTPUT_W
    parameter integer OUTPUT_W = 24,               // mixer / 效果器样本位宽
    parameter integer FX_DELAY_DEPTH = 4096        // 延迟模式缓冲容量，单位：样本
)(
    input  logic                             sys_clk,
    input  logic                             rst_n,             // 低有效，同步复位
    input  logic                             audio_ce,          // 单周期采样使能

    // 原事件接口：sys_clk 上升沿 event_valid && event_ready 接受一次。
    input  logic                             event_valid,
    output logic                             event_ready,
    input  logic [1:0]                       event_type,
    input  logic [NOTE_W-1:0]                event_note_id,
    input  logic [7:0]                       event_velocity,

    // 原表情接口：expr_valid 有效时同时锁存三个字段，无 ready。
    input  logic                             expr_valid,
    input  logic [7:0]                       expression,         // 0～255
    input  logic [11:0]                      pitch_bend,         // 0/2048/4095 对应 -2/0/+2 半音
    input  logic [1:0]                       waveform_sel,       // 00 正弦，01 管风琴类，10 拨弦类，11 静音

    // 新配置接口：地址 8 位、数据 32 位；读数据为当前地址的组合读回。
    // 写寄存器只在 cfg_valid && cfg_ready && cfg_write 时更新。
    // cfg_valid && !cfg_ready 时，发送方保持 valid 及全部请求字段。
    input  logic                             cfg_valid,
    output logic                             cfg_ready,
    input  logic                             cfg_write,          // 1 写，0 读
    input  logic [7:0]                       cfg_addr,           // 字节偏移，按 4 字节对齐
    input  logic [31:0]                      cfg_wdata,
    output logic [31:0]                      cfg_rdata,

    // 原 PCM 接口：阻塞时保持 valid 和左右样本；单声道复制到左右。
    output logic                             pcm_valid,
    input  logic                             pcm_ready,
    output logic signed [SAMPLE_W-1:0]       pcm_left,
    output logic signed [SAMPLE_W-1:0]       pcm_right,

    input  logic                             test_mode,
    input  logic [1:0]                       test_pattern,
    output logic [$clog2(VOICE_COUNT+1)-1:0] active_voice_count,
    output logic [VOICE_COUNT-1:0]           voice_active
);

    logic test_event_valid, routed_event_valid, routed_event_ready, test_event_ready;
    logic [1:0] test_event_type, routed_event_type;
    logic [NOTE_W-1:0] test_event_note_id, routed_event_note_id;
    logic [7:0] test_event_velocity, routed_event_velocity;
    logic [15:0]                       voice_envelope [0:VOICE_COUNT-1];
    logic [VOICE_COUNT-1:0]            voice_start;
    logic [VOICE_COUNT-1:0]            voice_release;
    logic [NOTE_W-1:0]                 voice_note_id [0:VOICE_COUNT-1];
    logic [7:0]                        voice_velocity [0:VOICE_COUNT-1];
    logic signed [OUTPUT_W-1:0]                voice_sample [0:VOICE_COUNT-1];
    logic [VOICE_COUNT-1:0]            voice_sample_valid;
    logic                              mixer_sample_valid;
    logic signed [OUTPUT_W-1:0]        mixed_sample;
    logic                              mixed_valid;
    logic [7:0]                        expression_reg;
    logic [11:0]                       pitch_bend_reg;
    logic [1:0]                        waveform_sel_reg;

    assign mixer_sample_valid = &voice_sample_valid;

    audio_test_source #(
        .NOTE_W     (NOTE_W /* default 7 */),
        .SAMPLE_RATE(SAMPLE_RATE /* default 48_000 */)
     ) audio_test_source (
        .sys_clk       (sys_clk),
        .rst_n         (rst_n),
        .audio_ce      (audio_ce),
        .enable        (test_mode),
        .test_pattern  (test_pattern),
        .event_valid   (test_event_valid),
        .event_ready   (test_event_ready),
        .event_type    (test_event_type),
        .event_note_id (test_event_note_id),
        .event_velocity(test_event_velocity)
    );

    event_router #(
        .NOTE_W(NOTE_W /* default 7 */)
     ) event_router (
        .sys_clk              (sys_clk),
        .rst_n                (rst_n),
        .test_mode            (test_mode),
        .event_valid          (event_valid),
        .event_ready          (event_ready),
        .event_type           (event_type),
        .event_note_id        (event_note_id),
        .event_velocity       (event_velocity),
        .test_event_valid     (test_event_valid),
        .test_event_ready     (test_event_ready),
        .test_event_type      (test_event_type),
        .test_event_note_id   (test_event_note_id),
        .test_event_velocity  (test_event_velocity),
        .routed_event_valid   (routed_event_valid),
        .routed_event_ready   (routed_event_ready),
        .routed_event_type    (routed_event_type),
        .routed_event_note_id (routed_event_note_id),
        .routed_event_velocity(routed_event_velocity)
    );

    voice_manager #(
        .VOICE_COUNT(VOICE_COUNT /* default 4 */),
        .NOTE_W     (NOTE_W /* default 7 */)
     ) voice_manager (
        .sys_clk           (sys_clk),
        .rst_n             (rst_n),
        .event_valid       (routed_event_valid),
        .event_ready       (routed_event_ready),
        .event_type        (routed_event_type),
        .event_note_id     (routed_event_note_id),
        .event_velocity    (routed_event_velocity),
        .voice_active      (voice_active),
        .voice_envelope    (voice_envelope),
        .voice_start       (voice_start),
        .voice_release     (voice_release),
        .voice_note_id     (voice_note_id),
        .voice_velocity    (voice_velocity),
        .active_voice_count(active_voice_count)
    );

    generate
    for (genvar i = 0; i < VOICE_COUNT; i++) begin : gen_voice
        voice #(
            .NOTE_W      (NOTE_W),
            .PHASE_W     (PHASE_W),
            .SAMPLE_W    (SAMPLE_W),
            .OUTPUT_W    (VOICE_W),
            .SAMPLE_RATE (SAMPLE_RATE),
            .WAVE_ADDR_W (WAVE_ADDR_W),
            .ATTACK_STEP   (ATTACK_STEP),
            .DECAY_STEP    (DECAY_STEP),
            .SUSTAIN_LEVEL (SUSTAIN_LEVEL),
            .RELEASE_STEP  (RELEASE_STEP)
        ) u_voice (
            .sys_clk        (sys_clk),
            .rst_n          (rst_n),
            .audio_ce       (audio_ce),

            .note_on        (voice_start[i]),
            .note_off       (voice_release[i]),
            .note_id        (voice_note_id[i]),
            .velocity       (voice_velocity[i]),
            .expression     (expression_reg),
            .pitch_bend     (pitch_bend_reg),
            .waveform_sel   (waveform_sel_reg),

            .voice_sample   (voice_sample[i]),
            .sample_valid   (voice_sample_valid[i]),
            .active         (voice_active[i]),
            .envelope_value (voice_envelope[i])
        );
        end
    endgenerate

    mixer #(
        .VOICE_COUNT(VOICE_COUNT /* default 4 */),
        .VOICE_W    (VOICE_W /* default 24 */),
        .OUTPUT_W   (OUTPUT_W /* default 24 */)
     ) mixer (
        .sys_clk     (sys_clk),
        .rst_n       (rst_n),
        .audio_ce    (audio_ce),
        .sample_valid(mixer_sample_valid),
        .voice_sample(voice_sample),
        .master_gain (MASTER_GAIN),
        .mixed_sample(mixed_sample),
        .mixed_valid (mixed_valid)
    );

    pcm_stream_adapter #(
        .INPUT_W   (INPUT_W /* default 24 */),
        .SAMPLE_W  (SAMPLE_W /* default 16 */),
        .FIFO_DEPTH(PCM_FIFO_DEPTH /* default 4 */),
        .MIX_SHIFT (0) // mixer 已包含四声部的 /4 衰减，这里只限幅。
     ) pcm_stream_adapter (
        .sys_clk     (sys_clk),
        .rst_n       (rst_n),
        .sample_valid(mixed_valid),
        .mixed_sample(mixed_sample),
        .pcm_valid   (pcm_valid),
        .pcm_ready   (pcm_ready),
        .pcm_left    (pcm_left),
        .pcm_right   (pcm_right),
        .overflow    ()
    );

    always_ff @(posedge sys_clk) begin
    if (!rst_n) begin
        expression_reg   <= 8'd255;
        pitch_bend_reg   <= 12'd2048;
        waveform_sel_reg <= 2'd0;
    end
    else if (expr_valid) begin
        expression_reg   <= expression;
        pitch_bend_reg   <= pitch_bend;
        waveform_sel_reg <= waveform_sel;
    end
end

    // 仅接口骨架：输出尚无驱动，不可作为可播放的核心使用。
endmodule
