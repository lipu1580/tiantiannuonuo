//=============================================================================
// 文件   : input_top.sv
// 归属   : 成员 2（交互输入与演奏事件模块）唯一公开顶层
// 功能   : 4x4 按键矩阵 + 5 路 FSR 触发 + FSR 力度 + 电位器表情
//          -> 标准演奏事件 + 表情接口。
//
// 【这个模块在系统中的位置】
//
//   4x4 矩阵 ──► key_scan ──► key_debounce ──► key_event_decoder ──┐
//                                                                  │
//   5 路 FSR ──► ADS7830 CH2~CH6 ──► fsr_trigger ───────────────────┼─► event_queue ──► event_* ──► audio_core（成员 1）
//   （FSR 一端接 3.3V，另一端直接进 ADC，实测无需前端电路）          │
//                                                                  │
//   ADS7830 ──► 7 通道采样调度 ──► fsr_filter ──► expression ───────┘
//                            └──► expression_mapper ──► pitch_bend / waveform_sel
//
// 【建议阅读顺序】
//   key_scan.sv -> key_debounce.sv -> note_map.sv -> key_event_decoder.sv
//   -> fsr_trigger.sv -> event_queue.sv -> adc_ads7830.sv -> fsr_filter.sv
//   -> expression_mapper.sv -> input_event_stub.sv -> 本文件（看拼装）
//
// 【一句话理解】
//   本模块把“物理按键/压力/旋钮”翻译成“MIDI 事件 + 表情控制字”，
//   并且用 valid/ready 握手把事件安全地交给成员 1 的 audio_core。
//
// 【时钟/复位】
//   全部逻辑工作在 sys_clk 单时钟域；rst_n 低有效，采用同步复位。
//
// 【事件握手规则】
//   event_valid=1 且 event_ready=1 的时钟上升沿完成一次传输；
//   event_ready=0 时本模块必须保持事件字段不变，事件由 event_queue 缓存。
//
// 【重要说明】
//   1. 成员 1 只需例化本模块，并把 event_* / expr_* 接到 audio_core。
//   2. ADS7830 是 I2C 器件，物理接口为 adc_scl/adc_sda_oe/adc_sda_i；
//      板级顶层用三态缓冲把 oe 转换成双向 SDA。
//   3. ADC 通道分配（通过参数可改）：
//      CH0=FSR 表情、CH1=电位器、CH2~CH6=5 路 FSR 触发(P0~P4)、CH7=备用。
//      调度顺序 CH2..CH6 -> CH0 -> CH1，触发通道优先以降低延迟。
//   4. test_mode=1 时事件源切换为 input_event_stub，真实按键事件被排空丢弃；
//      表情仍来自实际 ADC，waveform_sel 强制为正弦波。
//   5. 成员 1 的 audio_core 内部也有测试音源，两套 test_mode 不要同时打开。
//   6. 事件优先级：ALL_NOTES_OFF > FSR 触发 > 矩阵按键。
//=============================================================================
import audio_defs_pkg::EVENT_ALL_NOTES_OFF;
import audio_defs_pkg::DEFAULT_VELOCITY;

