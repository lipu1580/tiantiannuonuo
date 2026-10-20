`timescale 1ns/1ns

module voice #(
    parameter integer NOTE_W   = 7,       // 音符编号位宽
    parameter integer PHASE_W  = 32,      // DDS 相位位宽
    parameter integer SAMPLE_W = 16,      // DDS 波形位宽
    parameter integer OUTPUT_W = 24,      // 声部输出位宽
    parameter integer SAMPLE_RATE = 48_000, // 音频采样率
    parameter integer WAVE_ADDR_W = 10,   // 波表地址位宽
    parameter logic [15:0] ATTACK_STEP   = 16'd500,    // ADSR 起音步长
    parameter logic [15:0] DECAY_STEP    = 16'd30,     // ADSR 衰减步长
    parameter logic [15:0] SUSTAIN_LEVEL = 16'd42000, // ADSR 延音电平
    parameter logic [15:0] RELEASE_STEP  = 16'd40     // ADSR 释放步长
)(
    input  logic                         sys_clk, // 系统主时钟
    input  logic                         rst_n,   // 低有效复位
    input  logic                         audio_ce, // 生成一个新音频样本

    input  logic                         note_on, // 启动/重触发声部
    input  logic                         note_off, // 进入包络释放阶段
    input  logic [NOTE_W-1:0]            note_id, // MIDI 音符编号
    input  logic [7:0]                   velocity, // 触发力度
    input  logic [7:0]                   expression, // 持续音量/力度
    input  logic [11:0]                  pitch_bend, // 滑音值，2048 为中心
    input  logic [1:0]                   waveform_sel, // 振荡器波形选择

    output logic signed [OUTPUT_W-1:0]   voice_sample, // 当前声部有符号样本
    output logic                         sample_valid, // 当前声部样本有效
    output logic                         active, // 声部仍处于发声/释放状态
    output logic [15:0]                  envelope_value // 当前包络电平
);
    // note_on/note_off 为 sys_clk 域的单周期命令，必须独立于 audio_ce 接收。
    // note_on 时锁存 note_id/velocity；同周期 on/off 时 note_on 优先。
    // sample_valid 每个采样请求产生一次；非活跃声部也输出有效的零样本。
    // RELEASE 结束前 active 保持为 1。
endmodule
