`timescale 1ns/1ns

// 运行：make sim WAIT_TB_NAME=voice_manager RTL_NAME=voice_manager
// 波形：make sim WAIT_TB_NAME=voice_manager RTL_NAME=voice_manager \
//           VFLAGS='--binary --timing --trace -Wno-fatal'
//       build/verilator/voice_manager/Vtb_voice_manager +waves
// 本 TB 只通过端口检查四路管理器，不访问 DUT 内部状态。
// voice_active/envelope 由测试端驱动，模拟尚未启动、持续发声和释放尾音。
// 空闲声部的选择不限定编号；全满时按“最早启动者”抢占，重触发刷新顺序。
module tb_voice_manager;
    localparam integer VOICE_COUNT = 4;
    localparam integer NOTE_W = 7;
    localparam logic [1:0] NOP = 2'd0;
    localparam logic [1:0] NOTE_ON = 2'd1;
    localparam logic [1:0] NOTE_OFF = 2'd2;
    localparam logic [1:0] ALL_NOTES_OFF = 2'd3;

    logic sys_clk = 0;
    logic rst_n = 0;
    logic event_valid = 0;
    logic event_ready;
    logic [1:0] event_type = NOP;
    logic [NOTE_W-1:0] event_note_id = 0;
    logic [7:0] event_velocity = 0;
    logic [VOICE_COUNT-1:0] voice_active = '0;
    logic [15:0] voice_envelope [0:VOICE_COUNT-1];
    logic [VOICE_COUNT-1:0] voice_start;
    logic [VOICE_COUNT-1:0] voice_release;
    logic [NOTE_W-1:0] voice_note_id [0:VOICE_COUNT-1];
    logic [7:0] voice_velocity [0:VOICE_COUNT-1];
    logic [$clog2(VOICE_COUNT+1)-1:0] active_voice_count;

    integer checks = 0;
    integer errors = 0;
    integer case_errors = 0;
    integer cases = 0;
    integer failed_cases = 0;
    string case_name = "";
    integer slots [0:VOICE_COUNT-1];
    integer selected;

    voice_manager #(.VOICE_COUNT(VOICE_COUNT), .NOTE_W(NOTE_W)) DUT (.*);
    always #5 sys_clk = ~sys_clk;

    task automatic check(input logic condition, input string message);
        checks++;
        if (condition !== 1'b1) begin
            errors++;
            // 每个用例最多打印六条，所有失败仍计入统计。
            if (errors - case_errors <= 6)
                $display("FAIL @%0t: %s (start=%b release=%b active=%b count=%0d)",
                         $time, message, voice_start, voice_release,
                         voice_active, active_voice_count);
        end
    endtask

    task automatic finish_case;
        if (case_name != "") begin
            $display("RESULT %s: failures=%0d", case_name, errors - case_errors);
            if (errors != case_errors) failed_cases++;
        end
    endtask

    task automatic begin_case(input string name);
        finish_case();
        cases++;
        case_name = name;
        case_errors = errors;
        $display("%s", name);
    endtask

    function automatic logic [VOICE_COUNT-1:0] bit_for(input integer index);
        return VOICE_COUNT'(1) << index;
    endfunction

    // 在下降沿驱动，在上升沿 NBA 更新完成后检查，避免与 DUT 竞争。
    // 相邻两次 step 之间恰好一个时钟周期，可发送连续 valid 事件。
    task automatic step(input logic valid, input logic [1:0] kind,
                        input logic [NOTE_W-1:0] note,
                        input logic [7:0] velocity);
        logic [NOTE_W-1:0] old_note [0:VOICE_COUNT-1];
        logic [7:0] old_velocity [0:VOICE_COUNT-1];
        @(negedge sys_clk);
        event_valid = valid;
        event_type = kind;
        event_note_id = note;
        event_velocity = velocity;
        for (integer i = 0; i < VOICE_COUNT; i++) begin
            old_note[i] = voice_note_id[i];
            old_velocity[i] = voice_velocity[i];
        end
        #1;
        // 当前设计的约定：复位后每拍都能接收，ready 不施加背压。
        check(event_ready === 1'b1, "event_ready must be high outside reset");
        @(posedge sys_clk);
        #1;
        check(int'(active_voice_count) === $countones(voice_active),
              "active_voice_count must count active feedback, including release tails");
        if (!(valid && kind == NOTE_ON))
            check(voice_start === '0, "only an accepted NOTE_ON may issue start");
        else
            check($onehot(voice_start), "one NOTE_ON must start exactly one voice");
        if (!(valid && (kind == NOTE_OFF || kind == ALL_NOTES_OFF)))
            check(voice_release === '0, "release must clear without an accepted OFF event");
        // 只有本拍启动的声部才允许改变其音符和力度。
        for (integer i = 0; i < VOICE_COUNT; i++) begin
            if (!(valid && kind == NOTE_ON && voice_start[i] === 1'b1)) begin
                check(voice_note_id[i] === old_note[i],
                      $sformatf("voice%0d note must hold without start", i));
                check(voice_velocity[i] === old_velocity[i],
                      $sformatf("voice%0d velocity must hold without start", i));
            end
        end
    endtask

    task automatic idle;
        step(0, NOP, 0, 0);
    endtask

    task automatic reset_dut;
        @(negedge sys_clk);
        rst_n = 0;
        event_valid = 0;
        event_type = NOP;
        event_note_id = 0;
        event_velocity = 0;
        voice_active = '0;
        for (integer i = 0; i < VOICE_COUNT; i++)
            voice_envelope[i] = 0;
        repeat (2) begin
            @(posedge sys_clk);
            #1;
            check(event_ready === 1'b0, "reset must block event acceptance");
            check(voice_start === '0 && voice_release === '0,
                  "reset must clear command outputs");
            check(active_voice_count === '0, "reset must clear active count");
        end
        @(negedge sys_clk);
        rst_n = 1;
        idle();
    endtask

    task automatic send_on(input logic [NOTE_W-1:0] note,
                           input logic [7:0] velocity, output integer index);
        step(1, NOTE_ON, note, velocity);
        index = -1;
        for (integer i = 0; i < VOICE_COUNT; i++) begin
            if (voice_start[i] === 1'b1) begin
                if (index == -1) index = i;
                check(voice_note_id[i] === note,
                      $sformatf("started voice%0d must latch note %0d", i, note));
                check(voice_velocity[i] === velocity,
                      $sformatf("started voice%0d must latch velocity %0d", i, velocity));
            end
        end
        // step 已检查 onehot；失败后仍运行其他用例，避免非法数组下标。
        if (index == -1) index = 0;
    endtask

    task automatic send_off(input logic [NOTE_W-1:0] note,
                            input logic [VOICE_COUNT-1:0] expected);
        step(1, NOTE_OFF, note, 0);
        check(voice_release === expected,
              $sformatf("NOTE_OFF %0d must release mask %b", note, expected));
    endtask

    // 连续发送 60/61/62/63，记下 DUT 自己选择的声部编号。
    // delayed=1 时故意不更新 active，测试“分配后立即预占”。
    task automatic fill_voices(input bit delayed);
        logic [VOICE_COUNT-1:0] used;
        used = '0;
        for (integer j = 0; j < VOICE_COUNT; j++) begin
            send_on(NOTE_W'(60 + j), 8'(100 + j), slots[j]);
            check((voice_start & used) === '0,
                  "different pending notes must use different free voices");
            used |= bit_for(slots[j]);
            if (!delayed) voice_active = used;
        end
        check(used === '1, "four different notes must occupy four voices");
    endtask

    initial begin
        if ($test$plusargs("waves")) begin
            $dumpfile("/tmp/tb_voice_manager.vcd");
            $dumpvars(0, tb_voice_manager);
        end

        begin_case("CASE 1: reset and invalid events");
        reset_dut();
        step(0, NOTE_ON, 60, 200);
        step(0, NOTE_OFF, 60, 0);
        step(0, ALL_NOTES_OFF, 0, 0);
        send_off(0, '0); // 复位后的旧 note_id=0 不代表存在 MIDI 0 音符。

        begin_case("CASE 2: single note, pulse width, NOP and metadata hold");
        reset_dut();
        send_on(69, 8'd203, selected);
        voice_active = bit_for(selected);
        voice_envelope[selected] = 16'd30000;
        repeat (3) idle();
        step(1, NOP, 81, 17);
        step(0, NOTE_ON, 81, 17);
        step(0, NOTE_OFF, 69, 0);
        step(0, ALL_NOTES_OFF, 0, 0);
        send_off(81, '0);

        begin_case("CASE 3: consecutive NOTE_ON before active feedback");
        reset_dut();
        fill_voices(1);
        idle();
        voice_active = '1;
        idle();

        begin_case("CASE 4: same pending note must retrigger its original voice");
        reset_dut();
        send_on(60, 90, slots[0]);
        send_on(60, 220, selected);
        check(selected == slots[0], "pending same-note ON must reuse its original voice");
        idle();

        begin_case("CASE 5: same active note updates velocity without allocating again");
        reset_dut();
        fill_voices(0);
        send_on(62, 7, selected);
        check(selected == slots[2], "active same-note ON must reuse its original voice");
        idle();

        begin_case("CASE 6: unmatched OFF, matching OFF and release tail occupancy");
        reset_dut();
        fill_voices(0);
        send_off(100, '0);
        send_off(61, bit_for(slots[1]));
        // 声部处于 RELEASE：active 保持 1，计数仍为 4。
        voice_envelope[slots[1]] = 16'd100;
        repeat (3) idle();
        send_on(70, 150, selected);
        check(selected == slots[0],
              "a release tail is occupied; full allocation must steal the oldest voice");
        // 模拟尾音结束；这时 slots[1] 才成为唯一空闲声部。
        voice_active[slots[1]] = 0;
        voice_envelope[slots[1]] = 0;
        idle();
        send_on(71, 151, selected);
        check(selected == slots[1], "a finished release tail must become reusable");

        begin_case("CASE 7: full allocation steals oldest, not quietest; stale OFF ignored");
        reset_dut();
        fill_voices(0);
        for (integer j = 0; j < VOICE_COUNT; j++)
            voice_envelope[slots[j]] = 16'(40000 - j * 10000);
        send_on(72, 180, selected);
        check(selected == slots[0], "first overflow must steal the oldest note (60)");
        send_off(60, '0);
        send_on(73, 181, selected);
        check(selected == slots[1], "second overflow must steal the next oldest note (61)");
        send_off(61, '0);

        begin_case("CASE 8: retrigger refreshes start order before stealing");
        reset_dut();
        fill_voices(0);
        send_on(60, 250, selected);
        check(selected == slots[0], "retrigger must keep the note on its original voice");
        send_on(74, 182, selected);
        check(selected == slots[1], "retriggered note is newest; steal note 61 instead");
        send_on(75, 183, selected);
        check(selected == slots[2], "start order must remain correct after stealing");

        begin_case("CASE 9: ALL_NOTES_OFF preserves tails until feedback clears");
        reset_dut();
        fill_voices(0);
        step(1, ALL_NOTES_OFF, 0, 0);
        check(voice_release === '1, "ALL_NOTES_OFF must release all four active voices");
        repeat (3) idle();
        for (integer j = 0; j < VOICE_COUNT; j++) begin
            voice_active[slots[j]] = 0;
            idle();
        end
        send_on(76, 184, selected);
        voice_active = bit_for(selected);
        idle();

        begin_case("CASE 10: OFF and ALL_OFF also release notes awaiting activation");
        reset_dut();
        send_on(60, 100, selected);
        send_off(60, bit_for(selected));
        idle();
        reset_dut();
        fill_voices(1);
        step(1, ALL_NOTES_OFF, 0, 0);
        check(voice_release === '1, "ALL_NOTES_OFF must release pending starts too");
        idle();

        begin_case("CASE 11: every active feedback mask is counted correctly");
        reset_dut();
        for (integer mask = 0; mask < (1 << VOICE_COUNT); mask++) begin
            voice_active = VOICE_COUNT'(mask);
            idle();
        end

        begin_case("CASE 12: MIDI note boundaries and full 8-bit velocity");
        reset_dut();
        // 本项目 velocity=0 是合法力度，不在管理器中隐式转换为 NOTE_OFF。
        send_on(0, 0, slots[0]);
        voice_active = bit_for(slots[0]);
        send_on(127, 255, slots[1]);
        check(slots[0] != slots[1], "MIDI notes 0 and 127 must use different voices");
        voice_active |= bit_for(slots[1]);
        send_off(0, bit_for(slots[0]));
        send_off(127, bit_for(slots[1]));
        idle();

        begin_case("CASE 13: reset cancels commands and allocation history");
        reset_dut();
        fill_voices(1);
        // reset_dut 紧接上一拍 start 复位，检查启动脉冲不会遗留。
        reset_dut();
        send_off(60, '0);
        fill_voices(1);
        send_on(77, 190, selected);
        check(selected == slots[0], "reset must discard old allocation/start history");
        step(1, ALL_NOTES_OFF, 0, 0);
        reset_dut(); // 检查释放脉冲同样被复位清除。

        finish_case();
        $display("VOICE_MANAGER cases=%0d failed_cases=%0d checks=%0d failures=%0d",
                 cases, failed_cases, checks, errors);
        if (errors != 0) $fatal(1, "tb_voice_manager failed; see FAIL/RESULT messages");
        $display("PASS: tb_voice_manager");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "TIMEOUT: tb_voice_manager did not finish");
    end
endmodule
