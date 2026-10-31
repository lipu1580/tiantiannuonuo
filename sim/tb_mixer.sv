`timescale 1ns/1ns

module tb_mixer #(
    parameter integer VOICE_COUNT = 4,
    parameter integer VOICE_W = 24,
    parameter integer OUTPUT_W = 24
);
    // 当前接口约定：master_gain / 256，额外混音缩放 / 4，总计 / 1024。
    // 默认配置不会触发限幅；用 -GOUTPUT_W=16 检查正负饱和及边界。
    localparam integer CLK_PERIOD = 10;
    localparam longint signed VOICE_MAX = (64'sd1 << (VOICE_W - 1)) - 1;
    localparam longint signed VOICE_MIN = -(64'sd1 << (VOICE_W - 1));
    localparam longint signed OUTPUT_MAX = (64'sd1 << (OUTPUT_W - 1)) - 1;
    localparam longint signed OUTPUT_MIN = -(64'sd1 << (OUTPUT_W - 1));
    typedef logic signed [VOICE_W-1:0] sample_t;
    typedef sample_t samples_t [0:VOICE_COUNT-1];

    logic sys_clk = 0;
    logic rst_n = 0;
    logic audio_ce = 0;
    logic sample_valid = 0;
    samples_t voice_sample;
    logic [7:0] master_gain = 0;
    logic signed [OUTPUT_W-1:0] mixed_sample;
    logic mixed_valid;

    logic signed [OUTPUT_W-1:0] expected_sample = 0;
    samples_t stimulus;
    logic [31:0] rng = 32'h6d69_7865;
    logic [31:0] controls;
    integer checks = 0;
    integer errors = 0;
    integer positive_clips = 0;
    integer negative_clips = 0;
    integer case_errors = 0;
    string case_name = "";

    mixer #(
        .VOICE_COUNT(VOICE_COUNT), .VOICE_W(VOICE_W), .OUTPUT_W(OUTPUT_W)
    ) DUT (.*);

    always #(CLK_PERIOD / 2) sys_clk = ~sys_clk;

    task automatic check(input logic condition, input string message);
        checks++;
        if (condition !== 1'b1) begin
            errors++;
            if (errors <= 20)
                $display("FAIL @%0t [%s]: %s", $time, case_name, message);
        end
    endtask

    task automatic begin_case(input string name);
        if (case_name != "")
            $display("RESULT %s: failures=%0d", case_name, errors - case_errors);
        case_name = name;
        case_errors = errors;
        $display("%s", name);
    endtask

    // 独立使用 64 位整数运算，不读取 DUT 内部信号。
    // SV 有符号除法向零取整；负数有余数时减一，以匹配算术右移向下取整。
    function automatic longint signed reference_value(
        input samples_t samples, input logic [7:0] gain
    );
        longint signed total, product, scaled;
        total = 0;
        for (int i = 0; i < VOICE_COUNT; i++)
            total += longint'(samples[i]);
        product = total * longint'({1'b0, gain});
        scaled = product / 64'sd1024;
        if (product < 0 && product % 64'sd1024 != 0) scaled--;
        return scaled;
    endfunction

    // 下降沿驱动；上升沿后 1 ns 检查 NBA 更新后的输出。
    task automatic cycle(
        input logic reset_n, input logic valid, input logic ce,
        input logic [7:0] gain, input samples_t samples, input string label_text
    );
        longint signed expected;
        logic signed [OUTPUT_W-1:0] old_sample;
        logic old_valid;
        @(negedge sys_clk);
        old_sample = mixed_sample;
        old_valid = mixed_valid;
        rst_n = reset_n;
        sample_valid = valid;
        audio_ce = ce;
        master_gain = gain;
        voice_sample = samples;
        if (!reset_n) expected_sample = '0;
        else if (valid) begin
            expected = reference_value(samples, gain);
            if (expected > OUTPUT_MAX) begin
                expected = OUTPUT_MAX;
                positive_clips++;
            end else if (expected < OUTPUT_MIN) begin
                expected = OUTPUT_MIN;
                negative_clips++;
            end
            expected_sample = OUTPUT_W'(expected);
        end
        #1;
        check(mixed_sample === old_sample && mixed_valid === old_valid,
              {label_text, ": registered outputs changed before clock edge"});
        @(posedge sys_clk);
        #1;
        check(mixed_valid === (reset_n && valid),
              {label_text, ": mixed_valid must follow sample_valid, independent of audio_ce"});
        check(mixed_sample === expected_sample,
              $sformatf("%s: expected sample=%0d, got=%0d (gain=%0d valid=%b ce=%b)",
                        label_text, expected_sample, mixed_sample, gain, valid, ce));
    endtask

    task automatic fill_samples(input longint signed value);
        for (int i = 0; i < VOICE_COUNT; i++) stimulus[i] = sample_t'(value);
    endtask

    // 将指定总和分配到各路，避免构造边界用例时发生输入截断。
    task automatic total_sample(input longint signed total,
                                input logic [7:0] gain, input string label_text);
        longint signed remaining, part;
        remaining = total;
        for (int i = 0; i < VOICE_COUNT; i++) begin
            part = remaining;
            if (part > VOICE_MAX) part = VOICE_MAX;
            if (part < VOICE_MIN) part = VOICE_MIN;
            stimulus[i] = sample_t'(part);
            remaining -= part;
        end
        if (remaining != 0) $fatal(1, "TB stimulus exceeds input range: %s", label_text);
        cycle(1, 1, 0, gain, stimulus, label_text);
    endtask

    // 固定种子的 xorshift32，便于复现随机用例。
    function automatic logic [31:0] next_random();
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        return rng;
    endfunction

    initial begin
        if (VOICE_COUNT < 1 || VOICE_W < 2 || VOICE_W > 32 ||
            OUTPUT_W < 2 || OUTPUT_W > 32 || VOICE_W + $clog2(VOICE_COUNT) + 9 > 63)
            $fatal(1, "TB supports 2..32-bit samples and products fitting signed 64 bits");
        if ($test$plusargs("waves")) begin
            $dumpfile("/tmp/tb_mixer.vcd");
            $dumpvars(0, tb_mixer);
        end
        $display("MIXER voices=%0d input=%0d output=%0d scaling=/1024 seed=%h",
                 VOICE_COUNT, VOICE_W, OUTPUT_W, rng);

        begin_case("CASE 1: reset priority and valid zero samples");
        fill_samples(0);
        cycle(0, 0, 0, 0, stimulus, "initial reset");
        fill_samples(VOICE_MAX);
        cycle(0, 1, 1, 255, stimulus, "reset overrides valid");
        fill_samples(0);
        cycle(1, 1, 0, 255, stimulus, "silence is also a valid sample");

        begin_case("CASE 2: each voice, signed values, no accumulation across samples");
        for (int i = 0; i < VOICE_COUNT; i++) begin
            fill_samples(0);
            stimulus[i] = sample_t'(VOICE_MAX);
            cycle(1, 1, 0, 128, stimulus, $sformatf("positive voice %0d", i));
            cycle(1, 1, 1, 128, stimulus, "repeat identical sample");
            stimulus[i] = sample_t'(-VOICE_MAX);
            cycle(1, 1, 0, 128, stimulus, $sformatf("negative voice %0d", i));
            fill_samples(0);
            cycle(1, 1, 0, 255, stimulus, "zero after nonzero");
        end
        for (int i = 0; i < VOICE_COUNT; i++)
            stimulus[i] = (i % 2 == 0) ? sample_t'(VOICE_MAX) : sample_t'(-VOICE_MAX);
        cycle(1, 1, 0, 255, stimulus, "opposite signs cancel in pairs");

        begin_case("CASE 3: full-scale sum and all gain values");
        for (int gain = 0; gain < 256; gain++) begin
            fill_samples(VOICE_MAX);
            cycle(1, 1, 0, 8'(gain), stimulus, "positive full-scale sum");
            fill_samples(VOICE_MIN);
            cycle(1, 1, 1, 8'(gain), stimulus, "negative full-scale sum");
        end

        begin_case("CASE 4: negative fractional rounding");
        total_sample(-1, 1, "negative fraction rounds down to -1");
        total_sample(1, 1, "positive fraction rounds down to zero");
        if (VOICE_MAX >= 1025) begin
            total_sample(-1023, 1, "negative value before division boundary");
            total_sample(-1024, 1, "exact negative quotient");
            total_sample(-1025, 1, "negative value after division boundary");
            total_sample(1024, 1, "exact positive quotient");
        end

        begin_case("CASE 5: audio_ce independence, invalid hold, consecutive valid");
        fill_samples(VOICE_MAX);
        cycle(1, 1, 0, 128, stimulus, "valid without audio_ce");
        fill_samples(VOICE_MIN);
        cycle(1, 0, 1, 255, stimulus, "audio_ce alone must not update output");
        fill_samples(0);
        cycle(1, 0, 0, 0, stimulus, "invalid data and gain changes must be ignored");
        fill_samples(VOICE_MIN);
        cycle(1, 1, 0, 64, stimulus, "delayed valid after audio_ce");
        fill_samples(VOICE_MAX);
        cycle(1, 1, 0, 255, stimulus, "back-to-back valid");
        cycle(1, 0, 0, 0, stimulus, "valid pulse ends");

        begin_case("CASE 6: saturation boundaries when reachable");
        // gain=128 时输出为 floor(total / 8)，直接构造输出边界的相邻整数。
        if ((OUTPUT_MAX + 1) * 8 <= VOICE_MAX * VOICE_COUNT &&
            (OUTPUT_MIN - 1) * 8 >= VOICE_MIN * VOICE_COUNT) begin
            for (int offset = -1; offset <= 1; offset++) begin
                total_sample((OUTPUT_MAX + longint'(offset)) * 8, 128, "positive saturation boundary");
                total_sample((OUTPUT_MIN + longint'(offset)) * 8, 128, "negative saturation boundary");
            end
            check(positive_clips > 0 && negative_clips > 0,
                  "must exercise both saturation directions");
        end else
            $display("INFO: boundary stimulus unavailable; run -GOUTPUT_W=16 for clipping coverage");

        begin_case("CASE 7: deterministic random data, gain, valid and reset");
        for (int n = 0; n < 256; n++) begin
            for (int i = 0; i < VOICE_COUNT; i++) stimulus[i] = sample_t'(next_random());
            controls = next_random();
            cycle(n % 53 != 0, controls[8], controls[9], controls[7:0], stimulus,
                  $sformatf("random cycle %0d", n));
        end
        fill_samples(VOICE_MAX);
        cycle(0, 1, 0, 255, stimulus, "reset while valid");
        cycle(1, 0, 1, 255, stimulus, "no stale output after reset");
        fill_samples(0);
        cycle(1, 1, 0, 255, stimulus, "first valid sample after reset");

        $display("RESULT %s: failures=%0d", case_name, errors - case_errors);
        $display("MIXER checks=%0d failures=%0d positive_clips=%0d negative_clips=%0d",
                 checks, errors, positive_clips, negative_clips);
        if (errors != 0) $fatal(1, "tb_mixer failed; see FAIL messages");
        $display("PASS: tb_mixer");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "TIMEOUT: tb_mixer did not finish");
    end
endmodule
