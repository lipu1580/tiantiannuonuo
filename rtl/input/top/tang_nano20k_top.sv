// 临时逻辑集成接口；真实板级端口等待成员3确认。
// 板级顶层在 sys_clk 域内接入 sample_tick_gen，生成 audio_core 的 audio_ce。
module tang_nano20k_top #(
    parameter integer VOICE_COUNT = 4,      // 音频声部数量
    parameter integer NOTE_W      = 7,      // 音符编号位宽
    parameter integer SAMPLE_W    = 16,     // PCM 输出位宽
    parameter integer SYS_CLK_HZ   = 27_000_000, // 板载时钟频率，待成员3确认
    parameter integer SAMPLE_RATE = 48_000  // 音频采样率
)(
    input  logic                              sys_clk, // 板载系统时钟
    input  logic                              rst_n,   // 低有效复位

    input  logic                              event_valid, // 成员2事件有效
    output logic                              event_ready, // 音频核心可接收事件
    input  logic [1:0]                        event_type, // 事件类型编码
    input  logic [NOTE_W-1:0]                 event_note_id, // MIDI 音符编号
    input  logic [7:0]                        event_velocity, // 音符触发力度
    input  logic                              expr_valid, // 表情数据有效
    input  logic [7:0]                        expression, // 持续音量/力度
    input  logic [11:0]                       pitch_bend, // 滑音，2048 为中心
    input  logic [1:0]                        waveform_sel, // 波形选择

    output logic                              pcm_valid, // PCM 样本有效
    input  logic                              pcm_ready, // 成员3可接收 PCM
    output logic signed [SAMPLE_W-1:0]        pcm_left, // 左声道 PCM 样本
    output logic signed [SAMPLE_W-1:0]        pcm_right, // 右声道 PCM 样本

    input  logic                              test_mode, // 选择内部测试事件源
    input  logic [1:0]                        test_pattern, // 测试音符序列编号
    output logic [$clog2(VOICE_COUNT+1)-1:0]  active_voice_count, // 活跃声部数量
    output logic [VOICE_COUNT-1:0]            voice_active // 每个声部的活跃标志
);
endmodule
