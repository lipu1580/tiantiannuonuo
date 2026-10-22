`timescale 1ns/1ns

module tb_adsr;
    // 放大步长，几次采样即可走完一个阶段；步长不能整除边界，便于检查饱和。
    localparam integer CLK_PERIOD = 10;
    localparam integer ATTACK_STEP = 20000;
    localparam integer DECAY_STEP = 12000;
    localparam integer SUSTAIN_LEVEL = 30000;
    localparam integer RELEASE_STEP = 17000;
    localparam integer MAX_VALUE = 65535;
    localparam logic [2:0] IDLE = 0, ATTACK = 1, DECAY = 2,
                           SUSTAIN = 3, RELEASE = 4;

    logic sys_clk = 0;
    logic rst_n = 0;
    logic audio_ce = 0;
    logic note_on = 0;
    logic note_off = 0;
    logic [7:0] velocity = 0;
    logic [7:0] expression = 255;
    logic [15:0] envelope_value;
    logic active;
    integer errors = 0;
    integer checks = 0;
    logic [7:0] expected_velocity = 0;

    adsr #(
        .ATTACK_STEP(16'(ATTACK_STEP)),
        .DECAY_STEP(16'(DECAY_STEP)),
        .SUSTAIN_LEVEL(16'(SUSTAIN_LEVEL)),
        .RELEASE_STEP(16'(RELEASE_STEP)),
        .MAX_VALUE(16'(MAX_VALUE))
    ) DUT (.*);

    always #(CLK_PERIOD / 2) sys_clk = ~sys_clk;

    task automatic check(input logic condition, input string message);
        checks++;
        if (condition !== 1'b1) begin
            errors++;
            $display("FAIL @%0t: %s (state=%0d level=%0d env=%0d active=%b)",
                     $time, message, DUT.state, DUT.level, envelope_value, active);
        end
    endtask

    // 本 TB 有意观察内部 state/level，将包络运算和音量缩放分别检查。
    // 缩放暂按当前 RTL 的 >>16 约定，即除以65536；255并非严格满量程。
    // 若之后改为 /255/255，需要同步修改这里的参考公式。
    task automatic check_output;
        logic [63:0] product;
        logic [15:0] expected_envelope;
        product = 64'(DUT.level) * 64'(expected_velocity) * 64'(expression);
        expected_envelope = 16'(product >> 16);
        check(envelope_value === expected_envelope,
              $sformatf("volume scaling / velocity latch: expected %0d", expected_envelope));
        check(active === (DUT.state != IDLE),
              "active must stay high throughout ATTACK/DECAY/SUSTAIN/RELEASE");
    endtask

    // 下降沿驱动，上升沿后延迟1ns检查，避开非阻塞赋值的更新时间。
    // ce=0时仍可发出单周期命令，验证命令不会因等待采样而丢失。
    task automatic cycle(input logic ce, input logic on_cmd,
                         input logic off_cmd, input logic [7:0] vel);
        logic [2:0] old_state;
        logic [15:0] old_level;
        @(negedge sys_clk);
        old_state = DUT.state;
        old_level = DUT.level;
        audio_ce = ce;
        note_on = on_cmd;
        note_off = off_cmd;
        velocity = vel;
        if (on_cmd) expected_velocity = vel;
        @(posedge sys_clk);
        #1;
        if (!ce) begin
            check(DUT.state === old_state, "state changed without audio_ce");
            check(DUT.level === old_level, "level changed without audio_ce");
        end else begin
            check(DUT.pending_cmd === 2'd0,
                  "sampling must consume and clear the pending command");
        end
        check_output();
    endtask

    task automatic reset_dut;
        @(negedge sys_clk);
        rst_n = 0;
        audio_ce = 0;
        note_on = 0;
        note_off = 0;
        velocity = 0;
        expression = 255;
        expected_velocity = 0;
        repeat (2) @(posedge sys_clk);
        #1;
        check(DUT.state === IDLE && DUT.level === 16'd0,
              "reset must clear state and level without audio_ce");
        check(envelope_value === 16'd0 && active === 1'b0,
              "reset must silence output");
        @(negedge sys_clk);
        rst_n = 1;
    endtask

    // 检查无新命令时，每次采样的加减法及边界处理。
    // 使用integer参考运算，避免参考模型自身发生16位回绕。
    task automatic sample_step;
        integer expected_level;
        case (DUT.state)
            IDLE: expected_level = 0;
            ATTACK: begin
                expected_level = int'(DUT.level) + ATTACK_STEP;
                if (expected_level > MAX_VALUE) expected_level = MAX_VALUE;
            end
            DECAY: begin
                expected_level = int'(DUT.level) - DECAY_STEP;
                if (expected_level < SUSTAIN_LEVEL) expected_level = SUSTAIN_LEVEL;
            end
            SUSTAIN: expected_level = SUSTAIN_LEVEL;
            RELEASE: begin
                expected_level = int'(DUT.level) - RELEASE_STEP;
                if (expected_level < 0) expected_level = 0;
            end
            default: expected_level = 0;
        endcase
        cycle(1, 0, 0, 8'd17); // 改变输入velocity，已锁存的力度应保持不变
        check(DUT.level === 16'(expected_level),
              $sformatf("sample arithmetic: expected level %0d", expected_level));
        cycle(0, 0, 0, 8'd17);
    endtask

    // 允许到达边界与切换状态相差一拍，但必须在有限采样次数内完成。
    task automatic reach_state(input logic [2:0] target, input integer limit);
        integer count;
        count = 0;
        while (DUT.state !== target && count < limit) begin
            sample_step();
            count++;
        end
        check(DUT.state === target,
              $sformatf("expected state %0d within %0d samples", target, limit));
    endtask

    task automatic start_note(input logic [7:0] vel);
        cycle(0, 1, 0, vel);
        repeat (3) cycle(0, 0, 0, 8'd17);
        cycle(1, 0, 0, 8'd17);
        check(DUT.state === ATTACK, "pending NOTE_ON must start ATTACK");
        cycle(0, 0, 0, 8'd17);
    endtask

    task automatic release_note;
        cycle(0, 0, 1, 8'd17);
        repeat (2) cycle(0, 0, 0, 8'd17);
        cycle(1, 0, 0, 8'd17);
        check(DUT.state === RELEASE, "pending NOTE_OFF must enter RELEASE");
        cycle(0, 0, 0, 8'd17);
        reach_state(IDLE, 10);
        check(DUT.level === 16'd0 && envelope_value === 16'd0 && active === 1'b0,
              "release must finish at zero and clear active");
    endtask

    initial begin
        if ($test$plusargs("waves")) begin
            $dumpfile("build/tb_adsr.vcd");
            $dumpvars(0, tb_adsr);
        end

        $display("CASE 1: full ADSR, velocity latch, expression, command consumption");
        reset_dut();
        start_note(255);
        reach_state(DECAY, 6);
        reach_state(SUSTAIN, 6);
        repeat (3) sample_step();
        expression = 128;
        cycle(0, 0, 0, 17);
        sample_step();
        expression = 0;
        sample_step();
        check(envelope_value === 16'd0 && active === 1'b1,
              "expression=0 must mute without deactivating the voice");
        expression = 255;
        sample_step();
        release_note();
        repeat (3) sample_step(); // 已消费的NOTE_ON/OFF不能导致再次启动

        $display("CASE 2: NOTE_OFF during ATTACK");
        reset_dut();
        start_note(200);
        sample_step();
        release_note();

        $display("CASE 3: NOTE_OFF during DECAY");
        reset_dut();
        start_note(200);
        reach_state(DECAY, 6);
        release_note();

        $display("CASE 4: simultaneous ON/OFF, ON wins");
        reset_dut();
        cycle(0, 1, 1, 180);
        cycle(0, 0, 0, 17);
        cycle(1, 0, 0, 17);
        check(DUT.state === ATTACK, "simultaneous ON/OFF must prefer ON");

        $display("CASE 5: pending command overwrite, ON then OFF");
        reset_dut();
        cycle(0, 1, 0, 180);
        cycle(0, 0, 1, 17);
        cycle(0, 0, 0, 17);
        cycle(1, 0, 0, 17);
        check(DUT.state === IDLE && active === 1'b0,
              "ON overwritten by OFF while idle must not start a note");

        $display("CASE 6: pending command overwrite, OFF then ON");
        reset_dut();
        cycle(0, 0, 1, 17);
        cycle(0, 1, 0, 100);
        cycle(0, 0, 0, 17);
        cycle(1, 0, 0, 17);
        check(DUT.state === ATTACK, "later ON must overwrite pending OFF");
        cycle(0, 0, 0, 17);
        sample_step();

        $display("CASE 7: command arrives on audio_ce itself");
        reset_dut();
        cycle(1, 1, 0, 220);
        check(DUT.state === ATTACK, "new ON must be handled on the same sampling edge");
        cycle(0, 0, 0, 17);
        sample_step();
        cycle(1, 0, 1, 17);
        check(DUT.state === RELEASE, "new OFF must be handled on the same sampling edge");

        $display("CASE 8: retrigger while releasing");
        reset_dut();
        start_note(200);
        repeat (2) sample_step();
        cycle(0, 0, 1, 17);
        cycle(1, 0, 0, 17);
        check(DUT.state === RELEASE, "setup must enter RELEASE");
        cycle(0, 1, 0, 90);
        cycle(0, 0, 0, 17);
        cycle(1, 0, 0, 17);
        check(DUT.state === ATTACK && active === 1'b1,
              "NOTE_ON during RELEASE must retrigger ATTACK");

        $display("CASE 9: reset while active clears pending commands too");
        cycle(0, 1, 0, 100);
        reset_dut();
        repeat (3) sample_step();
        check(DUT.state === IDLE, "reset must discard pending commands");

        $display("ADSR checks=%0d failures=%0d", checks, errors);
        if (errors != 0) $fatal(1, "ADSR test failed; inspect FAIL messages and waveform");
        $display("PASS: tb_adsr");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "TIMEOUT: tb_adsr did not finish");
    end
endmodule
