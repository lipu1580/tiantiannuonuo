`timescale 1ns/1ns

module tb_voice #(
    // 对应当前 voice：audio_ce 沿保存 ADSR 更新前的包络。
    // 若实现选择更新后的包络，运行时用 -GENVELOPE_BEFORE_UPDATE=0。
    parameter bit ENVELOPE_BEFORE_UPDATE = 1
);
    localparam integer CLK_PERIOD = 10;
    localparam integer SUSTAIN_LEVEL = 30000;

    logic sys_clk = 0;
    logic rst_n = 0;
    logic audio_ce = 0;
    logic note_on = 0;
    logic note_off = 0;
    logic [6:0] note_id = 0;
    logic [7:0] velocity = 255;
    logic [7:0] expression = 255;
    logic [11:0] pitch_bend = 2048;
    logic [1:0] waveform_sel = 0;
    logic [20:0] vibrato_ratio_q20;
    logic [20:0] manual_ratio_q20 = 21'd1048576;
    logic use_lfo = 0;
    logic [7:0] vibrato_depth = 0;
    logic [31:0] vibrato_rate = 1280;
    logic signed [15:0] lfo_q15;
    logic signed [24:0] depth_product;
    logic signed [17:0] vibrato_cents_q8;
    logic [20:0] lfo_ratio_q20;
    logic signed [23:0] voice_sample;
    logic sample_valid;
    logic active;
    logic [15:0] envelope_value;

    integer case_errors = 0;
    string case_name = "";
    integer checks = 0;
    integer errors = 0;
    integer sample_errors = 0;
    integer valid_errors = 0;
    integer positive_samples = 0;
    integer negative_samples = 0;
    integer phase_checks = 0;
    integer phase_errors = 0;
    logic signed [15:0] sine_table [0:1023];
    logic signed [15:0] organ_table [0:1023];
    logic signed [15:0] pluck_table [0:1023];

    // 独立维护音符和相位，不读取 DUT 的内部信号。
    // 使用 MIDI 0、A4/A5，直接写出按 48 kHz、32 位相位算出的常量，
    // 避免复用被测 LUT 导致同一个接线错误同时出现在参考值里。
    logic [6:0] saved_note = 0;
    logic [31:0] ref_phase = 0;
    logic pending = 0;
    logic signed [23:0] expected_sample = 0;
    logic check_sample_value = 1;

    voice #(
        .ATTACK_STEP(16'd20000),
        .DECAY_STEP(16'd12000),
        .SUSTAIN_LEVEL(16'(SUSTAIN_LEVEL)),
        .RELEASE_STEP(16'd17000)
    ) DUT (.*);

    // 真实颤音链路作为输入激励。voice 只接收比例，深度平滑属于核心测试。
    vibrato_lfo #(.SAMPLE_RATE(48000)) u_lfo (
        .sys_clk(sys_clk), .rst_n(rst_n), .audio_ce(audio_ce),
        .vibrato_rate(vibrato_rate), .lfo_q15(lfo_q15)
    );
    assign depth_product = lfo_q15 * $signed({1'b0, vibrato_depth});
    assign vibrato_cents_q8 = 18'(depth_product >>> 7);
    pitch_ratio_lut u_vibrato_ratio (
        .cents_q8(vibrato_cents_q8), .ratio_q20(lfo_ratio_q20)
    );
    assign vibrato_ratio_q20 = use_lfo ? lfo_ratio_q20 : manual_ratio_q20;

    always #(CLK_PERIOD / 2) sys_clk = ~sys_clk;

    task automatic check(input logic condition, input string message);
        checks++;
        if (condition !== 1'b1) begin
            errors++;
            // 限制日志数量，但所有失败仍计入统计。
            if (errors <= 20)
                $display("FAIL @%0t: %s (sample=%0d env=%0d active=%b)",
                         $time, message, voice_sample, envelope_value, active);
        end
    endtask

    task automatic begin_case(input string name);
        if (case_name != "")
            $display("RESULT %s: failures=%0d", case_name, errors - case_errors);
        case_name = name;
        case_errors = errors;
        $display("%s", name);
    endtask

    function automatic logic [20:0] ratio_for_cents(input int cents);
        return 21'($rtoi(1048576.0 * (2.0 ** (real'(cents) / 1200.0)) + 0.5));
    endfunction

    // 以公式独立计算滑音系数；每一级乘法后分别截断，与两级音高路径对应。
    // 不实例化第二个被测滑音 LUT 作为参考，也不读取 DUT 的中间步长。
    function automatic logic [31:0] reference_increment(
        input logic [6:0] note,
        input logic [11:0] bend,
        input logic [20:0] vibrato_ratio
    );
        longint unsigned base_increment;
        longint unsigned bend_coefficient;
        longint unsigned bent_increment;
        longint unsigned final_increment;
        real cents;
        case (note)
            0: base_increment = 64'd731558;
            69: base_increment = 64'd39370534;
            81: base_increment = 64'd78741067;
            default: $fatal(1, "reference model received unsupported note");
        endcase
        if (bend <= 2048)
            cents = 200.0 * real'(int'(bend) - 2048) / 2048.0;
        else
            cents = 200.0 * real'(int'(bend) - 2048) / 2047.0;
        bend_coefficient = 64'($rtoi(1048576.0 * (2.0 ** (cents / 1200.0)) + 0.5));
        bent_increment = (base_increment * bend_coefficient) >> 20;
        final_increment = (bent_increment * 64'(vibrato_ratio)) >> 20;
        return 32'(final_increment);
    endfunction

    // 请求沿之后更新相位；下一拍检查同步 ROM 返回的新相位样本。
    // 常规用例在请求至返回期间保持控制量稳定。
    // 包络采用更新前还是更新后的值，由上面的参数明确指定。
    // 任务书未规定两拍间 expression 更新的归属，CASE 10 只观察此边界。
    // 先做 64 位有符号乘法，再算术右移，避免参考运算发生窄位宽截断。
    task automatic cycle(input logic ce, input logic on_cmd, input logic off_cmd);
        logic [31:0] increment;
        logic signed [63:0] raw_sample;
        logic signed [63:0] product;
        logic [1:0] requested_wave;
        logic [15:0] request_envelope;
        @(negedge sys_clk);
        audio_ce = ce;
        note_on = on_cmd;
        note_off = off_cmd;
        requested_wave = waveform_sel;
        increment = reference_increment(saved_note, pitch_bend, vibrato_ratio_q20);
        @(posedge sys_clk);
        request_envelope = envelope_value; // NBA 更新前取值，与 saved_envelope 对应
        #1;
        if (!ENVELOPE_BEFORE_UPDATE) request_envelope = envelope_value;
        if (!rst_n) begin
            ref_phase = 0;
            saved_note = 0;
            pending = 0;
            expected_sample = 0;
            check(sample_valid === 1'b0, "reset must clear sample_valid");
            check(active === 1'b0 && envelope_value === 0,
                  "reset must clear active and envelope");
            check(voice_sample === 0, "reset must silence output");
        end else begin
            if (sample_valid !== pending) valid_errors++;
            check(sample_valid === pending, "sample_valid must equal previous audio_ce");
            if (pending) begin
                if (check_sample_value) begin
                    if (voice_sample !== expected_sample) sample_errors++;
                    check(voice_sample === expected_sample,
                          $sformatf("sample mismatch: expected %0d", expected_sample));
                end
                if (expected_sample > 0) positive_samples++;
                if (expected_sample < 0) negative_samples++;
            end
            if (ce) begin
                ref_phase = ref_phase + increment;
                case (requested_wave)
                    0: raw_sample = 64'($signed(sine_table[ref_phase[31:22]]));
                    1: raw_sample = 64'($signed(organ_table[ref_phase[31:22]]));
                    2: raw_sample = 64'($signed(pluck_table[ref_phase[31:22]]));
                    default: raw_sample = 0;
                endcase
                product = raw_sample * $signed({1'b0, request_envelope});
                expected_sample = 24'(product >>> 16);
            end
            // 包括 CE=0 的保持、两级乘法的截断、相位回绕和换音时的连续性。
            phase_checks++;
            if (DUT.DUT1.phase_accumulator !== ref_phase) phase_errors++;
            check(DUT.DUT1.phase_accumulator === ref_phase,
                  $sformatf("DDS phase mismatch: expected %0d got %0d",
                            ref_phase, DUT.DUT1.phase_accumulator));
            pending = ce;
            if (on_cmd) saved_note = note_id;
        end
    endtask

    task automatic reset_dut;
        rst_n = 0;
        note_id = 0;
        velocity = 255;
        expression = 255;
        waveform_sel = 0;
        pitch_bend = 2048;
        manual_ratio_q20 = 21'd1048576;
        use_lfo = 0;
        vibrato_depth = 0;
        vibrato_rate = 1280;
        repeat (2) cycle(0, 0, 0);
        rst_n = 1;
        cycle(0, 0, 0);
    endtask

    task automatic sample_step;
        cycle(1, 0, 0);
        repeat (3) cycle(0, 0, 0);
    endtask

    task automatic start_note(input logic [6:0] note, input logic [7:0] vel);
        note_id = note;
        velocity = vel;
        cycle(0, 1, 0); // 故意在 audio_ce=0 时发送单周期命令
        velocity = 17;
        repeat (2) cycle(0, 0, 0);
        sample_step();
        check(active === 1'b1, "pending NOTE_ON must activate voice");
    endtask

    task automatic check_sustain(input integer vel, input integer expr);
        integer expected_envelope;
        expected_envelope = (SUSTAIN_LEVEL * vel * expr) >> 16;
        check(envelope_value === 16'(expected_envelope),
              $sformatf("sustain/velocity/expression: expected envelope %0d",
                        expected_envelope));
    endtask

    initial begin : tests
        int positive_modulation;
        int negative_modulation;
        logic [31:0] held_phase;
        $readmemh("rtl/audio/sine_1024.hex", sine_table);
        $readmemh("rtl/audio/organ_1024.hex", organ_table);
        $readmemh("rtl/audio/pluck_1024.hex", pluck_table);
        if ($test$plusargs("waves")) begin
            $dumpfile("/tmp/tb_voice.vcd");
            $dumpvars(0, tb_voice);
        end

        begin_case("CASE 1: reset and valid zero samples while idle");
        reset_dut();
        repeat (4) sample_step();

        begin_case("CASE 2: NOTE_ON between samples, attack and sustain");
        start_note(69, 255);
        repeat (15) sample_step();
        check_sustain(255, 255);

        begin_case("CASE 3: A4 phase, positive/negative samples, signed scaling");
        repeat (120) sample_step();

        begin_case("CASE 4: external note_id changes without NOTE_ON");
        note_id = 81; // 声部必须继续演奏已锁存的 A4
        repeat (120) sample_step();

        begin_case("CASE 5: expression changes and mute while active");
        // 上一项故意改变了外部音符；复位隔离失败，避免相位误差传到后续用例。
        reset_dut();
        start_note(69, 255);
        repeat (15) sample_step();
        expression = 128;
        repeat (3) sample_step();
        check_sustain(255, 128);
        expression = 0;
        repeat (3) sample_step();
        check(envelope_value === 0 && active === 1'b1,
              "expression=0 must mute without freeing voice");
        expression = 255;
        sample_step();

        begin_case("CASE 6: release tail, then valid idle silence");
        cycle(0, 0, 1);
        cycle(0, 0, 0);
        sample_step();
        check(active === 1'b1, "NOTE_OFF must preserve active during release");
        repeat (10) sample_step();
        check(active === 1'b0 && envelope_value === 0,
              "release must finish and free voice");
        repeat (3) sample_step();

        begin_case("CASE 7: new A5 note, velocity latch, simultaneous ON/OFF");
        start_note(81, 128);
        repeat (15) sample_step();
        check_sustain(128, 255);
        repeat (60) sample_step();
        velocity = 200;
        cycle(1, 1, 1); // 本次仍是 A5，避免规定同沿换音的相位先后顺序
        cycle(0, 0, 0);
        repeat (15) sample_step();
        check(active === 1'b1, "simultaneous ON/OFF must prefer ON");
        check_sustain(200, 255);

        begin_case("CASE 8: retrigger during release");
        cycle(0, 0, 1);
        sample_step();
        check(active === 1'b1, "setup must leave a release tail");
        start_note(81, 90);
        repeat (15) sample_step();
        check(active === 1'b1, "retrigger must keep voice active");
        check_sustain(90, 255);

        begin_case("CASE 9: consecutive sampling requests");
        repeat (80) cycle(1, 0, 0);
        repeat (3) cycle(0, 0, 0);

        begin_case("CASE 10: observe expression update timing");
        cycle(1, 0, 0);
        expression = 0;
        // 规范没有要求本次返回必须使用旧 expression 或新 expression。
        // 保留 valid 检查；这一拍只记录样本，不按自定快照策略判错。
        check_sample_value = 0;
        cycle(0, 0, 0);
        $display("INFO: expression changed after request; returned sample=%0d",
                 voice_sample);
        check_sample_value = 1;
        sample_step();
        expression = 255;

        begin_case("CASE 11: reset cancels pending sample and note command");
        cycle(1, 0, 0);
        reset_dut();
        cycle(0, 1, 0);
        reset_dut();
        repeat (4) sample_step();
        check(active === 1'b0, "reset must discard pending NOTE_ON");

        begin_case("CASE 12: organ / pluck / mute sample arithmetic");
        reset_dut();
        start_note(69, 255);
        repeat (15) sample_step();
        for (int wave_id = 0; wave_id < 4; wave_id++) begin
            waveform_sel = 2'(wave_id);
            repeat (120) sample_step();
        end

        begin_case("CASE 13: unity vibrato preserves all 4096 original bend values");
        reset_dut();
        start_note(69, 255);
        repeat (15) sample_step();
        for (int bend = 0; bend < 4096; bend++) begin
            pitch_bend = 12'(bend);
            sample_step();
        end

        begin_case("CASE 14: manual +/-100-cent vibrato at both bend endpoints, A4/A5");
        for (int note_index = 0; note_index < 2; note_index++) begin
            start_note(note_index == 0 ? 7'd69 : 7'd81, 255);
            repeat (15) sample_step();
            for (int bend_index = 0; bend_index < 3; bend_index++) begin
                case (bend_index)
                    0: pitch_bend = 12'd0;
                    1: pitch_bend = 12'd2048;
                    2: pitch_bend = 12'd4095;
                endcase
                for (int cents = -100; cents <= 100; cents += 25) begin
                    manual_ratio_q20 = ratio_for_cents(cents);
                    repeat (32) sample_step();
                end
            end
        end

        begin_case("CASE 15: real LFO + ratio LUT, dynamic depth/rate with bend");
        reset_dut();
        start_note(69, 255);
        repeat (15) sample_step();
        use_lfo = 1;
        vibrato_depth = 100;
        positive_modulation = 0;
        negative_modulation = 0;
        for (int bend_index = 0; bend_index < 2; bend_index++) begin
            pitch_bend = bend_index == 0 ? 12'd0 : 12'd4095;
            repeat (10000) begin
                sample_step();
                if (vibrato_ratio_q20 > 21'd1048576) positive_modulation++;
                if (vibrato_ratio_q20 < 21'd1048576) negative_modulation++;
                check(active === 1'b1, "vibrato must not release the note");
            end
        end
        check(positive_modulation > 0 && negative_modulation > 0,
              "real LFO stimulus must modulate above and below the bent pitch");
        for (int rate_index = 0; rate_index < 4; rate_index++) begin
            case (rate_index)
                0: vibrato_rate = 256;
                1: vibrato_rate = 1408;
                2: vibrato_rate = 2048;
                3: vibrato_rate = 1280;
            endcase
            vibrato_depth = 8'(25 * rate_index);
            repeat (257) sample_step();
        end
        // 深度为零时，来自真实链路的倍率也必须精确等于 1。
        vibrato_depth = 0;
        repeat (64) begin
            sample_step();
            check(vibrato_ratio_q20 === 21'd1048576,
                  "zero vibrato depth must produce exact unity");
        end

        begin_case("CASE 16: CE=0 control changes hold phase; continuous modulated requests");
        held_phase = ref_phase;
        for (int i = 0; i < 32; i++) begin
            pitch_bend = 12'(i * 127);
            vibrato_depth = 8'(i * 3);
            vibrato_rate = 32'(256 + i * 50);
            cycle(0, 0, 0);
            check(DUT.DUT1.phase_accumulator === held_phase,
                  "changing pitch controls without CE must not advance phase");
        end
        repeat (512) cycle(1, 0, 0);
        repeat (3) cycle(0, 0, 0);
        for (int wave_id = 0; wave_id < 4; wave_id++) begin
            waveform_sel = 2'(wave_id);
            repeat (120) sample_step();
        end

        begin_case("CASE 17: NOTE_OFF and reset while vibrato is running");
        cycle(0, 0, 1);
        repeat (12) sample_step();
        check(active === 1'b0 && envelope_value === 0,
              "vibrato must not prevent release from finishing");
        repeat (3) sample_step();
        cycle(1, 0, 0);
        reset_dut();
        repeat (4) sample_step();

        check(positive_samples > 0 && negative_samples > 0,
              "stimulus must cover both positive and negative reference samples");
        $display("RESULT %s: failures=%0d", case_name, errors - case_errors);
        $display("VOICE checks=%0d failures=%0d sample_errors=%0d valid_errors=%0d phase_checks=%0d phase_errors=%0d",
                 checks, errors, sample_errors, valid_errors, phase_checks, phase_errors);
        if (errors != 0) $fatal(1, "tb_voice failed; see FAIL messages");
        $display("PASS: tb_voice");
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "TIMEOUT: tb_voice did not finish");
    end
endmodule
