//=============================================================================
// 文件   : expression_mapper.sv
// 功能   : 电位器 ADC -> pitch_bend；波形选择与测试模式合并。
//
// 【数据流】
//   ADC CH1 -> 一阶滤波 -> 线性映射 -> pitch_bend[11:0]
//   按键 K14 -> waveform_key_sel -> （test_mode? 正弦 : 按键值）-> waveform_sel
//
// 【pitch_bend 公式】
//   pitch_bend = clamp(2048 + (pot - CENTER_RAW) * BEND_SPAN, 0, 4095)
//   默认 CENTER_RAW=128，BEND_SPAN=16：
//     pot=0   -> 0
//     pot=128 -> 2048（不弯音）
//     pot=192 -> 3072
//     pot=255 -> 4080
//   pitch_bend 是 12 位，成员 1 用 2048 作为中心。
//
// 【为什么滤波】
//   旋钮 ADC 有 ±1~2 LSB 噪声，BEND_SPAN=16 时会被放大成 ±16~32 的
//   pitch 抖动，所以先做 alpha=1/4 的一阶滤波。
//
// 【expr_valid】
//   电位器至少完成一次采样后置 1；表达式数据不是事件，可持续更新。
//=============================================================================
import audio_defs_pkg::WAVE_SINE;

module expression_mapper #(
    parameter integer FILTER_SHIFT   = 2,   // 滤波 alpha = 1/4
    parameter integer CENTER_RAW     = 128, // 电位器中点 ADC 值
    parameter integer BEND_SPAN      = 16,  // 每 1 LSB 对应的 pitch 步进
    parameter integer CENTER_DEADZONE = 2   // 中心死区（±LSB，抑制静止抖动）
)(
    input  logic        sys_clk,
    input  logic        rst_n,

    // ADC 样本流（与 fsr_filter 共用）
    input  logic        sample_valid,
    input  logic [2:0]  sample_channel,
    input  logic [7:0]  sample_data,
    input  logic [2:0]  pot_channel,     // 电位器所在通道

    // 来自 key_event_decoder 的按键状态
    input  logic [1:0]  waveform_key_sel,
    // 测试模式：强制正弦
    input  logic        test_mode,

    // 输出
    output logic [11:0] pitch_bend,
    output logic [7:0]  pot_raw,         // 调试：原始值
    output logic        expr_valid,      // 至少完成一次采样
    output logic [1:0]  waveform_sel
);

    logic [7:0]        pot_f;      // 滤波值
    logic              ready_r;    // 是否完成首次采样
    logic [11:0]       bend_r;     // 输出寄存器
    logic [7:0]        pot_next;   // 下一滤波值
    logic [11:0]       bend_next;  // 下一 pitch 值

    logic signed [9:0] delta_c;    // raw - pot_f
    logic signed [9:0] filt_full;  // 未限幅结果
    integer            calc_c;     // 中间计算

    // 一阶指数滤波：pot(n+1) = pot(n) + (raw - pot(n))/4
    assign delta_c   = $signed({2'b00, sample_data}) - $signed({2'b00, pot_f});
    assign filt_full = $signed({2'b00, pot_f}) + (delta_c >>> FILTER_SHIFT);

    always_comb begin
        // 首次采样直接装载
        if (!ready_r) begin
            pot_next = sample_data;
        // 限幅到 0~255
        end else if (filt_full > 10'sd255) begin
            pot_next = 8'd255;
        end else if (filt_full < 10'sd0) begin
            pot_next = 8'd0;
        end else begin
            pot_next = 8'(filt_full);     // 已限幅到 0~255
        end

        // 电位器 -> pitch_bend：中点 2048，两端 0/4095。
        // 中心死区：|pot - CENTER| <= DEADZONE 时不弯音，抑制静止抖动（F-06）。
        if ((int'(pot_next) - CENTER_RAW) > CENTER_DEADZONE) begin
            calc_c = 2048 + (int'(pot_next) - CENTER_RAW) * BEND_SPAN;
        end else if ((CENTER_RAW - int'(pot_next)) > CENTER_DEADZONE) begin
            calc_c = 2048 - (CENTER_RAW - int'(pot_next)) * BEND_SPAN;
        end else begin
            calc_c = 2048;
        end

        if (calc_c < 0) begin
            bend_next = 12'd0;
        end else if (calc_c > 4095) begin
            bend_next = 12'd4095;
        end else begin
            bend_next = 12'(calc_c);      // 已限幅到 0~4095
        end
    end

    //-------------------------------------------------------------------------
    // 寄存器更新：只处理电位器通道
    //-------------------------------------------------------------------------
    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            pot_raw    <= 8'd0;
            pot_f      <= 8'd0;
            ready_r    <= 1'b0;
            bend_r     <= 12'd2048;   // 复位默认不弯音
        end else if (sample_valid && (sample_channel == pot_channel)) begin
            pot_raw <= sample_data;
            pot_f   <= pot_next;
            ready_r <= 1'b1;
            bend_r  <= bend_next;
        end
    end

    assign pitch_bend   = bend_r;
    assign expr_valid   = ready_r;
    // 测试模式强制正弦；正常模式使用 K14 的按键状态
    assign waveform_sel = test_mode ? WAVE_SINE : waveform_key_sel;

endmodule
