`timescale 1ns/1ns

// 独立使用实数频率公式计算参考步长，不复制 DUT 的移位/整除表达式。
module vibrato_lfo_test_case #(
    parameter integer SAMPLE_RATE = 48_000
)(
    output logic done = 1'b0
);
    localparam real PHASE_SCALE = 4294967296.0;
    localparam real PI = 3.14159265358979323846;
    logic sys_clk = 1'b0;
    logic rst_n = 1'b0;
    logic audio_ce = 1'b0;
    logic [31:0] vibrato_rate = 32'd1280;
    logic signed [15:0] lfo_q15;
    logic [31:0] reference_phase = '0;
    int checked_cycles = 0;
    int accepted_samples = 0;
    int phase_wraps = 0;

    vibrato_lfo #(.SAMPLE_RATE(SAMPLE_RATE)) dut (
        .sys_clk(sys_clk),
        .rst_n(rst_n),
        .audio_ce(audio_ce),
        .vibrato_rate(vibrato_rate),
        .lfo_q15(lfo_q15)
    );

    always #5 sys_clk = ~sys_clk;

    function automatic logic [31:0] reference_step(input logic [31:0] rate);
        real frequency_hz;
        frequency_hz = real'(rate) / 256.0;
        return 32'($rtoi(frequency_hz * PHASE_SCALE / real'(SAMPLE_RATE) + 0.5));
    endfunction

    // 在上升沿记录本次请求，NBA 完成后再检查状态和组合波形，避免竞争。
    always @(posedge sys_clk) begin : scoreboard
        logic [31:0] expected_step;
        logic [31:0] old_phase;
        real sine_value;
        int expected_sample;
        expected_step = reference_step(vibrato_rate);
        old_phase = reference_phase;
        if (!rst_n) begin
            reference_phase = '0;
        end
        else if (audio_ce) begin
            reference_phase = reference_phase + expected_step;
            accepted_samples++;
            if (reference_phase < old_phase)
                phase_wraps++;
        end
        sine_value = 32767.0 * $sin(2.0 * PI * real'(reference_phase[31:22]) / 1024.0);
        expected_sample = $rtoi(sine_value >= 0.0 ? sine_value + 0.5 : sine_value - 0.5);
        #1;
        if (dut.lfo_step !== expected_step)
            $fatal(1, "Fs=%0d rate=%0d step expected=%0d got=%0d",
                   SAMPLE_RATE, vibrato_rate, expected_step, dut.lfo_step);
        if (dut.ifo_phase !== reference_phase)
            $fatal(1, "Fs=%0d reset_n=%b ce=%b rate=%0d phase expected=%0d got=%0d",
                   SAMPLE_RATE, rst_n, audio_ce, vibrato_rate, reference_phase, dut.ifo_phase);
        if (lfo_q15 !== 16'(expected_sample))
            $fatal(1, "Fs=%0d phase=%0d waveform expected=%0d got=%0d",
                   SAMPLE_RATE, reference_phase, expected_sample, lfo_q15);
        checked_cycles++;
    end

    task automatic cycle(input bit reset_n, input bit ce, input logic [31:0] rate);
        @(negedge sys_clk);
        rst_n = reset_n;
        audio_ce = ce;
        vibrato_rate = rate;
        @(posedge sys_clk);
        #2;
    endtask

    task automatic check_period(input logic [31:0] rate);
        real expected_period;
        int sample_limit;
        int last_wrap_sample;
        int measured_period;
        int wraps;
        logic [31:0] previous_phase;
        bit saw_positive;
        bit saw_negative;

        expected_period = real'(SAMPLE_RATE) / (real'(rate) / 256.0);
        sample_limit = $rtoi(2.0 * expected_period) + 8;
        last_wrap_sample = 0;
        measured_period = 0;
        wraps = 0;
        saw_positive = 1'b0;
        saw_negative = 1'b0;
        cycle(0, 1, rate); // reset 优先于使能。
        cycle(1, 0, rate);
        for (int sample_number = 1; sample_number <= sample_limit; sample_number++) begin
            previous_phase = dut.ifo_phase;
            cycle(1, 1, rate);
            if (lfo_q15 > 0) saw_positive = 1'b1;
            if (lfo_q15 < 0) saw_negative = 1'b1;
            if (dut.ifo_phase < previous_phase) begin
                wraps++;
                if (wraps > 1) begin
                    measured_period = sample_number - last_wrap_sample;
                    if (real'(measured_period) < expected_period - 1.0 ||
                        real'(measured_period) > expected_period + 1.0)
                        $fatal(1, "Fs=%0d rate=%0d expected period=%f got=%0d samples",
                               SAMPLE_RATE, rate, expected_period, measured_period);
                end
                last_wrap_sample = sample_number;
            end
            // 不规则插入停顿，周期按被接受的音频采样点数计算。
            // 它同时验证 audio_ce 是使能，而不是另一个时钟。
            if (sample_number % 4 == 0) cycle(1, 0, rate);
            if (sample_number % 17 == 0) cycle(1, 0, rate);
        end
        if (wraps < 2 || !saw_positive || !saw_negative)
            $fatal(1, "Fs=%0d rate=%0d insufficient cycles or missing signed half-wave", SAMPLE_RATE, rate);
        $display("Fs=%0d rate=%0.2f Hz step=%0d period=%0d samples (ideal=%0.3f)",
                 SAMPLE_RATE, real'(rate)/256.0, reference_step(rate), measured_period, expected_period);
    endtask

    initial begin : tests
        logic [31:0] held_phase;

        // 同步复位、复位与使能同时有效，以及长时间没有采样的情况。
        cycle(0, 0, 1280);
        cycle(0, 1, 1280);
        repeat (16) cycle(1, 0, 1280);

        check_period(256);  // 1 Hz 下限。
        check_period(1280); // 5 Hz 默认值。
        check_period(1408); // 5.5 Hz，检查 Q8.8 小数编码。
        check_period(2048); // 8 Hz 上限。

        // 在非零相位上改速率，停顿期间必须连低位相位都完全保持。
        repeat (123) cycle(1, 1, 1408);
        held_phase = dut.ifo_phase;
        for (int rate = 256; rate <= 2048; rate++) begin
            cycle(1, 0, 32'(rate));
            if (dut.ifo_phase !== held_phase)
                $fatal(1, "Changing rate while CE=0 changed phase");
        end

        // 覆盖全部合法 Q8.8 速率，以及逐拍改速率、连续采样和停顿。
        for (int rate = 2048; rate >= 256; rate--)
            cycle(1, rate % 3 != 0, 32'(rate));
        repeat (257) cycle(1, 1, 2048);

        // 检查复位是同步复位：拉低 rst_n 后，到上升沿前仍保持相位。
        held_phase = dut.ifo_phase;
        @(negedge sys_clk);
        rst_n = 1'b0;
        audio_ce = 1'b1;
        #1;
        if (dut.ifo_phase !== held_phase)
            $fatal(1, "Reset unexpectedly changed phase before the clock edge");
        @(posedge sys_clk);
        #2;
        cycle(1, 1, 1280);
        cycle(1, 0, 1280);

        $display("PASS: vibrato_lfo Fs=%0d, checked=%0d clocks, samples=%0d, wraps=%0d",
                 SAMPLE_RATE, checked_cycles, accepted_samples, phase_wraps);
        done = 1'b1;
    end
endmodule

module tb_vibrato_lfo;
    logic [1:0] done;
    vibrato_lfo_test_case #(.SAMPLE_RATE(48000)) fs_48k (.done(done[0]));
    vibrato_lfo_test_case #(.SAMPLE_RATE(44100)) fs_44k1 (.done(done[1]));

    initial begin
        wait (&done);
        $display("PASS: all vibrato_lfo test cases");
        $finish;
    end

    initial begin
        #10_000_000;
        $fatal(1, "vibrato_lfo test timed out");
    end
endmodule
