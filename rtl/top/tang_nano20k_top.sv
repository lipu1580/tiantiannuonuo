`timescale 1ns/1ps
// Complete system wiring for Tang Nano 20K.
// Compile packages.sv before input RTL; use SystemVerilog mode.
module tang_nano20k_top #(
    parameter integer SYS_CLK_HZ = 27_000_000,
    parameter integer SAMPLE_RATE = 48_000,
    parameter integer VOICE_COUNT = 4,
    // 第 2 轮起键盘不再发声，MATRIX_MODE 已删除（根音/波形/效果都由键位直选）。
    // Compile-time selection: 0=real inputs, 1=input test source,
    // 2=audio core test source. Change parameter and rebuild to switch.
    parameter integer TEST_SOURCE = 0,
    parameter [1:0] TEST_PATTERN = 2'b00
)(
    input  wire       sys_clk,
    input  wire       rst_n,       // External active-low reset button.
    output wire [3:0] key_row,
    input  wire [3:0] key_col,
    output wire       adc_scl,
    inout  wire       adc_sda,     // External pull-up to 3.3 V required.
    output wire       i2s_bclk,
    output wire       i2s_lrclk,
    output wire       i2s_din,
    output wire [5:0] led_n        // Active-low status LEDs.
);
    // Asynchronous assertion, synchronous release after four clock edges.
    // Initial value also requests reset after FPGA configuration.
    reg [3:0] reset_pipe = 4'b0000;
    wire sys_rst_n;
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n)
            reset_pipe <= 4'b0000;
        else
            reset_pipe <= {reset_pipe[2:0], 1'b1};
    end
    assign sys_rst_n = reset_pipe[3];

    // Member 2 -> member 1: musical events and expression.
    wire event_valid, event_ready;
    wire [1:0] event_type;
    wire [6:0] event_note_id;
    wire [7:0] event_velocity;
    wire expr_valid;
    wire [7:0] expression;
    wire [11:0] pitch_bend;
    wire [1:0] waveform_sel;

    // Member 2 -> member 1: cfg 配置总线（效果/颤音参数）。
    // audio_core_expr 尚未合入，这里先把 cfg_ready 常量置 1：
    // 按键序列会瞬间写完、无副作用，接入后直接换成 audio_core_expr 的端口即可。
    wire        cfg_valid;
    wire        cfg_write;
    wire [7:0]  cfg_addr;
    wire [31:0] cfg_wdata;
    wire        cfg_ready = 1'b1;

    // Member 1 -> member 3: signed 16-bit stereo PCM.
    // ready flows BACK from audio_out_top to audio_core.
    wire pcm_valid, pcm_ready;
    wire signed [15:0] pcm_left, pcm_right;
    wire audio_ce;

    wire adc_sda_oe;
    wire adc_bus_error, input_overflow;
    wire underrun, overflow;
    wire [VOICE_COUNT-1:0] voice_active;

    // Open-drain SDA: drive only 0; otherwise release the wire.
    // The same physical wire is read back by input_top.
    assign adc_sda = (sys_rst_n && adc_sda_oe) ? 1'b0 : 1'bz;

    input_top #(
        .SYS_CLK_HZ(SYS_CLK_HZ),
        .ROW_COUNT(4),
        .COL_COUNT(4)
    ) u_input_top (
        .sys_clk(sys_clk),
        .rst_n(sys_rst_n),
        .key_row(key_row),
        .key_col(key_col),
        .adc_scl(adc_scl),
        .adc_sda_oe(adc_sda_oe),
        .adc_sda_i(adc_sda),
        .event_valid(event_valid),
        .event_ready(event_ready),
        .event_type(event_type),
        .event_note_id(event_note_id),
        .event_velocity(event_velocity),
        .expr_valid(expr_valid),
        .expression(expression),
        .pitch_bend(pitch_bend),
        .waveform_sel(waveform_sel),
        .cfg_valid(cfg_valid),
        .cfg_write(cfg_write),
        .cfg_addr(cfg_addr),
        .cfg_wdata(cfg_wdata),
        .cfg_ready(cfg_ready),
        .cfg_rdata(32'd0),
        .test_mode(TEST_SOURCE == 1),
        .test_pattern(TEST_PATTERN),
        .adc_bus_error(adc_bus_error),
        .input_overflow(input_overflow),
        // Optional debug outputs need no physical FPGA pins.
        .key_down(), .fsr_raw(), .fsr_filtered(), .input_state(),
        .adc_busy(), .adc_valid(), .adc_timeout_debug(),
        .piezo_peak_rst(), .piezo_hit_debug(),
        .piezo_active_debug(), .base_note_debug()
    );

    // audio_ce is a one-cycle ENABLE, not a separate clock.
    sample_tick_gen #(
        .SYS_CLK_HZ(SYS_CLK_HZ),
        .SAMPLE_RATE(SAMPLE_RATE)
    ) u_sample_tick_gen (
        .sys_clk(sys_clk),
        .rst_n(sys_rst_n),
        .audio_ce(audio_ce)
    );

    audio_core #(
        .VOICE_COUNT(VOICE_COUNT),
        .NOTE_W(7),
        .SAMPLE_W(16),
        .SAMPLE_RATE(SAMPLE_RATE)
    ) u_audio_core (
        .sys_clk(sys_clk),
        .rst_n(sys_rst_n),
        .audio_ce(audio_ce),
        .event_valid(event_valid),
        .event_ready(event_ready),
        .event_type(event_type),
        .event_note_id(event_note_id),
        .event_velocity(event_velocity),
        // Test playback must not depend on connected ADC/FSR hardware.
        .expr_valid(TEST_SOURCE == 0 ? expr_valid : 1'b1),
        .expression(TEST_SOURCE == 0 ? expression : 8'd255),
        .pitch_bend(TEST_SOURCE == 0 ? pitch_bend : 12'd2048),
        .waveform_sel(TEST_SOURCE == 0 ? waveform_sel : 2'b00),
        .pcm_valid(pcm_valid),
        .pcm_ready(pcm_ready),
        .pcm_left(pcm_left),
        .pcm_right(pcm_right),
        .test_mode(TEST_SOURCE == 2),
        .test_pattern(TEST_PATTERN),
        .active_voice_count(),
        .voice_active(voice_active)
    );

    audio_out_top #(
        .SYS_CLK_HZ(SYS_CLK_HZ),
        .SAMPLE_RATE(SAMPLE_RATE),
        .SAMPLE_W(16),
        .FIFO_DEPTH(8)
    ) u_audio_out_top (
        .sys_clk(sys_clk),
        .rst_n(sys_rst_n),
        .pcm_left(pcm_left),
        .pcm_right(pcm_right),
        .pcm_valid(pcm_valid),
        .pcm_ready(pcm_ready),
        .i2s_bclk(i2s_bclk),
        .i2s_lrclk(i2s_lrclk),
        .i2s_din(i2s_din),
        .underrun(underrun),
        .overflow(overflow)
    );

    assign led_n[0] = ~sys_rst_n;       // On: reset released.
    assign led_n[1] = ~(|voice_active); // On: at least one active voice.
    assign led_n[2] = ~adc_bus_error;   // On: ADC reports a bus error.
    assign led_n[3] = ~input_overflow;  // On: input queue reports overflow.
    assign led_n[4] = ~underrun;        // On: audio output ran out of samples.
    assign led_n[5] = ~overflow;        // On: PCM source violated handshake.

    // synthesis translate_off
    initial begin
        if (TEST_SOURCE < 0 || TEST_SOURCE > 2)
            $fatal(1, "TEST_SOURCE must be 0, 1 or 2");
        if (VOICE_COUNT < 1)
            $fatal(1, "Invalid VOICE_COUNT");
    end
    // synthesis translate_on
endmodule
