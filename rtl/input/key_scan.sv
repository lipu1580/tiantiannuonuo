//=============================================================================
// 文件   : key_scan.sv
// 归属   : 成员 2（交互输入与演奏事件模块）
// 功能   : 4x4（可参数化）按键矩阵行扫描，产生原始按键状态。
//
// 【硬件模型】
//   行线：FPGA 输出，同一时刻只有一行有效（默认低有效）。
//   列线：外部上拉，按键把行和列短接；扫描到某行时，该行按下的键
//         会把对应列拉低。
//
// 【一次扫描的时间轴（默认 27 MHz）】
//
//   dwell_cnt : 0   1   2 ... SETTLE_CYC ... DWELL_CYC-1 | 0 ...
//   key_row   : <----- 当前行保持有效 -------------------> | 下一行
//   key_col   : 行切换后可能有寄生电容/上拉爬升，先等 SETTLE_CYC
//   sampling  :                     ▲ 在这里采样一次
//
//   SETTLE_CYC = 8 拍（约 0.3 us），DWELL_CYC 默认 3375 拍（125 us）。
//   4 行共 500 us，即整张矩阵刷新率 2 kHz。
//
// 【本模块不做什么】
//   - 不做消抖（key_debounce.sv 负责）
//   - 不解释按键含义（note_map.sv 负责）
//   - 不做按键按下/释放边沿（key_debounce.sv 负责）
//=============================================================================
module key_scan #(
    parameter integer SYS_CLK_HZ     = project_params_pkg::SYS_CLK_HZ,   // 系统时钟
    parameter integer ROW_COUNT      = project_params_pkg::KEY_ROW_COUNT, // 行数
    parameter integer COL_COUNT      = project_params_pkg::KEY_COL_COUNT, // 列数
    // 默认整帧刷新率 2 kHz，即单行驻留 125 us
    parameter integer ROW_DWELL_CYC  = SYS_CLK_HZ / (project_params_pkg::MATRIX_FRAME_HZ * ROW_COUNT), //每行停留多少拍
    parameter integer SETTLE_CYC     = 8,             // 行切换后的等待拍数
    // 行/列有效电平：1 表示低有效（配合外部上拉）
    parameter logic   ROW_ACTIVE_LOW = 1'b1,
    parameter logic   COL_ACTIVE_LOW = 1'b1,
    parameter integer ROW_W          = (ROW_COUNT <= 1) ? 1 : $clog2(ROW_COUNT) //行号计数器的位宽2，2位宽表示4行足够
                                                        //这么写其实没啥用，我们不会换成8x8矩阵的
)(
    input  logic                            sys_clk,
    input  logic                            rst_n,

    // 行驱动：只有当前扫描行有效，其余保持无效电平
    output logic [ROW_COUNT-1:0]            key_row,
    // 列输入：必须先同步再使用
    input  logic [COL_COUNT-1:0]            key_col,    //[3:0]

    // 原始按键状态：bit[row*COL_COUNT + col]，1=按下（已归一化极性）
    output logic [ROW_COUNT*COL_COUNT-1:0]  raw_key_state,

    // 调试：当前扫描行 / 本拍是否采样
    output logic [ROW_W-1:0]                scan_row_debug,
    output logic                            scan_sample_debug,

    //-------------------------------------------------------------------------
    // 矩阵组合告警（无二极管矩阵的固有限制，见文件末尾说明）
    //   ghost_detect  : 某个 2x2 矩形里出现了 3 个及以上按键
    //                   -> 第 4 个角会被误读成“按下”（鬼键）
    //   row_conflict  : 同一列上跨行出现 2 个及以上按键
    //                   -> 未选中的行正在输出高电平，会与选中行的低电平
    //                      通过两个按键直接短路（行驱动争用）
    //   这两路只是告警，不改变扫描结果；要彻底消除请给每个按键串二极管。
    //-------------------------------------------------------------------------
    output logic                            ghost_detect,
    output logic                            row_conflict
);

    localparam integer DWELL_CYC = (ROW_DWELL_CYC < (SETTLE_CYC + 2))
                                   ? (SETTLE_CYC + 2) : ROW_DWELL_CYC;
    localparam integer DWELL_W   = (DWELL_CYC <= 1) ? 1 : $clog2(DWELL_CYC);    //存放DWELL的容器需要12位宽

    //-------------------------------------------------------------------------
    // 列输入同步（两级触发器）
    //   外部列线相对 sys_clk 是异步的，直接采样可能进入亚稳态。
    //   col_meta 是第一级，col_sync 是第二级；后面只用 col_sync。
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
    //   dwell_cnt：当前行已经保持了多久
    //   row_idx  ：当前扫描到第几行
    //   每到 DWELL_CYC-1 就切到下一行；在一行中间只采样一次。
    //-------------------------------------------------------------------------
    logic [ROW_W-1:0]   row_idx;
    logic [DWELL_W-1:0] dwell_cnt;

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            row_idx       <= '0;
            dwell_cnt     <= '0;
            raw_key_state <= '0;     // 上电默认全部未按下
        end else if (dwell_cnt == DWELL_W'(DWELL_CYC - 1)) begin
            // 当前行驻留结束，切到下一行（环形）
            dwell_cnt <= '0;
            row_idx   <= (row_idx == ROW_W'(ROW_COUNT - 1)) ? '0 : row_idx + 1'b1;
        end else begin
            dwell_cnt <= dwell_cnt + 1'b1;      //其实这一步非常重要，是整个模块中的周期更新计数器的自增行

            // 行电平稳定后采样一次，本行其余时间保持上次结果。
            // 这样即使行切换瞬间有毛刺，也不会写进 raw_key_state。
            if (dwell_cnt == DWELL_W'(SETTLE_CYC)) begin
                for (int c = 0; c < COL_COUNT; c++) begin
                    // COL_ACTIVE_LOW=1：列低表示按下，所以取反；
                    // 输出统一成“1=按下”，上层不需要关心硬件极性。
                    raw_key_state[row_idx * COL_COUNT + c]
                        <= COL_ACTIVE_LOW ? ~col_sync[c] : col_sync[c];
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // 行驱动：只有一个有效行，其余保持无效电平
    //   先把所有行置为无效电平，再把当前行改成有效电平。
    //   ROW_ACTIVE_LOW=1 时：无效=1，有效=0。
    //-------------------------------------------------------------------------
    always_comb begin
        key_row = {ROW_COUNT{ROW_ACTIVE_LOW}};          // 批量拼接全部为无效电平
        key_row[row_idx] = ~ROW_ACTIVE_LOW;             // 当前行有效
    end

    assign scan_row_debug    = row_idx;
    assign scan_sample_debug = (dwell_cnt == DWELL_W'(SETTLE_CYC));

    //-------------------------------------------------------------------------
    // 矩阵组合告警（组合逻辑，只做检测，不修改扫描结果）
    //
    //   无二极管矩阵的两个已知问题：
    //   1. 同列跨行双键：选中行输出低、未选中行输出高，两个按键会把
    //      这两个行输出直接短接 —— 电学上是行驱动争用，可能过热/损坏。
    //   2. L 形三键：扫描某一行时，另一个未按的键会被误读成按下（鬼键）。
    //   本模块用 raw_key_state 做检测：出现这些组合时拉高对应告警，
    //   便于上层提示“当前键位组合不可靠”。真正的解决办法是每键串
    //   1N4148（或换成只按单个根音键的配置模式）。
    //-------------------------------------------------------------------------
    always_comb begin
        // 2 位足够表示 0~4 个角的和（显式位宽，避免依赖表达式的上下文位宽）
        logic [2:0] corner_sum;

        ghost_detect = 1'b0;
        row_conflict = 1'b0;
        corner_sum   = 3'd0;

        // 1) 同列跨行：>=2 个按键
        for (int c = 0; c < COL_COUNT; c++) begin
            for (int r0 = 0; r0 < ROW_COUNT; r0++) begin
                for (int r1 = 0; r1 < ROW_COUNT; r1++) begin
                    if ((r1 > r0) && raw_key_state[r0*COL_COUNT + c] &&
                        raw_key_state[r1*COL_COUNT + c]) begin
                        row_conflict = 1'b1;
                    end
                end
            end
        end

        // 2) 2x2 矩形内 >=3 个按键：第 4 个角会被误读
        for (int r0 = 0; r0 < ROW_COUNT; r0++) begin
            for (int r1 = 0; r1 < ROW_COUNT; r1++) begin
                for (int c0 = 0; c0 < COL_COUNT; c0++) begin
                    for (int c1 = 0; c1 < COL_COUNT; c1++) begin
                        if ((r1 > r0) && (c1 > c0)) begin
                            corner_sum = {2'd0, raw_key_state[r0*COL_COUNT + c0]}
                                       + {2'd0, raw_key_state[r0*COL_COUNT + c1]}
                                       + {2'd0, raw_key_state[r1*COL_COUNT + c0]}
                                       + {2'd0, raw_key_state[r1*COL_COUNT + c1]};
                            if (corner_sum >= 3'd3) begin
                                ghost_detect = 1'b1;
                            end
                        end
                    end
                end
            end
        end
    end

endmodule
