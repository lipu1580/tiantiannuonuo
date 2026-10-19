//=============================================================================
// 文件   : key_scan.sv
// 归属   : 成员 2（交互输入与演奏事件模块）
// 功能   : 4x4（可参数化）按键矩阵行扫描，产生原始按键状态。
// 说明   :
//   1. 每次只驱动一行，行切换后等待 SETTLE_CYC 个时钟再采样，避免上一行
//      残留电平串扰。
//   2. 列输入先经两级同步器，再进入采样逻辑。
//   3. 输出 raw_key_state 中 1 表示“按下”，与行列有效电平无关。
//   4. 本模块不解释按键含义，不做消抖；消抖由 key_debounce.sv 完成。
//=============================================================================
`include "project_params.svh"

module key_scan #(
    parameter integer SYS_CLK_HZ     = `SYS_CLK_HZ,
    parameter integer ROW_COUNT      = `KEY_ROW_COUNT,
    parameter integer COL_COUNT      = `KEY_COL_COUNT,
    // 默认整帧刷新率 2 kHz，即单行驻留 125 us
    parameter integer ROW_DWELL_CYC  = SYS_CLK_HZ / (`MATRIX_FRAME_HZ * ROW_COUNT),
    parameter integer SETTLE_CYC     = 8,
    // 行/列有效电平：1 表示低有效（配合外部上拉）
    parameter logic   ROW_ACTIVE_LOW = 1'b1,
    parameter logic   COL_ACTIVE_LOW = 1'b1,
    parameter integer ROW_W          = (ROW_COUNT <= 1) ? 1 : $clog2(ROW_COUNT)
)(
    input  logic                            sys_clk,
    input  logic                            rst_n,

    output logic [ROW_COUNT-1:0]            key_row,
    input  logic [COL_COUNT-1:0]            key_col,

    output logic [ROW_COUNT*COL_COUNT-1:0]  raw_key_state,

    output logic [ROW_W-1:0]                scan_row_debug,
    output logic                            scan_sample_debug
);

    localparam integer DWELL_CYC = (ROW_DWELL_CYC < (SETTLE_CYC + 2))
                                   ? (SETTLE_CYC + 2) : ROW_DWELL_CYC;
    localparam integer DWELL_W   = (DWELL_CYC <= 1) ? 1 : $clog2(DWELL_CYC);

    //-------------------------------------------------------------------------
    // 列输入同步（两级触发器）
    //-------------------------------------------------------------------------
    logic [COL_COUNT-1:0] col_meta;
    logic [COL_COUNT-1:0] col_sync;

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            col_meta <= '0;
            col_sync <= '0;
        end else begin
            col_meta <= key_col;
            col_sync <= col_meta;
        end
    end

    //-------------------------------------------------------------------------
    // 行扫描计数器
    //-------------------------------------------------------------------------
    logic [ROW_W-1:0]   row_idx;
    logic [DWELL_W-1:0] dwell_cnt;

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            row_idx       <= '0;
            dwell_cnt     <= '0;
            raw_key_state <= '0;
        end else if (dwell_cnt == DWELL_W'(DWELL_CYC - 1)) begin
            dwell_cnt <= '0;
            row_idx   <= (row_idx == ROW_W'(ROW_COUNT - 1)) ? '0 : row_idx + 1'b1;
        end else begin
            dwell_cnt <= dwell_cnt + 1'b1;

            // 行电平稳定后采样一次，本行其余时间保持上次结果
            if (dwell_cnt == DWELL_W'(SETTLE_CYC)) begin
                for (int c = 0; c < COL_COUNT; c++) begin
                    raw_key_state[row_idx * COL_COUNT + c]
                        <= COL_ACTIVE_LOW ? ~col_sync[c] : col_sync[c];
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // 行驱动：只有一个有效行，其余保持无效电平
    //-------------------------------------------------------------------------
    always_comb begin
        key_row = {ROW_COUNT{ROW_ACTIVE_LOW}};          // 全部为无效电平
        key_row[row_idx] = ~ROW_ACTIVE_LOW;             // 当前行有效
    end

    assign scan_row_debug    = row_idx;
    assign scan_sample_debug = (dwell_cnt == DWELL_W'(SETTLE_CYC));

endmodule
