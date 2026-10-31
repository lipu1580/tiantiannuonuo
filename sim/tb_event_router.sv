`timescale 1ns/1ns

// 面向接口的测试：不读取 DUT 的 state、缓存或 active_mode。
// 约定：单条缓存，模式切换先排空旧事件，再发送一次 ALL_NOTES_OFF；
// 释放握手时采用最新 test_mode。不要求状态编码或固定的输出延迟。
module tb_event_router;
    localparam integer NOTE_W = 7;
    localparam integer CASES = 10, GROUPS = 7, WAIT_LIMIT = 24;
    localparam integer RESET_ERR = 0, READY_ERR = 1, DATA_ERR = 2,
                       HOLD_ERR = 3, SWITCH_ERR = 4, TIMEOUT_ERR = 5,
                       COUNT_ERR = 6;
    localparam logic [1:0] NOP = 0, NOTE_ON = 1, NOTE_OFF = 2, ALL_NOTES_OFF = 3;
    typedef struct packed {
        logic [1:0] kind;
        logic [NOTE_W-1:0] note;
        logic [7:0] velocity;
    } event_t;

    logic sys_clk = 0, rst_n = 0, test_mode = 0;
    logic event_valid = 0, event_ready;
    logic [1:0] event_type = 0;
    logic [NOTE_W-1:0] event_note_id = 0;
    logic [7:0] event_velocity = 0;
    logic test_event_valid = 0, test_event_ready;
    logic [1:0] test_event_type = 0;
    logic [NOTE_W-1:0] test_event_note_id = 0;
    logic [7:0] test_event_velocity = 0;
    logic routed_event_valid, routed_event_ready = 0;
    logic [1:0] routed_event_type;
    logic [NOTE_W-1:0] routed_event_note_id;
    logic [7:0] routed_event_velocity;

    event_router #(.NOTE_W(NOTE_W)) DUT (.*);
    always #5 sys_clk = ~sys_clk;

    // 两个合法的上游驱动器：未握手时始终保留 valid 和原始事件。
    bit ext_pending = 0, test_pending = 0;
    event_t ext_packet, test_packet;
    event_t expected_queue[$];
    bit model_mode = 0, release_pending = 0;
    bit was_stalled = 0;
    event_t stalled_packet;

    integer cycles = 0, checks = 0, errors = 0, current_case = 0;
    integer group_errors [0:GROUPS-1];
    string first_error [0:GROUPS-1];
    integer case_errors [0:CASES-1];
    integer case_cycles [0:CASES-1];
    string case_names [0:CASES-1];
    integer ext_accepted = 0, test_accepted = 0, forwarded = 0;
    integer releases = 0, reset_discarded = 0, blocked_cycles = 0;
    integer both_valid_cycles = 0, release_blocked_cycles = 0;
    integer report_fd, mark, mark_ext, mark_test;
    logic [31:0] rng = 32'h6576_7431, random_bits;
    string summary_path = "/tmp/tb_event_router_summary.txt";

    function automatic event_t packet(input logic [1:0] kind,
                                     input integer note, input integer velocity);
        event_t value;
        value.kind = kind;
        value.note = NOTE_W'(note);
        value.velocity = 8'(velocity);
        return value;
    endfunction

    function automatic string describe(input event_t value);
        return $sformatf("type=%0d note=%0d velocity=%0d",
                         value.kind, value.note, value.velocity);
    endfunction

    function automatic string group_name(input integer id);
        case (id)
            RESET_ERR:   return "RESET / 复位";
            READY_ERR:   return "READY / 来源选择与接收许可";
            DATA_ERR:    return "DATA / 缓存、字段与顺序";
            HOLD_ERR:    return "HOLD / 背压期间保持";
            SWITCH_ERR:  return "SWITCH / 释放命令与模式切换";
            TIMEOUT_ERR: return "TIMEOUT / 事件未完成";
            COUNT_ERR:   return "COUNT / 丢失或重复发送";
            default:     return "UNKNOWN";
        endcase
    endfunction

    function automatic string hint(input integer id);
        case (id)
            RESET_ERR: return "复位应清除输出 valid，关闭两个输入 ready，并把实际模式恢复为外部模式；缓存事件允许被复位丢弃。";
            READY_ERR: return "只有空闲、模式一致且选中的源能获得 ready；缓存占用或释放期间两个 ready 都应为 0。";
            DATA_ERR: return "输入握手发生的上升沿就要保存全部字段；不要等进入 SEND_CACHE 才检查输入握手。valid=1 时必须已经给出正确数据，不能等下游 ready。";
            HOLD_ERR: return "上拍 valid=1 且 ready=0 后，本拍必须保持 valid 和所有字段，即使 ready 恢复或 test_mode 改变。";
            SWITCH_ERR: return "旧缓存事件必须先完成；释放命令也要等待握手；释放成功后才能启用新源。返回 IDLE 时避免多发送一次释放命令。";
            TIMEOUT_ERR: return "先检查是否在 IDLE 握手时写入缓存，再检查发送期间 valid 是否持续有效；模式切换不依赖输入 valid。";
            COUNT_ERR: return "每条被输入握手接收的事件只能输出一次；内部释放单独计数。检查输出 valid 是否在离开发送状态后仍多保持一拍。";
            default: return "";
        endcase
    endfunction

    task automatic check(input logic condition, input integer id, input string detail);
        string message_text;
        checks++;
        if (condition !== 1'b1) begin
            errors++;
            group_errors[id]++;
            case_errors[current_case]++;
            message_text = $sformatf("cycle=%0d CASE %0d (%s): %s", cycles,
                            current_case + 1, case_names[current_case], detail);
            if (group_errors[id] == 1) first_error[id] = message_text;
            if (group_errors[id] <= 3)
                $display("FAIL [%s] %s", group_name(id), message_text);
        end
    endtask

    task automatic begin_case(input integer id);
        current_case = id;
        $display("CASE %0d: %s", id + 1, case_names[id]);
    endtask

    task automatic offer(input bit source, input event_t value);
        // 驱动器自身的错误立即终止，不能把非法激励归咎于 DUT。
        if (source) begin
            if (test_pending) $fatal(1, "TB bug: replacing a pending test event");
            test_packet = value;
            test_pending = 1;
        end else begin
            if (ext_pending) $fatal(1, "TB bug: replacing a pending external event");
            ext_packet = value;
            ext_pending = 1;
        end
    endtask

    // 下降沿驱动，上升沿采样；计分板只记录实际接口握手。
    // 上游字段在 valid=0 时故意变化，检测 DUT 是否错误使用实时输入。
    task automatic cycle(input bit reset_n, input bit mode, input bit downstream_ready);
        bit ext_fire, test_fire, output_fire, expected_release;
        event_t observed, expected;
        @(negedge sys_clk);
        rst_n = reset_n;
        test_mode = mode;
        routed_event_ready = downstream_ready;
        event_valid = ext_pending;
        test_event_valid = test_pending;
        {event_type, event_note_id, event_velocity} = ext_pending ? ext_packet : packet(NOTE_OFF, cycles, 255 - cycles);
        {test_event_type, test_event_note_id, test_event_velocity} = test_pending ? test_packet : packet(NOTE_ON, 127 - cycles, cycles);
        @(posedge sys_clk);
        cycles++;
        case_cycles[current_case]++;
        if (!reset_n) begin
            reset_discarded += expected_queue.size();
            expected_queue.delete();
            model_mode = 0;
            release_pending = 0;
            was_stalled = 0;
            ext_pending = 0;
            test_pending = 0;
            #1;
            check(event_ready === 1'b0 && test_event_ready === 1'b0 &&
                  routed_event_valid === 1'b0, RESET_ERR,
                  $sformatf("reset: ext_ready=%b test_ready=%b out_valid=%b",
                             event_ready, test_event_ready, routed_event_valid));
        end else begin
            observed = {routed_event_type, routed_event_note_id, routed_event_velocity};
            ext_fire = event_valid === 1'b1 && event_ready === 1'b1;
            test_fire = test_event_valid === 1'b1 && test_event_ready === 1'b1;
            output_fire = routed_event_valid === 1'b1 && downstream_ready;

            // 模式差异只在旧事件排空后产生一个释放义务；一旦产生，
            // 即使请求变回原模式，也必须完成该释放再采用最新请求。
            if (expected_queue.size() == 0 && model_mode != mode)
                release_pending = 1;
            expected_release = release_pending;
            if (expected_queue.size() != 0 || release_pending || model_mode != mode)
                check(event_ready === 1'b0 && test_event_ready === 1'b0,
                      READY_ERR, "缓存占用或模式切换期间，上游 ready 必须都为 0");
            else if (mode)
                check(event_ready === 1'b0, READY_ERR, "测试模式下外部源不得获得 ready");
            else
                check(test_event_ready === 1'b0, READY_ERR, "外部模式下测试源不得获得 ready");

            if (was_stalled)
                check(routed_event_valid === 1'b1 && observed === stalled_packet,
                      HOLD_ERR, $sformatf("expected held {%s}; got valid=%b {%s}",
                      describe(stalled_packet), routed_event_valid, describe(observed)));
            if (event_valid && test_event_valid) both_valid_cycles++;

            if (ext_fire) begin
                expected_queue.push_back(ext_packet);
                ext_accepted++;
                ext_pending = 0;
            end
            if (test_fire) begin
                expected_queue.push_back(test_packet);
                test_accepted++;
                test_pending = 0;
            end

            // valid 为 1 时就检查字段，包括 ready=0 的周期。
            // 合法上游 ALL_NOTES_OFF 在队列中，不能误算为内部释放。
            if (routed_event_valid === 1'b1) begin
                if (expected_release) begin
                    check(routed_event_type === ALL_NOTES_OFF, SWITCH_ERR,
                          {"切换时应先输出 ALL_NOTES_OFF，实际 ", describe(observed)});
                    if (!downstream_ready) release_blocked_cycles++;
                    if (output_fire) begin
                        releases++;
                        release_pending = 0;
                        model_mode = mode;
                    end
                end else if (expected_queue.size() != 0) begin
                    expected = expected_queue[0];
                    check(observed === expected, DATA_ERR,
                          $sformatf("expected {%s}; got {%s}, ready=%b",
                          describe(expected), describe(observed), downstream_ready));
                    if (output_fire) begin
                        expected = expected_queue.pop_front();
                        forwarded++;
                    end
                end else begin
                    check(0, COUNT_ERR, {"没有待发送事件却输出 valid=1: ", describe(observed)});
                end
            end
            was_stalled = routed_event_valid === 1'b1 && !downstream_ready;
            stalled_packet = observed;
            if (was_stalled) blocked_cycles++;
            #1;
        end
    endtask

    task automatic reset_dut();
        cycle(0, 0, 0);
        cycle(0, 0, 1);
        cycle(1, 0, 1);
        check(event_ready === 1'b1 && test_event_ready === 1'b0,
              RESET_ERR, "复位后空闲时应允许外部源，不应等待 valid 才给 ready");
    endtask

    task automatic wait_accepted(input bit source, input bit mode, input bit ready_value);
        for (int i = 0; i < WAIT_LIMIT; i++) begin
            if (!(source ? test_pending : ext_pending)) return;
            cycle(1, mode, ready_value);
        end
        check(0, TIMEOUT_ERR, $sformatf("%s输入在 %0d 拍内未被接收",
              source ? "测试源" : "外部源", WAIT_LIMIT));
    endtask

    task automatic wait_presented(input bit mode);
        for (int i = 0; i < WAIT_LIMIT; i++) begin
            cycle(1, mode, 0);
            if (routed_event_valid === 1'b1) return;
        end
        check(0, TIMEOUT_ERR, "已接收事件或待发送释放命令一直没有输出 valid");
    endtask

    // 有限等待；失败后仍继续其他 CASE，防止第一处 bug 阻止总结生成。
    task automatic settle(input bit mode);
        for (int i = 0; i < WAIT_LIMIT; i++) begin
            cycle(1, mode, 1);
            if (expected_queue.size() == 0 && !release_pending && model_mode == mode &&
                !(mode ? test_pending : ext_pending)) begin
                // 多观察几拍，检测握手后多保持一拍 valid 导致的重复发送。
                repeat (3) cycle(1, mode, 1);
                check(expected_queue.size() == 0 && !release_pending,
                      COUNT_ERR, "排空结束后仍有待处理事件");
                return;
            end
        end
        check(0, TIMEOUT_ERR, $sformatf("排空/切换超时: queued=%0d release_pending=%b model_mode=%b requested=%b",
              expected_queue.size(), release_pending, model_mode, mode));
    endtask

    function automatic logic [31:0] next_random();
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        return rng;
    endfunction

    task automatic report_line(input string line_text);
        $display("%s", line_text);
        if (report_fd != 0) $fdisplay(report_fd, "%s", line_text);
    endtask

    task automatic report(input bit timed_out);
        report_fd = $fopen(summary_path, "w");
        if (report_fd == 0) $display("WARNING: cannot write %s", summary_path);
        report_line("\n===== EVENT ROUTER 自动检查总结 =====");
        report_line($sformatf("RESULT: %s | cycles=%0d checks=%0d failed_checks=%0d",
                    (timed_out || errors != 0) ? "FAIL" : "PASS", cycles, checks, errors));
        report_line("失败次数表示检查点数量，不等于独立 bug 数量；首个故障可能引发后续失败。");
        for (int i = 0; i < CASES; i++)
            report_line($sformatf("  CASE %0d %s failures=%0d: %s", i + 1,
                        case_cycles[i] == 0 ? "SKIP" : (case_errors[i] == 0 ? "PASS" : "FAIL"),
                        case_errors[i], case_names[i]));
        for (int i = 0; i < GROUPS; i++) begin
            report_line($sformatf("  [%s] failures=%0d", group_name(i), group_errors[i]));
            if (group_errors[i] != 0) begin
                report_line({"    首例: ", first_error[i]});
                report_line({"    排查: ", hint(i)});
            end
        end
        report_line($sformatf("事件统计: external_accepted=%0d test_accepted=%0d forwarded=%0d internal_releases=%0d reset_discarded=%0d pending=%0d",
                    ext_accepted, test_accepted, forwarded, releases, reset_discarded, expected_queue.size()));
        report_line($sformatf("覆盖统计: output_stalled=%0d release_stalled=%0d both_sources_valid=%0d",
                    blocked_cycles, release_blocked_cycles, both_valid_cycles));
        report_line("本 TB 按单条缓存方案验收，不要求固定输出延迟；每个等待最多 24 拍。");
        report_line("Verilator 通常采用二态仿真：未复位寄存器可能碰巧为 0；PASS 不能代替对复位赋值的代码检查。");
        if (timed_out) report_line("TIMEOUT: 全局看门狗触发，部分场景可能尚未完成。");
        report_line({"总结文件: ", summary_path});
        if (report_fd != 0) $fclose(report_fd);
    endtask

    initial begin
        for (int i = 0; i < GROUPS; i++) begin
            group_errors[i] = 0;
            first_error[i] = "";
        end
        for (int i = 0; i < CASES; i++) begin
            case_errors[i] = 0;
            case_cycles[i] = 0;
        end
        case_names[0] = "复位、默认外部模式、无 valid 不得产生输出";
        case_names[1] = "外部源四种事件编码、字段边界与顺序";
        case_names[2] = "两源同时有效，只接收被选源，再切换接收另一源";
        case_names[3] = "测试模式与测试源字段；不自动接收外部源";
        case_names[4] = "缓存背压、上游下一事件等待、ready 恢复";
        case_names[5] = "缓存事件阻塞期间切换，旧事件→释放→新事件";
        case_names[6] = "无输入事件时双向切换，每次只发一个释放命令";
        case_names[7] = "释放阻塞期间请求反转，保留释放并采用最新模式";
        case_names[8] = "缓存占用及释放过程中复位，恢复默认模式";
        case_names[9] = "固定种子随机事件、背压、模式切换及最终排空";
        if ($value$plusargs("summary=%s", summary_path)) begin end
        if ($test$plusargs("waves")) begin
            $dumpfile("/tmp/tb_event_router.vcd");
            $dumpvars(0, tb_event_router);
        end

        begin_case(0);
        reset_dut();
        repeat (5) cycle(1, 0, 1);

        begin_case(1);
        for (int i = 0; i < 4; i++) begin
            reset_dut();
            mark = forwarded;
            offer(0, packet(2'(i), (i == 0) ? 0 : 127 - i, (i == 3) ? 255 : i * 61));
            wait_accepted(0, 0, 1);
            settle(0);
            check(forwarded == mark + 1, COUNT_ERR, "外部事件必须恰好转发一次，包括 NOP 和源发来的 ALL_NOTES_OFF");
        end

        begin_case(2);
        reset_dut();
        mark_ext = ext_accepted;
        mark_test = test_accepted;
        offer(0, packet(NOTE_ON, 60, 91));
        offer(1, packet(NOTE_ON, 72, 123));
        settle(0);
        check(ext_accepted == mark_ext + 1 && test_accepted == mark_test,
              READY_ERR, "外部模式下两源同时有效，只允许外部输入握手");
        settle(1);
        check(test_accepted == mark_test + 1, COUNT_ERR, "切换后应接收此前等待的测试事件");

        begin_case(3);
        reset_dut();
        settle(1);
        mark_ext = ext_accepted;
        offer(0, packet(NOTE_ON, 11, 19));
        repeat (4) cycle(1, 1, 1);
        check(ext_accepted == mark_ext, READY_ERR, "测试源空闲时也不能自动改选外部源");
        offer(1, packet(NOTE_OFF, 127, 255));
        wait_accepted(1, 1, 1);
        settle(1);

        begin_case(4);
        reset_dut();
        mark = forwarded;
        offer(0, packet(NOTE_ON, 64, 201));
        wait_accepted(0, 0, 0);
        wait_presented(0);
        if (!ext_pending) offer(0, packet(NOTE_OFF, 64, 0));
        repeat (6) cycle(1, 0, 0);
        settle(0);
        check(forwarded == mark + 2, COUNT_ERR, "阻塞前后两条事件均应各转发一次");

        begin_case(5);
        reset_dut();
        mark = releases;
        offer(0, packet(NOTE_ON, 60, 100));
        wait_accepted(0, 0, 0);
        wait_presented(0);
        offer(1, packet(NOTE_ON, 72, 80));
        repeat (5) cycle(1, 1, 0);
        settle(1);
        check(releases == mark + 1, SWITCH_ERR, "旧事件与新源事件之间应恰好完成一次释放");

        begin_case(6);
        reset_dut();
        mark = releases;
        settle(1);
        settle(0);
        check(releases == mark + 2, SWITCH_ERR, "没有输入 valid 也必须完成两次模式切换");

        begin_case(7);
        reset_dut();
        mark = releases;
        wait_presented(1);
        repeat (4) cycle(1, 1, 0);
        repeat (4) cycle(1, 0, 0);
        settle(0);
        check(releases == mark + 1, SWITCH_ERR, "请求变回外部模式，已呈现的释放仍必须完成一次");
        check(event_ready === 1'b1 && test_event_ready === 1'b0,
              SWITCH_ERR, "释放成功后应采用最新的外部模式请求");

        begin_case(8);
        reset_dut();
        offer(0, packet(NOTE_ON, 67, 88));
        wait_accepted(0, 0, 0);
        repeat (3) cycle(1, 0, 0);
        reset_dut();
        settle(0);
        // 先实际进入测试模式，再在切回外部的释放过程中复位。
        settle(1);
        wait_presented(0);
        reset_dut();
        settle(0);
        offer(0, packet(NOTE_ON, 69, 99));
        wait_accepted(0, 0, 1);
        settle(0);

        begin_case(9);
        reset_dut();
        for (int i = 0; i < 400; i++) begin
            random_bits = next_random();
            if (!ext_pending && random_bits[0])
                offer(0, packet(random_bits[4:3], int'(random_bits[11:5]), int'(random_bits[19:12])));
            if (!test_pending && random_bits[1])
                offer(1, packet(random_bits[21:20], int'(random_bits[28:22]), i));
            cycle(1, random_bits[2], random_bits[29] || random_bits[30]);
        end
        settle(0);
        settle(1);
        check(!ext_pending && !test_pending && expected_queue.size() == 0,
              COUNT_ERR, "最终仍有源事件或缓存事件未完成");
        check(ext_accepted + test_accepted == forwarded + reset_discarded + expected_queue.size(),
              COUNT_ERR, "事件守恒失败：输入接收数 != 转发数 + 复位丢弃数 + 缓存占用数");
        report(0);
        if (errors != 0) $fatal(1, "tb_event_router failed; see %s", summary_path);
        $display("PASS: tb_event_router");
        $finish;
    end

    initial begin
        #1000000;
        report(1);
        $fatal(1, "TIMEOUT: tb_event_router");
    end
endmodule
