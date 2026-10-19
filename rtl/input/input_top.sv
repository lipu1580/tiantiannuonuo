//=============================================================================
// 文件   : input_top.sv
// 归属   : 成员 2（交互输入与演奏事件模块）唯一公开顶层
// 功能   : 4x4 按键矩阵 + FSR 力度 + 电位器表情 -> 标准演奏事件 + 表情接口。
//
// 【这个模块在系统中的位置】
//
//   4x4 矩阵 ──► key_scan ──► key_debounce ──► key_event_decoder ──┐
//                                                                  ├─► event_queue ──► event_* ──► audio_core（成员 1）
//   ADS7830 ──► ADC 采样调度 ──► fsr_filter ──► velocity ───────────┘
//                            └──► expression_mapper ──► pitch_bend / waveform_sel
//
// 【建议阅读顺序】
//   key_scan.sv -> key_debounce.sv -> note_map.sv -> key_event_decoder.sv
//   -> event_queue.sv -> adc_ads7830.sv -> fsr_filter.sv
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
//   3. ADC 通道默认 CH0=FSR，CH1=电位器，可参数化。
//   4. test_mode=1 时事件源切换为 input_event_stub，真实按键事件被排空丢弃；
//      表情仍来自实际 ADC，waveform_sel 强制为正弦波。
//   5. 成员 1 的 audio_core 内部也有测试音源，两套 test_mode 不要同时打开。
//=============================================================================
`include "project_params.svh"
`include "audio_defs.svh"

