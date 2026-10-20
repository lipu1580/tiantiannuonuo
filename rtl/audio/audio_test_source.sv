`timescale 1ns/1ns

module audio_test_source #(
    parameter integer NOTE_W = 7,          // 音符编号位宽
    parameter integer SAMPLE_RATE = 48_000 // 用于生成测试事件间隔
)(
    input  logic                  sys_clk, // 系统主时钟
    input  logic                  rst_n,   // 低有效复位
    input  logic                  audio_ce, // 按采样率推进序列计时
    input  logic                  enable, // 允许生成测试事件
    input  logic [1:0]            test_pattern, // 测试序列编号

    output logic                  event_valid, // 当前测试事件有效
    input  logic                  event_ready, // 下游可以接收事件
    output logic [1:0]            event_type, // 测试事件类型
    output logic [NOTE_W-1:0]     event_note_id, // 测试音符编号
    output logic [7:0]            event_velocity // 测试触发力度
);
    // audio_ce 用于按采样次数计时；事件握手在每个 sys_clk 上升沿处理。
    // enable=0 停止生成新事件；已呈现的有效事件必须保留到握手完成。
    // test_pattern 变化在序列重启时生效，不修改阻塞中的事件。
endmodule
