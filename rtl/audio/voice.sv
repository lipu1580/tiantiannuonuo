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
    parameter logic [15:0] RELEASE_STEP  = 16'd40,    // ADSR 释放步长
    parameter bit SHARED_PITCH_BEND = 1'b0
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
    input  logic [20:0]                  vibrato_ratio_q20,

    output logic signed [OUTPUT_W-1:0]   voice_sample, // 当前声部有符号样本
    output logic                         sample_valid, // 当前声部样本有效
    output logic                         active, // 声部仍处于发声/释放状态
    output logic [15:0]                  envelope_value, // 当前包络电平
    input logic [20:0]                   shared_bend_ratio_q20 // SHARED_PITCH_BEND=1 时使用
);
    logic waveform_valid;
    logic signed [SAMPLE_W-1:0] waveform_sample;
    logic [PHASE_W-1:0] phase_increment;
    logic [PHASE_W-1:0] mid_out_increment;
    logic [NOTE_W-1:0] lock_note_id;
    logic [PHASE_W-1:0] bend_phase_increment;
    logic [PHASE_W+20:0] vibrato_product;

    note_freq_lut # (
        .NOTE_W (NOTE_W),
        .PHASE_W (PHASE_W),
        .SAMPLE_RATE (SAMPLE_RATE)
    ) DUT0 (
        .note_id (lock_note_id),
        .pitch_bend (pitch_bend),
        .phase_increment (mid_out_increment)
    );

    generate
        if (SHARED_PITCH_BEND) begin : gen_shared_bend
            // 保留旧 pitch_bend_lut 的 32 位输入/截断语义，只有系数表被共享。
            logic [52:0] product;
            assign product = 32'(mid_out_increment) * shared_bend_ratio_q20;
            assign bend_phase_increment = PHASE_W'(32'(product >> 20));
        end else begin : gen_local_bend
            pitch_bend_lut u_bend (
                .in_phase_increment(mid_out_increment),
                .pitch_bend(pitch_bend),
                .phase_increment(bend_phase_increment)
            );
        end
    endgenerate

    // 两级相位增量流水线：滑音结果 -> 颤音乘法结果 -> DDS。
    // 采样使能、波形选择和包络同步延迟两拍，保证属于同一个采样请求。
    logic [PHASE_W-1:0] bend_increment_reg;
    logic [20:0] vibrato_ratio_reg;
    logic [1:0] sample_ce_pipe;
    logic [1:0] waveform_pipe_0, waveform_pipe_1;
    logic [15:0] envelope_pipe_0, envelope_pipe_1;
    assign vibrato_product = bend_increment_reg * vibrato_ratio_reg;
    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            bend_increment_reg <= '0;
            vibrato_ratio_reg <= 21'd1048576;
            phase_increment <= '0;
            sample_ce_pipe <= '0;
            waveform_pipe_0 <= '0;
            waveform_pipe_1 <= '0;
            envelope_pipe_0 <= '0;
            envelope_pipe_1 <= '0;
        end else begin
            bend_increment_reg <= bend_phase_increment;
            vibrato_ratio_reg <= vibrato_ratio_q20;
            phase_increment <= PHASE_W'(vibrato_product >> 20);
            sample_ce_pipe <= {sample_ce_pipe[0], audio_ce};
            waveform_pipe_0 <= waveform_sel;
            waveform_pipe_1 <= waveform_pipe_0;
            envelope_pipe_0 <= envelope_value;
            envelope_pipe_1 <= envelope_pipe_0;
        end
    end

    dds_oscillator # (
        .PHASE_W (PHASE_W),
        .SAMPLE_W (SAMPLE_W),
        .WAVE_ADDR_W (WAVE_ADDR_W)
    ) DUT1 (
        .sys_clk (sys_clk),
        .rst_n (rst_n),
        .audio_ce (sample_ce_pipe[1]),
        .phase_increment (phase_increment),
        .waveform_sel (waveform_pipe_1),
        .waveform_sample (waveform_sample),
        .waveform_valid (waveform_valid)
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

    logic [15:0] waveform_envelope;
    logic [15:0] saved_envelope;
    // Split envelope into four unsigned nibbles. Keep all low product bits until
    // the final >>>16, so negative rounding is identical to the original multiply.
    localparam integer PART_W = SAMPLE_W + 4;
    localparam integer PROD_W = SAMPLE_W + 17;
    // Explicit fabric shift/add: DSPs are already full on the target device.
    // Do not let four small multiplies take DSPs away from the pitch path.
    function automatic logic signed [PART_W-1:0] nibble_product(
        input logic signed [SAMPLE_W-1:0] wave,
        input logic [3:0] nibble
    );
        logic signed [PART_W-1:0] w, a, b, c, d;
        begin
            w = PART_W'(wave);
            a = nibble[0] ? w : '0;
            b = nibble[1] ? (w <<< 1) : '0;
            c = nibble[2] ? (w <<< 2) : '0;
            d = nibble[3] ? (w <<< 3) : '0;
            nibble_product = (a + b) + (c + d);
        end
    endfunction
    logic signed [PART_W-1:0] partial_q [0:3];
    logic signed [PROD_W-1:0] low_pair_q, high_pair_q;
    logic partial_valid, pair_valid;
    wire signed [PROD_W-1:0] combined_product = low_pair_q + (high_pair_q <<< 8);
    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            waveform_envelope <= '0;
            partial_valid <= 1'b0;
            pair_valid <= 1'b0;
            sample_valid <= 1'b0;
            low_pair_q <= '0;
            high_pair_q <= '0;
            voice_sample <= '0;
            for (integer i=0; i<4; i=i+1) partial_q[i] <= '0;
        end else begin
            waveform_envelope <= saved_envelope;
            partial_valid <= waveform_valid;
            pair_valid <= partial_valid;
            sample_valid <= pair_valid;
            if (waveform_valid) begin
                for (integer i=0; i<4; i=i+1)
                    partial_q[i] <= nibble_product(waveform_sample, waveform_envelope[4*i +: 4]);
            end
            if (partial_valid) begin
                low_pair_q <= PROD_W'(partial_q[0]) + (PROD_W'(partial_q[1]) <<< 4);
                high_pair_q <= PROD_W'(partial_q[2]) + (PROD_W'(partial_q[3]) <<< 4);
            end
            if (pair_valid) voice_sample <= OUTPUT_W'(combined_product >>> 16);
        end
    end

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
        else if (sample_ce_pipe[1]) begin
            saved_envelope <= envelope_pipe_1;
        end
    end
endmodule
