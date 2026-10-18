module adsr #(
    parameter logic [15:0] ATTACK_STEP   = 16'd500,   // 每个采样周期的起音增量
    parameter logic [15:0] DECAY_STEP    = 16'd30,    // 每个采样周期的衰减量
    parameter logic [15:0] SUSTAIN_LEVEL = 16'd42000, // 延音阶段目标电平
    parameter logic [15:0] RELEASE_STEP  = 16'd40     // 每个采样周期的释放量
)(
    input  logic         sys_clk, // 系统主时钟
    input  logic         rst_n,   // 低有效复位
    input  logic         audio_ce, // 推进一次包络更新
    input  logic         note_on, // 开始起音阶段
    input  logic         note_off, // 开始释放阶段
    input  logic [7:0]   velocity, // NOTE_ON 时锁存的力度
    input  logic [7:0]   expression, // 持续音量/力度控制
    output logic [15:0]  envelope_value, // 当前包络幅度
    output logic         active // 包络非零或仍处于释放阶段
);
    // TODO: note_on/note_off 在 sys_clk 域接收并保留至采样更新，不丢窄脉冲。
    // 同周期 note_on 优先；audio_ce 推进包络，释放至零后 active 清零。
    // velocity 触发时锁存，expression 为持续幅度控制；默认 255 为满量程。
endmodule
