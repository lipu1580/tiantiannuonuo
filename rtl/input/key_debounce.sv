//=============================================================================
// 文件   : key_debounce.sv
// 功能   : 对 KEY_COUNT 路按键原始状态逐键消抖，输出稳定状态和单周期边沿。
// 说明   :
//   1. 每个键独立计数，一个键抖动不会阻塞其它键。
//   2. 按下和释放使用不同确认时间：按下更快，保证控制到发声延迟；
//      释放稍慢，抑制机械回弹。
//   3. key_pressed / key_released 均为 sys_clk 域单周期脉冲。
//=============================================================================
`include "project_params.svh"

module key_debounce #(
    parameter integer KEY_COUNT      = `KEY_COUNT,
    parameter integer PRESS_CYCLES   = (`SYS_CLK_HZ / 1000) * `KEY_PRESS_MS,
    parameter integer RELEASE_CYCLES = (`SYS_CLK_HZ / 1000) * `KEY_RELEASE_MS
)(
    input  logic                  sys_clk,
    input  logic                  rst_n,

    input  logic [KEY_COUNT-1:0]  key_raw,

    output logic [KEY_COUNT-1:0]  key_down,
    output logic [KEY_COUNT-1:0]  key_pressed,
    output logic [KEY_COUNT-1:0]  key_released
);

    localparam integer CNT_MAX = (PRESS_CYCLES > RELEASE_CYCLES)
                                 ? PRESS_CYCLES : RELEASE_CYCLES;
    localparam integer CNT_W   = (CNT_MAX <= 1) ? 1 : $clog2(CNT_MAX + 1);

    logic [CNT_W-1:0] cnt [KEY_COUNT];

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            key_down     <= '0;
            key_pressed  <= '0;
            key_released <= '0;
            for (int i = 0; i < KEY_COUNT; i++) begin
                cnt[i] <= '0;
            end
        end else begin
            for (int i = 0; i < KEY_COUNT; i++) begin
                if (key_raw[i] != key_down[i]) begin
                    // 目标电平对应的确认时间
                    if ((key_raw[i] ? (cnt[i] + 1'b1 >= CNT_W'(PRESS_CYCLES))
                                    : (cnt[i] + 1'b1 >= CNT_W'(RELEASE_CYCLES)))) begin
                        key_down[i] <= key_raw[i];
                        cnt[i]      <= '0;
                        if (key_raw[i]) begin
                            key_pressed[i]  <= 1'b1;
                            key_released[i] <= 1'b0;
                        end else begin
                            key_pressed[i]  <= 1'b0;
                            key_released[i] <= 1'b1;
                        end
                    end else begin
                        cnt[i] <= cnt[i] + 1'b1;
                    end
                end else begin
                    cnt[i]          <= '0;
                    key_pressed[i]  <= 1'b0;
                    key_released[i] <= 1'b0;
                end
            end
        end
    end

endmodule
