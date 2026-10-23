//=============================================================================
// 文件   : note_map.sv
// 功能   : 物理键号 -> MIDI 音符 / 系统功能键 的集中映射表。
//
// 【默认映射】
//   key_index :  0  1  2  3  4  5  6  7  8  9 10 11 | 12      13       14      15
//   功能      : C4 C#4 D4 D#4 E4 F4 F#4 G4 G#4 A4 A#4 B4 | ALL_OFF 八度+  波形    八度-
//   MIDI      : 60 61 62 63 64 65 66 67 68 69 70 71 |  -       -        -       -
//
// 【八度偏移】
//   note = BASE_NOTE + key_index + 12 * octave_offset
//   octave_offset 范围 -2~+2，最终 note_id 限幅到 0~127。
//
// 【为什么单独一个文件】
//   按键排列是最容易改的东西。把映射集中在这里，扫描/消抖/事件协议
//   都不用动。改键位只改本文件。
//=============================================================================
module note_map #(
    parameter integer     NOTE_KEY_COUNT = 12,          // 前 12 个键是音符键
    parameter logic [6:0] BASE_NOTE      = project_params_pkg::NOTE_BASE_C4 // K0 的 MIDI 音符，默认 60
)(
    input  logic [3:0]        key_index,     // 物理键号 0~15
    input  logic signed [3:0] octave_offset, // 八度偏移 -2~+2

    // 功能键标志（互斥，最多一个为 1）
    output logic              is_note_key,
    output logic              is_all_notes_off,
    output logic              is_waveform_key,
    output logic              is_octave_up,
    output logic              is_octave_down,

    // 音符键的有效 MIDI 编号（功能键时无意义，但已限幅）
    output logic [6:0]        note_id
);

    // 用 integer 做中间计算，避免 7 位无符号加法在负偏移时回绕
    integer note_calc;

    always_comb begin
        is_note_key     = 1'b0;
        is_all_notes_off = 1'b0;
        is_waveform_key = 1'b0;
        is_octave_up    = 1'b0;
        is_octave_down  = 1'b0;
        note_calc       = int'(BASE_NOTE);

        if (int'(key_index) < NOTE_KEY_COUNT) begin
            // 音符键：半音阶排列 + 八度偏移
            is_note_key = 1'b1;
            note_calc   = int'(BASE_NOTE) + int'(key_index)
                          + 12 * int'(octave_offset);
        end else begin
            // 功能键：K12~K15
            case (key_index)
                4'd12: is_all_notes_off = 1'b1;  // 释放全部声部
                4'd13: is_octave_up     = 1'b1;  // 升八度
                4'd14: is_waveform_key  = 1'b1;  // 循环切换波形
                4'd15: is_octave_down   = 1'b1;  // 降八度
                default: begin
                    is_note_key = 1'b0;          // 超出 0~15 的键号：无功能
                end
            endcase
        end

        // 限幅到合法 MIDI 范围，避免八度偏移造成回绕。
        // 例如 BASE_NOTE=60、offset=-2、key_index=0 -> 36，合法；
        // 若 BASE_NOTE 很小且 offset=-2，可能算出负数，统一夹到 0。
        if (note_calc < 0) begin
            note_id = 7'd0;
        end else if (note_calc > 127) begin
            note_id = 7'd127;
        end else begin
            note_id = 7'(note_calc);      // 已限幅到 0~127
        end
    end

endmodule
