`ifndef AUDIO_DEFS_SVH
`define AUDIO_DEFS_SVH

package audio_defs_pkg;
    // valid && ready 在 sys_clk 上升沿接受一次事件；阻塞时保持 valid 和字段。
    // NOP 消耗一次握手但不改变声部；ALL_NOTES_OFF 进入 RELEASE。
    typedef enum logic [1:0] {
        EVENT_NOP           = 2'b00, // 空操作
        EVENT_NOTE_ON       = 2'b01, // 触发指定音符
        EVENT_NOTE_OFF      = 2'b10, // 释放指定音符
        EVENT_ALL_NOTES_OFF = 2'b11  // 释放全部音符
    } event_type_t;

    typedef enum logic [1:0] {
        WAVE_SINE     = 2'b00, // 正弦波
        WAVE_SQUARE   = 2'b01, // 方波
        WAVE_SAWTOOTH = 2'b10, // 锯齿波
        WAVE_RESERVED = 2'b11  // 保留/静音
    } waveform_t;

    // 仅固定规范第 11 节的扩展地址，基础版暂不暴露配置总线。
    localparam logic [7:0] CFG_MASTER_GAIN   = 8'h00; // 主音量配置地址
    localparam logic [7:0] CFG_ATTACK_STEP   = 8'h04; // 包络起音步长地址
    localparam logic [7:0] CFG_DECAY_STEP    = 8'h08; // 包络衰减步长地址
    localparam logic [7:0] CFG_SUSTAIN_LEVEL = 8'h0C; // 包络延音电平地址
    localparam logic [7:0] CFG_RELEASE_STEP  = 8'h10; // 包络释放步长地址
    localparam logic [7:0] CFG_WAVEFORM_SEL  = 8'h14; // 波形选择地址
    localparam logic [7:0] CFG_TEST_MODE     = 8'h18; // 测试模式地址
    localparam logic [7:0] CFG_ACTIVE_VOICES = 8'h1C; // 活跃声部只读地址
endpackage

`endif
