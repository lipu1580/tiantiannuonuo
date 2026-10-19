//=============================================================================
// 文件   : fsr_filter.sv
// 功能   : FSR 压力采样滤波、噪声门限、力度映射。
// 说明   :
//   1. 只处理 sample_channel == fsr_channel 的 ADC 样本。
//   2. 一阶指数滤波：filtered += (raw - filtered) / 2^FILTER_SHIFT。
//   3. 迟滞噪声门限：静止时不产生随机力度。
//   4. velocity 映射到 0~255；压力低于门限时为 0。
//   5. velocity 为寄存器输出，更新率为该通道 ADC 采样率。
//   6. 触发瞬间的力度由 key_event_decoder 在 NOTE_ON 时锁存。
//=============================================================================
`include "project_params.svh"

module fsr_filter #(
    parameter integer FILTER_SHIFT = `FSR_FILTER_SHIFT,
    parameter logic [7:0] NOISE_GATE = `FSR_NOISE_GATE,
    parameter integer GATE_HYST    = 2,
    // 起音加速：新样本比滤波值高超过该阈值时直接跟随，
    // 保证按键瞬间的力度响应；释放仍使用指数滤波。
    parameter logic signed [9:0] FAST_ATTACK_DELTA = 10'sd32
)(
    input  logic       sys_clk,
    input  logic       rst_n,

    input  logic       sample_valid,
    input  logic [2:0] sample_channel,
    input  logic [7:0] sample_data,
    input  logic [2:0] fsr_channel,

    output logic [7:0] fsr_raw,
    output logic [7:0] fsr_filtered,
    output logic [7:0] velocity,
    output logic       pressure_valid,
    output logic       ready
);

    localparam integer GATE_LOW = (int'(NOISE_GATE) > GATE_HYST)
                                  ? (int'(NOISE_GATE) - GATE_HYST) : 0;
    localparam integer SPAN     = 255 - GATE_LOW;

    logic [7:0]        raw_r;
    logic [7:0]        filtered;
    logic              ready_r;
    logic              press_r;
    logic [7:0]        vel_r;

    logic signed [9:0] delta_c;
    logic signed [9:0] filt_full;
    logic [7:0]        flt_next;
    logic              press_next;

    //-------------------------------------------------------------------------
    // 组合计算：滤波下一值、迟滞门限、力度映射
    //-------------------------------------------------------------------------
    assign delta_c   = $signed({2'b00, sample_data})
                       - $signed({2'b00, filtered});
    assign filt_full = $signed({2'b00, filtered})
                       + (delta_c >>> FILTER_SHIFT);

    always_comb begin
        if (!ready_r) begin
            flt_next = sample_data;
        end else if (delta_c > FAST_ATTACK_DELTA) begin
            // 力度快速起音：大阶跃直接跟随
            flt_next = sample_data;
        end else if (filt_full > 10'sd255) begin
            flt_next = 8'd255;
        end else if (filt_full < 10'sd0) begin
            flt_next = 8'd0;
        end else begin
            flt_next = 8'(filt_full);     // 已限幅到 0~255
        end

        if (press_r) begin
            press_next = (flt_next > 8'(GATE_LOW));
        end else begin
            press_next = (flt_next >= NOISE_GATE);
        end
    end

    function automatic logic [7:0] calc_velocity(input logic [7:0] v);
        integer d;
        begin
            if (int'(v) <= GATE_LOW) begin
                calc_velocity = 8'd0;
            end else begin
                d = int'(v) - GATE_LOW;
                if (d >= SPAN) begin
                    calc_velocity = 8'd255;
                end else begin
                    calc_velocity = 8'((d * 255) / SPAN);
                end
            end
        end
    endfunction

    //-------------------------------------------------------------------------
    // 寄存器更新
    //-------------------------------------------------------------------------
    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            raw_r    <= 8'd0;
            filtered <= 8'd0;
            ready_r  <= 1'b0;
            press_r  <= 1'b0;
            vel_r    <= 8'd0;
        end else if (sample_valid && (sample_channel == fsr_channel)) begin
            raw_r    <= sample_data;
            filtered <= flt_next;
            ready_r  <= 1'b1;
            press_r  <= press_next;
            vel_r    <= calc_velocity(flt_next);
        end
    end

    assign fsr_raw        = raw_r;
    assign fsr_filtered   = filtered;
    assign velocity       = vel_r;
    assign pressure_valid = press_r;
    assign ready          = ready_r;

endmodule
