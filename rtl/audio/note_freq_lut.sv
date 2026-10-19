module note_freq_lut #(
    parameter integer NOTE_W      = 7,      // 音符编号位宽
    parameter integer PHASE_W     = 32,     // DDS 相位累加器位宽
    parameter integer SAMPLE_RATE = 48_000  // 音频采样率
)(
    input  logic [NOTE_W-1:0]   note_id, // MIDI 音符编号，69 对应 A4
    input  logic [11:0]         pitch_bend, // 滑音输入，2048 为中心
    output logic [PHASE_W-1:0]  phase_increment // DDS 每采样周期的相位增量
);
    // 组合查表接口；MIDI 69=A4=440 Hz。
    // phase_increment = round(frequency * 2**PHASE_W / SAMPLE_RATE)。
    // 基础版 pitch_bend 可暂不参与计算，但必须保留端口；2048 为中心。
endmodule
