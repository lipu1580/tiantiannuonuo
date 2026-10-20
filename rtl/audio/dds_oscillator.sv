`timescale 1ns/1ns
module dds_oscillator #(
    parameter integer PHASE_W  = 32, // 相位累加器位宽
    parameter integer SAMPLE_W = 16, // 波形样本位宽
    parameter integer WAVE_ADDR_W = 10 // 波表地址位宽
)(
    input  logic                         sys_clk, // 系统主时钟
    input  logic                         rst_n,   // 低有效复位
    input  logic                         audio_ce, // 推进一次相位并请求新样本
    input  logic [PHASE_W-1:0]           phase_increment, // 每个采样周期增加的相位
    input  logic [1:0]                   waveform_sel, // 波形类型
    output logic signed [SAMPLE_W-1:0]   waveform_sample, // 当前有符号波形值
    output logic                         waveform_valid // 波形值有效脉冲
);
    // 当前 DDS 的时序定义：audio_ce 在一个 sys_clk 周期内请求一个新样本。
    // 同步 ROM 在时钟沿读取地址，波形数据在下一个周期作为结果使用。
    // 因此 waveform_valid 也要延后一拍，不能直接等于 audio_ce。

    // 当前相位累加器的状态。只有 audio_ce 有效时才推进相位；
    // 它的高位同时作为波表地址。
    logic [PHASE_W - 1:0] phase_accumulator;

    // 保存上一拍的 audio_ce，用来产生与同步 ROM 数据对应的 valid 脉冲。
    logic                 sample_pending;

    // 保存发起本次采样请求时的波形选择，避免 waveform_sel 在 ROM 延迟期间
    // 改变后，与已经请求的波形样本发生错位。
    logic [1:0]           waveform_sel_pending;

    always_ff @( posedge sys_clk ) begin : dds_oscillator
        if (!rst_n) begin
            phase_accumulator <= 'b0;
            sample_pending <= 1'b0;
            waveform_sel_pending <= 2'b00;
            waveform_valid <= 0;
        end
        else begin
            // ROM 在本时钟沿采样当前 phase；当前请求对应的新 phase
            // 会在下一个时钟沿之后出现在 waveform_sample 上。
            sample_pending <= audio_ce;
            waveform_sel_pending <= waveform_sel;
            waveform_valid <= sample_pending;

            if (audio_ce)
                phase_accumulator <= phase_accumulator + phase_increment;
        end
    end
    
    waveform_rom #(
        .ADDR_W (WAVE_ADDR_W),
        .SAMPLE_W (SAMPLE_W)
        ) rom (
            .sys_clk (sys_clk),
            .address (phase_accumulator[PHASE_W - 1 : PHASE_W - WAVE_ADDR_W]),
            .waveform_sel (waveform_sel_pending),
            .waveform_sample (waveform_sample)        
        );

endmodule
