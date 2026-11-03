//=============================================================================
// 文件   : key_tap_hold.sv
// 归属   : 成员 2
// 功能   : 单键「短按 / 长按」识别，两者严格互斥。
//
// 【为什么需要它】
//   4x4 键盘 16 个键已全部分配完（9 根音 + 3 波形 + 3 效果），
//   没有第 4 个键给「合唱」，也没有键给「颤音」。
//   于是 K15 被设计成复用键：短按 = 切合唱，长按 = 颤音档位 +1。
//   这个判决必须在输入侧做完——成员 1 只该收到普通的寄存器写，
//   完全不需要知道是短按还是长按。
//
// 【时序判决：600 ms 门槛】
//
//   按下 ─┬─ < 600 ms 松开 ──────────► tap_pulse（单周期）
//         └─ 到 600 ms 仍未松开 ────► hold_pulse（单周期，当拍即出）
//                                     之后松开不再补 tap_pulse
//
//   按住 3 秒也只出一次 hold_pulse，不周期重复（hold_fired 标志）。
//
// 【为什么 hold 到点就出，不等松手】
//   颤音档位要「按住就能听见下一档」，如果等松手才切，演奏时手感是错的。
//   代价是：到点之后松开，不能再补一个短按——所以必须互斥。
//
// 【为什么用 armed 而不是直接看 key_down 的下降沿】
//   上电时 key_down 可能就是 0（没人按键）。若在「key_down=0」时无条件
//   出 tap_pulse，会每拍狂发脉冲。armed 保证只有「真的按下过」才算一次。
//=============================================================================
module key_tap_hold #(
    parameter integer SYS_CLK_HZ = project_params_pkg::SYS_CLK_HZ, // 27_000_000
    parameter integer HOLD_MS    = 600                             // 长按门槛
)(
    input  logic sys_clk,
    input  logic rst_n,       // 低有效，同步复位
    input  logic key_down,    // 消抖后的电平（1 = 按住）

    output logic tap_pulse,   // 单周期：短按
    output logic hold_pulse   // 单周期：长按（到点即出，不等松手）
);

    //-------------------------------------------------------------------------
    // 计数器位宽：HOLD_CYC 拍
    //   SYS_CLK_HZ=27e6、HOLD_MS=600 -> 16_200_000 拍 = 600 ms
    //   仿真时把 SYS_CLK_HZ 覆盖成小值即可（见 tb_key_tap_hold）。
    //-------------------------------------------------------------------------
    localparam integer HOLD_CYC_RAW = (SYS_CLK_HZ / 1000) * HOLD_MS;
    localparam integer HOLD_CYC     = (HOLD_CYC_RAW < 2) ? 2 : HOLD_CYC_RAW;
    localparam integer CNT_W        = $clog2(HOLD_CYC + 1);

    logic [CNT_W-1:0] cnt;        // 已按住拍数（饱和在 HOLD_CYC-1）
    logic             hold_fired; // 本次按压已经出过长按
    logic             armed;      // 见过 key_down=1，松开时才允许出短按

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            // 复位期间：计时清零、不产生任何脉冲
            cnt        <= '0;
            hold_fired <= 1'b0;
            armed      <= 1'b0;
            tap_pulse  <= 1'b0;
            hold_pulse <= 1'b0;
        end else begin
            // 脉冲默认归零，只在下面条件成立的当拍置 1（单周期）
            tap_pulse  <= 1'b0;
            hold_pulse <= 1'b0;

            if (key_down) begin
                armed <= 1'b1;
                if (!hold_fired) begin
                    if (cnt >= CNT_W'(HOLD_CYC - 1)) begin
                        // 到点：当拍出长按，并锁死，避免按住不放反复触发
                        hold_pulse <= 1'b1;
                        hold_fired <= 1'b1;
                        cnt        <= '0;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end
            end else begin
                // 松开：只有「按过但没到点」才算短按
                if (armed && !hold_fired) begin
                    tap_pulse <= 1'b1;
                end
                armed      <= 1'b0;
                hold_fired <= 1'b0;
                cnt        <= '0;
            end
        end
    end

endmodule
