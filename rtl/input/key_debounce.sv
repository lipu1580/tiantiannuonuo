//=============================================================================
// 文件   : key_debounce.sv
// 功能   : 对 KEY_COUNT 路按键原始状态逐键消抖，输出稳定状态和单周期边沿。
//
// 【消抖算法】
//   每个键维护：
//     key_down[i] : 当前稳定状态
//     cnt[i]      : 输入与稳定状态不一致的连续拍数
//
//   输入 != 稳定状态时计数；连续保持到阈值才承认新状态：
//     按下确认 PRESS_CYCLES   （默认 2 ms，响应快）
//     释放确认 RELEASE_CYCLES （默认 5 ms，抑制回弹）
//   一旦承认，输出一个单周期脉冲 key_pressed / key_released。
//
// 【时序示意】
//   key_raw[i]   : 0 1 0 1 1 1 1 1 ...（前 3 拍抖动，之后稳定）
//   cnt[i]       : 0 1 0 1 2 3 4 ...
//   key_down[i]  : 0 0 0 0 0 1 1 1 ...
//   key_pressed  : 0 0 0 0 0 1 0 0 ...  ← 只响一次
//
// 【特点】
//   1. 每个键独立计数，一个键抖动不会阻塞其它键。
//   2. 长按不会重复产生 key_pressed，只有真实释放后再次按下才重新触发。
//   3. key_pressed / key_released 均为 sys_clk 域单周期脉冲。
//=============================================================================
module key_debounce #(
    parameter integer KEY_COUNT      = project_params_pkg::KEY_COUNT,		//此处为16
    parameter integer PRESS_CYCLES   = (project_params_pkg::SYS_CLK_HZ / 1000) * project_params_pkg::KEY_PRESS_MS,	//按下预设。表达的是2ms经过的周期数
    parameter integer RELEASE_CYCLES = (project_params_pkg::SYS_CLK_HZ / 1000) * project_params_pkg::KEY_RELEASE_MS	//释放预设。这里是5ms。这两个数据将直接和后面的计数器进行比较
)(
    input  logic                  sys_clk,
    input  logic                  rst_n,

    // 原始按键状态（来自 key_scan，1=按下）
    input  logic [KEY_COUNT-1:0]  key_raw,

    // 消抖后的稳定状态
    output logic [KEY_COUNT-1:0]  key_down,
    // 按下沿 / 释放沿，均为单周期脉冲
    output logic [KEY_COUNT-1:0]  key_pressed,
    output logic [KEY_COUNT-1:0]  key_released
);

    // 计数器要能装下两个阈值中较大的那个
    localparam integer CNT_MAX = (PRESS_CYCLES > RELEASE_CYCLES)        //CNT_MAX的值是一个周期数，很大
                                 ? PRESS_CYCLES : RELEASE_CYCLES;       //我觉得这里可以优化，完全没必要这个二选一，5ms的肯定是更大的
    localparam integer CNT_W   = (CNT_MAX <= 1) ? 1 : $clog2(CNT_MAX + 1);  //需要几位宽来存储这个周期数？在这里算出来是十几位

    // 每个键一个独立计数器
    logic [CNT_W-1:0] cnt [KEY_COUNT];      //16个按键是一对一的计数器

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            key_down     <= '0;
            key_pressed  <= '0;
            key_released <= '0;
            for (int i = 0; i < KEY_COUNT; i++) begin
                cnt[i] <= '0;
            end
        end else begin                      //主行为块
            // 逐键独立处理；for 循环在综合时展开成 16 份并行逻辑
            for (int i = 0; i < KEY_COUNT; i++) begin
                if (key_raw[i] != key_down[i]) begin            //举个例子，如果当前的初始情况下，key_down什么都没有而
                                                                //key_raw已经由key_scan产生了输出，那么就会进入代码块
                                                                //即两种状态发生接触
                    // 目标电平对应的确认时间：按下快、释放慢
                    if ((key_raw[i] ? (cnt[i] + 1'b1 >= CNT_W'(PRESS_CYCLES))   //如果raw有输入，判断一次当前此按键的计数器+1是否会大于按下预设
                                    : (cnt[i] + 1'b1 >= CNT_W'(RELEASE_CYCLES)))) begin //如果raw不再有输入，判断一次当前此按键计数器+1是否大于释放预设
                    //当前if是“承认新状态有效”

                        // 连续保持够久：承认新状态，并输出一个单周期边沿
                        key_down[i] <= key_raw[i];  //承认raw的输入的信号了
                        cnt[i]      <= '0;          //已经承认这一次信号了，cnt清零
                        if (key_raw[i]) begin
                            key_pressed[i]  <= 1'b1;//刚刚只是承认有效，承认之后的一次才算输入进去。1/主频，根本感觉不到，不可能存在巧合
                            key_released[i] <= 1'b0;
                        end else begin
                            key_pressed[i]  <= 1'b0;
                            key_released[i] <= 1'b1;
                        end
                    end else begin
                        // 还在抖动窗口内：继续计数
                        cnt[i] <= cnt[i] + 1'b1;
                    end
                end else begin
                    // 输入与稳定状态一致：一直摁着，或者一直不摁。清计数，清脉冲
                    // （脉冲只在状态变化的那个时钟沿为 1）
                    cnt[i]          <= '0;
                    key_pressed[i]  <= 1'b0;
                    key_released[i] <= 1'b0;
                end
            end
        end
    end

endmodule
