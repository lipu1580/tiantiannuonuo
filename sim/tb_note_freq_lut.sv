`timescale 1ns/1ns

module tb_note_freq_lut;
    localparam int PHASE_W = 32;

    logic [7:0] note_id;
    logic [11:0] pitch_bend;
    logic [PHASE_W-1:0] phase_increment;
    logic [23:0] phase_increment_44k;
    logic [31:0] words [0:127]; // 保存各音符结果，用于检查相差八度的音符。

    note_freq_lut #(
        .NOTE_W (7),
        .PHASE_W (PHASE_W),
        .SAMPLE_RATE (48_000)
    ) dut (
        .note_id (note_id[6:0]),
        .pitch_bend (pitch_bend),
        .phase_increment (phase_increment)
    );

    // 第二组参数：确认改变位宽和采样率时，常量会随参数正确换算。
    // 扩大 MIDI 输入到 8 位，也可检查超出 0..127 的输入处理。
    note_freq_lut #(
        .NOTE_W (8),
        .PHASE_W (24),
        .SAMPLE_RATE (44_100)
    ) dut_44k (
        .note_id (note_id),
        .pitch_bend (pitch_bend),
        .phase_increment (phase_increment_44k)
    );

    task automatic check_note(
        input logic [6:0] note,
        input logic [PHASE_W-1:0] expected,
        input string name
    );
        note_id = {1'b0, note};
        #1;
        if (phase_increment !== expected)
            $fatal(1, "%s: note=%0d expected=%0d got=%0d",
                   name, note, expected, phase_increment);
    endtask

    initial begin
        pitch_bend = 12'd2048; // 基础版暂不使用滑音，中心值用于接口完整性检查。

        // 三个任务书要求的基准音：C4、A4、C5。
        check_note(7'd60, 32'd23409859, "C4");
        check_note(7'd69, 32'd39370534, "A4");
        check_note(7'd72, 32'd46819719, "C5");

        // 只在 TB 中使用 real 和指数运算，独立计算全部 128 个期望值。
        // DUT 内部运行时不需要这些运算；组合接口等待 #1 后即可检查。
        for (int note = 0; note < 128; note++) begin
            real frequency;
            logic [31:0] expected_48k;
            logic [23:0] expected_44k;
            longint signed octave_error;

            frequency = 440.0 * (2.0 ** ((real'(note) - 69.0) / 12.0));
            expected_48k = 32'($rtoi(frequency * (2.0 ** 32) / 48000.0 + 0.5));
            expected_44k = 24'($rtoi(frequency * (2.0 ** 24) / 44100.0 + 0.5));
            note_id = 8'(note);
            #1;
            if (phase_increment !== expected_48k)
                $fatal(1, "48k MIDI %0d: expected=%0d got=%0d",
                       note, expected_48k, phase_increment);
            if (phase_increment_44k !== expected_44k)
                $fatal(1, "44.1k MIDI %0d: expected=%0d got=%0d",
                       note, expected_44k, phase_increment_44k);

            words[note] = phase_increment;
            if (note > 0) begin
                if (words[note] <= words[note-1])
                    $fatal(1, "LUT is not monotonic at MIDI %0d", note);
            end
            if (note >= 12) begin
                // 高一个八度时增量应接近两倍；分别取整允许差 1。
                octave_error = longint'(words[note]) - 2 * longint'(words[note-12]);
                if (octave_error < -1 || octave_error > 1)
                    $fatal(1, "Wrong octave relationship at MIDI %0d", note);
            end
        end

        // 基础版忽略 pitch_bend：中心、最小和最大输入均应得到相同结果。
        pitch_bend = 12'd0;
        check_note(7'd69, 32'd39370534, "A4 bend=0");
        pitch_bend = 12'd4095;
        check_note(7'd69, 32'd39370534, "A4 bend=4095");

        // 扩宽的音符输入超出标准 MIDI 范围时，返回零相位增量。
        note_id = 8'd128;
        #1;
        if (phase_increment_44k !== 24'd0)
            $fatal(1, "MIDI 128 should return zero");
        note_id = 8'd255;
        #1;
        if (phase_increment_44k !== 24'd0)
            $fatal(1, "MIDI 255 should return zero");

        $display("PASS: C4/A4/C5, all 128 notes at 48k/32-bit and 44.1k/24-bit, octaves, bend and bounds");
        $finish;
    end
endmodule
