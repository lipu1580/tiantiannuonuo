`timescale 1ns/1ns

// 效果器：三段串联反馈延迟、整数延迟调制合唱、三路并联反馈梳状混响。
// 三块同步 RAM：延迟时串联，混响时独立反馈；读存储、混合/写回分两拍。
// 读写同址通过显式旁路处理，不依赖器件 RAM 的 read-during-write 模式。
// 路径：mixer -> audio_fx_chain -> pcm_stream_adapter。
// 公共 cfg 总线在 audio_core_expr 内统一译码，本模块接收完整参数快照。
module audio_fx_chain #(
    parameter integer SAMPLE_W = 24,       // 内部输入/输出位宽，保持原 PCM 数值标度
    parameter integer SAMPLE_RATE = 48_000, // 每秒有效输入样本数
    parameter integer DELAY_DEPTH = 4096    // 每段缓冲容量，单位：样本；延迟模式共三段
)(
    input  logic                       sys_clk,
    input  logic                       rst_n,             // 低有效，同步复位

    // 音频接口没有 ready：每个 in_valid 接受一个样本，两拍后输出一次 out_valid（相对旧实现增加一拍）。
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
    input  logic [11:0]               ctrl_delay_samples, // 每段 1～DELAY_DEPTH-1 样本；总延迟为此值的三倍
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
    logic [11:0]               pending_delay_samples;// 每段 1～DELAY_DEPTH-1 样本；总延迟为此值的三倍
    logic [7:0]                pending_feedback_gain;// Q0.8，0～128，仅延迟模式使用
    logic                      pending_clear;
    logic [1:0]                active_mode;         // 0 旁路，1 延迟，2 合唱，3 混响
    logic [7:0]                active_wet_gain;      // Q0.8，0～128
    logic [11:0]               active_delay_samples;// 每段 1～DELAY_DEPTH-1 样本；总延迟为此值的三倍
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
    // 48 kHz 下为 2887/3469/4001 样本，避免三个反射时间落在同一整数毫秒网格。
    // 独立 3/4 反馈，理论幅度衰减 60 dB 约需 1.44/1.74/2.00 秒。
    localparam integer REV_SHORT = imax(1, imin(integer'(64'(SAMPLE_RATE) * 2887 / 48000), DELAY_DEPTH-1));
    localparam integer REV_MID = imax(1, imin(integer'(64'(SAMPLE_RATE) * 3469 / 48000), DELAY_DEPTH-1));
    localparam integer REV_LONG = imax(1, imin(integer'(64'(SAMPLE_RATE) * 4001 / 48000), DELAY_DEPTH-1));
    // 每个数组只有一个同步读口和一个同步写口，可映射为简单双口 BSRAM。
    // 每块 RAM 的内容可以不同；仍无组合读口，不增加 RAM 深度或乘法器。
    logic signed [SAMPLE_W-1:0] history_a [0:DELAY_DEPTH-1];
    logic signed [SAMPLE_W-1:0] history_b [0:DELAY_DEPTH-1];
    logic signed [SAMPLE_W-1:0] history_c [0:DELAY_DEPTH-1];
    logic signed [SAMPLE_W-1:0] ram_a_q, ram_b_q, ram_c_q;
    logic [PTR_W-1:0] read_addr_a, read_addr_b, read_addr_c;
    logic [PTR_W-1:0] ram_write_addr, sample_addr_q;
    logic signed [SAMPLE_W-1:0] ram_write_data, ram_write_data_b, ram_write_data_c;
    logic ram_write_en;
    logic valid_q, process_q;
    logic signed [SAMPLE_W-1:0] input_q;
    logic [1:0] mode_q;
    logic [7:0] wet_gain_q, feedback_gain_q;
    logic bypass_a_q, bypass_b_q, bypass_c_q;
    logic signed [SAMPLE_W-1:0] bypass_data_q, bypass_data_b_q, bypass_data_c_q;
    logic signed [SAMPLE_W-1:0] tap_a, tap_b, tap_c;
    logic [PTR_W-1:0] wr_ptr, clear_ptr;
    logic [31:0] lfo_phase;
    logic [7:0] triangle;
    integer tap_delay;
    logic signed [MATH_W-1:0] wet_sample, feedback_sample;
    logic signed [MATH_W-1:0] wet_product, feedback_product;
    logic signed [SAMPLE_W-1:0] processed_sample, write_sample, write_sample_b, write_sample_c;
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

    // 3/4 反馈用加法/移位实现，并向零截断，避免小负数产生永久尾音。
    function automatic logic signed [SAMPLE_W-1:0] comb_write(
        input logic signed [SAMPLE_W-1:0] dry, delayed);
        logic signed [MATH_W-1:0] three_tap;
        three_tap = MATH_W'(delayed) + (MATH_W'(delayed) <<< 1);
        if (three_tap < 0) three_tap = three_tap + 3;
        return saturate(MATH_W'(dry) + (three_tap >>> 2));
    endfunction

    // 地址仅取决于当前输入样本的写指针/配置；读结果与输入一起寄存。
    always_comb begin
        triangle = lfo_phase[31] ? ~lfo_phase[30:23] : lfo_phase[30:23];
        tap_delay = int'(active_delay_samples);
        if (active_mode == 2)
            tap_delay = CH_BASE - CH_SPAN + (int'(triangle) * 2 * CH_SPAN / 256);
        if (active_mode == 3) tap_delay = REV_SHORT;
        read_addr_a = tap_addr(tap_delay);
        read_addr_b = tap_addr(active_mode == 1 ? int'(active_delay_samples) : REV_MID);
        read_addr_c = tap_addr(active_mode == 1 ? int'(active_delay_samples) : REV_LONG);
    end

    assign tap_a = bypass_a_q ? bypass_data_q : ram_a_q;
    assign tap_b = bypass_b_q ? bypass_data_b_q : ram_b_q;
    assign tap_c = bypass_c_q ? bypass_data_c_q : ram_c_q;

    always_comb begin
        wet_sample = '0;
        feedback_sample = '0;
        case (mode_q)
            1: begin
                wet_sample = MATH_W'(tap_c);
                feedback_sample = wet_sample;
            end
            2: wet_sample = MATH_W'(tap_a);
            3: begin
                wet_sample = (MATH_W'(tap_a) + MATH_W'(tap_b) + MATH_W'(tap_c)) >>> 2;
            end
            default: begin end
        endcase
        wet_product = wet_sample * $signed({1'b0, wet_gain_q});
        feedback_product = feedback_sample * $signed({1'b0, feedback_gain_q});
        processed_sample = input_q;
        write_sample = input_q;
        write_sample_b = input_q;
        write_sample_c = input_q;
        if (process_q) begin
            processed_sample = saturate(MATH_W'(input_q) + (wet_product >>> 8));
            write_sample = saturate(MATH_W'(input_q) + (feedback_product >>> 8));
            if (mode_q == 1) begin
                // 每段只存自己的信号；第三段回声反馈到第一段。
                write_sample_b = tap_a;
                write_sample_c = tap_b;
            end else if (mode_q == 3) begin
                write_sample = comb_write(input_q, tap_a);
                write_sample_b = comb_write(input_q, tap_b);
                write_sample_c = comb_write(input_q, tap_c);
            end
        end
    end

    // 清理与正常写回共用唯一写口。整块 RAM 无复位、无组合读口。
    assign ram_write_en = rst_n && ((state == CLEAR) || (valid_q && process_q));
    assign ram_write_addr = (state == CLEAR) ? clear_ptr : sample_addr_q;
    assign ram_write_data = (state == CLEAR) ? SAMPLE_W'(0) : write_sample;
    assign ram_write_data_b = (state == CLEAR) ? SAMPLE_W'(0) : write_sample_b;
    assign ram_write_data_c = (state == CLEAR) ? SAMPLE_W'(0) : write_sample_c;
    always_ff @(posedge sys_clk) begin
        if (ram_write_en) begin
            history_a[ram_write_addr] <= ram_write_data;
            history_b[ram_write_addr] <= ram_write_data_b;
            history_c[ram_write_addr] <= ram_write_data_c;
        end
        ram_a_q <= history_a[read_addr_a];
        ram_b_q <= history_b[read_addr_b];
        ram_c_q <= history_c[read_addr_c];
    end

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            valid_q <= 1'b0;
            process_q <= 1'b0;
            input_q <= '0;
            sample_addr_q <= '0;
            mode_q <= '0;
            wet_gain_q <= '0;
            feedback_gain_q <= '0;
            bypass_a_q <= 1'b0;
            bypass_b_q <= 1'b0;
            bypass_c_q <= 1'b0;
            bypass_data_q <= '0;
            bypass_data_b_q <= '0;
            bypass_data_c_q <= '0;
            out_valid <= 1'b0;
            out_sample <= '0;
            wr_ptr <= '0;
            clear_ptr <= '0;
            lfo_phase <= '0;
        end else begin
            valid_q <= in_valid;
            out_valid <= valid_q;
            if (valid_q) out_sample <= processed_sample;
            if (in_valid) begin
                input_q <= in_sample;
                sample_addr_q <= wr_ptr;
                mode_q <= active_mode;
                wet_gain_q <= active_wet_gain;
                feedback_gain_q <= active_feedback_gain;
                process_q <= fx_initialized && state != CLEAR && active_mode != 0;
            end
            // 包括 delay=1、背靠背采样及非 2 次幂深度的环回同址情况。
            bypass_a_q <= ram_write_en && (read_addr_a == ram_write_addr);
            bypass_b_q <= ram_write_en && (read_addr_b == ram_write_addr);
            bypass_c_q <= ram_write_en && (read_addr_c == ram_write_addr);
            bypass_data_q <= ram_write_data;
            bypass_data_b_q <= ram_write_data_b;
            bypass_data_c_q <= ram_write_data_c;
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
