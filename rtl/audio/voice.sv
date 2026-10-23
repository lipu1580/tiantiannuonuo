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
    logic signed [15:0] waveform_sample;
    logic [PHASE_W-1:0] phase_increment;
    logic [NOTE_W-1:0] lock_note_id;

    note_freq_lut # (
        .NOTE_W (NOTE_W),
        .PHASE_W (PHASE_W),
        .SAMPLE_RATE (SAMPLE_RATE)
    ) DUT0 (
        .note_id (lock_note_id),
        .pitch_bend (pitch_bend),
        .phase_increment (phase_increment)
    );

    dds_oscillator # (
        .PHASE_W (PHASE_W),
        .SAMPLE_W (SAMPLE_W),
        .WAVE_ADDR_W (WAVE_ADDR_W)
    ) DUT1 (
        .sys_clk (sys_clk),
        .rst_n (rst_n),
        .audio_ce (audio_ce),
        .phase_increment (phase_increment),
        .waveform_sel (waveform_sel),
        .waveform_sample (waveform_sample),
        .waveform_valid (sample_valid)
    );

    adsr # (
        .ATTACK_STEP (ATTACK_STEP),
        .DECAY_STEP (DECAY_STEP),
        .SUSTAIN_LEVEL (SUSTAIN_LEVEL),
        .RELEASE_STEP (RELEASE_STEP)
    ) DUT2 (
        .sys_clk (sys_clk),
        .rst_n (rst_n),
        .audio_ce (audio_ce),
        .note_on (note_on),
        .note_off (note_off),
        .velocity (velocity),
        .expression (expression),
        .envelope_value (envelope_value),
        .active (active)
    );

    logic signed [SAMPLE_W+16:0] sample_product;
    logic [15:0] saved_envelope;

    assign sample_product = waveform_sample * $signed({1'b0, saved_envelope});
    assign voice_sample = OUTPUT_W'(sample_product >>> 16);

    always_ff @(posedge sys_clk) begin
    if (!rst_n)
        lock_note_id <= '0;
    else if (note_on)
        lock_note_id <= note_id;
    end

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            saved_envelope <= 'd0;
        end
        else if (audio_ce) begin
            saved_envelope <= envelope_value;
        end
    end
endmodule
