`timescale 1ns/1ns

module mixer #(
    parameter integer VOICE_COUNT = 4, // 输入声部数量
    parameter integer VOICE_W     = 24, // 单路声部位宽
    parameter integer OUTPUT_W    = 24  // 混音结果位宽
)(
    input  logic                              sys_clk, // 系统主时钟
    input  logic                              rst_n,   // 低有效复位
    input  logic                              audio_ce, // 采样边界/更新使能
    input  logic                              sample_valid, // 全部声部样本已对齐有效
    input  logic signed [VOICE_W-1:0]         voice_sample [0:VOICE_COUNT-1], // 各声部样本数组
    input  logic [7:0]                        master_gain, // 总音量，0~255
    output logic signed [OUTPUT_W-1:0]        mixed_sample, // 混音后的有符号样本
    output logic                              mixed_valid // 混音结果有效脉冲
);
    localparam integer LEVELS = (VOICE_COUNT <= 1) ? 0 : $clog2(VOICE_COUNT);
    localparam integer LEAVES = 1 << LEVELS;
    localparam integer SUM_W = VOICE_W + LEVELS;
    localparam integer PROD_W = SUM_W + 9;
    localparam integer CMP_W = (PROD_W > OUTPUT_W) ? PROD_W : OUTPUT_W;
    localparam logic signed [CMP_W-1:0] MAX_OUT =
        CMP_W'($signed({1'b0, {(OUTPUT_W-1){1'b1}}}));
    localparam logic signed [CMP_W-1:0] MIN_OUT =
        CMP_W'($signed({1'b1, {(OUTPUT_W-1){1'b0}}}));
    wire signed [SUM_W-1:0] tree [0:LEVELS][0:LEAVES-1];
    wire [LEVELS:0] valid_pipe;
    wire [7:0] gain_pipe [0:LEVELS];
    assign valid_pipe[0] = sample_valid;
    assign gain_pipe[0] = master_gain;
    for (genvar i=0; i<LEAVES; i++) begin : gen_leaf
        if (i < VOICE_COUNT) assign tree[0][i] = SUM_W'(voice_sample[i]);
        else assign tree[0][i] = '0;
    end
    for (genvar level=1; level<=LEVELS; level++) begin : gen_level
        logic valid_q;
        logic [7:0] gain_q;
        assign valid_pipe[level] = valid_q;
        assign gain_pipe[level] = gain_q;
        always_ff @(posedge sys_clk) begin
            if (!rst_n) begin valid_q <= 1'b0; gain_q <= '0; end
            else begin
                valid_q <= valid_pipe[level-1];
                gain_q <= gain_pipe[level-1];
            end
        end
        for (genvar i=0; i<(LEAVES >> level); i++) begin : gen_add
            logic signed [SUM_W-1:0] sum_q;
            assign tree[level][i] = sum_q;
            always_ff @(posedge sys_clk) begin
                if (!rst_n) sum_q <= '0;
                else if (valid_pipe[level-1])
                    sum_q <= tree[level-1][2*i] + tree[level-1][2*i+1];
            end
        end
    end
    logic signed [PROD_W-1:0] product_q;
    logic product_valid;
    wire signed [CMP_W-1:0] scaled = CMP_W'(product_q >>> 10);
    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            product_q <= '0;
            product_valid <= 1'b0;
            mixed_sample <= '0;
            mixed_valid <= 1'b0;
        end else begin
            product_valid <= valid_pipe[LEVELS];
            if (valid_pipe[LEVELS])
                product_q <= tree[LEVELS][0] * $signed({1'b0, gain_pipe[LEVELS]});
            mixed_valid <= product_valid;
            if (product_valid) begin
                if (scaled > MAX_OUT) mixed_sample <= OUTPUT_W'(MAX_OUT);
                else if (scaled < MIN_OUT) mixed_sample <= OUTPUT_W'(MIN_OUT);
                else mixed_sample <= OUTPUT_W'(scaled);
            end
        end
    end
    // Latency: LEVELS + 2 register stages, throughput: one sample per clock.
    // Gain travels with its sample; saturation and the original >>>10 scale are preserved.
endmodule
