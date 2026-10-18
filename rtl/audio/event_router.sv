module event_router #(
    parameter integer NOTE_W = 7 // 音符编号位宽
)(
    input  logic                  sys_clk, // 系统主时钟
    input  logic                  rst_n,   // 低有效复位
    input  logic                  test_mode, // 选择测试源或外部事件源

    input  logic                  event_valid, // 外部事件有效；与 event_ready 同为 1 时完成握手
    output logic                  event_ready, // 路由器可接收外部事件
    input  logic [1:0]            event_type, // 外部事件类型
    input  logic [NOTE_W-1:0]     event_note_id, // 外部音符编号
    input  logic [7:0]            event_velocity, // 外部触发力度

    input  logic                  test_event_valid, // 测试事件有效；与 ready 同为 1 时完成握手
    output logic                  test_event_ready, // 路由器可接收测试事件
    input  logic [1:0]            test_event_type, // 测试事件类型
    input  logic [NOTE_W-1:0]     test_event_note_id, // 测试音符编号
    input  logic [7:0]            test_event_velocity, // 测试触发力度

    output logic                  routed_event_valid, // 转发事件有效；与 ready 同为 1 时完成握手
    input  logic                  routed_event_ready, // 下游可接收转发事件
    output logic [1:0]            routed_event_type, // 转发的事件类型
    output logic [NOTE_W-1:0]     routed_event_note_id, // 转发的音符编号
    output logic [7:0]            routed_event_velocity // 转发的触发力度
);
    // TODO: 两个事件源选一路；未选中源的 ready 为 0。
    // 下游阻塞时锁定当前来源和事件，不能因 test_mode 改变而替换字段。
    // 模式切换先完成已呈现事件，再释放旧模式声部，最后接收新源事件。
endmodule
