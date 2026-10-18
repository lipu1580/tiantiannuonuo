module demo_mode_ctrl (
    input  logic        sys_clk, // 系统主时钟
    input  logic        rst_n,   // 低有效复位
    input  logic        mode_toggle, // 切换测试/外部输入模式的单周期脉冲
    input  logic        pattern_next, // 切换测试序列的单周期脉冲
    output logic        test_mode, // 当前是否使用测试事件源
    output logic [1:0]  test_pattern // 当前测试序列编号
);
    // mode_toggle/pattern_next 必须已经同步、消抖，并各为单周期脉冲。
    // 复位默认 test_mode=0、test_pattern=0。
endmodule
