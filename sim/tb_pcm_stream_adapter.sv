`timescale 1ns/1ns

module tb_pcm_stream_adapter #(
    parameter integer INPUT_W = 24,
    parameter integer SAMPLE_W = 16,
    parameter integer FIFO_DEPTH = 4
);
    localparam integer SHIFT = INPUT_W - SAMPLE_W;
    localparam longint signed SCALE = 64'sd1 << SHIFT;
    localparam longint signed INPUT_MAX = (64'sd1 << (INPUT_W - 1)) - 1;
    localparam longint signed INPUT_MIN = -(64'sd1 << (INPUT_W - 1));
    localparam integer GROUPS = 6;
    localparam integer CASES = 10;
    localparam integer RESET_ERR = 0, VALID_ERR = 1, DATA_ERR = 2,
                       STEREO_ERR = 3, HOLD_ERR = 4, OVERFLOW_ERR = 5;
    typedef logic signed [INPUT_W-1:0] input_t;
    typedef logic signed [SAMPLE_W-1:0] pcm_t;

    logic sys_clk = 0;
    logic rst_n = 0;
    logic sample_valid = 0;
    input_t mixed_sample = 0;
    logic pcm_valid, pcm_ready = 0;
    pcm_t pcm_left, pcm_right;
    logic overflow;

    // 软件队列只依赖接口输入和规范，不读取 DUT 的指针/计数等内部信号。
    pcm_t expected_queue[$];
    bit expected_overflow = 0;
    logic [31:0] rng = 32'h7063_6d31;
    logic [31:0] controls, random_sample;
    integer checks = 0, errors = 0, cycles = 0;
    integer group_errors [0:GROUPS-1];
    string first_error [0:GROUPS-1];
    integer case_errors [0:CASES-1];
    integer case_cycles [0:CASES-1];
    string case_names [0:CASES-1];
    integer current_case = 0;
    integer accepted = 0, consumed = 0, dropped = 0;
    integer simultaneous = 0, full_replace = 0, stalled = 0, empty_ready = 0;
    integer reset_with_data = 0;
    integer report_fd;
    string summary_path = "/tmp/tb_pcm_stream_adapter_summary.txt";

    pcm_stream_adapter #(
        .INPUT_W(INPUT_W), .SAMPLE_W(SAMPLE_W), .FIFO_DEPTH(FIFO_DEPTH)
    ) DUT (.*);

    always #5 sys_clk = ~sys_clk;

    function automatic string group_name(input integer group_id);
        case (group_id)
            RESET_ERR:    return "RESET / 复位";
            VALID_ERR:    return "VALID / 空满与有效信号";
            DATA_ERR:     return "DATA / 高位转换、队首时序与样本顺序";
            STEREO_ERR:   return "STEREO / 左右声道一致";
            HOLD_ERR:     return "HOLD / 下游阻塞期间保持";
            OVERFLOW_ERR: return "OVERFLOW / 丢样标志及粘滞保持";
            default:      return "UNKNOWN";
        endcase
    endfunction

    function automatic string hint(input integer group_id);
        case (group_id)
            RESET_ERR: return "检查复位是否清空队列并清除 overflow；空队列的数据值不作要求。";
            VALID_ERR: return "检查实际 push/pop 与计数更新，尤其是空队列及满时同拍出入队。";
            DATA_ERR: return "先检查握手沿之前是否已经输出队首，再检查保留高位、符号、指针及丢样；不是等 pop 后才输出被接收的样本。";
            STEREO_ERR: return "左右声道应来自同一份队首样本，并使用一次共同握手。";
            HOLD_ERR: return "valid && !ready 后必须保持 valid 和数据直到接收；检查是否覆盖队首或错误推进读指针。";
            OVERFLOW_ERR: return "输入有效且满且无出队时置位，保持至复位；满时成功出队仍可入队，不能误报。";
            default: return "";
        endcase
    endfunction

    task automatic check(input logic condition, input integer group_id,
                         input string detail);
        string message_text;
        checks++;
        if (condition !== 1'b1) begin
            errors++;
            group_errors[group_id]++;
            case_errors[current_case]++;
            message_text = $sformatf("cycle=%0d case=%0d (%s): %s", cycles,
                                     current_case + 1, case_names[current_case], detail);
            if (group_errors[group_id] == 1) first_error[group_id] = message_text;
            // 每类只打印前两条，避免同一故障刷屏；末尾保留完整计数和首例。
            if (group_errors[group_id] <= 2)
                $display("FAIL [%s] %s", group_name(group_id), message_text);
        end
    endtask

    task automatic begin_case(input integer id);
        current_case = id;
        $display("CASE %0d: %s", id + 1, case_names[id]);
    endtask

    // 用整数除法独立计算参考值，避免复制 DUT 的移位/切片写法。
    // SV 除法向零取整，负数有余数时减一，得到保留高位的向下取整结果。
    function automatic pcm_t reference_pcm(input input_t sample_value);
        longint signed value, quotient;
        value = longint'(sample_value);
        quotient = value / SCALE;
        if (value < 0 && value % SCALE != 0) quotient--;
        return pcm_t'(quotient);
    endfunction

    function automatic logic [31:0] next_random();
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        return rng;
    endfunction

    task automatic check_interface(input string phase_name);
        bit expected_valid;
        expected_valid = expected_queue.size() != 0;
        check(pcm_valid === expected_valid, VALID_ERR,
              $sformatf("%s: count=%0d expected valid=%b got=%b", phase_name,
                        expected_queue.size(), expected_valid, pcm_valid));
        check(overflow === expected_overflow, OVERFLOW_ERR,
              $sformatf("%s: expected overflow=%b got=%b", phase_name,
                        expected_overflow, overflow));
        if (pcm_valid === 1'b1) begin
            check(pcm_left === pcm_right, STEREO_ERR,
                  $sformatf("%s: left=%0d right=%0d", phase_name, pcm_left, pcm_right));
            if (expected_valid)
                check(pcm_left === expected_queue[0] && pcm_right === expected_queue[0],
                      DATA_ERR, $sformatf("%s: expected head=%0d got L=%0d R=%0d ready=%b",
                      phase_name, expected_queue[0], pcm_left, pcm_right, pcm_ready));
        end
        // valid=0 时不检查数据，允许输出零或保留旧值。
    endtask

    // 下降沿驱动，分别检查握手前和 NBA 更新后，避免把沿后旧样本误认为成功交付。
    // 使用无空队列直通、入队沿后可见队首的同步 FIFO 时序。
    task automatic cycle(input bit reset_n, input bit valid, input bit ready,
                         input longint signed value);
        bit do_pop, do_push, was_full, held;
        pcm_t held_left, held_right, discarded;
        @(negedge sys_clk);
        cycles++;
        case_cycles[current_case]++;
        rst_n = reset_n;
        sample_valid = valid;
        pcm_ready = ready;
        mixed_sample = input_t'(value);
        #1;
        held = 0;
        do_pop = 0;
        do_push = 0;
        was_full = expected_queue.size() == FIFO_DEPTH;
        if (reset_n) begin
            check_interface("before edge");
            held = pcm_valid === 1'b1 && !ready;
            held_left = pcm_left;
            held_right = pcm_right;
            do_pop = expected_queue.size() != 0 && ready;
            do_push = valid && (!was_full || do_pop);
            if (held) stalled++;
            if (expected_queue.size() == 0 && ready) empty_ready++;
        end

        @(posedge sys_clk);
        if (!reset_n) begin
            if (expected_queue.size() != 0) reset_with_data++;
            expected_queue.delete();
            expected_overflow = 0;
        end else begin
            if (do_pop) begin
                discarded = expected_queue.pop_front();
                consumed++;
            end
            if (do_push) begin
                expected_queue.push_back(reference_pcm(mixed_sample));
                accepted++;
            end
            if (do_push && do_pop) begin
                simultaneous++;
                if (was_full) full_replace++;
            end
            if (valid && !do_push) begin
                expected_overflow = 1;
                dropped++;
            end
        end
        #1;
        if (!reset_n) begin
            check(pcm_valid === 1'b0 && overflow === 1'b0, RESET_ERR,
                  $sformatf("reset expected valid=0 overflow=0; got valid=%b overflow=%b",
                            pcm_valid, overflow));
        end else begin
            check_interface("after edge");
            if (held)
                check(pcm_valid === 1'b1 && pcm_left === held_left && pcm_right === held_right,
                      HOLD_ERR, "blocked output changed across edge");
        end
    endtask

    task automatic reset_dut();
        cycle(0, 0, 0, 0);
        cycle(1, 0, 0, 0);
    endtask

    task automatic drain();
        // 固定长度避免 DUT 的 valid 故障使测试永远等不到空队列。
        repeat (FIFO_DEPTH + 2) cycle(1, 0, 1, INPUT_MAX);
    endtask

    task automatic report_line(input string line_text);
        $display("%s", line_text);
        if (report_fd != 0) $fdisplay(report_fd, "%s", line_text);
    endtask

    task automatic report(input bit timed_out);
        report_fd = $fopen(summary_path, "w");
        if (report_fd == 0) $display("WARNING: cannot write summary file %s", summary_path);
        report_line("\n===== PCM STREAM ADAPTER 自动检查总结 =====");
        report_line($sformatf("RESULT: %s | INPUT_W=%0d SAMPLE_W=%0d FIFO_DEPTH=%0d",
                    (timed_out || errors != 0) ? "FAIL" : "PASS", INPUT_W, SAMPLE_W, FIFO_DEPTH));
        report_line($sformatf("cycles=%0d checks=%0d failed_checks=%0d", cycles, checks, errors));
        report_line("失败次数是检查点数量，不等于独立 bug 数量；一个时序问题可能导致多类失败。");
        for (int i = 0; i < CASES; i++)
            report_line($sformatf("  CASE %0d %-5s failures=%0d : %s", i + 1,
                case_cycles[i] == 0 ? "SKIP" : (case_errors[i] == 0 ? "PASS" : "FAIL"),
                case_errors[i], case_names[i]));
        for (int i = 0; i < GROUPS; i++) begin
            report_line($sformatf("  [%s] failures=%0d", group_name(i), group_errors[i]));
            if (group_errors[i] != 0) begin
                report_line({"    首例: ", first_error[i]});
                report_line({"    排查: ", hint(i)});
            end
        end
        report_line($sformatf("参考模型事件: accepted=%0d consumed=%0d dropped=%0d simultaneous=%0d full_replace=%0d",
                    accepted, consumed, dropped, simultaneous, full_replace));
        report_line($sformatf("场景覆盖: stalled=%0d empty_ready=%0d reset_with_data=%0d",
                    stalled, empty_ready, reset_with_data));
        if (timed_out) report_line("TIMEOUT: 测试未完成，请检查时钟或仿真是否卡住；部分 CASE 可能未完成。");
        report_line({"总结文件: ", summary_path});
        if (report_fd != 0) $fclose(report_fd);
    endtask

    initial begin
        if (SAMPLE_W < 2 || INPUT_W < SAMPLE_W || INPUT_W > 32 || FIFO_DEPTH < 1)
            $fatal(1, "TB requires 2 <= SAMPLE_W <= INPUT_W <= 32 and FIFO_DEPTH >= 1");
        for (int i = 0; i < GROUPS; i++) begin
            group_errors[i] = 0;
            first_error[i] = "";
        end
        for (int i = 0; i < CASES; i++) begin
            case_errors[i] = 0;
            case_cycles[i] = 0;
        end
        case_names[0] = "复位、空队列 ready、有效零样本";
        case_names[1] = "正负满幅、符号及截位边界";
        case_names[2] = "连续输入输出与 sample_valid=0 忽略输入";
        case_names[3] = "反复填满排空、指针绕回、顺序";
        case_names[4] = "背压期间保持队首，允许队尾入队";
        case_names[5] = "满且阻塞丢新样本、overflow 粘滞";
        case_names[6] = "满队列同拍出入队，必须接收新样本";
        case_names[7] = "积压/溢出后的复位与重新接收";
        case_names[8] = "固定种子随机输入、背压与复位";
        case_names[9] = "稀疏采样脉冲与最终排空";
        if ($value$plusargs("summary=%s", summary_path)) begin end
        if ($test$plusargs("waves")) begin
            $dumpfile("/tmp/tb_pcm_stream_adapter.vcd");
            $dumpvars(0, tb_pcm_stream_adapter);
        end
        $display("PCM TB input=%0d output=%0d depth=%0d seed=%h", INPUT_W, SAMPLE_W, FIFO_DEPTH, rng);

        begin_case(0);
        reset_dut();
        cycle(0, 1, 1, INPUT_MAX);
        repeat (3) cycle(1, 0, 1, INPUT_MIN);
        cycle(1, 1, 0, 0);
        drain();

        begin_case(1);
        reset_dut();
        for (int i = 0; i < 10; i++) begin
            case (i)
                0: cycle(1, 1, 0, INPUT_MAX);
                1: cycle(1, 1, 0, INPUT_MIN);
                2: cycle(1, 1, 0, 1);
                3: cycle(1, 1, 0, -1);
                4: cycle(1, 1, 0, SCALE - 1);
                5: cycle(1, 1, 0, SCALE);
                6: cycle(1, 1, 0, SCALE + 1);
                7: cycle(1, 1, 0, -SCALE + 1);
                8: cycle(1, 1, 0, -SCALE);
                9: cycle(1, 1, 0, -SCALE - 1);
            endcase
            cycle(1, 0, 1, 0);
        end
        drain();

        begin_case(2);
        reset_dut();
        for (int i = 0; i < 4 * FIFO_DEPTH + 8; i++)
            cycle(1, 1, 1, (longint'(i) + 1) * SCALE);
        repeat (5) cycle(1, 0, 0, INPUT_MIN);
        drain();
        repeat (3) cycle(1, 0, 1, INPUT_MAX);

        begin_case(3);
        reset_dut();
        for (int round_id = 0; round_id < 4; round_id++) begin
            for (int i = 0; i < FIFO_DEPTH; i++)
                cycle(1, 1, 0, (longint'(round_id) * FIFO_DEPTH + longint'(i) + 1) * SCALE);
            drain();
        end

        begin_case(4);
        reset_dut();
        cycle(1, 1, 0, -SCALE);
        repeat (4) cycle(1, 0, 0, INPUT_MAX);
        for (int i = 1; i < FIFO_DEPTH; i++) cycle(1, 1, 0, longint'(i) * SCALE);
        repeat (4) cycle(1, 0, 0, INPUT_MIN);
        drain();

        begin_case(5);
        reset_dut();
        for (int i = 0; i < FIFO_DEPTH; i++) cycle(1, 1, 0, (longint'(i) + 1) * SCALE);
        repeat (3) cycle(1, 1, 0, INPUT_MIN);
        drain();
        cycle(1, 1, 0, INPUT_MAX);
        drain();

        begin_case(6);
        reset_dut();
        for (int i = 0; i < FIFO_DEPTH; i++) cycle(1, 1, 0, (longint'(i) + 1) * SCALE);
        for (int i = 0; i < 3 * FIFO_DEPTH + 3; i++)
            cycle(1, 1, 1, -(longint'(i) + 1) * SCALE);
        drain();

        begin_case(7);
        reset_dut();
        for (int i = 0; i < FIFO_DEPTH + 1; i++) cycle(1, 1, 0, INPUT_MIN);
        cycle(0, 1, 1, INPUT_MAX);
        cycle(1, 0, 1, 0);
        cycle(1, 1, 0, SCALE);
        drain();

        begin_case(8);
        reset_dut();
        for (int i = 0; i < 600; i++) begin
            controls = next_random();
            random_sample = next_random();
            cycle(i % 97 != 96, controls[0] || controls[1], controls[2],
                  longint'(input_t'(random_sample)));
        end
        drain();

        begin_case(9);
        reset_dut();
        for (int i = 0; i < 12; i++) begin
            cycle(1, 1, 1, (i % 2 == 0) ? INPUT_MAX : INPUT_MIN);
            repeat (7) cycle(1, 0, 1, 0);
        end
        drain();
        report(0);
        if (errors != 0) $fatal(1, "tb_pcm_stream_adapter failed; read summary above or %s", summary_path);
        $display("PASS: tb_pcm_stream_adapter");
        $finish;
    end

    initial begin
        #1000000;
        report(1);
        $fatal(1, "TIMEOUT: tb_pcm_stream_adapter");
    end
endmodule
