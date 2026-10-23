//=============================================================================
// 文件   : fsr_filter.sv
// 功能   : FSR 压力采样滤波、噪声门限、力度映射。
//
// 【数据流】
//   ADC 原始值 -> 零点/门限 -> 一阶指数滤波 -> 迟滞判断 -> 0~255 力度
//              -> fsr_raw / fsr_filtered / velocity / pressure_valid
//
// 【滤波公式】
//   filtered(n+1) = filtered(n) + (raw(n) - filtered(n)) / 2^FILTER_SHIFT
//   FILTER_SHIFT=2 时 alpha=1/4，时间常数约 4 个采样周期。
//
// 【快速起音】
//   如果新样本比当前滤波值高超过 FAST_ATTACK_DELTA，直接跟随新样本。
//   这样按下瞬间的力度不会被缓慢滤波拖得偏小；释放时仍用指数滤波，
//   避免松手时力度突然跳变。
//
// 【迟滞门限】
//   静止时 filtered <  NOISE_GATE 判断为无压力；
//   已按下时 filtered <= GATE_LOW 才认为松开。
//   两个阈值不同（差 GATE_HYST），防止临界值附近反复抖动。
//
// 【力度映射】
//   d = filtered - GATE_LOW
//   velocity = d * 255 / (255 - GATE_LOW)，再限幅到 0~255。
//   门限以下输出 0，满量程输出 255。
//
// 【注意】
//   velocity 是寄存器输出，更新率约 1.4 kHz；按键按下时由
//   key_event_decoder 锁存当时的值，因此不需要在音乐速率上更新。
//=============================================================================
module fsr_filter #(
    parameter integer FILTER_SHIFT = project_params_pkg::FSR_FILTER_SHIFT, // alpha = 1/2^SHIFT
    parameter logic [7:0] NOISE_GATE = project_params_pkg::FSR_NOISE_GATE, // 无压力上限
    parameter integer GATE_HYST    = 2,                 // 迟滞回差
    // 起音加速：新样本比滤波值高超过该阈值时直接跟随，
    // 保证按键瞬间的力度响应；释放仍使用指数滤波。
    parameter logic signed [9:0] FAST_ATTACK_DELTA = 10'sd32
)(
    input  logic       sys_clk,
    input  logic       rst_n,

    // ADC 样本流（所有通道共用）
    input  logic       sample_valid,
    input  logic [2:0] sample_channel,
    input  logic [7:0] sample_data,
    // 本模块关心的通道号
    input  logic [2:0] fsr_channel,

    // 原始/滤波/力度
    output logic [7:0] fsr_raw,
    output logic [7:0] fsr_filtered,
    output logic [7:0] velocity,
    // 当前是否处于有效压力状态
    output logic       pressure_valid,
    // 是否已经完成至少一次采样
    output logic       ready
);

    // GATE_LOW：释放阈值（比 NOISE_GATE 低 GATE_HYST）
    // SPAN    ：力度映射的满量程范围
    localparam integer GATE_LOW = (int'(NOISE_GATE) > GATE_HYST)
                                  ? (int'(NOISE_GATE) - GATE_HYST) : 0;
    localparam integer SPAN     = 255 - GATE_LOW;

    logic [7:0]        raw_r;      // 最近一次原始值
    logic [7:0]        filtered;   // 滤波值
    logic              ready_r;    // 是否完成首次采样
    logic              press_r;    // 迟滞后的压力有效
    logic [7:0]        vel_r;      // 映射后的力度

    // 有符号中间量，允许 filtered - raw 为负
    logic signed [9:0] delta_c;    // raw - filtered
    logic signed [9:0] filt_full;  // 未限幅的下一滤波值
    logic [7:0]        flt_next;   // 限幅后的下一滤波值
    logic              press_next; // 下一压力状态

    //-------------------------------------------------------------------------
    // 组合计算：滤波下一值、迟滞门限、力度映射
    //-------------------------------------------------------------------------
    // 当前的偏差和“如果按普通 EMA 走一步”的结果
    assign delta_c   = $signed({2'b00, sample_data})
                       - $signed({2'b00, filtered});
    assign filt_full = $signed({2'b00, filtered})
                       + (delta_c >>> FILTER_SHIFT);

    always_comb begin
        // 1) 首次采样直接装载，避免上电从 0 慢慢爬升
        if (!ready_r) begin
            flt_next = sample_data;
        // 2) 快速起音：大阶跃直接跟随
        end else if (delta_c > FAST_ATTACK_DELTA) begin
            flt_next = sample_data;
        // 3) 限幅到 0~255（理论上 EMA 不会越界，保留兜底）
        end else if (filt_full > 10'sd255) begin
            flt_next = 8'd255;
        end else if (filt_full < 10'sd0) begin
            flt_next = 8'd0;
        end else begin
            flt_next = 8'(filt_full);     // 已限幅到 0~255
        end

        // 迟滞：已按下时用较低阈值判断松开，未按下时用较高阈值判断按下
        if (press_r) begin
            press_next = (flt_next > 8'(GATE_LOW));
        end else begin
            press_next = (flt_next >= NOISE_GATE);
        end
    end

    //-------------------------------------------------------------------------
    // 力度映射函数：把滤波值线性映射到 0~255
    //   v <= GATE_LOW          -> 0
    //   v >= GATE_LOW + SPAN   -> 255
    //   中间                   -> (v-GATE_LOW)*255/SPAN
    //-------------------------------------------------------------------------
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
    //   只在“本通道样本有效”时更新，其它通道（电位器）的样点直接忽略。
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
