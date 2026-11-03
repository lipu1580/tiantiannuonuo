`timescale 1ns/1ns

module tb_pitch_bend_lut;
    localparam real SAMPLE_RATE = 48000.0;
    localparam real PHASE_SCALE = 4294967296.0;
    localparam longint unsigned RATIO_SCALE = 64'd1048576;
    localparam longint unsigned MAX_PHASE = 64'hffffffff;
    // 最大倍率下仍能放进 32 位输出的基础步长；溢出后的策略尚未约定。
    localparam logic [31:0] MAX_SAFE_INPUT = 32'(MAX_PHASE * RATIO_SCALE / 64'd1176987);

    logic [31:0] in_phase_increment = '0;
    logic [11:0] pitch_bend = 12'd2048;
    logic [31:0] phase_increment;
    int check_count = 0;
    real maximum_error_cents = 0.0;

    logic sys_clk = 1'b0;
    logic rst_n = 1'b0;
    logic audio_ce = 1'b0;
    logic signed [15:0] waveform_sample;
    logic waveform_valid;
    logic [31:0] reference_phase = '0;
    int dds_sample_count = 0;
    int dds_wrap_count = 0;

    pitch_bend_lut dut (
        .in_phase_increment (in_phase_increment),
        .pitch_bend (pitch_bend),
        .phase_increment (phase_increment)
    );

    // 联接真实 DDS，检查动态弯音不会清零相位。
    dds_oscillator dds (
        .sys_clk (sys_clk), .rst_n (rst_n), .audio_ce (audio_ce),
        .phase_increment (phase_increment), .waveform_sel (2'b00),
        .waveform_sample (waveform_sample), .waveform_valid (waveform_valid)
    );

    always #5 sys_clk = ~sys_clk;

    // 独立按协议计算参考倍率，不读取 DUT 内部信号或复制表项。
    function automatic real reference_ratio(input int bend);
        real semitones;
        if (bend <= 2048)
            semitones = -2.0 + 2.0 * real'(bend) / 2048.0;
        else
            semitones = 2.0 * real'(bend - 2048) / 2047.0;
        return 2.0 ** (semitones / 12.0);
    endfunction

    function automatic longint unsigned reference_increment(
        input logic [31:0] base_increment,
        input int bend
    );
        longint unsigned coefficient;
        longint unsigned product;
        coefficient = 64'($rtoi(reference_ratio(bend) * real'(RATIO_SCALE) + 0.5));
        product = 64'(base_increment) * coefficient;
        // 当前 RTL 在乘法后直接截断，没有加半个 LSB 做四舍五入。
        return product / RATIO_SCALE;
    endfunction

    task automatic check_increment(
        input logic [31:0] base_increment,
        input int bend,
        output logic [31:0] actual
    );
        longint unsigned expected;
        in_phase_increment = base_increment;
        pitch_bend = 12'(bend);
        expected = reference_increment(base_increment, bend);
        if (expected > MAX_PHASE)
            $fatal(1, "TB vector exceeds 32-bit output: base=%0d bend=%0d", base_increment, bend);
        #1; // DUT 是组合逻辑。
        if (phase_increment !== 32'(expected))
            $fatal(1, "base=%0d bend=%0d expected=%0d got=%0d",
                   base_increment, bend, expected, phase_increment);
        actual = phase_increment;
        check_count++;
    endtask

    // 时钟沿采样参考步长，等待 NBA 更新后检查 DDS 真实相位。
    // 参考模型使用公式算出的步长，不使用 DUT 输出作为期望值。
    always @(posedge sys_clk) begin
        longint unsigned phase_sum;
        if (!rst_n) begin
            reference_phase = '0;
        end
        else if (audio_ce) begin
            phase_sum = 64'(reference_phase)
                      + reference_increment(in_phase_increment, int'(pitch_bend));
            reference_phase = 32'(phase_sum);
            dds_sample_count++;
            if (phase_sum > MAX_PHASE)
                dds_wrap_count++;
        end
        #1;
        if (dds.phase_accumulator !== reference_phase)
            $fatal(1, "DDS phase discontinuity/incorrect hold: ce=%0b bend=%0d expected=%0d got=%0d",
                   audio_ce, pitch_bend, reference_phase, dds.phase_accumulator);
    end

    initial begin : tests
        logic [31:0] actual;
        logic [31:0] previous_increment;
        logic [31:0] base_increment;
        real note_frequency;
        real ideal_frequency;
        real actual_frequency;
        real error_cents;

        // 1. A4 的中心、两端、代表中间值和中心邻近值。
        check_increment(32'd39370534, 2048, actual);
        if (actual !== 32'd39370534)
            $fatal(1, "Center must preserve the base increment exactly");
        $display("A4 center: increment=%0d", actual);
        check_increment(32'd39370534, 0, actual);
        $display("A4 -2 semitones: increment=%0d", actual);
        check_increment(32'd39370534, 4095, actual);
        $display("A4 +2 semitones: increment=%0d", actual);
        check_increment(32'd39370534, 1024, actual);
        check_increment(32'd39370534, 3072, actual);
        check_increment(32'd39370534, 2047, actual);
        check_increment(32'd39370534, 2049, actual);

        // 2. 输入 2**20 时，输出就是倍率编码，可以从端口验证全部表项。
        // 再检查零输入、小输入、无符号最高位和接近输出上限的乘法。
        for (int bend = 0; bend < 4096; bend++) begin
            check_increment(32'd1048576, bend, actual);
            case (bend)
                0: if (actual !== 32'd934175) $fatal(1, "Incorrect lower endpoint");
                2048: if (actual !== 32'd1048576) $fatal(1, "Incorrect unity coefficient");
                4095: if (actual !== 32'd1176987) $fatal(1, "Incorrect upper endpoint");
                default: ;
            endcase
            check_increment(32'd0, bend, actual);
            check_increment(32'd1, bend, actual);
            check_increment(32'h80000000, bend, actual);
            check_increment(MAX_SAFE_INPUT, bend, actual);
        end
        check_increment(32'hffffffff, 2048, actual);
        check_increment(32'hffffffff, 0, actual);
        $display("PASS: 4096 table entries, zero/small inputs, unsigned and wide products");

        // 3. 全部 128 个 MIDI 音符，各扫描全部 4096 个弯音输入。
        // 同时验证定点结果、非递减性、中心一致性及协议的 <=2 音分误差目标。
        for (int note = 0; note < 128; note++) begin
            note_frequency = 440.0 * (2.0 ** ((real'(note) - 69.0) / 12.0));
            base_increment = 32'($rtoi(note_frequency * PHASE_SCALE / SAMPLE_RATE + 0.5));
            previous_increment = '0;
            for (int bend = 0; bend < 4096; bend++) begin
                check_increment(base_increment, bend, actual);
                if (bend > 0 && actual < previous_increment)
                    $fatal(1, "Non-monotonic output: note=%0d bend=%0d", note, bend);
                if (bend == 2048 && actual !== base_increment)
                    $fatal(1, "Center changed MIDI %0d base increment", note);

                ideal_frequency = note_frequency * reference_ratio(bend);
                actual_frequency = real'(actual) * SAMPLE_RATE / PHASE_SCALE;
                if (actual == 0 || ideal_frequency >= SAMPLE_RATE / 2.0)
                    $fatal(1, "Invalid audio test range: note=%0d bend=%0d", note, bend);
                error_cents = 1200.0 * $ln(actual_frequency / ideal_frequency) / $ln(2.0);
                if (error_cents < 0.0)
                    error_cents = -error_cents;
                if (error_cents > 2.0)
                    $fatal(1, "Pitch error exceeds 2 cents: note=%0d bend=%0d error=%f",
                           note, bend, error_cents);
                if (error_cents > maximum_error_cents)
                    maximum_error_cents = error_cents;
                previous_increment = actual;
            end
        end
        $display("PASS: 128 notes x 4096 bends; max total pitch error=%0.6f cents", maximum_error_cents);

        // 4. 反向扫描，并在相同弯音值下连续改变基础步长，检查组合更新。
        for (int bend = 4095; bend >= 0; bend--)
            check_increment(32'd39370534, bend, actual);
        check_increment(32'd23409859, 3072, actual); // C4
        check_increment(32'd46819719, 3072, actual); // C5
        check_increment(32'd39370534, 3072, actual); // A4

        // 5. 一次复位后动态弯音：连续采样、暂停时改弯音、恢复和正常相位回绕。
        @(negedge sys_clk);
        in_phase_increment = 32'd39370534;
        rst_n = 1'b1;
        for (int cycle = 0; cycle < 512; cycle++) begin
            @(negedge sys_clk);
            case (cycle % 8)
                0: pitch_bend = 12'd2048;
                1: pitch_bend = 12'd0;
                2: pitch_bend = 12'd4095;
                3: pitch_bend = 12'd1024;
                4: pitch_bend = 12'd3072;
                5: pitch_bend = 12'd2047;
                6: pitch_bend = 12'd2049;
                7: pitch_bend = 12'd2048;
            endcase
            audio_ce = (cycle % 4 != 3);
            @(posedge sys_clk);
            #2;
        end
        if (dds_sample_count != 384 || dds_wrap_count == 0)
            $fatal(1, "DDS coverage missing: samples=%0d wraps=%0d", dds_sample_count, dds_wrap_count);

        $display("PASS: DDS phase continuity, audio_ce hold, and %0d natural phase wraps", dds_wrap_count);
        $display("PASS: tb_pitch_bend_lut completed %0d numerical checks", check_count);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "tb_pitch_bend_lut timeout");
    end
endmodule
