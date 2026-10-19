module voice_manager #(
    parameter integer VOICE_COUNT = 4, // 管理的声部数量
    parameter integer NOTE_W      = 7  // 音符编号位宽
)(
    input  logic                              sys_clk, // 系统主时钟
    input  logic                              rst_n,   // 低有效复位

    input  logic                              event_valid, // 输入事件有效
    output logic                              event_ready, // 事件可被接收
    input  logic [1:0]                        event_type, // 事件类型
    input  logic [NOTE_W-1:0]                 event_note_id, // 目标音符编号
    input  logic [7:0]                        event_velocity, // 新音符力度

    input  logic [VOICE_COUNT-1:0]            voice_active, // 各声部活跃状态
    input  logic [15:0]                       voice_envelope [0:VOICE_COUNT-1], // 各声部包络电平

    output logic [VOICE_COUNT-1:0]            voice_start, // 各声部启动脉冲
    output logic [VOICE_COUNT-1:0]            voice_release, // 各声部释放脉冲
    output logic [NOTE_W-1:0]                 voice_note_id [0:VOICE_COUNT-1], // 分配给各声部的音符
    output logic [7:0]                        voice_velocity [0:VOICE_COUNT-1], // 分配给各声部的力度
    output logic [$clog2(VOICE_COUNT+1)-1:0]  active_voice_count // 活跃声部数量
);
    // TODO: 接收事件后发出单周期 voice_start/voice_release。
    // 优先空闲声部；全满时抢占最早启动者；同音重复 NOTE_ON 重触发现有声部。
    // NOTE_OFF 释放匹配音符；ALL_NOTES_OFF 释放全部；NOP 只完成握手。
    // 分配时须立即预占，避免 voice_active 反馈更新前再次分配同一声部。
    // active_voice_count 包含处于 RELEASE 的声部。
endmodule
