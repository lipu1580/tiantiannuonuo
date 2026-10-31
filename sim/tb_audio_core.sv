`timescale 1ns/1ns

// 任务书阶段7：顶层接口激励 + 只读内部监测，不 force DUT。
// 加速系统时钟比例，保持合成采样率 48 kHz；ADSR 加快以缩短回归。
module tb_audio_core;
    localparam int SYS_HZ = 1_000_000, RATE = 48_000, DEPTH = 4;
    logic sys_clk = 0, rst_n = 0;
    always #5 sys_clk = ~sys_clk;
    logic audio_ce;
    logic event_valid = 0, event_ready;
    logic [1:0] event_type = 0;
    logic [6:0] event_note_id = 0;
    logic [7:0] event_velocity = 0;
    logic expr_valid = 0;
    logic [7:0] expression = 255;
    logic [11:0] pitch_bend = 2048;
    logic [1:0] waveform_sel = 0;
    logic pcm_valid, pcm_ready = 1;
    logic signed [15:0] pcm_left, pcm_right;
    logic test_mode = 0;
    logic [1:0] test_pattern = 0;
    logic [2:0] active_voice_count;
    logic [3:0] voice_active;

    sample_tick_gen #(.SYS_CLK_HZ(SYS_HZ), .SAMPLE_RATE(RATE)) tick (.*);
    audio_core #(.ATTACK_STEP(16'd16384), .DECAY_STEP(16'd8192),
        .SUSTAIN_LEVEL(16'd49152), .RELEASE_STEP(16'd8192)) dut (.*);

    int errors = 0, checks = 0, case_errors = 0;
    string case_name = "startup";
    longint cycles = 0, ticks = 0, received = 0, generated = 0, dropped = 0;
    int external_hs = 0, routed_hs = 0, auto_on = 0, auto_off = 0;
    int peak = 0, trough = 0;
    int rising_crossings = 0, previous_pcm = 0;
    bit count_frequency = 0, expected_mode = 0;
    bit measure = 0, require_silence = 0;
    bit tick_last = 0, stalled = 0;
    logic signed [15:0] held_left, held_right;
    logic [2:0] ce_pipe = 0;
    logic [7:0] expected_expr = 255;
    logic [11:0] expected_bend = 2048;
    logic [1:0] expected_wave = 0;
    typedef struct packed {
        logic [1:0] kind;
        logic [6:0] note_id;
        logic [7:0] velocity;
    } event_t;
    event_t event_queue[$];
    logic signed [15:0] pcm_queue[$];
    bit mix_pending = 0, overflow_expected = 0;
    longint signed mix_expected = 0;

    task automatic check(input logic ok, input string message);
        checks++;
        if (ok !== 1'b1) begin
            errors++;
            if (errors <= 40) $display("FAIL @%0t [%s] %s", $time, case_name, message);
        end
    endtask
    task automatic begin_case(input string name);
        $display("RESULT %s: failures=%0d", case_name, errors-case_errors);
        case_errors = errors;
        case_name = name;
        $display("CASE %s", name);
    endtask
    task automatic clocks(input int n);
        repeat (n) @(negedge sys_clk);
    endtask
    task automatic samples(input int n);
        longint target;
        target = ticks + n;
        while (ticks < target) @(negedge sys_clk);
        clocks(8); // 排空 DDS/mixer 流水线（FIFO 仍按 ready 消费）
    endtask
    task automatic reset_core;
        @(negedge sys_clk);
        rst_n = 0; event_valid = 0; expr_valid = 0; test_mode = 0;
        pcm_ready = 1; measure = 0; require_silence = 0;
        clocks(5);
        check(!pcm_valid && voice_active == 0 && active_voice_count == 0,
              "reset must clear PCM and voices");
        check(!audio_ce && !event_ready, "reset must suppress tick/event ready");
        rst_n = 1;
        clocks(5);
    endtask
    task automatic send_event(input logic [1:0] kind, input int note_id = 0,
                              input int velocity = 255);
        bit accepted;
        @(negedge sys_clk);
        event_valid = 1; event_type = kind;
        event_note_id = 7'(note_id); event_velocity = 8'(velocity);
        accepted = 0;
        for (int i = 0; i < 200; i++) begin
            @(posedge sys_clk);
            if (event_ready) begin accepted = 1; break; end
        end
        @(negedge sys_clk);
        event_valid = 0;
        check(accepted, "event handshake timeout");
    endtask
    task automatic update_expr(input int value, input int bend = 2048,
                               input int wave = 0);
        @(negedge sys_clk);
        expr_valid = 1; expression = 8'(value);
        pitch_bend = 12'(bend); waveform_sel = 2'(wave);
        clocks(1); expr_valid = 0;
    endtask
    function automatic int note_slot(input int note_id);
        for (int i = 0; i < 4; i++)
            if (voice_active[i] && dut.voice_note_id[i] == 7'(note_id)) return i;
        return -1;
    endfunction

    // 在时钟沿读取传输前的数据；#1 以后只检查 NBA 更新后的组合输出。
    always @(posedge sys_clk) begin : monitor
        event_t ev;
        logic signed [15:0] expected_pcm;
        longint signed sum, scaled;
        bit pop;
        if (!rst_n) begin
            cycles = 0; ticks = 0; received = 0; generated = 0; dropped = 0;
            external_hs = 0; routed_hs = 0; auto_on = 0; auto_off = 0;
            event_queue.delete(); pcm_queue.delete();
            ce_pipe = 0; stalled = 0; tick_last = 0;
            mix_pending = 0; overflow_expected = 0;
            expected_expr = 255; expected_bend = 2048; expected_wave = 0;
            expected_mode = 0;
        end else begin
            cycles++;
            check(!(tick_last && audio_ce), "audio_ce wider than one clock");
            tick_last = audio_ce;
            if (audio_ce) ticks++;
            // 发生器的注册输出被核心晚一拍采集，因此使用 cycles-1。
            check(ticks == ((cycles-1)*RATE)/64'(SYS_HZ), "fractional sample rate drift");
            check(dut.voice_sample_valid == {4{ce_pipe[1]}}, "voice sample alignment/count");
            check(dut.mixed_valid == ce_pipe[2], "one mixed sample per audio_ce");
            ce_pipe = {ce_pipe[1:0], audio_ce};
            check(dut.mixed_valid == mix_pending, "mixer valid pipeline");
            if (mix_pending) check(longint'($signed(dut.mixed_sample)) == mix_expected,
                                   "mixer arithmetic / saturation mismatch");
            mix_pending = dut.mixer_sample_valid;
            sum = 0;
            for (int i = 0; i < 4; i++) sum += longint'($signed(dut.voice_sample[i]));
            scaled = sum * 255 / 1024;
            if (sum < 0 && (sum*255)%1024 != 0) scaled--;
            if (scaled > 8388607) scaled = 8388607;
            if (scaled < -8388608) scaled = -8388608;
            mix_expected = scaled;

            if (test_mode != expected_mode) begin
                ev = '{2'd3, 7'd0, 8'd0};
                event_queue.push_back(ev);
                expected_mode = test_mode;
            end
            if (event_valid && event_ready) begin
                ev = '{event_type, event_note_id, event_velocity};
                event_queue.push_back(ev); external_hs++;
            end
            if (dut.test_event_valid && dut.test_event_ready) begin
                ev = '{dut.test_event_type, dut.test_event_note_id, dut.test_event_velocity};
                event_queue.push_back(ev);
                if (ev.kind == 1) begin
                    case (auto_on % 4)
                        0: check(ev.note_id == 60, "test source C4 order");
                        1: check(ev.note_id == 64, "test source E4 order");
                        2: check(ev.note_id == 67, "test source G4 order");
                        3: check(ev.note_id == 72, "test source C5 order");
                    endcase
                    auto_on++;
                end
                if (ev.kind == 2) auto_off++;
            end
            if (dut.routed_event_valid && dut.routed_event_ready) begin
                if (event_queue.size() != 0) begin
                    ev = event_queue.pop_front();
                    check(ev == {dut.routed_event_type, dut.routed_event_note_id,
                                 dut.routed_event_velocity}, "lost/reordered event fields");
                end else check(0, "unexpected/duplicated routed event");
                routed_hs++;
            end
            if (test_mode) check(!event_ready, "external ready asserted in test mode");
            if (stalled) check(pcm_valid && pcm_left == held_left && pcm_right == held_right,
                               "PCM changed while stalled");
            stalled = pcm_valid && !pcm_ready;
            held_left = pcm_left; held_right = pcm_right;
            pop = pcm_valid && pcm_ready;
            check(pcm_valid == (pcm_queue.size() != 0), "FIFO valid/occupancy mismatch");
            if (pcm_valid) check(pcm_left == pcm_right, "left/right mismatch");
            if (pop) begin
                received++;
                if (pcm_queue.size() != 0) begin
                    expected_pcm = pcm_queue.pop_front();
                    check(pcm_left == expected_pcm, "PCM dropped/duplicated/reordered/corrupted");
                end
                if (require_silence) check(pcm_left == 0, "expected silence");
                if (count_frequency) begin
                    if (previous_pcm <= 0 && $signed(pcm_left) > 0) rising_crossings++;
                    previous_pcm = int'($signed(pcm_left));
                end
                if (measure) begin
                    if (int'($signed(pcm_left)) > peak) peak = int'($signed(pcm_left));
                    if (int'($signed(pcm_left)) < trough) trough = int'($signed(pcm_left));
                end
            end
            if (dut.mixed_valid) begin
                generated++;
                if (pcm_queue.size() < DEPTH)
                    pcm_queue.push_back(16'($signed(dut.mixed_sample) >>> 8));
                else begin dropped++; overflow_expected = 1; end
            end
            if (expr_valid) begin
                expected_expr = expression; expected_bend = pitch_bend;
                expected_wave = waveform_sel;
            end
        end
        #1;
        check(active_voice_count == $countones(voice_active), "active voice count mismatch");
        check(dut.expression_reg == expected_expr && dut.pitch_bend_reg == expected_bend &&
              dut.waveform_sel_reg == expected_wave, "expression latch/reset/hold mismatch");
        check(dut.pcm_stream_adapter.overflow == overflow_expected, "FIFO sticky overflow mismatch");
    end

    initial begin : tests
        int slot, oldest, before_hs;
        longint before_drop;
        int full_peak, half_peak;
        reset_core();
        begin_case("reset / silence / fractional 48kHz sampling");
        require_silence = 1; samples(4800); require_silence = 0;
        check(received >= 4800, "continuous silent PCM missing");

        begin_case("single note / NOP / unmatched NOTE_OFF");
        send_event(1, 69); samples(32);
        check(active_voice_count == 1 && note_slot(69) >= 0, "A4 did not start");
        slot = note_slot(69);
        peak = 0; trough = 0; measure = 1; samples(480); measure = 0;
        check(peak > 0 && trough < 0, "single note must produce bipolar PCM");
        $display("MEASURE single A4 PCM peak=%0d trough=%0d", peak, trough);
        rising_crossings = 0; previous_pcm = 0; count_frequency = 1;
        samples(4800); count_frequency = 0;
        check(rising_crossings >= 43 && rising_crossings <= 45, "A4 frequency outside 430..450 Hz");
        $display("MEASURE A4 positive crossings in 100ms=%0d", rising_crossings);
        send_event(0); send_event(2, 12); samples(20);
        check(active_voice_count == 1 && note_slot(69) == slot, "NOP/unmatched OFF changed voice");
        send_event(1, 69, 200); samples(20);
        check(active_voice_count == 1 && note_slot(69) == slot, "duplicate ON allocated extra voice");

        begin_case("four voices / oldest stealing / selective OFF / ALL_OFF");
        send_event(1, 60); send_event(1, 64); send_event(1, 67); samples(32);
        check(active_voice_count == 4, "four notes not simultaneously active");
        check(note_slot(60)>=0 && note_slot(64)>=0 && note_slot(67)>=0, "missing chord note");
        peak = 0; trough = 0; measure = 1; samples(480); measure = 0;
        check(peak > 0 && trough < 0, "four voices must produce bipolar PCM");
        $display("MEASURE four-voice PCM peak=%0d trough=%0d", peak, trough);
        oldest = slot;
        send_event(1, 72); samples(24);
        check(active_voice_count == 4 && note_slot(69)<0 && note_slot(72)==oldest,
              "fifth note must steal oldest voice");
        send_event(2, 64); samples(24);
        check(active_voice_count == 3 && note_slot(64)<0 && note_slot(60)>=0 &&
              note_slot(67)>=0 && note_slot(72)>=0, "NOTE_OFF must release only matching voice");
        send_event(3); samples(32);
        check(active_voice_count == 0, "ALL_OFF failed to finish release");
        require_silence = 1; samples(50); require_silence = 0;
        check(event_queue.size() == 0, "event queue not drained");

        begin_case("expression update / hold / mute / amplitude");
        send_event(1, 69); samples(32);
        peak = 0; trough = 0; measure = 1; samples(480); measure = 0; full_peak = peak;
        update_expr(128); samples(10);
        peak = 0; trough = 0; measure = 1; samples(480); measure = 0; half_peak = peak;
        check(half_peak > 0 && half_peak < full_peak &&
              half_peak*100 >= full_peak*40 && half_peak*100 <= full_peak*60,
              "expression half-scale amplitude ratio");
        // 无 valid 时端口变化不能影响已锁存值。
        expression = 0; pitch_bend = 3000; waveform_sel = 2;
        samples(32);
        update_expr(0); samples(16);
        require_silence = 1; samples(50); require_silence = 0;
        check(active_voice_count == 1, "expression mute must not release voice");
        update_expr(255); samples(32);
        $display("MEASURE expression full=%0d half=%0d", full_peak, half_peak);
        // 16-bit DDS -> Q16 envelope -> /4 mix 应仍是16位幅值。
        // 当前 core 又以24位满幅格式转16位，额外损失8位；作为诊断而非未约定增益的硬断言。
        if (full_peak < 100) $display("DIAGNOSTIC low PCM gain: inspect voice/adapter binary-point agreement");

        begin_case("short / random / overflowing PCM backpressure");
        before_drop = dropped;
        @(negedge sys_clk); pcm_ready = 0; samples(2); pcm_ready = 1; samples(8);
        check(dropped == before_drop, "short stall lost samples");
        for (int i = 0; i < 2000; i++) begin
            @(negedge sys_clk); pcm_ready = ((i*17+3)%11 < 6);
        end
        pcm_ready = 1; samples(10);
        check(dropped == before_drop, "bounded random stall lost samples");
        pcm_ready = 0; samples(20);
        check(dropped > before_drop, "long stall did not exercise FIFO overflow");
        pcm_ready = 1; samples(20);
        check(generated == received+dropped+64'(pcm_queue.size()), "PCM sample conservation");
        $display("MEASURE generated=%0d received=%0d dropped=%0d queued=%0d",
                 generated, received, dropped, pcm_queue.size());

        begin_case("reset during active/stalled output");
        pcm_ready = 0; samples(5); reset_core();
        require_silence = 1; samples(32); require_silence = 0;

        begin_case("fast ON/OFF between sample ticks");
        // 对齐到刚消费过一次 audio_ce，后续命令在下一个采样点前完成。
        samples(1);
        send_event(1, 60); send_event(2, 60); samples(32);
        check(active_voice_count == 0, "quick ON/OFF left a stuck voice");
        send_event(1, 60); send_event(1, 64); send_event(1, 67); send_event(1, 72);
        samples(32);
        check(active_voice_count == 4, "rapid events lost/allocated same voice");
        send_event(3); samples(32);

        begin_case("autonomous source / source selection / switch back");
        reset_core();
        test_mode = 1;
        // 内部源固定 C4/E4/G4/C5；阶段6要求自主产生四音。
        // 当前实现每秒一步；0.1秒建议节奏的差异另记，不将建议当硬性验收条件。
        samples(4800);
        $display("MEASURE auto NOTE_ON after 100ms=%0d", auto_on);
        if (auto_on == 0) $display("DIAGNOSTIC test source has no NOTE_ON at recommended 100ms");
        samples(4*RATE);
        check(auto_on == 4 && active_voice_count == 4, "autonomous C4/E4/G4/C5 chord missing");
        samples(9*RATE);
        check(auto_off == 4 && active_voice_count == 0, "autonomous NOTE_OFF sequence missing");
        before_hs = external_hs;
        // 外部源在未选中期间持续保持字段，切回后必须恰好接收一次。
        @(negedge sys_clk);
        event_valid = 1; event_type = 1; event_note_id = 81; event_velocity = 220;
        clocks(50);
        check(external_hs == before_hs, "unselected external event accepted");
        test_mode = 0;
        for (int i = 0; i < 100; i++) begin
            @(posedge sys_clk);
            if (event_ready) break;
        end
        @(negedge sys_clk); event_valid = 0;
        samples(32);
        check(external_hs == before_hs+1 && active_voice_count == 1 && note_slot(81)>=0,
              "held event not accepted exactly once after mode switch");
        send_event(3); samples(32);
        check(event_queue.size() == 0, "final pending event");
        check(active_voice_count == 0, "final voices not silent");
        $display("RESULT %s: failures=%0d", case_name, errors-case_errors);
        $display("SUMMARY checks=%0d errors=%0d", checks, errors);
        if (errors != 0) $fatal(1, "audio_core regression FAILED");
        $display("PASS tb_audio_core");
        $finish;
    end

    // +trace 只记录前200000拍，避免自主源长序列生成巨量VCD。
    initial begin
        if ($test$plusargs("trace")) begin
            $dumpfile("build/tb_audio_core.vcd");
            $dumpvars(0, tb_audio_core);
            repeat (200000) @(negedge sys_clk);
            $display("TRACE capture complete; run without +trace for full regression");
            $finish;
        end
    end
    initial begin
        #200000000;
        $fatal(1, "global timeout");
    end
endmodule
