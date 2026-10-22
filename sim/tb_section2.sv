`timescale 1ns/1ps

// 运行：make sim WAIT_TB_NAME=section2
module tb_section2;
    parameter integer SYS_CLK_HZ   = 27_000_000;
    parameter integer SAMPLE_RATE  = 48_000;
    parameter integer NOTE_W       = 7;
    parameter integer PHASE_W      = 32;
    parameter integer ADDR_W       = 10;
    parameter integer SAMPLE_W     = 16;
    parameter integer TEST_SAMPLES = 12_000; // 每个音符约 0.25 秒
    parameter INIT_FILE = "rtl/audio/sine_1024.hex";

    localparam realtime CLK_PERIOD = 1.0e9 / SYS_CLK_HZ;
    localparam integer TABLE_DEPTH = 1 << ADDR_W;
    localparam real FULL_SCALE = (2.0 ** (SAMPLE_W - 1)) - 1.0;
    localparam real PI = 3.141592653589793;

    logic sys_clk = 1'b0;
    logic rst_n = 1'b0;
    logic audio_ce, waveform_valid;
    logic [NOTE_W-1:0] note_id = NOTE_W'(69);
    logic [PHASE_W-1:0] phase_increment;
    logic signed [SAMPLE_W-1:0] waveform_sample;
    logic [1:0] waveform_sel = 2'b00;
    logic signed [SAMPLE_W-1:0] sine_table [0:TABLE_DEPTH-1];

    always #(CLK_PERIOD / 2.0) sys_clk = ~sys_clk;

    sample_tick_gen #(
        .SYS_CLK_HZ (SYS_CLK_HZ), .SAMPLE_RATE (SAMPLE_RATE)
    ) DUT0 (
        .sys_clk (sys_clk), .rst_n (rst_n), .audio_ce (audio_ce)
    );

    note_freq_lut #(
        .NOTE_W (NOTE_W), .PHASE_W (PHASE_W), .SAMPLE_RATE (SAMPLE_RATE)
    ) DUT1 (
        .note_id (note_id), .pitch_bend (12'd2048),
        .phase_increment (phase_increment)
    );

    dds_oscillator #(
        .PHASE_W (PHASE_W), .SAMPLE_W (SAMPLE_W), .WAVE_ADDR_W (ADDR_W)
    ) DUT2 (
        .sys_clk (sys_clk), .rst_n (rst_n), .audio_ce (audio_ce),
        .phase_increment (phase_increment), .waveform_sel (waveform_sel),
        .waveform_sample (waveform_sample), .waveform_valid (waveform_valid)
    );

    function automatic real abs_real(input real value);
        return value < 0.0 ? -value : value;
    endfunction

    // 参考相位按数学公式产生的增量推进，不读取 DUT 的相位作为期望值。
    logic [PHASE_W-1:0] expected_increment = '0;
    logic [PHASE_W-1:0] expected_phase = '0;
    logic pending_valid = 1'b0;
    logic signed [SAMPLE_W-1:0] pending_sample = '0;
    integer cycle_count = 0;
    integer last_request_cycle = -1;
    integer request_count = 0;
    integer valid_count = 0;

    integer sample_count = 0;
    integer rising_crossings = 0;
    integer positive_count = 0;
    integer negative_count = 0;
    integer min_sample = 0;
    integer max_sample = 0;
    integer previous_sample = 0;
    bit have_previous = 1'b0; //二态逻辑类型，它的每一位只能取两个值：0 或 1。
    real target_hz = 440.0;
    real first_crossing_ns = 0.0; //real 是一个浮点数数据类型，用于表示实数。它在 SystemVerilog 中等同于 C 语言中的 double，通常遵循 64 位 IEEE 754 浮点数标准。
    real last_crossing_ns = 0.0;
    real previous_sample_ns = 0.0;
    // 换音只清除测频统计，连续性检查保留前一个有效样本。
    integer continuity_previous = 0;
    bit continuity_started = 1'b0;

    // 上升沿记录请求，延迟 1 ps 等待 NBA 更新后检查，避开时序竞争。
    // 当前 DDS 在请求后的下一个 sys_clk 上升沿给出对应有效样本。
    always @(posedge sys_clk) begin : monitor
        logic expected_valid;
        logic signed [SAMPLE_W-1:0] expected_sample;
        integer current_sample;
        integer interval_cycles;
        real crossing_ns;
        real step_limit;

        if (!rst_n) begin
            expected_phase = '0;
            pending_valid = 1'b0;
            cycle_count = 0;
            last_request_cycle = -1;
            request_count = 0;
            valid_count = 0;
            continuity_started = 1'b0;
            #0.001;
            if (audio_ce !== 1'b0 || waveform_valid !== 1'b0 ||
                DUT2.phase_accumulator !== '0)
                $fatal(1, "Reset did not clear tick, valid and phase");
        end else begin
            cycle_count++;
            expected_valid = pending_valid;
            expected_sample = pending_sample;
            pending_valid = audio_ce;
            if (audio_ce) begin
                if (last_request_cycle >= 0) begin
                    interval_cycles = cycle_count - last_request_cycle;
                    if (interval_cycles < SYS_CLK_HZ / SAMPLE_RATE ||
                        interval_cycles > (SYS_CLK_HZ + SAMPLE_RATE - 1) / SAMPLE_RATE)
                        $fatal(1, "Wrong sample interval: %0d clocks", interval_cycles);
                end
                last_request_cycle = cycle_count;
                request_count++;
                expected_phase = expected_phase + expected_increment;
                pending_sample = sine_table[expected_phase[PHASE_W-1 -: ADDR_W]];
            end

            #0.001;
            // 每拍检查：空闲时保持；回绕为模加；换音不得重置。
            if (DUT2.phase_accumulator !== expected_phase)
                $fatal(1, "Unexpected phase/reset: note=%0d cycle=%0d expected=%h got=%h",
                       note_id, cycle_count, expected_phase, DUT2.phase_accumulator);
            if (waveform_valid !== expected_valid)
                $fatal(1, "Invalid sample timing at cycle %0d: expected=%b got=%b",
                       cycle_count, expected_valid, waveform_valid);

            // 仅统计有效样本，不能按 sys_clk 对重复的 ROM 输出计数。
            if (waveform_valid) begin
                valid_count++;
                if (waveform_sample !== expected_sample)
                    $fatal(1, "Waveform mismatch: note=%0d sample=%0d expected=%0d got=%0d",
                           note_id, sample_count, expected_sample, waveform_sample);
                current_sample = int'($signed(waveform_sample));

                // 正弦相邻样本最大差，加上查表量化余量。
                step_limit = 2.0 * FULL_SCALE * $sin(PI * target_hz / SAMPLE_RATE)
                             + 2.0 * PI * FULL_SCALE / TABLE_DEPTH + 2.0;
                if (continuity_started &&
                    abs_real(real'(current_sample) - real'(continuity_previous)) > step_limit)
                    $fatal(1, "Discontinuous waveform: previous=%0d current=%0d limit=%.2f",
                           continuity_previous, current_sample, step_limit);
                continuity_previous = current_sample;
                continuity_started = 1'b1;

                sample_count++;
                if (current_sample > 0) positive_count++;
                if (current_sample < 0) negative_count++;
                if (current_sample < min_sample) min_sample = current_sample;
                if (current_sample > max_sample) max_sample = current_sample;

                // 允许负 -> 0：使用 >0 会漏掉波表的精确零点。
                // 对相邻有效样本线性插值，并用实际仿真时间测频。
                if (have_previous && previous_sample < 0 && current_sample >= 0) begin
                    crossing_ns = previous_sample_ns + ($realtime - previous_sample_ns)
                                  * real'(-previous_sample)
                                  / real'(current_sample - previous_sample);
                    if (rising_crossings == 0) first_crossing_ns = crossing_ns;
                    last_crossing_ns = crossing_ns;
                    rising_crossings++;
                end
                previous_sample = current_sample;
                previous_sample_ns = $realtime;
                have_previous = 1'b1;
            end
        end
    end

    task automatic check_tone(input integer midi_note, input string name);
        real measured_hz;
        real tolerance_hz;
        // 调整音符时没有未完成请求，且远离上升沿，避免混入旧音符。
        @(negedge sys_clk);
        note_id = NOTE_W'(midi_note);
        target_hz = 440.0 * (2.0 ** ((real'(midi_note) - 69.0) / 12.0));
        expected_increment = PHASE_W'($rtoi(target_hz * (2.0 ** PHASE_W)
                                            / SAMPLE_RATE + 0.5));
        sample_count = 0;
        rising_crossings = 0;
        positive_count = 0;
        negative_count = 0;
        min_sample = 0;
        max_sample = 0;
        have_previous = 1'b0;
        #0.001;
        if (phase_increment !== expected_increment)
            $fatal(1, "%s LUT: expected=%0d got=%0d", name, expected_increment, phase_increment);

        while (sample_count < TEST_SAMPLES) @(negedge sys_clk);
        if (positive_count == 0 || negative_count == 0 ||
            real'(max_sample) < 0.9 * FULL_SCALE || real'(min_sample) > -0.9 * FULL_SCALE)
            $fatal(1, "%s missing signed full-scale sine: min=%0d max=%0d", name, min_sample, max_sample);
        if (rising_crossings < 3)
            $fatal(1, "%s has too few rising crossings: %0d", name, rising_crossings);
        measured_hz = real'(rising_crossings - 1) * 1.0e9
                      / (last_crossing_ns - first_crossing_ns);
        // 允许 0.1% 测量误差及一个相位增量 LSB 的频率量化误差。
        tolerance_hz = target_hz * 0.001 + SAMPLE_RATE / (2.0 ** PHASE_W);
        if (abs_real(measured_hz - target_hz) > tolerance_hz)
            $fatal(1, "%s frequency: target=%.6f Hz measured=%.6f Hz tolerance=%.6f Hz",
                   name, target_hz, measured_hz, tolerance_hz);
        $display("PASS %s (MIDI %0d): target=%.6f Hz measured=%.6f Hz samples=%0d crossings=%0d range=[%0d,%0d]",
                 name, midi_note, target_hz, measured_hz, sample_count, rising_crossings, min_sample, max_sample);
    endtask

    initial begin : stimulus
        real ideal_sample;
        if (SYS_CLK_HZ < 3 * SAMPLE_RATE || SAMPLE_RATE < 8_000 ||
            PHASE_W < ADDR_W || PHASE_W > 32 || NOTE_W < 7 ||
            ADDR_W != 10 || SAMPLE_W != 16 || TEST_SAMPLES < 1024)
            $fatal(1, "Unsupported parameters: use 1024x16 sine ROM, PHASE_W<=32 and >=1024 samples");
        $readmemh(INIT_FILE, sine_table);
        // 独立核对表内容，避免 DUT 和参考模型共用错误波表而一起通过。
        for (int i = 0; i < TABLE_DEPTH; i++) begin
            ideal_sample = FULL_SCALE * $sin(2.0 * PI * real'(i) / TABLE_DEPTH);
            if ($isunknown(sine_table[i]) || abs_real(real'($signed(sine_table[i])) - ideal_sample) > 1.0)
                $fatal(1, "Invalid signed sine table at address %0d", i);
        end
        // 可选波形：用 --trace 编译，再运行 Vtb_section2 +waves。
        if ($test$plusargs("waves")) begin
            $dumpfile("build/tb_section2.vcd");
            $dumpvars(0, tb_section2);
        end
        repeat (5) @(negedge sys_clk);
        rst_n = 1'b1;
        check_tone(69, "A4");
        check_tone(60, "C4");
        check_tone(72, "C5");
        if (request_count != valid_count)
            $fatal(1, "Unmatched requests: requests=%0d valid=%0d", request_count, valid_count);
        $display("PASS section2: frequency, signed sine, continuity, valid timing and phase preservation (%0d samples)",
                 valid_count);
        $finish;
    end

    initial begin : watchdog
        #(CLK_PERIOD * ((3.0 * TEST_SAMPLES + 20.0) * SYS_CLK_HZ / SAMPLE_RATE + 20.0));
        $fatal(1, "Timeout waiting for valid audio samples");
    end
endmodule
