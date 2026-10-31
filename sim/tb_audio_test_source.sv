`timescale 1ns/1ns

// 运行：make sim WAIT_TB_NAME=audio_test_source RTL_NAME=audio_test_source
// 波形：make sim WAIT_TB_NAME=audio_test_source RTL_NAME=audio_test_source \
//           VFLAGS='--binary --timing --trace -Wno-fatal'
//       build/verilator/audio_test_source/Vtb_audio_test_source +waves
//
// 本 TB 只检查模块接口，不读取 DUT 内部状态。
// 约定的测试序列为 C4、E4、G4、C5 的 NOTE_ON，随后是相同顺序的 NOTE_OFF。
// enable=0 时冻结计时和序列；已有事件仍可完成握手，但不会生成下一事件。
// enable 上升沿从序列开头重新启动。
module tb_audio_test_source;
    localparam integer NOTE_W = 7;
    localparam integer SAMPLE_RATE = 4; // 缩短每个“100 ms”窗口，便于快速仿真
    localparam integer ARR_DEPTH = 4;
    localparam integer WINDOW_CLOCKS = SAMPLE_RATE * SAMPLE_RATE;
    localparam integer EVENT_WAIT_CLOCKS = 8 * WINDOW_CLOCKS;
    localparam integer CASES = 5;
    localparam integer GROUPS = 7;
    localparam logic [7:0] EXPECTED_VELOCITY = 8'd100;

    localparam logic [1:0] NOTE_ON = 2'd1;
    localparam logic [1:0] NOTE_OFF = 2'd2;

    localparam integer RESET_ERR = 0, VALID_ERR = 1, DATA_ERR = 2,
                       HOLD_ERR = 3, ENABLE_ERR = 4, COUNT_ERR = 5,
                       TIMEOUT_ERR = 6;

    logic sys_clk = 1'b0;
    logic rst_n = 1'b0;
    logic audio_ce = 1'b0;
    logic enable = 1'b0;
    logic [1:0] test_pattern = 2'b0;
    logic event_valid;
    logic event_ready = 1'b0;
    logic [1:0] event_type;
    logic [NOTE_W-1:0] event_note_id;
    logic [7:0] event_velocity;

    logic [1:0] expected_type [0:2*ARR_DEPTH-1];
    logic [NOTE_W-1:0] expected_note [0:2*ARR_DEPTH-1];

    integer checks = 0, errors = 0, cycles = 0;
    integer group_errors [0:GROUPS-1];
    string first_error [0:GROUPS-1];
    integer case_errors [0:CASES-1];
    integer case_cycles [0:CASES-1];
    string case_names [0:CASES-1];
    integer current_case = 0;

    integer accepted_events = 0;
    integer stalled_cycles = 0;
    integer disabled_cycles = 0;
    logic last_fire;
    logic [1:0] last_type;
    logic [NOTE_W-1:0] last_note;
    logic [7:0] last_velocity;

    integer report_fd;
    string summary_path = "/tmp/tb_audio_test_source_summary.txt";

    audio_test_source #(
        .NOTE_W(NOTE_W),
        .SAMPLE_RATE(SAMPLE_RATE)
    ) DUT (
        .sys_clk(sys_clk),
        .rst_n(rst_n),
        .audio_ce(audio_ce),
        .enable(enable),
        .test_pattern(test_pattern),
        .event_valid(event_valid),
        .event_ready(event_ready),
        .event_type(event_type),
        .event_note_id(event_note_id),
        .event_velocity(event_velocity)
    );

    always #5 sys_clk = ~sys_clk;

    function automatic string group_name(input integer id);
        case (id)
            RESET_ERR:   return "RESET / 复位";
            VALID_ERR:   return "VALID / 握手后撤销 valid";
            DATA_ERR:    return "DATA / 事件类型、音符和力度";
            HOLD_ERR:    return "HOLD / 背压期间事件保持";
            ENABLE_ERR:  return "ENABLE / 暂停、重启与关闭期间握手";
            COUNT_ERR:   return "COUNT / 事件数量与重复发送";
            TIMEOUT_ERR: return "TIMEOUT / 事件未出现或未撤销";
            default:     return "UNKNOWN";
        endcase
    endfunction

    function automatic string hint(input integer id);
        case (id)
            RESET_ERR:
                return "复位必须清 event_valid；enable=0 时不应开始产生事件。";
            VALID_ERR:
                return "valid 与 ready 在上升沿同时为 1 后就应立即撤销 valid，不能等下一个 100 ms 窗口。";
            DATA_ERR:
                return "NOTE_ON/OFF 顺序应为 C4,E4,G4,C5；event_velocity 输出固定为 EXPECTED_VELOCITY，不能为 X。";
            HOLD_ERR:
                return "ready=0 后 valid 和所有字段必须保持；期间不能用下一事件覆盖当前事件。";
            ENABLE_ERR:
                return "enable=0 应冻结序列但仍允许已有事件握手；enable 上升沿应从 C4 重新开始。";
            COUNT_ERR:
                return "每次握手只允许推进一个事件；ready 连续为 1 时不能重复发送同一个事件。";
            TIMEOUT_ERR:
                return "先用 SAMPLE_RATE=4 检查 100 ms 窗口，再检查 enable 与 ready 是否错误阻塞了内部计数。";
            default:
                return "";
        endcase
    endfunction

    function automatic string describe(input logic valid,
                                       input logic [1:0] kind,
                                       input logic [NOTE_W-1:0] note,
                                       input logic [7:0] velocity);
        return $sformatf("valid=%b type=%0d note=%0d velocity=%0d",
                         valid, kind, note, velocity);
    endfunction

    task automatic check(input logic condition, input integer group_id,
                         input string detail);
        string message_text;
        checks++;
        if (condition !== 1'b1) begin
            errors++;
            group_errors[group_id]++;
            case_errors[current_case]++;
            message_text = $sformatf(
                "cycle=%0d CASE %0d (%s): %s [actual %s]",
                cycles, current_case + 1, case_names[current_case], detail,
                describe(event_valid, event_type, event_note_id, event_velocity));
            if (group_errors[group_id] == 1)
                first_error[group_id] = message_text;
            if (group_errors[group_id] <= 3)
                $display("FAIL [%s] %s", group_name(group_id), message_text);
        end
    endtask

    task automatic begin_case(input integer id);
        current_case = id;
        $display("CASE %0d: %s", id + 1, case_names[id]);
    endtask

    // 下降沿驱动，上升沿采样握手。last_fire 使用沿前接口值，避免 NBA 更新
    // 把“本拍完成的传输”误判成下一拍传输。
    task automatic cycle(input bit reset_value, input bit enable_value,
                         input bit ready_value, input bit ce_value);
        logic pre_valid;
        logic [1:0] pre_type;
        logic [NOTE_W-1:0] pre_note;
        logic [7:0] pre_velocity;
        logic pre_ready;

        @(negedge sys_clk);
        cycles++;
        case_cycles[current_case]++;
        rst_n = reset_value;
        enable = enable_value;
        event_ready = ready_value;
        audio_ce = ce_value;
        #1;

        pre_valid = event_valid;
        pre_type = event_type;
        pre_note = event_note_id;
        pre_velocity = event_velocity;
        pre_ready = event_ready;
        last_fire = reset_value && (pre_valid === 1'b1) &&
                    (pre_ready === 1'b1);

        if (reset_value && pre_valid === 1'b1) begin
            check(!$isunknown(pre_type), DATA_ERR,
                  "valid=1 时 event_type 不能为未知值");
            check(!$isunknown(pre_note), DATA_ERR,
                  "valid=1 时 event_note_id 不能为未知值");
            check(pre_velocity === EXPECTED_VELOCITY, DATA_ERR,
                  $sformatf("测试事件力度应为 %0d", EXPECTED_VELOCITY));
        end

        if (last_fire) begin
            accepted_events++;
            last_type = pre_type;
            last_note = pre_note;
            last_velocity = pre_velocity;
        end

        @(posedge sys_clk);
        #1;

        if (!reset_value)
            check(event_valid === 1'b0, RESET_ERR,
                  "复位沿之后 event_valid 必须保持为 0");

        if (last_fire)
            check(event_valid === 1'b0, VALID_ERR,
                  "完成握手后的本拍必须撤销 event_valid");
    endtask

    task automatic reset_dut();
        cycle(0, 0, 0, 0);
        cycle(0, 1, 1, 1); // enable 不能越过复位启动序列
        cycle(1, 0, 0, 0);
        check(event_valid === 1'b0, RESET_ERR,
              "释放复位且 enable=0 时不应存在事件");
    endtask

    task automatic wait_for_valid(input integer limit, input bit enable_value,
                                  output bit found);
        found = 1'b0;
        for (integer i = 0; i < limit; i++) begin
            if (event_valid === 1'b1) begin
                found = 1'b1;
                return;
            end
            // 每 SAMPLE_RATE 个系统周期模拟一次 audio_ce，缩短 100 ms 窗口。
            cycle(1, enable_value, 0,
                  ((i + 1) % SAMPLE_RATE) == 0);
            if (event_valid === 1'b1) begin
                found = 1'b1;
                return;
            end
        end
    endtask

    task automatic wait_for_clear(input integer limit, input bit enable_value,
                                  output bit cleared);
        cleared = 1'b0;
        for (integer i = 0; i < limit; i++) begin
            if (event_valid === 1'b0) begin
                cleared = 1'b1;
                return;
            end
            cycle(1, enable_value, 0,
                  ((i + 1) % SAMPLE_RATE) == 0);
        end
        cleared = event_valid === 1'b0;
    endtask

    task automatic check_no_event(input integer ce_windows,
                                  input bit enable_value,
                                  input integer group_id,
                                  input string context_text);
        integer clocks;
        clocks = ce_windows * WINDOW_CLOCKS;
        for (integer i = 0; i < clocks; i++) begin
            cycle(1, enable_value, 0,
                  ((i + 1) % SAMPLE_RATE) == 0);
            if (!enable_value)
                disabled_cycles++;
            check(event_valid === 1'b0, group_id,
                  enable_value ?
                      {context_text, ": 不应产生新事件"} :
                      {context_text, ": enable=0 时不应产生新事件"});
        end
    endtask

    // 每次只给出一个 ready 脉冲，避免一个“未撤销 valid”故障把后续所有
    // 事件顺序都变成连锁失败。撤销延迟本身仍由 cycle() 单独检查。
    task automatic accept_expected(input integer index, output bit ok);
        bit found, cleared;
        logic [1:0] held_type;
        logic [NOTE_W-1:0] held_note;
        logic [7:0] held_velocity;

        ok = 1'b0;
        wait_for_valid(EVENT_WAIT_CLOCKS, 1'b1, found);
        if (!found) begin
            check(0, TIMEOUT_ERR,
                  $sformatf("等待第 %0d 个事件超时", index));
            return;
        end

        check(event_type === expected_type[index], DATA_ERR,
              $sformatf("第 %0d 个事件类型应为 %0d",
                        index, expected_type[index]));
        check(event_note_id === expected_note[index], DATA_ERR,
              $sformatf("第 %0d 个事件音符应为 %0d",
                        index, expected_note[index]));
        check(event_velocity === EXPECTED_VELOCITY, DATA_ERR,
              $sformatf("第 %0d 个事件力度应为 %0d",
                        index, EXPECTED_VELOCITY));

        held_type = event_type;
        held_note = event_note_id;
        held_velocity = event_velocity;
        for (integer i = 0; i < WINDOW_CLOCKS; i++) begin
            cycle(1, 1, 0, ((i + 1) % SAMPLE_RATE) == 0);
            stalled_cycles++;
            check(event_valid === 1'b1, HOLD_ERR,
                  $sformatf("第 %0d 个事件背压期间 valid 不得撤销", index));
            check(event_type === held_type &&
                  event_note_id === held_note &&
                  event_velocity === held_velocity,
                  HOLD_ERR,
                  $sformatf("第 %0d 个事件背压期间字段不得变化", index));
        end

        cycle(1, 1, 1, 0);
        check(last_fire, COUNT_ERR,
              $sformatf("第 %0d 个事件在 ready=1 时未完成握手", index));
        check(last_type === expected_type[index] &&
              last_note === expected_note[index] &&
              last_velocity === EXPECTED_VELOCITY,
              DATA_ERR,
              $sformatf("第 %0d 个事件的握手数据不正确", index));

        wait_for_clear(EVENT_WAIT_CLOCKS, 1'b1, cleared);
        if (!cleared) begin
            check(0, TIMEOUT_ERR,
                  $sformatf("第 %0d 个事件握手后未撤销 valid", index));
            return;
        end
        ok = 1'b1;
    endtask

    task automatic report_line(input string line_text);
        $display("%s", line_text);
        if (report_fd != 0)
            $fdisplay(report_fd, "%s", line_text);
    endtask

    task automatic report(input bit timed_out);
        report_fd = $fopen(summary_path, "w");
        if (report_fd == 0)
            $display("WARNING: cannot write %s", summary_path);

        report_line("\n===== AUDIO TEST SOURCE 自动检查总结 =====");
        report_line($sformatf(
            "RESULT: %s | cycles=%0d checks=%0d failed_checks=%0d",
            (timed_out || errors != 0) ? "FAIL" : "PASS",
            cycles, checks, errors));
        report_line("失败次数表示检查点数量，不等于独立 bug 数量；首个故障可能引发后续失败。");

        for (integer i = 0; i < CASES; i++)
            report_line($sformatf(
                "  CASE %0d %s failures=%0d: %s",
                i + 1,
                case_cycles[i] == 0 ? "SKIP" :
                    (case_errors[i] == 0 ? "PASS" : "FAIL"),
                case_errors[i], case_names[i]));

        for (integer i = 0; i < GROUPS; i++) begin
            report_line($sformatf(
                "  [%s] failures=%0d", group_name(i), group_errors[i]));
            if (group_errors[i] != 0) begin
                report_line({"    首例: ", first_error[i]});
                report_line({"    排查: ", hint(i)});
            end
        end

        report_line($sformatf(
            "覆盖统计: accepted=%0d stalled_cycles=%0d disabled_cycles=%0d",
            accepted_events, stalled_cycles, disabled_cycles));
        report_line("本 TB 只依赖 valid/ready 接口；不要求固定输出延迟或状态编码。");
        if (timed_out)
            report_line("TIMEOUT: 全局看门狗触发，部分场景可能尚未完成。");
        report_line({"总结文件: ", summary_path});

        if (report_fd != 0)
            $fclose(report_fd);
    endtask

    initial begin
        logic [NOTE_W-1:0] notes [0:ARR_DEPTH-1];
        bit ok;
        integer mark;

        notes[0] = 7'd60;
        notes[1] = 7'd64;
        notes[2] = 7'd67;
        notes[3] = 7'd72;
        for (integer i = 0; i < ARR_DEPTH; i++) begin
            expected_type[i] = NOTE_ON;
            expected_note[i] = notes[i];
            expected_type[i + ARR_DEPTH] = NOTE_OFF;
            expected_note[i + ARR_DEPTH] = notes[i];
        end

        for (integer i = 0; i < GROUPS; i++) begin
            group_errors[i] = 0;
            first_error[i] = "";
        end
        for (integer i = 0; i < CASES; i++) begin
            case_errors[i] = 0;
            case_cycles[i] = 0;
        end

        case_names[0] = "复位、enable=0 与 audio_ce 不自行启动序列";
        case_names[1] = "C4,E4,G4,C5 的 NOTE_ON/OFF 顺序、类型、力度与数量";
        case_names[2] = "ready=0 背压保持；enable=0 仍可完成已有握手";
        case_names[3] = "enable 暂停计时，重新使能后从 C4 重启";
        case_names[4] = "ready 连续为 1 不重复发送；复位取消待发事件";

        if ($value$plusargs("summary=%s", summary_path)) begin end
        if ($test$plusargs("waves")) begin
            $dumpfile("/tmp/tb_audio_test_source.vcd");
            $dumpvars(0, tb_audio_test_source);
        end

        begin_case(0);
        reset_dut();
        check_no_event(3, 1'b0, ENABLE_ERR,
                       "enable=0 且持续提供 audio_ce");

        begin_case(1);
        reset_dut();
        mark = accepted_events;
        for (integer i = 0; i < ARR_DEPTH; i++) begin
            accept_expected(i, ok);
            if (!ok) break;
        end
        // 四个 NOTE_ON 后应进入约 600 ms 的保持区；先确认不会立刻发 NOTE_OFF。
        check_no_event(2, 1'b1, COUNT_ERR,
                       "四个 NOTE_ON 后的保持区");
        for (integer i = ARR_DEPTH; i < 2 * ARR_DEPTH; i++) begin
            accept_expected(i, ok);
            if (!ok) break;
        end
        repeat (3) cycle(1, 1, 0, 0); // 无 audio_ce 时不能立即重发
        check(event_valid === 1'b0, COUNT_ERR,
              "最后一个 NOTE_OFF 后不应立刻重复发送");
        check(accepted_events - mark == 2 * ARR_DEPTH, COUNT_ERR,
              $sformatf("一个完整序列应握手 %0d 次", 2 * ARR_DEPTH));

        begin_case(2);
        reset_dut();
        mark = accepted_events;
        wait_for_valid(EVENT_WAIT_CLOCKS, 1'b1, ok);
        if (!ok) begin
            check(0, TIMEOUT_ERR, "背压用例未等到首个事件");
        end
        else begin
            for (integer i = 0; i < WINDOW_CLOCKS; i++) begin
                cycle(1, 1, 0, ((i + 1) % SAMPLE_RATE) == 0);
                stalled_cycles++;
                check(event_valid === 1'b1, HOLD_ERR,
                      "背压期间 valid 必须保持");
                check(event_type === NOTE_ON && event_note_id === 7'd60,
                      HOLD_ERR, "背压期间首事件必须保持 C4 NOTE_ON");
            end
            cycle(1, 0, 1, 0);
            check(last_fire, ENABLE_ERR,
                  "enable=0 时已有事件仍应能完成握手");
            check(event_valid === 1'b0, ENABLE_ERR,
                  "enable=0 完成旧事件后 valid 应撤销");
            check_no_event(3, 1'b0, ENABLE_ERR,
                           "旧事件握手完成且 enable=0");
            check(accepted_events - mark == 1, COUNT_ERR,
                  "背压场景应只握手一次");
        end

        begin_case(3);
        reset_dut();
        accept_expected(0, ok);
        cycle(1, 0, 0, 0); // 首个音符刚接收后暂停
        check_no_event(3, 1'b0, ENABLE_ERR,
                       "序列中途 enable=0");
        cycle(1, 1, 0, 0); // enable 上升沿，不立即产生事件
        check(event_valid === 1'b0, ENABLE_ERR,
              "enable 上升沿不能与旧计时状态立即产生事件");
        accept_expected(0, ok); // 重新使能后应从 C4 重启

        begin_case(4);
        reset_dut();
        wait_for_valid(EVENT_WAIT_CLOCKS, 1'b1, ok);
        if (!ok) begin
            check(0, TIMEOUT_ERR, "连续 ready 用例未等到首个事件");
        end
        else begin
            mark = accepted_events;
            for (integer i = 0; i < 4; i++) begin
                cycle(1, 1, 1, 0);
                if (i == 0)
                    check(last_fire, COUNT_ERR,
                          "ready=1 时首个事件应完成握手");
                else
                    check(!last_fire, COUNT_ERR,
                          "握手后 ready 连续为 1 时不得重复发送");
                check(event_valid === 1'b0 || i == 0, VALID_ERR,
                      "握手后 valid 必须撤销");
            end
            check(accepted_events - mark == 1, COUNT_ERR,
                  "连续 ready 期间同一事件只能握手一次");
        end

        // 待发事件阻塞时复位，既检查 valid 清零，也检查复位后 enable=0
        // 不会把旧序列重新启动。
        reset_dut();
        wait_for_valid(EVENT_WAIT_CLOCKS, 1'b1, ok);
        cycle(0, 1, 0, 0);
        cycle(1, 0, 0, 0);
        check(event_valid === 1'b0, RESET_ERR,
              "复位必须取消阻塞中的待发事件");

        report(0);
        if (errors != 0) begin
            $fatal(1, "tb_audio_test_source failed; see %s", summary_path);
        end
        $display("PASS: tb_audio_test_source");
        $finish;
    end

    initial begin
        #200000;
        report(1);
        $fatal(1, "TIMEOUT: tb_audio_test_source did not finish");
    end
endmodule
