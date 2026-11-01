`timescale 1ns/1ns

module pcm_stream_adapter #(
    parameter integer INPUT_W  = 24, // 混音输入位宽
    parameter integer SAMPLE_W = 16, // PCM 输出位宽
    parameter integer FIFO_DEPTH = 4, // 当前 FIFO 指针实现仅支持深度 4
    parameter integer MIX_SHIFT = 2 // 当前 4 声部：混音除以 4，预留叠加余量
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

    // voice 输出虽然用 24 位保存，但幅值仍是 16 位 PCM 标度。
    // 因此不能因 24 -> 16 位转换而再除以 256。
    // 默认只除以 4，为四个声部同时满幅发声预留余量。
    // 前提：INPUT_W >= SAMPLE_W；MIX_SHIFT >= 0。
    localparam logic signed [SAMPLE_W-1:0] PCM_MAX =
        {1'b0, {(SAMPLE_W-1){1'b1}}};
    localparam logic signed [SAMPLE_W-1:0] PCM_MIN =
        {1'b1, {(SAMPLE_W-1){1'b0}}};
    localparam logic signed [INPUT_W-1:0] LIMIT_MAX = PCM_MAX;
    localparam logic signed [INPUT_W-1:0] LIMIT_MIN = PCM_MIN;
    wire signed [INPUT_W-1:0] scaled_sample;
    assign scaled_sample = mixed_sample >>> MIX_SHIFT;

    logic signed [SAMPLE_W-1:0] mid_product;
    logic is_full, pop, push, is_empty, is_overflow;
    logic [1:0] rd_index, wr_index;
    logic [2:0] queue_cnt;
    logic signed [SAMPLE_W-1:0] queue [0:FIFO_DEPTH-1]; 


    always_comb begin
        if (!rst_n) begin
            mid_product = 'b0;
        end else begin
            // 超出 PCM 范围时限幅，避免直接截位使正数翻成负数。
            if (scaled_sample > LIMIT_MAX)
                mid_product = PCM_MAX;
            else if (scaled_sample < LIMIT_MIN)
                mid_product = PCM_MIN;
            else
                mid_product = scaled_sample[SAMPLE_W-1:0];
        end
    end

    assign push = sample_valid && (!is_full || pop);
    assign pop = pcm_valid && pcm_ready;
    assign is_empty = queue_cnt == 0;
    assign is_full = queue_cnt == FIFO_DEPTH;
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
            if (push && pop) begin
                queue[wr_index] <= mid_product;
                wr_index <= (wr_index + 1) % FIFO_DEPTH;
                rd_index <= (rd_index + 1) % FIFO_DEPTH;
            end 
            else if (push) begin
                queue[wr_index] <= mid_product;
                wr_index <= (wr_index + 1) % FIFO_DEPTH;
                queue_cnt <= queue_cnt + 1;
            end 
            else if (pop) begin
                rd_index <= (rd_index + 1) % FIFO_DEPTH;
                queue_cnt <= queue_cnt - 1;
            end
            else begin
                
            end
            overflow <= is_overflow ? 1'b1 : overflow;
        end
    end

    always_comb begin
        pcm_left = pcm_valid ? queue[rd_index] : 'b0;
        pcm_right = pcm_valid ? queue[rd_index] : 'b0;
    end
    // sample_valid 接 mixer.mixed_valid，不能在 audio_ce 提前读取未完成的样本。
    // INPUT_W >= SAMPLE_W；按 MIX_SHIFT 缩放并饱和限幅，左右声道复制。
    // FIFO 满且本周期无出队时丢弃新输入，overflow 置 1 并保持至复位。
    // 满载时若同周期成功出队，仍应接收新样本；不覆盖被阻塞的队首。
    // pcm_valid && !pcm_ready 时，pcm_valid/pcm_left/pcm_right 必须保持。
endmodule
