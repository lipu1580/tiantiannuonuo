//=============================================================================
// 文件   : input_top.sv
// 归属   : 成员 2 唯一公开顶层
// 功能   : 4x4 按键矩阵 + FSR 力度 + 电位器表情 -> 标准演奏事件 + 表情接口。
// 说明   :
//   1. 成员 1 只需例化本模块，并把 event_* / expr_* 接到 audio_core。
//   2. ADS7830 为 I2C 器件，物理接口为 adc_scl/adc_sda_oe/adc_sda_i；
//      板级顶层用三态缓冲把 oe 转换成双向 SDA。
//   3. ADC 通道默认 CH0=FSR，CH1=电位器，可参数化。
//   4. event_ready=0 时，事件保存在 event_queue 中，字段保持稳定。
//   5. test_mode=1 时事件源切换为 input_event_stub，真实按键事件被丢弃；
//      表情仍来自实际 ADC，waveform_sel 强制为正弦波。
//=============================================================================
`include "project_params.svh"
`include "audio_defs.svh"

module input_top #(
    parameter integer SYS_CLK_HZ       = `SYS_CLK_HZ,
    parameter integer ROW_COUNT        = `KEY_ROW_COUNT,
    parameter integer COL_COUNT        = `KEY_COL_COUNT,
    parameter integer KEY_COUNT        = ROW_COUNT * COL_COUNT,

    // 扫描与消抖
    parameter integer ROW_DWELL_CYC    = SYS_CLK_HZ / (`MATRIX_FRAME_HZ * ROW_COUNT),
    parameter integer PRESS_CYCLES     = (SYS_CLK_HZ / 1000) * `KEY_PRESS_MS,
    parameter integer RELEASE_CYCLES   = (SYS_CLK_HZ / 1000) * `KEY_RELEASE_MS,
    parameter logic   ROW_ACTIVE_LOW   = 1'b1,
    parameter logic   COL_ACTIVE_LOW   = 1'b1,

    // ADC
    parameter integer I2C_QUARTER_DIV  = SYS_CLK_HZ / (`ADC_I2C_HZ * 4),
    parameter integer SAMPLE_INTERVAL  = SYS_CLK_HZ / (1_000_000 / `ADC_SAMPLE_INTERVAL_US),
    parameter logic [2:0] FSR_CHANNEL  = `FSR_ADC_CHANNEL,
    parameter logic [2:0] POT_CHANNEL  = `POT_ADC_CHANNEL,

    // 事件与音符
    parameter integer EVENT_FIFO_DEPTH = `EVENT_FIFO_DEPTH,
    parameter logic [6:0] BASE_NOTE    = `NOTE_BASE_C4
)(
    input  logic        sys_clk,
    input  logic        rst_n,

    // 4x4 按键矩阵
    output logic [ROW_COUNT-1:0] key_row,
    input  logic [COL_COUNT-1:0] key_col,

    // ADS7830 I2C
    output logic        adc_scl,
    output logic        adc_sda_oe,
    input  logic        adc_sda_i,

    // 演奏事件（成员 2 -> 成员 1）
    output logic        event_valid,
    input  logic        event_ready,
    output logic [1:0]  event_type,
    output logic [6:0]  event_note_id,
    output logic [7:0]  event_velocity,

    // 表情接口（成员 2 -> 成员 1）
    output logic        expr_valid,
    output logic [7:0]  expression,
    output logic [11:0] pitch_bend,
    output logic [1:0]  waveform_sel,

    // 测试模式
    input  logic        test_mode,
    input  logic [1:0]  test_pattern,

    // 调试
    output logic [KEY_COUNT-1:0] key_down,
    output logic [7:0]  fsr_raw,
    output logic [7:0]  fsr_filtered,
    output logic [3:0]  input_state,
    output logic        adc_busy,
    output logic        adc_valid,
    output logic        adc_bus_error,
    output logic        input_overflow,
    output logic signed [3:0] octave_debug
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
    //-------------------------------------------------------------------------
    localparam integer SAMPLE_WAIT_MAX = (SAMPLE_INTERVAL < 4) ? 4 : SAMPLE_INTERVAL;
    localparam integer WAIT_W          = $clog2(SAMPLE_WAIT_MAX + 1);

    logic [WAIT_W-1:0] sample_wait;
    logic              req_pending;
    logic [2:0]        next_adc_ch;
    logic              sample_busy_d;

    logic              sample_req;
    logic              sample_busy;
    logic              sample_valid;
    logic [7:0]        sample_data;
    logic [2:0]        sample_channel;
    logic              adc_bus_error_r;

    assign sample_req = req_pending && !sample_busy;

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            sample_wait  <= '0;
            req_pending  <= 1'b0;
            next_adc_ch  <= FSR_CHANNEL;
            sample_busy_d <= 1'b0;
        end else begin
            sample_busy_d <= sample_busy;

            if (sample_busy && !sample_busy_d) begin
                // ADC 刚接收请求（busy 上升沿）：清 pending 并切换通道。
                // 已进入 busy 后不能每拍翻转，否则通道会来回跳。
                req_pending <= 1'b0;
                sample_wait <= '0;
                next_adc_ch <= (next_adc_ch == FSR_CHANNEL) ? POT_CHANNEL
                                                            : FSR_CHANNEL;
            end else if (!req_pending && !sample_busy) begin
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
    //-------------------------------------------------------------------------
    logic [7:0] fsr_velocity;
    logic       pressure_valid;
    logic       fsr_ready;

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

    // 按下瞬间若 FSR 尚未稳定，使用默认力度
    logic [7:0] note_velocity;
    assign note_velocity = pressure_valid ? fsr_velocity : `DEFAULT_VELOCITY;

    //-------------------------------------------------------------------------
    // 表情：电位器 + 波形选择
    //-------------------------------------------------------------------------
    logic [1:0] waveform_key;

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

    assign expr_valid = fsr_ready;
    assign expression = fsr_filtered;

    //-------------------------------------------------------------------------
    // 按键事件译码 -> FIFO
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
    //   测试模式下真实事件被排空丢弃，避免 FIFO 堵塞；
    //   非测试模式下 FIFO 直接对接 audio_core 的 event_ready。
    //-------------------------------------------------------------------------
    assign stub_ready  = test_mode ? event_ready : 1'b0;
    assign queue_ready = test_mode ? 1'b1        : event_ready;

    assign event_valid    = test_mode ? stub_valid : queue_valid;
    assign event_type     = test_mode ? stub_type  : queue_type;
    assign event_note_id  = test_mode ? stub_note  : queue_note;
    assign event_velocity = test_mode ? stub_vel   : queue_vel;

    //-------------------------------------------------------------------------
    // 调试
    //-------------------------------------------------------------------------
    assign adc_busy      = sample_busy;
    assign adc_valid     = sample_valid;
    assign adc_bus_error = adc_bus_error_r;
    assign input_state   = {test_mode, pressure_valid, sample_busy, event_valid};

endmodule
