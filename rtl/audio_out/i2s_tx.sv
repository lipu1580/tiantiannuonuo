// BCLK 下降沿更新 DIN/WS，外部接收器在 BCLK 上升沿采样。
// WS 翻转后的下一位才是新声道 MSB；WS 翻转当拍仍属于前一声道末位。
module i2s_tx #(
    parameter integer SYS_CLK_HZ = 27_000_000,
    parameter integer SAMPLE_RATE = 48_000,
    parameter integer SAMPLE_W = 16,
    parameter integer SLOT_W = 32
)(
    input  logic sys_clk,
    input  logic rst_n,
    input  logic signed [SAMPLE_W-1:0] pcm_left,
    input  logic signed [SAMPLE_W-1:0] pcm_right,
    input  logic pcm_valid,
    output logic pcm_ready,
    output logic i2s_bclk,
    output logic i2s_lrclk,
    output logic i2s_din,
    // 开始接收并播放后，某帧缺样时置位，保持到复位。
    // 上电等待首份 PCM 时保持静音，不报欠载。
    output logic underrun
);
    localparam integer FRAME_BITS = 2 * SLOT_W;
    localparam integer POS_W = $clog2(FRAME_BITS);
    localparam integer TOGGLE_HZ = SAMPLE_RATE * FRAME_BITS * 2;
    localparam logic [POS_W-1:0] LAST_POS = FRAME_BITS - 1;
    localparam logic [POS_W-1:0] LEFT_LAST_POS = SLOT_W - 1;

    logic [31:0] frac_acc;
    logic [32:0] acc_sum;
    logic toggle_ce, falling_ce, frame_start;
    logic [POS_W-1:0] bit_pos;
    logic pending_valid, take_pcm, stream_started;
    logic signed [SAMPLE_W-1:0] pending_left, pending_right;
    logic signed [SAMPLE_W-1:0] active_left, active_right;

    // 分数分频保持长期平均采样率。27 MHz 时半个 BCLK 为 4 或 5 拍，
    // 存在一个 sys_clk 周期量级的边沿抖动；并非无抖动音频时钟。
    // 如需均匀 BCLK，可由板级提供 24.576 MHz 等可整除的时钟并修改参数。
    assign acc_sum = {1'b0, frac_acc} + TOGGLE_HZ;
    assign toggle_ce = acc_sum >= SYS_CLK_HZ;
    assign falling_ce = toggle_ce && i2s_bclk;
    assign frame_start = falling_ce && (bit_pos == LAST_POS);

    // pending 是一个预取槽；帧边界消费旧值时可同时接收新值。
    assign pcm_ready = rst_n && (!pending_valid || frame_start);
    assign take_pcm = pcm_valid && pcm_ready;

    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            frac_acc <= '0;
            bit_pos <= LAST_POS;
            i2s_bclk <= 1'b0;
            i2s_lrclk <= 1'b1;
            i2s_din <= 1'b0;
            pending_valid <= 1'b0;
            pending_left <= '0;
            pending_right <= '0;
            active_left <= '0;
            active_right <= '0;
            stream_started <= 1'b0;
            underrun <= 1'b0;
        end else begin
            if (toggle_ce) begin
                frac_acc <= acc_sum - SYS_CLK_HZ;
                i2s_bclk <= ~i2s_bclk;
            end else begin
                frac_acc <= acc_sum[31:0];
            end

            // 接收与消费统一处理，避免同一寄存器被两个分支互相覆盖。
            if (frame_start) begin
                if (pending_valid) begin
                    active_left <= pending_left;
                    active_right <= pending_right;
                    stream_started <= 1'b1;
                end else if (take_pcm) begin
                    // 没有预取数据，但本拍握手成功：直接用于当前帧。
                    active_left <= pcm_left;
                    active_right <= pcm_right;
                    stream_started <= 1'b1;
                end else begin
                    // 缺样输出整帧零，避免一直保持旧幅值。
                    active_left <= '0;
                    active_right <= '0;
                    if (stream_started)
                        underrun <= 1'b1;
                end

                if (pending_valid && take_pcm) begin
                    // 旧 pending 已用于当前帧，新样本留到下一帧。
                    pending_left <= pcm_left;
                    pending_right <= pcm_right;
                    pending_valid <= 1'b1;
                end else begin
                    pending_valid <= 1'b0;
                end
            end else if (take_pcm) begin
                pending_left <= pcm_left;
                pending_right <= pcm_right;
                pending_valid <= 1'b1;
            end

            if (falling_ce) begin
                bit_pos <= (bit_pos == LAST_POS) ? '0 : bit_pos + 1'b1;
                if (bit_pos == LAST_POS) begin
                    i2s_lrclk <= 1'b0;
                    // 完整槽宽 PCM 的最后一位跨到 WS 翻转当拍；
                    // 若 PCM 比槽短，这一拍本来就是补零位。
                    i2s_din <= (SAMPLE_W == SLOT_W) ? active_right[0] : 1'b0;
                end else if (bit_pos == LEFT_LAST_POS) begin
                    i2s_lrclk <= 1'b1;
                    i2s_din <= (SAMPLE_W == SLOT_W) ? active_left[0] : 1'b0;
                end else if (bit_pos < LEFT_LAST_POS) begin
                    if (bit_pos < SAMPLE_W)
                        i2s_din <= active_left[SAMPLE_W - 1 - bit_pos];
                    else
                        i2s_din <= 1'b0;
                end else begin
                    if ((bit_pos - SLOT_W) < SAMPLE_W)
                        i2s_din <= active_right[SAMPLE_W - 1 - (bit_pos - SLOT_W)];
                    else
                        i2s_din <= 1'b0;
                end
            end
        end
    end

    // synthesis translate_off
    initial begin
        if (SAMPLE_W < 1 || SAMPLE_W > SLOT_W || SLOT_W < 2)
            $fatal(1, "i2s_tx: require 1 <= SAMPLE_W <= SLOT_W and SLOT_W >= 2");
        if (SAMPLE_RATE <= 0 || SYS_CLK_HZ < TOGGLE_HZ)
            $fatal(1, "i2s_tx: system clock too slow or invalid sample rate");
    end
    // synthesis translate_on
endmodule
