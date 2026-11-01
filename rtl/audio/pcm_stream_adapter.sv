`timescale 1ns/1ns

module pcm_stream_adapter #(
    parameter integer INPUT_W  = 24, // 混音输入位宽
    parameter integer SAMPLE_W = 16, // PCM 输出位宽
    parameter integer FIFO_DEPTH = 4, // 缓冲样本数，至少为 1
    parameter integer MIX_SHIFT = 0 // 可选额外衰减；mixer 已除以 4，默认不再移位
)(
    input  logic                         sys_clk, // 系统主时钟
    input  logic                         rst_n,   // 低有效复位
    input  logic                         sample_valid, // 输入混音样本有效
    input  logic signed [INPUT_W-1:0]    mixed_sample, // 单声道有符号混音样本

    output logic                         pcm_valid, // PCM 有效；与 pcm_ready 同为 1 时完成传输
    input  logic                         pcm_ready, // 下游可接收 PCM
    output logic signed [SAMPLE_W-1:0]   pcm_left, // 左声道 PCM 样本
    output logic signed [SAMPLE_W-1:0]   pcm_right, // 右声道 PCM 样本
    output logic                         overflow // 缓冲满时发生过丢样
);

    localparam integer PTR_W = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH) : 1;
    localparam integer COUNT_W = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH + 1) : 1;
    localparam logic signed [SAMPLE_W-1:0] PCM_MAX =
        {1'b0, {(SAMPLE_W-1){1'b1}}};
    localparam logic signed [SAMPLE_W-1:0] PCM_MIN =
        {1'b1, {(SAMPLE_W-1){1'b0}}};
    localparam logic signed [INPUT_W-1:0] LIMIT_MAX = INPUT_W'(PCM_MAX);
    localparam logic signed [INPUT_W-1:0] LIMIT_MIN = INPUT_W'(PCM_MIN);

    initial begin
        if (SAMPLE_W < 2 || INPUT_W < SAMPLE_W)
            $fatal(1, "pcm_stream_adapter requires INPUT_W >= SAMPLE_W >= 2");
        if (FIFO_DEPTH < 1)
            $fatal(1, "pcm_stream_adapter requires FIFO_DEPTH >= 1");
        if (MIX_SHIFT < 0 || MIX_SHIFT >= INPUT_W)
            $fatal(1, "pcm_stream_adapter requires 0 <= MIX_SHIFT < INPUT_W");
    end

    logic signed [INPUT_W-1:0] scaled_sample;
    logic signed [SAMPLE_W-1:0] pcm_sample;
    logic is_full, pop, push, is_empty, is_overflow;
    logic [PTR_W-1:0] rd_index, wr_index;
    logic [COUNT_W-1:0] queue_cnt;
    logic signed [SAMPLE_W-1:0] queue [0:FIFO_DEPTH-1]; 


    // 24 位是内部存储位宽，voice/mixer 的数值仍按 16 位 PCM 标度计算。
    // 缩位前饱和限幅，避免直接截位将过大的正数变为负数。
    assign scaled_sample = mixed_sample >>> MIX_SHIFT;
    always_comb begin
        if (scaled_sample > LIMIT_MAX)
            pcm_sample = PCM_MAX;
        else if (scaled_sample < LIMIT_MIN)
            pcm_sample = PCM_MIN;
        else
            pcm_sample = scaled_sample[SAMPLE_W-1:0];
    end

    assign push = sample_valid && (!is_full || pop);
    assign pop = pcm_valid && pcm_ready;
    assign is_empty = queue_cnt == 0;
    assign is_full = queue_cnt == COUNT_W'(FIFO_DEPTH);
    assign pcm_valid = !is_empty;
    assign is_overflow = sample_valid && is_full && !pop;

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            wr_index <= 'b0;
            rd_index <= 'b0;
            queue_cnt <= 'b0;
            for (int i = 0; i < FIFO_DEPTH; i++) begin
                queue[i] <= 'b0;
            end
            overflow <= 'b0;
        end else begin
            if (push) begin
                queue[wr_index] <= pcm_sample;
                wr_index <= (wr_index == PTR_W'(FIFO_DEPTH - 1)) ? '0 : wr_index + 1'b1;
            end
            if (pop) begin
                rd_index <= (rd_index == PTR_W'(FIFO_DEPTH - 1)) ? '0 : rd_index + 1'b1;
            end
            case ({push, pop})
                2'b10: queue_cnt <= queue_cnt + 1'b1;
                2'b01: queue_cnt <= queue_cnt - 1'b1;
                default: ; // 同时出入队或无传输时，数量不变。
            endcase
            if (is_overflow) overflow <= 1'b1;
        end
    end

    always_comb begin
        pcm_left = pcm_valid ? queue[rd_index] : 'b0;
        pcm_right = pcm_valid ? queue[rd_index] : 'b0;
    end
    // sample_valid 接 mixer.mixed_valid，不能在 audio_ce 提前读取未完成的样本。
    // INPUT_W >= SAMPLE_W；可选移位后饱和到 PCM 范围，左右声道复制。
    // FIFO 满且本周期无出队时丢弃新输入，overflow 置 1 并保持至复位。
    // 满载时若同周期成功出队，仍应接收新样本；不覆盖被阻塞的队首。
    // pcm_valid && !pcm_ready 时，pcm_valid/pcm_left/pcm_right 必须保持。
endmodule
