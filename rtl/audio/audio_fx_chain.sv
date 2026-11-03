`timescale 1ns/1ns

// 基础效果器：反馈延迟、整数延迟调制合唱、多抽头反馈混响。
// 组合读 RAM / 同步写 RAM，输出打一拍；可每时钟接受一个样本。
// 路径：mixer -> audio_fx_chain -> pcm_stream_adapter。
// 公共 cfg 总线在 audio_core_expr 内统一译码，本模块接收完整参数快照。
module audio_fx_chain #(
    parameter integer SAMPLE_W = 24,       // 内部输入/输出位宽，保持原 PCM 数值标度
    parameter integer SAMPLE_RATE = 48_000, // 每秒有效输入样本数
    parameter integer DELAY_DEPTH = 4096    // 延迟模式缓冲容量，单位：样本
)(
    input  logic                       sys_clk,
    input  logic                       rst_n,             // 低有效，同步复位

    // 音频接口没有 ready：每个 in_valid 接受一个样本，之后输出一次 out_valid。
    // in_valid 接 mixer.mixed_valid，不直接接 audio_ce；内部必须满足采样吞吐。
    input  logic                       in_valid,
    input  logic signed [SAMPLE_W-1:0] in_sample,
    output logic                       out_valid,
    output logic signed [SAMPLE_W-1:0] out_sample,

    // 控制快照：ctrl_valid && ctrl_ready 时接受全部字段。
    // 阻塞时保持 valid 及字段；接受后在后续输入样本边界应用。
    input  logic                       ctrl_valid,
    output logic                       ctrl_ready,
    input  logic [1:0]                ctrl_mode,          // 0 旁路，1 延迟，2 合唱，3 混响
    input  logic [7:0]                ctrl_wet_gain,      // Q0.8，0～128
    input  logic [11:0]               ctrl_delay_samples, // 1～DELAY_DEPTH-1，仅延迟模式使用
    input  logic [7:0]                ctrl_feedback_gain, // Q0.8，0～128，仅延迟模式使用
    input  logic                       ctrl_clear,         // 随一次握手接受的清尾音命令

    // 忙于初始化/切换/清理时 ctrl_ready=0；音频样本仍须持续处理。
    output logic                       fx_busy,
    output logic                       fx_initialized,     // 当前效果工作存储已就绪
    output logic [1:0]                 fx_active_mode,      // 当前已完成应用的模式
    output logic                       clear_done
);

    localparam  IDLE = 2'b0,
                APPLY = 2'b1,
                CLEAR = 2'b10;

    logic [1:0] state, next_state;
    logic hs_scu;
    logic [1:0]                pending_mode;         // 0 旁路，1 延迟，2 合唱，3 混响
    logic [7:0]                pending_wet_gain;      // Q0.8，0～128
    logic [11:0]               pending_delay_samples;// 1～DELAY_DEPTH-1，仅延迟模式使用
    logic [7:0]                pending_feedback_gain;// Q0.8，0～128，仅延迟模式使用
    logic                      pending_clear;
    logic [1:0]                active_mode;         // 0 旁路，1 延迟，2 合唱，3 混响
    logic [7:0]                active_wet_gain;      // Q0.8，0～128
    logic [11:0]               active_delay_samples;// 1～DELAY_DEPTH-1，仅延迟模式使用
    logic [7:0]                active_feedback_gain;// Q0.8，0～128，仅延迟模式使用
    logic                      apply_params;
    localparam logic [11:0] DEFAULT_DELAY =
        12'((1920 < DELAY_DEPTH-1) ? 1920 : DELAY_DEPTH-1);

    initial begin
        if (SAMPLE_RATE < 1) $fatal(1, "SAMPLE_RATE must be positive");
        if (DELAY_DEPTH < 2 || DELAY_DEPTH > 4096)
            $fatal(1, "audio_fx_chain requires 2 <= DELAY_DEPTH <= 4096");
    end

    localparam integer PTR_W = $clog2(DELAY_DEPTH);
    localparam integer MATH_W = SAMPLE_W + 10;
    function automatic integer imin(input integer a, b);
        return a < b ? a : b;
    endfunction
    function automatic integer imax(input integer a, b);
        return a > b ? a : b;
    endfunction
    localparam integer CH_BASE = imax(1, imin(SAMPLE_RATE * 15 / 1000, DELAY_DEPTH / 2));
    localparam integer CH_SPAN = imin(SAMPLE_RATE * 3 / 1000, (CH_BASE-1) / 2);
    localparam logic [31:0] LFO_STEP = 32'(64'd2147483648 / SAMPLE_RATE); // 0.5 Hz
    localparam integer REV_LONG = imax(1, imin(SAMPLE_RATE * 43 / 1000, DELAY_DEPTH-1));
    localparam integer REV_MID = imax(1, REV_LONG * 37 / 43);
    localparam integer REV_SHORT = imax(1, REV_LONG * 29 / 43);
    logic signed [SAMPLE_W-1:0] history [0:DELAY_DEPTH-1];
    logic [PTR_W-1:0] wr_ptr, clear_ptr;
    logic [31:0] lfo_phase;
    logic [7:0] triangle;
    integer tap_delay;
    logic signed [MATH_W-1:0] wet_sample, feedback_sample;
    logic signed [MATH_W-1:0] wet_product, feedback_product;
    logic signed [SAMPLE_W-1:0] processed_sample, write_sample;
    logic needs_clear, last_clear;

    function automatic logic [PTR_W-1:0] tap_addr(input integer delay_count);
        integer addr;
        addr = int'(wr_ptr) - delay_count;
        if (addr < 0) addr = addr + DELAY_DEPTH;
        return PTR_W'(addr);
    endfunction
    function automatic logic signed [SAMPLE_W-1:0] saturate(
        input logic signed [MATH_W-1:0] value);
        if (value > MATH_W'($signed({1'b0, {(SAMPLE_W-1){1'b1}}})))
            return {1'b0, {(SAMPLE_W-1){1'b1}}};
        if (value < MATH_W'($signed({1'b1, {(SAMPLE_W-1){1'b0}}})))
            return {1'b1, {(SAMPLE_W-1){1'b0}}};
        return SAMPLE_W'(value);
    endfunction

    always_comb begin
        triangle = lfo_phase[31] ? ~lfo_phase[30:23] : lfo_phase[30:23];
        tap_delay = int'(active_delay_samples);
        wet_sample = '0;
        feedback_sample = '0;
        case (active_mode)
            1: begin
                wet_sample = MATH_W'(history[tap_addr(tap_delay)]);
                feedback_sample = wet_sample;
            end
            2: begin
                // 最基础的合唱：约 15 +/- 3 ms 整数延迟，无反馈。
                tap_delay = CH_BASE - CH_SPAN + (int'(triangle) * 2 * CH_SPAN / 256);
                wet_sample = MATH_W'(history[tap_addr(tap_delay)]);
            end
            3: begin
                // 三抽头反馈网络：默认约 29/37/43 ms，移位求和控制增益。
                wet_sample = (MATH_W'(history[tap_addr(REV_SHORT)]) +
                              MATH_W'(history[tap_addr(REV_MID)]) +
                              MATH_W'(history[tap_addr(REV_LONG)])) >>> 2;
                feedback_sample = wet_sample;
            end
            default: begin end
        endcase
        wet_product = wet_sample * $signed({1'b0, active_wet_gain});
        feedback_product = feedback_sample * $signed({1'b0, active_feedback_gain});
        // 混响固定 1/2 反馈，延迟使用配置反馈，合唱不反馈。
        if (active_mode == 3) feedback_product = feedback_sample * 128;
        processed_sample = in_sample;
        write_sample = in_sample;
        if (fx_initialized && state != CLEAR && active_mode != 0) begin
            processed_sample = saturate(MATH_W'(in_sample) + (wet_product >>> 8));
            write_sample = saturate(MATH_W'(in_sample) + (feedback_product >>> 8));
        end
    end

    // RAM 不做整块复位。初始化/清理每个时钟写一个地址，与音频 valid 无关。
    always_ff @(posedge sys_clk) begin
        if (rst_n) begin
            if (state == CLEAR) history[clear_ptr] <= '0;
            else if (in_valid && fx_initialized && active_mode != 0)
                history[wr_ptr] <= write_sample;
        end
    end
    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            out_valid <= 0;
            out_sample <= '0;
            wr_ptr <= '0;
            clear_ptr <= '0;
            lfo_phase <= '0;
        end else begin
            out_valid <= in_valid;
            if (in_valid) out_sample <= processed_sample;
            if (state == CLEAR) begin
                clear_ptr <= last_clear ? '0 : clear_ptr + 1'b1;
                wr_ptr <= '0;
                lfo_phase <= '0;
            end else if (in_valid && fx_initialized && active_mode != 0) begin
                wr_ptr <= (wr_ptr == PTR_W'(DELAY_DEPTH-1)) ? '0 : wr_ptr + 1'b1;
                lfo_phase <= lfo_phase + LFO_STEP;
            end
        end
    end
    assign needs_clear = pending_clear || pending_mode != active_mode;
    assign last_clear = clear_ptr == PTR_W'(DELAY_DEPTH-1);
    assign hs_scu = ctrl_valid && ctrl_ready;
    assign ctrl_ready = rst_n && (state == IDLE);
    assign fx_busy = !rst_n || (state != IDLE);
    // 无清理的快照在样本边界应用；附带清理的快照在 CLEAR 完成时应用。
    assign apply_params = ((state == APPLY) && in_valid && !needs_clear) ||
                          ((state == CLEAR) && last_clear);
    assign fx_active_mode = active_mode;
    // 自动模式切换/复位初始化不产生 clear 命令完成脉冲。
    assign clear_done = rst_n && (state == CLEAR) && last_clear && pending_clear;

    always_ff @(posedge sys_clk) begin
        if (!rst_n)
            fx_initialized <= 1'b0;
        else if (state == CLEAR && last_clear)
            fx_initialized <= 1'b1;
        else if ((state == APPLY) && in_valid && needs_clear)
            fx_initialized <= 1'b0;
    end

    always_comb begin
        if (!rst_n) begin
            next_state = CLEAR;
        end
        else begin
            case (state)
                IDLE: begin
                    if (hs_scu) begin
                        next_state = APPLY;
                    end
                    else next_state = IDLE;
                end
                APPLY: begin
                    if (in_valid) begin
                        if (needs_clear) begin
                            next_state = CLEAR;
                        end
                        else next_state = IDLE;
                    end
                    else next_state = APPLY;
                end
                CLEAR: next_state = last_clear ? IDLE : CLEAR;
                default: next_state = CLEAR;
            endcase
        end
    end

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            state <= CLEAR;
        end
        else begin
            state <= next_state;
        end
    end

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            pending_mode <= 'b0;
            pending_delay_samples <= DEFAULT_DELAY;
            pending_feedback_gain <= 'b0;
            pending_clear <= 'b0;
            pending_wet_gain <= 'b0;
        end
        else if (hs_scu) begin
            pending_clear <= ctrl_clear;
            pending_feedback_gain <= ctrl_feedback_gain;
            pending_delay_samples <= ctrl_delay_samples;
            pending_wet_gain <= ctrl_wet_gain;
            pending_mode <= ctrl_mode;
        end
        else if (state == CLEAR && last_clear) begin
            pending_clear <= 1'b0;
        end
    end

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            active_delay_samples <= DEFAULT_DELAY;
            active_feedback_gain <= 'b0;
            active_mode <= 'b0;
            active_wet_gain <= 'b0;
        end
        else if (apply_params) begin
            active_delay_samples <= pending_delay_samples < 1 ? 12'd1 :
                                    int'(pending_delay_samples) >= DELAY_DEPTH ? 12'(DELAY_DEPTH-1) :
                                    pending_delay_samples;
            active_feedback_gain <= pending_feedback_gain > 128 ? 8'd128 : pending_feedback_gain;
            active_mode <= pending_mode;
            active_wet_gain <= pending_wet_gain > 128 ? 8'd128 : pending_wet_gain;
        end
    end
    // clear 保留配置；同模式参数更新在边界沿之后的样本生效。
endmodule