module input_top #(
    //-------------------------------------------------------------------------
    // 系统/矩阵规模
    //-------------------------------------------------------------------------
    parameter integer SYS_CLK_HZ       = `SYS_CLK_HZ,           // 系统时钟 27 MHz
    parameter integer ROW_COUNT        = `KEY_ROW_COUNT,        // 矩阵行数，默认 4
    parameter integer COL_COUNT        = `KEY_COL_COUNT,        // 矩阵列数，默认 4
    parameter integer KEY_COUNT        = ROW_COUNT * COL_COUNT, // 总按键数，默认 16

    //-------------------------------------------------------------------------
    // 扫描与消抖
    //   ROW_DWELL_CYC = 27e6 / (2000 * 4) = 3375 拍 ≈ 125 us/行
    //   整帧 = 4 * 125 us = 500 us，即矩阵刷新率 2 kHz
    //-------------------------------------------------------------------------
    parameter integer ROW_DWELL_CYC    = SYS_CLK_HZ / (`MATRIX_FRAME_HZ * ROW_COUNT),
    parameter integer PRESS_CYCLES     = (SYS_CLK_HZ / 1000) * `KEY_PRESS_MS,   // 2 ms
    parameter integer RELEASE_CYCLES   = (SYS_CLK_HZ / 1000) * `KEY_RELEASE_MS, // 5 ms
    parameter logic   ROW_ACTIVE_LOW   = 1'b1,  // 行低有效：当前扫描行输出 0
    parameter logic   COL_ACTIVE_LOW   = 1'b1,  // 列低有效：按下时列被拉低

    //-------------------------------------------------------------------------
    // ADS7830 I2C 与采样调度
    //   I2C_QUARTER_DIV：I2C 每个 1/4 位占用的 sys_clk 拍数
    //       27e6 / (400e3 * 4) = 16.875 -> 整数 16
    //       实际 SCL ≈ 27e6 / (16 * 4) = 421.9 kHz
    //   SAMPLE_INTERVAL：一次转换完成后再等待多少拍才发起下一次请求
    //       27e6 / (1e6 / 250) = 6750 拍 = 250 us
    //   两个通道交替：CH0(FSR) -> CH1(POT) -> CH0 -> ...
    //-------------------------------------------------------------------------
    parameter integer I2C_QUARTER_DIV  = SYS_CLK_HZ / (`ADC_I2C_HZ * 4),
    parameter integer SAMPLE_INTERVAL  = SYS_CLK_HZ / (1_000_000 / `ADC_SAMPLE_INTERVAL_US),
    parameter logic [2:0] FSR_CHANNEL  = `FSR_ADC_CHANNEL,      // FSR 接 CH0
    parameter logic [2:0] POT_CHANNEL  = `POT_ADC_CHANNEL,      // 电位器接 CH1

    //-------------------------------------------------------------------------
    // 事件与音符
    //-------------------------------------------------------------------------
    parameter integer EVENT_FIFO_DEPTH = `EVENT_FIFO_DEPTH,     // 事件 FIFO 深度，默认 8
    parameter logic [6:0] BASE_NOTE    = `NOTE_BASE_C4          // K0 对应 MIDI 60 (C4)
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
    output logic signed [3:0] octave_debug   // 当前八度偏移 -2~+2
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
    // ADC 采样调度：FSR / 电位器交替采样
    //
    // 为什么需要调度器：
   //   ADS7830 一次事务约 100 us，不能每拍都发请求；本状态机负责
    //   “等间隔发起请求 -> 等 busy 上升沿确认 -> 切换下一个通道”。
    //
    // 关键信号：
    //   req_pending   : 已产生请求，等待 ADC 在它自己的位速率 tick 上接收
    //   sample_req    : 组合输出，真正送给 adc_ads7830 的电平
    //   sample_busy_d : busy 的上一拍值，用于检测 busy 的上升沿
    //   next_adc_ch   : 下一次要采样的通道
    //
    // 注意：不能看到 sample_req=1 就立刻清 pending。ADC 只在位速率 tick
    //       上采样 sample_req，过早清除会导致请求丢失。
    //-------------------------------------------------------------------------
    localparam integer SAMPLE_WAIT_MAX = (SAMPLE_INTERVAL < 4) ? 4 : SAMPLE_INTERVAL;
    localparam integer WAIT_W          = $clog2(SAMPLE_WAIT_MAX + 1);

    logic [WAIT_W-1:0] sample_wait;     // 空闲等待计数器
    logic              req_pending;     // 有请求待 ADC 接收
    logic [2:0]        next_adc_ch;     // 下一个通道
    logic              sample_busy_d;   // busy 打一拍

    logic              sample_req;      // 请求电平
    logic              sample_busy;     // ADC 忙
    logic              sample_valid;    // ADC 样本有效（单周期）
    logic [7:0]        sample_data;     // ADC 数据
    logic [2:0]        sample_channel;  // 样点对应通道
    logic              adc_bus_error_r; // I2C 错误

    // 只要还有 pending 且 ADC 空闲，就把请求电平拉高；
    // ADC 会在下一个 tick 看到它并置 busy。
    assign sample_req = req_pending && !sample_busy;

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            sample_wait   <= '0;
            req_pending   <= 1'b0;
            next_adc_ch   <= FSR_CHANNEL;   // 上电先采 FSR
            sample_busy_d <= 1'b0;
        end else begin
            sample_busy_d <= sample_busy;   // 用于检测 busy 的 0->1

            if (sample_busy && !sample_busy_d) begin
                // busy 上升沿：ADC 已经接收本次请求
                // 清 pending、重新计时，并切换到另一个通道
                req_pending <= 1'b0;
                sample_wait <= '0;
                next_adc_ch <= (next_adc_ch == FSR_CHANNEL) ? POT_CHANNEL
                                                            : FSR_CHANNEL;
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
        .adc_channel_req (next_adc_ch),
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
    //   note_velocity 在按键按下的那一刻被 key_event_decoder 锁存。
    //-------------------------------------------------------------------------
    logic [7:0] fsr_velocity;   // 滤波/映射后的 0~255 力度
    logic       pressure_valid; // 当前压力是否超过噪声门限
    logic       fsr_ready;      // FSR 是否完成过至少一次采样

    fsr_filter #(
        .FILTER_SHIFT (`FSR_FILTER_SHIFT),
        .NOISE_GATE   (`FSR_NOISE_GATE)
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
    assign note_velocity = pressure_valid ? fsr_velocity : `DEFAULT_VELOCITY;

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

    // expression 直接使用 FSR 滤波值；expr_valid 表示 FSR 至少采过一次样。
    // 成员 1 可以在 expr_valid=1 后持续读取 expression。
    assign expr_valid = fsr_ready;
    assign expression = fsr_filtered;

    //-------------------------------------------------------------------------
    // 按键事件译码 -> FIFO
    //   key_event_decoder 每拍最多产生 1 个事件请求（req_*）；
    //   event_queue 负责缓存并在 audio_core 能接收时送出。
    //   req_ready 是 FIFO 的写就绪，queue_valid/queue_ready 是读侧握手。
    //-------------------------------------------------------------------------
    logic        req_valid;
    logic        req_ready;
    logic [1:0]  req_type;
    logic [6:0]  req_note;
    logic [7:0]  req_vel;

    logic        queue_valid;
    logic        queue_ready;
    logic [1:0]  queue_type;
    logic [6:0]  queue_note;
    logic [7:0]  queue_vel;

    key_event_decoder #(
        .KEY_COUNT      (KEY_COUNT),
        .NOTE_KEY_COUNT (12),
        .BASE_NOTE      (BASE_NOTE)
    ) u_decoder (
        .sys_clk          (sys_clk),
        .rst_n            (rst_n),
        .key_pressed      (key_pressed),
        .key_released     (key_released),
        .key_down         (key_down),
        .velocity_in      (note_velocity),
        .event_req_valid  (req_valid),
        .event_req_ready  (req_ready),
        .event_req_type   (req_type),
        .event_req_note   (req_note),
        .event_req_velocity (req_vel),
        .octave_offset    (octave_debug),
        .waveform_sel     (waveform_key),
        .active_note_mask ()
    );

    event_queue #(
        .DEPTH  (EVENT_FIFO_DEPTH),
        .NOTE_W (7)
    ) u_event_queue (
        .sys_clk        (sys_clk),
        .rst_n          (rst_n),
        .wr_valid       (req_valid),
        .wr_ready       (req_ready),
        .wr_type        (req_type),
        .wr_note        (req_note),
        .wr_vel         (req_vel),
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
    //-------------------------------------------------------------------------
    assign adc_busy      = sample_busy;
    assign adc_valid     = sample_valid;
    assign adc_bus_error = adc_bus_error_r;
    assign input_state   = {test_mode, pressure_valid, sample_busy, event_valid};

endmodule
