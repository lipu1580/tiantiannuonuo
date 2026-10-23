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
    logic signed [15:0] sine_table [0:1023];

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
        case (saved_note)
            0: increment = 32'd731558;
            69: increment = 32'd39370534;
            81: increment = 32'd78741067;
            default: $fatal(1, "reference model received unsupported note");
        endcase
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
                raw_sample = (requested_wave == 0)
                           ? 64'($signed(sine_table[ref_phase[31:22]])) : 64'sd0;
                product = raw_sample * $signed({1'b0, request_envelope});
                expected_sample = 24'(product >>> 16);
            end
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

    initial begin
        $readmemh("rtl/audio/sine_1024.hex", sine_table);
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

        check(positive_samples > 0 && negative_samples > 0,
              "stimulus must cover both positive and negative reference samples");
        $display("RESULT %s: failures=%0d", case_name, errors - case_errors);
        $display("VOICE checks=%0d failures=%0d sample_errors=%0d valid_errors=%0d",
                 checks, errors, sample_errors, valid_errors);
        if (errors != 0) $fatal(1, "tb_voice failed; see FAIL messages");
        $display("PASS: tb_voice");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "TIMEOUT: tb_voice did not finish");
    end
endmodule
