//=============================================================================
// 文件   : note_map.sv
// 归属   : 成员 2
// 功能   : 物理键号 -> 逻辑功能 的集中映射表（第 2 轮键位）。
//
// 【第 2 轮键位：9 根音 + 3 波形 + 3 效果 + 1 复用键】
//
//   key :  0   1   2 | 3   | 4   5   6 | 7   | 8   9  10 | 11  | 12  13  14 | 15
//   功能:  C  C#   D | 波0 |  E   F  F# | 波1 | G#   A  A# | 波2 |旁路 延迟 混响|复用
//   音级:  0   1   2 |  -  |  4   5   6 |  -  |  8   9  10 |  -  |  -   -   - | -
//   波形:  -   -   - |  0  |  -   -   - |  1  |  -   -   - |  2  |  -   -   - | -
//   效果:  -   -   - |  -  |  -   -   - |  -  |  -   -   - |  -  |  0   1   3 | -
//
// 【为什么少了 D#(3) / G(7) / B(11)】
//   3x3 区块（col1~col3）保留原有半音排列，col4 被波形键占用，
//   所以音级集合是 0,1,2,4,5,6,8,9,10。FSR 触发的是「根音 + 五声音阶」，
//   9 个根音各自带 5 个音，合起来覆盖 MIDI 60~79（C4~G5），演奏够用。
//   想改成别的集合，只改本文件一张表即可，扫描/消抖/事件协议都不用动。
//
// 【K15 是复用键，不在本文件决定行为】
//   `is_dual_key=1` 的键交给 key_tap_hold 做 600 ms 短按/长按判决：
//     短按 = 合唱（fx_mode=2），长按 = 颤音档位。
//   所以 K15 的 `is_fx_key` 必须为 0，否则会被当成普通效果键直接发合唱。
//
// 【为什么单独一个文件】
//   键位是最容易改的东西。集中在这里，扫描/消抖/译码/协议都不用动。
//=============================================================================
module note_map (
    input  logic [3:0] key_index,          // 物理键号 0~15（= row*4 + col）

    // 根音键（K0,K1,K2,K4,K5,K6,K8,K9,K10）
    output logic       is_root_key,
    output logic [3:0] root_pitch_class,   // 半音音级 0~11

    // 波形键（K3,K7,K11）
    output logic       is_wave_key,
    output logic [1:0] wave_sel,           // 0 正弦 / 1 管风琴 / 2 拨弦

    // 效果键（K12,K13,K14）—— K15 不在此列
    output logic       is_fx_key,
    output logic [1:0] fx_mode,            // 0 旁路 / 1 延迟 / 2 合唱 / 3 混响

    // 复用键（K15）：短按=合唱，长按=颤音
    output logic       is_dual_key
);

    // 注意：这里**不** import audio_defs_pkg 的 WAVE_* 枚举。
    // 成员 1 会在第 2 轮把 WAVE_SQUARE/WAVE_SAWTOOTH 改名成
    // WAVE_ORGAN/WAVE_PLUCK，直接用字面量可以让本文件不受改名影响。
    // （名字加 SEL_ 前缀，避免与父模块 import 进来的 WAVE_SINE 同名隐藏）
    localparam logic [1:0] SEL_SINE  = 2'b00; // 正弦
    localparam logic [1:0] SEL_ORGAN = 2'b01; // 管风琴类波表
    localparam logic [1:0] SEL_PLUCK = 2'b10; // 拨弦类波表

    always_comb begin
        // 默认：无功能（超出 0~15 的键号也不会误触发）
        is_root_key      = 1'b0;
        root_pitch_class = 4'd0;
        is_wave_key      = 1'b0;
        wave_sel         = SEL_SINE;
        is_fx_key        = 1'b0;
        fx_mode          = 2'd0;
        is_dual_key      = 1'b0;

        case (key_index)
            //-----------------------------------------------------------------
            // col1~col3：根音（保留原有半音排列）
            //-----------------------------------------------------------------
            4'd0:  begin is_root_key = 1'b1; root_pitch_class = 4'd0;  end // C
            4'd1:  begin is_root_key = 1'b1; root_pitch_class = 4'd1;  end // C#
            4'd2:  begin is_root_key = 1'b1; root_pitch_class = 4'd2;  end // D
            4'd4:  begin is_root_key = 1'b1; root_pitch_class = 4'd4;  end // E
            4'd5:  begin is_root_key = 1'b1; root_pitch_class = 4'd5;  end // F
            4'd6:  begin is_root_key = 1'b1; root_pitch_class = 4'd6;  end // F#
            4'd8:  begin is_root_key = 1'b1; root_pitch_class = 4'd8;  end // G#
            4'd9:  begin is_root_key = 1'b1; root_pitch_class = 4'd9;  end // A
            4'd10: begin is_root_key = 1'b1; root_pitch_class = 4'd10; end // A#

            //-----------------------------------------------------------------
            // col4 上三行：波形直选（不循环、长按不变）
            //-----------------------------------------------------------------
            4'd3:  begin is_wave_key = 1'b1; wave_sel = SEL_SINE;  end // 正弦
            4'd7:  begin is_wave_key = 1'b1; wave_sel = SEL_ORGAN; end // 管风琴
            4'd11: begin is_wave_key = 1'b1; wave_sel = SEL_PLUCK; end // 拨弦

            //-----------------------------------------------------------------
            // row4：效果直选（模式号沿用成员 1 编码，不要按按键顺序推）
            //-----------------------------------------------------------------
            4'd12: begin is_fx_key = 1'b1; fx_mode = 2'd0; end // 旁路
            4'd13: begin is_fx_key = 1'b1; fx_mode = 2'd1; end // 延迟
            4'd14: begin is_fx_key = 1'b1; fx_mode = 2'd3; end // 混响（=3！）

            //-----------------------------------------------------------------
            // K15：复用键，交给 key_tap_hold
            //-----------------------------------------------------------------
            4'd15: begin is_dual_key = 1'b1; end

            default: ; // 其余键号无功能
        endcase
    end

endmodule