module input_top #(
    //-------------------------------------------------------------------------
    // 系统/矩阵规模
    //-------------------------------------------------------------------------
    parameter integer SYS_CLK_HZ       = project_params_pkg::SYS_CLK_HZ,           // 系统时钟 27 MHz
    parameter integer ROW_COUNT        = project_params_pkg::KEY_ROW_COUNT,        // 矩阵行数，默认 4
    parameter integer COL_COUNT        = project_params_pkg::KEY_COL_COUNT,        // 矩阵列数，默认 4
    parameter integer KEY_COUNT        = ROW_COUNT * COL_COUNT, // 总按键数，默认 16

    //-------------------------------------------------------------------------
    // 扫描与消抖
    //   ROW_DWELL_CYC = 27e6 / (2000 * 4) = 3375 拍 ≈ 125 us/行
    //   整帧 = 4 * 125 us = 500 us，即矩阵刷新率 2 kHz
    //-------------------------------------------------------------------------
    parameter integer ROW_DWELL_CYC    = SYS_CLK_HZ / (project_params_pkg::MATRIX_FRAME_HZ * ROW_COUNT),
    parameter integer PRESS_CYCLES     = (SYS_CLK_HZ / 1000) * project_params_pkg::KEY_PRESS_MS,   // 2 ms
    parameter integer RELEASE_CYCLES   = (SYS_CLK_HZ / 1000) * project_params_pkg::KEY_RELEASE_MS, // 5 ms
    parameter logic   ROW_ACTIVE_LOW   = 1'b1,  // 行低有效：当前扫描行输出 0
    parameter logic   COL_ACTIVE_LOW   = 1'b1,  // 列低有效：按下时列被拉低

    //-------------------------------------------------------------------------
    // ADS7830 I2C 与采样调度
    //   I2C_QUARTER_DIV：I2C 每个 1/4 位占用的 sys_clk 拍数
    //       27e6 / (400e3 * 4) = 16.875 -> 整数 16
    //       实际 SCL ≈ 27e6 / (16 * 4) = 421.9 kHz
    //   SAMPLE_INTERVAL：一次转换完成后再等待多少拍才发起下一次请求
    //       27e6 / (1e6 / 20) = 540 拍 = 20 us（ADC_SAMPLE_INTERVAL_US=20）
    //   7 通道轮询：CH2 CH3 CH4 CH5 CH6(FSR 触发) -> CH0(FSR 表情) -> CH1(POT) -> 循环
    //       单次 I2C 事务（地址+命令+读）约 100 us，加 20 us 间隔
    //       一轮 7 通道约 0.84 ms
    //-------------------------------------------------------------------------
    parameter integer I2C_QUARTER_DIV  = SYS_CLK_HZ / (project_params_pkg::ADC_I2C_HZ * 4),
    parameter integer SAMPLE_INTERVAL  = SYS_CLK_HZ / (1_000_000 / project_params_pkg::ADC_SAMPLE_INTERVAL_US),
    parameter logic [2:0] FSR_CHANNEL  = project_params_pkg::FSR_ADC_CHANNEL,      // FSR 接 CH0
    parameter logic [2:0] POT_CHANNEL  = project_params_pkg::POT_ADC_CHANNEL,      // 电位器接 CH1

    //-------------------------------------------------------------------------
    // 事件与音符
    //-------------------------------------------------------------------------
    parameter integer EVENT_FIFO_DEPTH = project_params_pkg::EVENT_FIFO_DEPTH,     // 事件 FIFO 深度，默认 8
    parameter logic [6:0] BASE_NOTE    = project_params_pkg::NOTE_BASE_C4,         // K0 对应 MIDI 60 (C4)

    //-------------------------------------------------------------------------
    // 矩阵/压电演奏模式
    //   MATRIX_MODE=0：矩阵当键盘（当前测试模式），K0~K11 直接发 NOTE_ON
    //   MATRIX_MODE=1：矩阵选根音，5 路压电触发（最终演奏模式）
    //-------------------------------------------------------------------------
    parameter integer MATRIX_MODE      = 0,

    //-------------------------------------------------------------------------
    // 5 路 FSR 触发输入
    //   参数名不能和 package 参数同名，否则会在模块内遮蔽。
    //-------------------------------------------------------------------------
    parameter logic [2:0] TRIG_BASE_CH   = project_params_pkg::TRIGGER_ADC_CHANNEL_BASE, // P0 所在 ADC 通道
    parameter logic [7:0] TRIG_THRESH    = project_params_pkg::TRIGGER_THRESHOLD,        // 触发阈值
    parameter integer     TRIG_HYST      = project_params_pkg::TRIGGER_RELEASE_HYST,     // 释放回差
    parameter integer     TRIG_REL_SAMP  = project_params_pkg::TRIGGER_RELEASE_SAMPLES,  // 释放确认样本数
    parameter integer     TRIG_OFF_MS    = project_params_pkg::TRIGGER_NOTE_OFF_MS,      // 兜底 NOTE_OFF 时间
    parameter integer     TRIG_RETRIG_MS = project_params_pkg::TRIGGER_RETRIGGER_MS,     // 防重复触发窗口
    parameter logic [7:0] TRIG_VEL_FULL  = project_params_pkg::TRIGGER_VEL_FULL_SCALE    // 力度满量程 ADC 值
)(
    //-------------------------------------------------------------------------
    // 时钟与复位（整颗模块单时钟域）
    //-------------------------------------------------------------------------
    input  logic        sys_clk,
    input  logic        rst_n,          // 低有效，同步复位

    //-------------------------------------------------------------------------
    // 4x4 按键矩阵
    //   key_row：同一时刻只有一行有效（默认低有效）
    //   key_col：列输入，外部上拉；按下时被拉低
    //-------------------------------------------------------------------------
    output logic [ROW_COUNT-1:0] key_row,
    input  logic [COL_COUNT-1:0] key_col,

    //-------------------------------------------------------------------------
    // ADS7830 I2C（ADS7830 是 I2C 器件，不是 SPI）
    //   板级顶层：assign adc_sda = adc_sda_oe ? 1'b0 : 1'bz;
    //-------------------------------------------------------------------------
    output logic        adc_scl,        // I2C SCL
    output logic        adc_sda_oe,     // 1=拉低 SDA，0=释放（靠外部上拉为高）
    input  logic        adc_sda_i,      // SDA 回读

    //-------------------------------------------------------------------------
    // 演奏事件（成员 2 -> 成员 1）
    //   传输条件：event_valid && event_ready 的 sys_clk 上升沿
    //-------------------------------------------------------------------------
    output logic        event_valid,    // 本模块驱动
    input  logic        event_ready,    // audio_core 驱动：能接收时置 1
    output logic [1:0]  event_type,     // 00=NOP 01=NOTE_ON 10=NOTE_OFF 11=ALL_OFF
    output logic [6:0]  event_note_id,  // MIDI 0~127
    output logic [7:0]  event_velocity, // NOTE_ON 力度 1~255；NOTE_OFF 为 0

    //-------------------------------------------------------------------------
    // 表情接口（成员 2 -> 成员 1）
    //   这些不是事件，可持续更新；只需在 sys_clk 域内稳定
    //-------------------------------------------------------------------------
    output logic        expr_valid,     // FSR 至少完成一次采样
    output logic [7:0]  expression,     // FSR 持续压力 0~255
    output logic [11:0] pitch_bend,     // 0~4095，中点 2048
    output logic [1:0]  waveform_sel,   // 0=正弦 1=方波 2=锯齿 3=预留

    //-------------------------------------------------------------------------
    // 测试模式
    //   test_mode=1：事件源改用 input_event_stub（真实按键事件被丢弃）
    //-------------------------------------------------------------------------
    input  logic        test_mode,
    input  logic [1:0]  test_pattern,

    //-------------------------------------------------------------------------
    // 调试输出（可接 LED / 逻辑分析仪，不影响事件握手）
    //-------------------------------------------------------------------------
    output logic [KEY_COUNT-1:0] key_down,   // 消抖后的按键状态
    output logic [7:0]  fsr_raw,             // FSR 原始 ADC 值
    output logic [7:0]  fsr_filtered,        // FSR 滤波值
    output logic [3:0]  input_state,         // {test_mode,pressure_valid,adc_busy,event_valid}
    output logic        adc_busy,            // ADS7830 正忙
    output logic        adc_valid,           // ADC 样本有效（单周期）
    output logic        adc_bus_error,       // I2C NACK/异常
    output logic        input_overflow,      // 事件 FIFO 溢出
    output logic signed [3:0] octave_debug,  // 当前八度偏移 -2~+2

    //-------------------------------------------------------------------------
    // 压电输入调试/控制
    //-------------------------------------------------------------------------
    output logic [4:0]  piezo_peak_rst,      // 旧压电峰值放电：新方案无此硬件，恒为 0（保留端口兼容板级约束）
    output logic [4:0]  piezo_hit_debug,     // 5 路 FSR 电平是否超过阈值
    output logic [4:0]  piezo_active_debug,  // 5 路 FSR 是否正在发声
    output logic [6:0]  base_note_debug      // 当前根音（含八度）
);

    //-------------------------------------------------------------------------
    // 按键扫描 + 消抖
    //-------------------------------------------------------------------------
    logic [KEY_COUNT-1:0] raw_key_state;
    logic [KEY_COUNT-1:0] key_pressed;
    logic [KEY_COUNT-1:0] key_released;

    key_scan #(
        .SYS_CLK_HZ     (SYS_CLK_HZ),
        .ROW_COUNT      (ROW_COUNT),
        .COL_COUNT      (COL_COUNT),
        .ROW_DWELL_CYC  (ROW_DWELL_CYC),
        .ROW_ACTIVE_LOW (ROW_ACTIVE_LOW),
        .COL_ACTIVE_LOW (COL_ACTIVE_LOW)
    ) u_key_scan (
        .sys_clk           (sys_clk),
        .rst_n             (rst_n),
        .key_row           (key_row),
        .key_col           (key_col),
        .raw_key_state     (raw_key_state),
        .scan_row_debug    (),
        .scan_sample_debug ()
    );

    key_debounce #(
        .KEY_COUNT      (KEY_COUNT),
        .PRESS_CYCLES   (PRESS_CYCLES),
        .RELEASE_CYCLES (RELEASE_CYCLES)
    ) u_key_debounce (
        .sys_clk      (sys_clk),
        .rst_n        (rst_n),
        .key_raw      (raw_key_state),
        .key_down     (key_down),
        .key_pressed  (key_pressed),
        .key_released (key_released)
    );

    //-------------------------------------------------------------------------
    // ADC 采样调度：7 通道轮询
    //
    //   顺序：CH2 CH3 CH4 CH5 CH6 CH0 CH1
    //   先采 5 路 FSR 触发，保证触发延迟最低；表情 FSR/电位器变化慢，放在后面。
    //   一轮 7 通道约 (100 us + SAMPLE_INTERVAL) * 7，
    //   默认 SAMPLE_INTERVAL=20 us -> 一轮约 0.84 ms。
    //
    // 关键信号：
    //   req_pending   : 已产生请求，等待 ADC 在它自己的位速率 tick 上接收
    //   sample_req    : 组合输出，真正送给 adc_ads7830 的电平
    //   sample_busy_d : busy 的上一拍值，用于检测 busy 的上升沿
    //   scan_idx      : 当前轮询位置 0~6
    //   adc_ch_sel    : 本轮要采的 ADC 通道
    //
    // 注意：不能看到 sample_req=1 就立刻清 pending。ADC 只在位速率 tick
    //       上采样 sample_req，过早清除会导致请求丢失。
    //-------------------------------------------------------------------------
    localparam integer ADC_SCAN_COUNT  = 7;
    localparam integer SAMPLE_WAIT_MAX = (SAMPLE_INTERVAL < 4) ? 4 : SAMPLE_INTERVAL;
    localparam integer WAIT_W          = $clog2(SAMPLE_WAIT_MAX + 1);

    logic [WAIT_W-1:0] sample_wait;     // 空闲等待计数器
    logic              req_pending;     // 有请求待 ADC 接收
    logic [2:0]        scan_idx;        // 7 通道轮询位置
    logic [2:0]        adc_ch_sel;      // 本轮通道
    logic              sample_busy_d;   // busy 打一拍

    logic              sample_req;      // 请求电平
    logic              sample_busy;     // ADC 忙
    logic              sample_valid;    // ADC 样本有效（单周期）
    logic [7:0]        sample_data;     // ADC 数据
    logic [2:0]        sample_channel;  // 样点对应通道
    logic              adc_bus_error_r; // I2C 错误

    // 通道顺序：FSR 触发优先，表情 FSR/电位器最后
    always_comb begin
        case (scan_idx)
            3'd0:    adc_ch_sel = TRIG_BASE_CH;
            3'd1:    adc_ch_sel = TRIG_BASE_CH + 3'd1;
            3'd2:    adc_ch_sel = TRIG_BASE_CH + 3'd2;
            3'd3:    adc_ch_sel = TRIG_BASE_CH + 3'd3;
            3'd4:    adc_ch_sel = TRIG_BASE_CH + 3'd4;
            3'd5:    adc_ch_sel = FSR_CHANNEL;
            default: adc_ch_sel = POT_CHANNEL;
        endcase
    end

    // 只要还有 pending 且 ADC 空闲，就把请求电平拉高；
    // ADC 会在下一个 tick 看到它并置 busy。
    assign sample_req = req_pending && !sample_busy;

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            sample_wait   <= '0;
            req_pending   <= 1'b0;
            scan_idx      <= 3'd0;
            sample_busy_d <= 1'b0;
        end else begin
            sample_busy_d <= sample_busy;   // 用于检测 busy 的 0->1

            if (sample_busy && !sample_busy_d) begin
                // busy 上升沿：ADC 已经接收本次请求
                // 清 pending、重新计时，并前进到下一个通道
                req_pending <= 1'b0;
                sample_wait <= '0;
                scan_idx    <= (scan_idx == 3'(ADC_SCAN_COUNT - 1))
                               ? 3'd0 : scan_idx + 1'b1;
            end else if (!req_pending && !sample_busy) begin
                // 空闲且没有待发请求：等够 SAMPLE_INTERVAL 后置 pending
                if (sample_wait == WAIT_W'(SAMPLE_WAIT_MAX - 1)) begin
                    sample_wait <= '0;
                    req_pending <= 1'b1;
                end else begin
                    sample_wait <= sample_wait + 1'b1;
                end
            end
        end
    end

    adc_ads7830 #(
        .SYS_CLK_HZ  (SYS_CLK_HZ),
        .QUARTER_DIV (I2C_QUARTER_DIV)
    ) u_adc (
        .sys_clk         (sys_clk),
        .rst_n           (rst_n),
        .sample_req      (sample_req),
        .adc_channel_req (adc_ch_sel),
        .sample_busy     (sample_busy),
        .sample_valid    (sample_valid),
        .sample_data     (sample_data),
        .sample_channel  (sample_channel),
        .bus_error       (adc_bus_error_r),
        .adc_scl         (adc_scl),
        .adc_sda_oe      (adc_sda_oe),
        .adc_sda_i       (adc_sda_i)
    );

    //-------------------------------------------------------------------------
    // FSR 力度
    //   fsr_filter 只接受 sample_channel == FSR_CHANNEL 的样本；
    //   velocity 是寄存器输出，更新率约 1.4 kHz。
    //   note_velocity 只在 MATRIX_MODE=0（矩阵当键盘）时用于按键力度；
    //   MATRIX_MODE=1 时力度由压电峰值提供，FSR 只做 expression。
    //-------------------------------------------------------------------------
    logic [7:0] fsr_velocity;   // 滤波/映射后的 0~255 力度
    logic       pressure_valid; // 当前压力是否超过噪声门限
    logic       fsr_ready;      // FSR 是否完成过至少一次采样

    fsr_filter #(
        .FILTER_SHIFT (project_params_pkg::FSR_FILTER_SHIFT),
        .NOISE_GATE   (project_params_pkg::FSR_NOISE_GATE)
    ) u_fsr (
        .sys_clk        (sys_clk),
        .rst_n          (rst_n),
        .sample_valid   (sample_valid),
        .sample_channel (sample_channel),
        .sample_data    (sample_data),
        .fsr_channel    (FSR_CHANNEL),
        .fsr_raw        (fsr_raw),
        .fsr_filtered   (fsr_filtered),
        .velocity       (fsr_velocity),
        .pressure_valid (pressure_valid),
        .ready          (fsr_ready)
    );

    // 按下瞬间若 FSR 尚未稳定（例如刚上电），使用默认力度 128，
    // 避免发出 velocity=0 的“听不见的 NOTE_ON”。
    logic [7:0] note_velocity;
    assign note_velocity = pressure_valid ? fsr_velocity : DEFAULT_VELOCITY;

    //-------------------------------------------------------------------------
    // 表情：电位器 -> pitch_bend，按键 -> 波形选择
    //   expression_mapper 只接受 sample_channel == POT_CHANNEL 的样本。
    //   它的 pot_raw/expr_valid 调试口本层不使用，故留空。
    //-------------------------------------------------------------------------
    logic [1:0] waveform_key;   // 来自 K14 的波形选择状态

    expression_mapper u_expr (
        .sys_clk          (sys_clk),
        .rst_n            (rst_n),
        .sample_valid     (sample_valid),
        .sample_channel   (sample_channel),
        .sample_data      (sample_data),
        .pot_channel      (POT_CHANNEL),
        .waveform_key_sel (waveform_key),
        .test_mode        (test_mode),
        .pitch_bend       (pitch_bend),
        .pot_raw          (),
        .expr_valid       (),
        .waveform_sel     (waveform_sel)
    );

    // expression 直接使用 FSR 滤波值，并抬升到 EXPR_MIN..255。
    //   若直接输出 fsr_filtered，松手时为 0，audio_core 的
    //   envelope = level × velocity × expression 会被乘成 0 → 整件乐器无声。
    //   映射到 EXPR_MIN..255 后，松手仍保留基线音量，按下才推到满。
    localparam logic [7:0] EXPR_MIN = project_params_pkg::EXPR_MIN;
    logic [15:0] expr_span;

    assign expr_valid = fsr_ready;
    assign expr_span  = 16'(fsr_filtered) * 16'(8'd255 - EXPR_MIN);
    assign expression = EXPR_MIN + 8'(expr_span >> 8);

    //-------------------------------------------------------------------------
    // 按键/FSR 触发事件 -> 仲裁 -> FIFO
    //
    //   两路事件源：
    //     matrix_req_*：矩阵译码器（NOTE_ON/OFF/ALL_NOTES_OFF）
    //     trig_req_*  ：5 路 FSR 触发（NOTE_ON / 电平释放 NOTE_OFF）
    //
    //   仲裁优先级：
    //     1. ALL_NOTES_OFF（矩阵）—— 最高，先清掉所有声部
    //     2. FSR 触发事件 —— 优先于普通矩阵事件
    //     3. 矩阵普通事件
    //
    //   未被选中的源会把事件保持在各自的 pending 表中，直到 ready。
    //-------------------------------------------------------------------------
    logic        matrix_req_valid;
    logic        matrix_req_ready;
    logic [1:0]  matrix_req_type;
    logic [6:0]  matrix_req_note;
    logic [7:0]  matrix_req_vel;

    logic        trig_req_valid;
    logic        trig_req_ready;
    logic [1:0]  trig_req_type;
    logic [6:0]  trig_req_note;
    logic [7:0]  trig_req_vel;

    logic [6:0]  base_note;       // 当前根音（含八度）
    logic        trig_all_off;    // ALL_NOTES_OFF 被接收时清触发状态

    logic        queue_wr_valid;
    logic        queue_wr_ready;
    logic [1:0]  queue_wr_type;
    logic [6:0]  queue_wr_note;
    logic [7:0]  queue_wr_vel;

    logic        queue_valid;
    logic        queue_ready;
    logic [1:0]  queue_type;
    logic [6:0]  queue_note;
    logic [7:0]  queue_vel;

    //-------------------------------------------------------------------------
    // 矩阵译码器
    //   MATRIX_MODE=0：K0~K11 直接发 NOTE_ON/OFF（当前测试模式）
    //   MATRIX_MODE=1：K0~K11 只更新 base_note，不发 NOTE_ON（最终模式）
    //-------------------------------------------------------------------------
    key_event_decoder #(
        .KEY_COUNT      (KEY_COUNT),
        .NOTE_KEY_COUNT (12),
        .BASE_NOTE      (BASE_NOTE),
        .MATRIX_MODE    (MATRIX_MODE)
    ) u_decoder (
        .sys_clk          (sys_clk),
        .rst_n            (rst_n),
        .key_pressed      (key_pressed),
        .key_released     (key_released),
        .key_down         (key_down),
        .velocity_in      (note_velocity),
        .event_req_valid  (matrix_req_valid),
        .event_req_ready  (matrix_req_ready),
        .event_req_type   (matrix_req_type),
        .event_req_note   (matrix_req_note),
        .event_req_velocity (matrix_req_vel),
        .octave_offset    (octave_debug),
        .waveform_sel     (waveform_key),
        .base_note        (base_note),
        .active_note_mask ()
    );

    //-------------------------------------------------------------------------
    // 5 路 FSR 触发
    //   ADC 样本 -> 阈值/迟滞 -> NOTE_ON + velocity
    //                        -> 电平释放判定 -> NOTE_OFF
    //   无峰值保持、无放电 MOSFET，硬件只需 FSR 直接接 ADC 通道。
    //-------------------------------------------------------------------------
    fsr_trigger #(
        .SYS_CLK_HZ      (SYS_CLK_HZ),
        .THRESHOLD       (TRIG_THRESH),
        .RELEASE_HYST    (TRIG_HYST),
        .RELEASE_SAMPLES (TRIG_REL_SAMP),
        .RETRIGGER_MS    (TRIG_RETRIG_MS),
        .NOTE_OFF_MS     (TRIG_OFF_MS),
        .VEL_FULL_SCALE  (TRIG_VEL_FULL)
    ) u_trig (
        .sys_clk            (sys_clk),
        .rst_n              (rst_n),
        .sample_valid       (sample_valid),
        .sample_channel     (sample_channel),
        .sample_data        (sample_data),
        .trig_ch_base       (TRIG_BASE_CH),
        .base_note          (base_note),
        .all_off            (trig_all_off),
        .event_req_valid    (trig_req_valid),
        .event_req_ready    (trig_req_ready),
        .event_req_type     (trig_req_type),
        .event_req_note     (trig_req_note),
        .event_req_velocity (trig_req_vel),
        .hit_debug          (piezo_hit_debug),
        .active_debug       (piezo_active_debug),
        .level_debug        ()
    );

    // 旧压电方案的峰值电容放电已不存在，端口固化输出 0（兼容板级约束）
    assign piezo_peak_rst = 5'd0;

    //-------------------------------------------------------------------------
    // 事件仲裁：ALL_OFF > FSR 触发 > 矩阵普通事件
    //-------------------------------------------------------------------------
    logic matrix_sel;
    logic trig_sel;

    always_comb begin
        matrix_sel = 1'b0;
        trig_sel   = 1'b0;

        if (matrix_req_valid && (matrix_req_type == EVENT_ALL_NOTES_OFF)) begin
            matrix_sel = 1'b1;
        end else if (trig_req_valid) begin
            trig_sel = 1'b1;
        end else if (matrix_req_valid) begin
            matrix_sel = 1'b1;
        end
    end

    //-------------------------------------------------------------------------
    // 输出保持（1 深度 skid buffer）
    //
    //   目的：满足 valid/ready 协议——一旦 queue_wr_valid=1，字段必须保持到
    //   queue_wr_ready=1。上游（矩阵译码器/FSR 触发）在背压期间可能产生
    //   新事件，若直接组合输出，字段会被改写（记 F-17）。
    //
    //   规则：
    //     - skid 空且 FIFO 能收：本拍直接写入 FIFO，源收到 ready；
    //     - skid 空且 FIFO 满：本拍把事件锁进 skid，源仍收到 ready；
    //     - skid 非空：只把 skid 里的事件送去 FIFO，源暂时不给 ready。
    //-------------------------------------------------------------------------
    logic        hold_valid;
    logic [1:0]  hold_type;
    logic [6:0]  hold_note;
    logic [7:0]  hold_vel;

    wire sel_valid = matrix_sel | trig_sel;

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            hold_valid <= 1'b0;
            hold_type  <= 2'b00;
            hold_note  <= '0;
            hold_vel   <= '0;
        end else if (hold_valid) begin
            if (queue_wr_ready) begin
                hold_valid <= 1'b0;
            end
        end else if (sel_valid && !queue_wr_ready) begin
            // FIFO 本拍收不下：先存进 skid，保证字段不再变化
            hold_valid <= 1'b1;
            hold_type  <= matrix_sel ? matrix_req_type : trig_req_type;
            hold_note  <= matrix_sel ? matrix_req_note : trig_req_note;
            hold_vel   <= matrix_sel ? matrix_req_vel  : trig_req_vel;
        end
    end

    // 只有确实能进 FIFO 时才拉高 valid，避免被 event_queue 误判为 overflow。
    // wr_ready 只由 FIFO 内部计数决定，不依赖 wr_valid，所以这样门控是安全的。
    assign queue_wr_valid = (hold_valid || sel_valid) && queue_wr_ready;
    assign queue_wr_type  = hold_valid ? hold_type :
                            (matrix_sel ? matrix_req_type : trig_req_type);
    assign queue_wr_note  = hold_valid ? hold_note :
                            (matrix_sel ? matrix_req_note : trig_req_note);
    assign queue_wr_vel   = hold_valid ? hold_vel  :
                            (matrix_sel ? matrix_req_vel  : trig_req_vel);

    // 源在事件被 FIFO 或 skid 接收后即可清除槽位
    assign matrix_req_ready = matrix_sel && !hold_valid;
    assign trig_req_ready   = trig_sel   && !hold_valid;

    // ALL_OFF 被 FIFO 接收的同拍，通知 fsr_trigger 清活跃状态/待发事件
    assign trig_all_off = matrix_req_valid &&
                          (matrix_req_type == EVENT_ALL_NOTES_OFF) &&
                          matrix_req_ready;

    //-------------------------------------------------------------------------
    // 事件 FIFO
    //-------------------------------------------------------------------------
    event_queue #(
        .DEPTH  (EVENT_FIFO_DEPTH),
        .NOTE_W (7)
    ) u_event_queue (
        .sys_clk        (sys_clk),
        .rst_n          (rst_n),
        .wr_valid       (queue_wr_valid),
        .wr_ready       (queue_wr_ready),
        .wr_type        (queue_wr_type),
        .wr_note        (queue_wr_note),
        .wr_vel         (queue_wr_vel),
        .rd_valid       (queue_valid),
        .rd_ready       (queue_ready),
        .rd_type        (queue_type),
        .rd_note        (queue_note),
        .rd_vel         (queue_vel),
        .overflow       (input_overflow),
        .overflow_clear (1'b0),
        .level          ()
    );

    //-------------------------------------------------------------------------
    // 无硬件测试事件源
    //   只有 test_mode=1 时它才被接到输出；否则 stub_ready 恒为 0，
    //   它的事件会一直停在 valid=1，不会影响真实事件链路。
    //-------------------------------------------------------------------------
    logic       stub_valid;
    logic       stub_ready;
    logic [1:0] stub_type;
    logic [6:0] stub_note;
    logic [7:0] stub_vel;

    input_event_stub #(
        .SYS_CLK_HZ (SYS_CLK_HZ)
    ) u_event_stub (
        .sys_clk       (sys_clk),
        .rst_n         (rst_n),
        .test_pattern  (test_pattern),
        .event_valid   (stub_valid),
        .event_ready   (stub_ready),
        .event_type    (stub_type),
        .event_note_id (stub_note),
        .event_velocity(stub_vel)
    );

    //-------------------------------------------------------------------------
    // 事件源选择
    //
    //   非测试模式：
    //     queue_valid/queue_* 直接送到 event_*；queue_ready = event_ready，
    //     FIFO 中的事件在下游接收时弹出。
    //
    //   测试模式：
    //     stub_valid/stub_* 送到 event_*；stub_ready = event_ready；
    //     同时 queue_ready 恒为 1，把真实按键事件“排空丢弃”，避免 FIFO
    //     长期堵塞后溢出或把旧事件带到退出测试模式之后。
    //-------------------------------------------------------------------------
    assign stub_ready  = test_mode ? event_ready : 1'b0;
    assign queue_ready = test_mode ? 1'b1        : event_ready;

    assign event_valid    = test_mode ? stub_valid : queue_valid;
    assign event_type     = test_mode ? stub_type  : queue_type;
    assign event_note_id  = test_mode ? stub_note  : queue_note;
    assign event_velocity = test_mode ? stub_vel   : queue_vel;

    //-------------------------------------------------------------------------
    // 调试
    //   input_state[3] = test_mode
    //   input_state[2] = pressure_valid
    //   input_state[1] = adc_busy
    //   input_state[0] = event_valid
    //   piezo_*_debug 单独给出，便于观察 5 路 FSR 触发状态。
    //-------------------------------------------------------------------------
    assign adc_busy       = sample_busy;
    assign adc_valid      = sample_valid;
    assign adc_bus_error  = adc_bus_error_r;
    assign input_state    = {test_mode, pressure_valid, sample_busy, event_valid};
    assign base_note_debug = base_note;

endmodule
