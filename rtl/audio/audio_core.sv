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
    parameter logic [15:0] RELEASE_STEP  = 16'd40     // ADSR 释放步长
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
    // TODO: 连接内部模块；所有模块使用 sys_clk。
    // audio_ce 由外部 sample_tick_gen 提供，频率必须与 SAMPLE_RATE 一致。
    // expr_valid=1 时同步锁存 expression/pitch_bend/waveform_sel，其他周期保持。
    // 表情复位值：expression=255、pitch_bend=2048、waveform_sel=0。
    // pcm_valid && !pcm_ready 时保持 valid 及左右样本；单声道复制到左右。
endmodule
