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

    // 仅接口骨架：输出尚无驱动，不可作为可播放的核心使用。
endmodule
