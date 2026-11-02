//=============================================================================
// 文件   : tb_key_event_decoder.sv
// 功能   : 键盘译码器第 2 轮行为验证。
//
//   第 1 轮这个 TB 测的是"键盘发 NOTE_ON/OFF、八度、ALL_OFF"，
//   第 2 轮键盘不再发任何事件，所以整个 TB 重写。
//
//   覆盖：
//     1. 9 个根音键 -> base_note = 60 + 音级（验收 A1）
//     2. 根音键不产生任何事件（本模块已经没有事件端口，直接看 fx_req=0）
//     3. 3 个波形键 -> waveform_sel = 0/1/2，直选不循环（验收 A3）
//     4. K12/K13/K14 -> fx_req 脉冲 + fx_mode = 0/1/3（验收 A4 的键位部分）
//     5. K15 不产生 fx_req（它是复用键，由 input_top 的 key_tap_hold 处理）
//     6. 复位默认：音级 0、波形正弦、无 fx_req
//     7. 长按根音键不改变其他状态（只锁存，不重复触发）
//=============================================================================
`timescale 1ns/1ps

module tb_key_event_decoder;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    logic [15:0] key_pressed = 16'd0;
    logic [15:0] key_down    = 16'd0;

    logic [6:0]  base_note;
    logic [1:0]  waveform_sel;
    logic        fx_req;
    logic [1:0]  fx_mode_req;
    logic [3:0]  root_pitch_class;
    logic [15:0] active_root_mask;

    int errors = 0;
    int checks = 0;

    // fx_req 脉冲记录
    int         fx_pulse_cnt = 0;
    logic [1:0] fx_pulse_mode = 2'd0;

    always #5 clk = ~clk;

    key_event_decoder #(
        .KEY_COUNT (16),
        .BASE_NOTE (7'd60)
    ) dut (
        .sys_clk          (clk),
        .rst_n            (rst_n),
        .key_pressed      (key_pressed),
        .key_down         (key_down),
        .base_note        (base_note),
        .waveform_sel     (waveform_sel),
        .fx_req           (fx_req),
        .fx_mode_req      (fx_mode_req),
        .root_pitch_class (root_pitch_class),
        .active_root_mask (active_root_mask)
    );

    always @(posedge clk) begin
        if (rst_n && fx_req) begin
            fx_pulse_cnt++;
            fx_pulse_mode = fx_mode_req;
        end
    end

    // 按一下某个键：pressed 一个周期，down 保持几拍再松开
    task automatic tap(input int k, input int hold_cycles = 3);
        @(negedge clk);
        key_pressed[k] = 1'b1;
        key_down[k]    = 1'b1;
        @(negedge clk);
        key_pressed[k] = 1'b0;
        repeat (hold_cycles) @(posedge clk);
        @(negedge clk);
        key_down[k] = 1'b0;
        repeat (2) @(posedge clk);
    endtask

    task automatic chk_base(input logic [6:0] exp, input string msg);
        checks++;
        if (base_note !== exp) begin
            $display("FAIL [%s]: base_note=%0d, 期望 %0d", msg, base_note, exp);
            errors++;
        end else begin
            $display("PASS [%s]: base_note=%0d", msg, base_note);
        end
    endtask

    task automatic chk_wave(input logic [1:0] exp, input string msg);
        checks++;
        if (waveform_sel !== exp) begin
            $display("FAIL [%s]: waveform_sel=%0d, 期望 %0d", msg, waveform_sel, exp);
            errors++;
        end else begin
            $display("PASS [%s]: waveform_sel=%0d", msg, waveform_sel);
        end
    endtask

    task automatic chk_fx(input int exp_cnt, input logic [1:0] exp_mode,
                          input string msg);
        checks++;
        if (fx_pulse_cnt != exp_cnt || fx_pulse_mode !== exp_mode) begin
            $display("FAIL [%s]: fx 脉冲 %0d 次(最后一个 mode=%0d), 期望 %0d 次(mode=%0d)",
                     msg, fx_pulse_cnt, fx_pulse_mode, exp_cnt, exp_mode);
            errors++;
        end else begin
            $display("PASS [%s]: fx 脉冲 %0d 次, mode=%0d",
                     msg, fx_pulse_cnt, fx_pulse_mode);
        end
    endtask

    task automatic clear_fx;
        fx_pulse_cnt  = 0;
        fx_pulse_mode = 2'd0;
    endtask

    initial begin
        $display("========================================");
        $display(" tb_key_event_decoder: 第 2 轮键盘译码");
        $display("========================================");

        key_pressed = 16'd0;
        key_down    = 16'd0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        //---------------------------------------------------------------------
        // 6) 复位默认
        //---------------------------------------------------------------------
        chk_base(7'd60, "复位 base_note=C4");
        chk_wave(2'd0,  "复位波形=正弦");
        checks++;
        if (root_pitch_class !== 4'd0) begin
            $display("FAIL [复位音级]: %0d, 期望 0", root_pitch_class);
            errors++;
        end else begin
            $display("PASS [复位音级]: 0");
        end
        checks++;
        if (active_root_mask !== 16'd0) begin
            $display("FAIL [复位根音掩码]: 0x%04h, 期望 0", active_root_mask);
            errors++;
        end else begin
            $display("PASS [复位根音掩码]: 0");
        end

        //---------------------------------------------------------------------
        // 1)+2) 9 个根音键：base_note 依次 60,61,62,64,65,66,68,69,70
        //       且全程不产生 fx_req（键盘不发音符，也不切效果）
        //---------------------------------------------------------------------
        clear_fx;
        begin
            int key_list [0:8];
            int pc_list  [0:8];
            key_list[0]=0;  pc_list[0]=0;
            key_list[1]=1;  pc_list[1]=1;
            key_list[2]=2;  pc_list[2]=2;
            key_list[3]=4;  pc_list[3]=4;
            key_list[4]=5;  pc_list[4]=5;
            key_list[5]=6;  pc_list[5]=6;
            key_list[6]=8;  pc_list[6]=8;
            key_list[7]=9;  pc_list[7]=9;
            key_list[8]=10; pc_list[8]=10;

            for (int i = 0; i < 9; i++) begin
                tap(key_list[i]);
                chk_base(7'(60 + pc_list[i]), $sformatf("K%0d 根音", key_list[i]));
                checks++;
                if (root_pitch_class !== 4'(pc_list[i])) begin
                    $display("FAIL [K%0d 音级]: %0d, 期望 %0d",
                             key_list[i], root_pitch_class, pc_list[i]);
                    errors++;
                end else begin
                    $display("PASS [K%0d 音级]: %0d", key_list[i], root_pitch_class);
                end
            end
        end
        chk_fx(0, 2'd0, "9 个根音键不切效果");

        // 回到 C 方便后面用
        tap(0);
        chk_base(7'd60, "回到 C");

        //---------------------------------------------------------------------
        // 3) 波形直选：K3->0, K7->1, K11->2（不循环）
        //---------------------------------------------------------------------
        tap(7);
        chk_wave(2'd1, "K7 -> 管风琴(1)");
        tap(11);
        chk_wave(2'd2, "K11 -> 拨弦(2)");
        tap(3);
        chk_wave(2'd0, "K3 -> 正弦(0)");
        tap(11);
        chk_wave(2'd2, "K11 -> 拨弦(2)（再按 K7 之前不应回绕）");
        tap(7);
        chk_wave(2'd1, "K7 -> 管风琴(1)");
        // 长按波形键仍然不变
        tap(11, 20);
        chk_wave(2'd2, "长按 K11 仍是拨弦(2)");

        //---------------------------------------------------------------------
        // 4) 效果键：K12->0, K13->1, K14->3（注意不是 2）
        //---------------------------------------------------------------------
        clear_fx;
        tap(12);
        chk_fx(1, 2'd0, "K12 -> 旁路(0)");
        clear_fx;
        tap(13);
        chk_fx(1, 2'd1, "K13 -> 延迟(1)");
        clear_fx;
        tap(14);
        chk_fx(1, 2'd3, "K14 -> 混响(3)");

        //---------------------------------------------------------------------
        // 5) K15 不产生 fx_req（复用键由 key_tap_hold 处理）
        //---------------------------------------------------------------------
        clear_fx;
        tap(15);
        chk_fx(0, 2'd0, "K15 不产生 fx_req");

        //---------------------------------------------------------------------
        // 7) 长按根音键：只锁存，不重复触发（base_note 保持）
        //---------------------------------------------------------------------
        tap(9, 30);
        chk_base(7'd69, "长按 K9 -> 根音 A (69)");
        checks++;
        if (root_pitch_class !== 4'd9) begin
            $display("FAIL [长按 K9 音级]: %0d, 期望 9", root_pitch_class);
            errors++;
        end else begin
            $display("PASS [长按 K9 音级]: 9");
        end

        //---------------------------------------------------------------------
        // 按住根音键时 active_root_mask 应指示对应键
        //---------------------------------------------------------------------
        @(negedge clk);
        key_pressed[5] = 1'b1;
        key_down[5]    = 1'b1;
        repeat (2) @(posedge clk);
        checks++;
        if (active_root_mask !== 16'h0020) begin
            $display("FAIL [按住 K5]: active_root_mask=0x%04h, 期望 0x0020",
                     active_root_mask);
            errors++;
        end else begin
            $display("PASS [按住 K5]: active_root_mask=0x0020");
        end
        @(negedge clk);
        key_pressed[5] = 1'b0;
        key_down[5]    = 1'b0;
        repeat (2) @(posedge clk);

        // 波形键/效果键不属于根音键，不应出现在 active_root_mask 里
        @(negedge clk);
        key_pressed[12] = 1'b1;
        key_down[12]    = 1'b1;
        key_pressed[3]  = 1'b1;
        key_down[3]     = 1'b1;
        repeat (2) @(posedge clk);
        checks++;
        if (active_root_mask !== 16'd0) begin
            $display("FAIL [波形/效果键不属于根音]: active_root_mask=0x%04h, 期望 0",
                     active_root_mask);
            errors++;
        end else begin
            $display("PASS [波形/效果键不属于根音]: active_root_mask=0");
        end
        @(negedge clk);
        key_pressed = 16'd0;
        key_down    = 16'd0;
        repeat (2) @(posedge clk);

        $display("========================================");
        if (errors == 0) begin
            $display("TEST PASSED: tb_key_event_decoder (%0d checks)", checks);
        end else begin
            $display("TEST FAILED: tb_key_event_decoder, %0d error(s)", errors);
        end
        $finish;
    end

    initial begin
        #1000000;
        $display("TEST TIMEOUT: tb_key_event_decoder");
        $finish;
    end

endmodule
