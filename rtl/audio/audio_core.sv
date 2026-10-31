`timescale 1ns/1ns

module audio_core #(
    parameter integer VOICE_COUNT = 4,       // 复音声部数量
    parameter integer NOTE_W      = 7,       // 音符编号位宽
    parameter integer SAMPLE_W    = 16,      // PCM 输出位宽
    parameter integer SAMPLE_RATE = 48_000,  // 音频采样率
    parameter integer PHASE_W     = 32,      // DDS 相位位宽
    parameter integer VOICE_W     = 24,      // 内部声部样本位宽
    parameter integer WAVE_ADDR_W = 10,      // 波表地址位宽
    parameter integer PCM_FIFO_DEPTH = 4,    // PCM 缓冲深度
    parameter logic [7:0] MASTER_GAIN = 8'd255, // 默认主音量
    parameter logic [15:0] ATTACK_STEP   = 16'd500,    // ADSR 起音步长
    parameter logic [15:0] DECAY_STEP    = 16'd30,     // ADSR 衰减步长
    parameter logic [15:0] SUSTAIN_LEVEL = 16'd42000, // ADSR 延音电平
    parameter logic [15:0] RELEASE_STEP  = 16'd40,     // ADSR 释放步长
    parameter integer INPUT_W  = 24,
    parameter integer OUTPUT_W    = 24
)(
    input  logic                              sys_clk, // 系统主时钟
    input  logic                              rst_n,   // 低有效复位
    input  logic                              audio_ce, // 采样更新使能脉冲

    input  logic                              event_valid, // 置 1 表示事件有效，与 event_ready 同为 1 时接收
    output logic                              event_ready, // 置 1 表示核心可在本周期接收事件
    input  logic [1:0]                        event_type, // NOP/NOTE_ON/OFF/ALL_OFF
    input  logic [NOTE_W-1:0]                 event_note_id, // MIDI 音符编号
    input  logic [7:0]                        event_velocity, // 触发力度，0~255

    input  logic                              expr_valid, // 表情数据有效
    input  logic [7:0]                        expression, // 持续音量/力度
    input  logic [11:0]                       pitch_bend, // 滑音值，2048 为中心
    input  logic [1:0]                        waveform_sel, // 波形选择

    output logic                              pcm_valid, // 置 1 表示 PCM 有效，与 pcm_ready 同为 1 时传输
    input  logic                              pcm_ready, // 置 1 表示下游可在本周期接收 PCM
    output logic signed [SAMPLE_W-1:0]        pcm_left, // 左声道有符号 PCM
    output logic signed [SAMPLE_W-1:0]        pcm_right, // 右声道有符号 PCM

    input  logic                              test_mode, // 选择内部测试事件源
    input  logic [1:0]                        test_pattern, // 测试音符序列编号

    output logic [$clog2(VOICE_COUNT+1)-1:0]  active_voice_count, // 当前活跃声部数
    output logic [VOICE_COUNT-1:0]            voice_active // 各声部活跃标志
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
        .FIFO_DEPTH(PCM_FIFO_DEPTH /* default 4 */)
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
    // TODO: 连接内部模块；所有模块使用 sys_clk。
    // audio_ce 由外部 sample_tick_gen 提供，频率必须与 SAMPLE_RATE 一致。
    // expr_valid=1 时同步锁存 expression/pitch_bend/waveform_sel，其他周期保持。
    // 表情复位值：expression=255、pitch_bend=2048、waveform_sel=0。
    // pcm_valid && !pcm_ready 时保持 valid 及左右样本；单声道复制到左右。
endmodule
