`timescale 1ns/1ns
module tb_section2;
    parameter integer SYS_CLK_HZ  = 27_000_000; // 输入 sys_clk 频率
    parameter integer SAMPLE_RATE = 48_000;      // 目标采样率
    parameter integer NOTE_W      = 7;     // 音符编号位宽
    parameter integer PHASE_W     = 32;     // DDS 相位累加器位宽
    parameter integer SAMPLE_RATE = 48_000;  // 音频采样率
    parameter integer ADDR_W   = 10; // 波形相位地址位宽
    parameter integer SAMPLE_W = 16;  // 波形样本位宽
    parameter integer CLK_PERIOD = 2;
    parameter integer RST_PERIOD = 10;
    parameter integer PITCH_BEND = 2048;
    parameter INIT_FILE = "rtl/audio/sine_1024.hex"

    logic sys_clk,audio_ce,rst_n,waveform_valid;
    logic [NOTE_W-1 : 0] note_id = 69;
    logic [PHASE_W-1 : 0] phase_increment;
    logic [SAMPLE_W-1 : 0] waveform_sample;
    logic [1:0] waveform_sel;

    always begin
        sys_clk = 0; #(CLK_PERIOD / 2);
        sys_clk = 1; #(CLK_PERIOD / 2);
    end

    sample_tick_gen #(
        .SYS_CLK_HZ (SYS_CLK_HZ),
        .SAMPLE_RATE (SAMPLE_RATE)
    ) DUT0 (
        .sys_clk (sys_clk),
        .rst_n (rst_n),
        .audio_ce (audio_ce)
    );

    note_freq_lut # (
        .NOTE_W (NOTE_W),
        .PHASE_W (PHASE_W),
        .SAMPLE_RATE (SAMPLE_RATE)
    ) DUT1 (
        .note_id (note_id),
        .pitch_bend (PITCH_BEND),
        .phase_increment (phase_increment)
    );

    dds_oscillator #(
        .PHASE_W (PHASE_W),
        .SAMPLE_W (SAMPLE_W),
        .WAVE_ADDR_W (ADDR_W)
    ) DUT2 (
        .sys_clk (sys_clk),
        .rst_n (rst_n),
        .audio_ce (audio_ce),
        .phase_increment (phase_increment),
        .waveform_sel (waveform_sel),
        .waveform_sample (waveform_sample),
        .waveform_valid (waveform_valid)
    );

    int rising_crossing = 0;
    logic [SAMPLE_W-1 : 0] pre_sample;

    always_ff @(posedge sys_clk) begin
        pre_sample <= waveform_sample;
    end

    always @(negedge sys_clk) begin
        if (pre_sample < 0 && waveform_sample > 0) begin
            rising_crossing++;
        end
    end
    //计算频率：测得频率 ≈ rising_crossings * SAMPLE_RATE / N

endmodule