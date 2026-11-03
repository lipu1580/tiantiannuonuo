`timescale 1ns/1ns

module tb_vibrato_luts;
    localparam real PI = 3.14159265358979323846;
    localparam real RATIO_SCALE = 1048576.0;
    logic [9:0] phase_index = '0;
    logic signed [15:0] lfo_q15;
    logic signed [17:0] cents_q8 = '0;
    logic [20:0] ratio_q20;
    int sine_samples [0:1023];
    real maximum_lfo_error = 0.0;
    real maximum_pitch_error_cents = 0.0;

    lfo_lut lfo (.phase_index(phase_index), .lfo_q15(lfo_q15));
    pitch_ratio_lut pitch (.cents_q8(cents_q8), .ratio_q20(ratio_q20));

    function automatic real abs_real(input real value);
        return value < 0.0 ? -value : value;
    endfunction

    initial begin : tests
        real expected;
        real error;
        real clamped_cents;
        real ideal_ratio;
        int expected_coefficient;
        int sample_sum;
        int previous_coefficient;
        int checks;

        sample_sum = 0;
        checks = 0;
        for (int i = 0; i < 1024; i++) begin
            phase_index = 10'(i);
            #1;
            expected = 32767.0 * $sin(2.0 * PI * real'(i) / 1024.0);
            error = abs_real(real'($signed(lfo_q15)) - expected);
            if (error > 0.500001)
                $fatal(1, "LFO index=%0d expected=%f got=%0d", i, expected, lfo_q15);
            if (error > maximum_lfo_error)
                maximum_lfo_error = error;
            sine_samples[i] = int'($signed(lfo_q15));
            sample_sum += sine_samples[i];
            checks++;
        end
        if (sample_sum != 0 || sine_samples[0] != 0 || sine_samples[256] != 32767 ||
            sine_samples[512] != 0 || sine_samples[768] != -32767)
            $fatal(1, "LFO DC/quarter-cycle values incorrect");
        for (int i = 0; i < 1024; i++) begin
            if (sine_samples[i] != -sine_samples[(i + 512) % 1024])
                $fatal(1, "LFO half-wave symmetry failed at %0d", i);
        end

        // 穷举全部 18 位输入，包括小数、负数和两端越界值。
        // 参考值直接使用指数公式，不读取或复制 DUT 的表项及插值算法。
        previous_coefficient = 0;
        for (int q8 = -131072; q8 <= 131071; q8++) begin
            cents_q8 = 18'(q8);
            clamped_cents = real'(q8) / 256.0;
            if (clamped_cents < -300.0) clamped_cents = -300.0;
            if (clamped_cents > 300.0) clamped_cents = 300.0;
            ideal_ratio = 2.0 ** (clamped_cents / 1200.0);
            expected_coefficient = $rtoi(ideal_ratio * RATIO_SCALE + 0.5);
            #1;
            if (ratio_q20 < 21'(previous_coefficient))
                $fatal(1, "Pitch ratio not monotonic at q8=%0d", q8);
            if (abs_real(real'(ratio_q20) - real'(expected_coefficient)) > 1.0)
                $fatal(1, "Pitch ratio q8=%0d expected~=%0d got=%0d",
                       q8, expected_coefficient, ratio_q20);
            if (q8 >= -76800 && q8 <= 76800 && q8 % 256 == 0 &&
                ratio_q20 != 21'(expected_coefficient))
                $fatal(1, "Integer-cent table entry incorrect at q8=%0d", q8);
            if ((q8 < -76800 || q8 > 76800) && ratio_q20 != 21'(expected_coefficient))
                $fatal(1, "Out-of-range input did not saturate at q8=%0d", q8);
            if (q8 == 0 && ratio_q20 != 21'd1048576)
                $fatal(1, "Zero cents must give exact unity");
            error = abs_real(1200.0 * $ln(real'(ratio_q20) / RATIO_SCALE / ideal_ratio)
                             / $ln(2.0));
            if (error > 0.003)
                $fatal(1, "Pitch error too large: q8=%0d error=%f cents", q8, error);
            if (error > maximum_pitch_error_cents)
                maximum_pitch_error_cents = error;
            previous_coefficient = int'(ratio_q20);
            checks++;
        end

        $display("PASS: vibrato LUTs, %0d vectors; max LFO error=%0.6f LSB; max pitch error=%0.6f cents",
                 checks, maximum_lfo_error, maximum_pitch_error_cents);
        $finish;
    end
endmodule
