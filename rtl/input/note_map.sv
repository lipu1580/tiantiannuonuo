//=============================================================================
// 文件   : note_map.sv
// 功能   : 物理键号 -> MIDI 音符 / 系统功能键 的集中映射表。
// 说明   :
//   1. 默认 K0~K11 为 12 个半音音符，从 BASE_NOTE(默认 60 = C4) 开始。
//   2. K12 = ALL_NOTES_OFF，K13 = 升八度，K14 = 切换波形，K15 = 降八度。
//   3. 八度偏移范围 -2 ~ +2，最终 note_id 限幅到 0~127。
//   4. 修改按键排列只需要改本文件，不要改扫描/消抖/事件协议。
//=============================================================================
`include "project_params.svh"
`include "audio_defs.svh"

module note_map #(
    parameter integer     NOTE_KEY_COUNT = 12,
    parameter logic [6:0] BASE_NOTE      = `NOTE_BASE_C4
)(
    input  logic [3:0]        key_index,
    input  logic signed [3:0] octave_offset,

    output logic              is_note_key,
    output logic              is_all_notes_off,
    output logic              is_waveform_key,
    output logic              is_octave_up,
    output logic              is_octave_down,
    output logic [6:0]        note_id
);

    integer note_calc;

    always_comb begin
        is_note_key     = 1'b0;
        is_all_notes_off = 1'b0;
        is_waveform_key = 1'b0;
        is_octave_up    = 1'b0;
        is_octave_down  = 1'b0;
        note_calc       = int'(BASE_NOTE);

        if (int'(key_index) < NOTE_KEY_COUNT) begin
            is_note_key = 1'b1;
            note_calc   = int'(BASE_NOTE) + int'(key_index)
                          + 12 * int'(octave_offset);
        end else begin
            case (key_index)
                4'd12: is_all_notes_off = 1'b1;
                4'd13: is_octave_up     = 1'b1;
                4'd14: is_waveform_key  = 1'b1;
                4'd15: is_octave_down   = 1'b1;
                default: begin
                    is_note_key = 1'b0;
                end
            endcase
        end

        // 限幅到合法 MIDI 范围，避免八度偏移造成回绕
        if (note_calc < 0) begin
            note_id = 7'd0;
        end else if (note_calc > 127) begin
            note_id = 7'd127;
        end else begin
            note_id = 7'(note_calc);      // 已限幅到 0~127
        end
    end

endmodule
