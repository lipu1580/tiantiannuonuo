//=============================================================================
// 文件   : expression_mapper.sv
// 功能   : 电位器 ADC -> pitch_bend；波形选择与测试模式合并。
// 说明   :
//   1. pitch_bend 为 12 位，中点 2048 表示不弯音。
//      raw=128 时输出 2048，raw=0 -> 0，raw=255 -> 4080。
//   2. 电位器采样做一阶滤波，抑制旋钮抖动。
//   3. 波形选择来自按键状态；test_mode 时强制正弦波，便于测试。
//   4. expr_valid 在电位器至少完成一次采样后置 1。
//=============================================================================
`include "project_params.svh"
`include "audio_defs.svh"

module expression_mapper #(
    parameter integer FILTER_SHIFT = 2,
    parameter integer CENTER_RAW   = 128,
    parameter integer BEND_SPAN    = 16
)(
    input  logic        sys_clk,
    input  logic        rst_n,

    input  logic        sample_valid,
    input  logic [2:0]  sample_channel,
    input  logic [7:0]  sample_data,
    input  logic [2:0]  pot_channel,

    input  logic [1:0]  waveform_key_sel,
    input  logic        test_mode,

    output logic [11:0] pitch_bend,
    output logic [7:0]  pot_raw,
    output logic        expr_valid,
    output logic [1:0]  waveform_sel
);

    logic [7:0]        pot_f;
    logic              ready_r;
    logic [11:0]       bend_r;
    logic [7:0]        pot_next;
    logic [11:0]       bend_next;

    logic signed [9:0] delta_c;
    logic signed [9:0] filt_full;
    integer            calc_c;

    assign delta_c   = $signed({2'b00, sample_data}) - $signed({2'b00, pot_f});
    assign filt_full = $signed({2'b00, pot_f}) + (delta_c >>> FILTER_SHIFT);

    always_comb begin
        if (!ready_r) begin
            pot_next = sample_data;
        end else if (filt_full > 10'sd255) begin
            pot_next = 8'd255;
        end else if (filt_full < 10'sd0) begin
            pot_next = 8'd0;
        end else begin
            pot_next = 8'(filt_full);     // 已限幅到 0~255
        end

        calc_c = 2048 + (int'(pot_next) - CENTER_RAW) * BEND_SPAN;
        if (calc_c < 0) begin
            bend_next = 12'd0;
        end else if (calc_c > 4095) begin
            bend_next = 12'd4095;
        end else begin
            bend_next = 12'(calc_c);      // 已限幅到 0~4095
        end
    end

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            pot_raw    <= 8'd0;
            pot_f      <= 8'd0;
            ready_r    <= 1'b0;
            bend_r     <= 12'd2048;
        end else if (sample_valid && (sample_channel == pot_channel)) begin
            pot_raw <= sample_data;
            pot_f   <= pot_next;
            ready_r <= 1'b1;
            bend_r  <= bend_next;
        end
    end

    assign pitch_bend   = bend_r;
    assign expr_valid   = ready_r;
    assign waveform_sel = test_mode ? `WAVE_SINE : waveform_key_sel;

endmodule
