//=============================================================================
// 文件   : tb_matrix_config.sv
// 功能   : 验证 key_event_decoder 的 MATRIX_MODE=1（矩阵选根音/音区）：
//     1. K0~K11 只更新 base_note，不产生 NOTE_ON
//     2. 八度 K13/K15 改变 base_note
//     3. K14 切换波形
//     4. K12 仍产生 ALL_NOTES_OFF
//
// MATRIX_MODE=0 的“矩阵当键盘”行为由 tb_input_top 覆盖。
//=============================================================================
`timescale 1ns/1ps

module tb_matrix_config;

    logic       clk = 1'b0;
    logic       rst_n = 1'b0;

    logic [15:0] key_pressed = '0;
    logic [15:0] key_released = '0;
    logic [15:0] key_down = '0;
    logic [7:0]  velocity_in = 8'd128;

    logic        event_req_valid;
    logic        event_req_ready = 1'b1;
    logic [1:0]  event_req_type;
    logic [6:0]  event_req_note;
    logic [7:0]  event_req_velocity;

    logic signed [3:0] octave_offset;
    logic [1:0] waveform_sel;
    logic [6:0] base_note;
    logic [15:0] active_note_mask;

    int errors = 0;
    int ev_count = 0;
    logic [1:0] evt_type [0:15];
    logic [6:0] evt_note [0:15];

    always #5 clk = ~clk;

    key_event_decoder #(
        .KEY_COUNT      (16),
        .NOTE_KEY_COUNT (12),
        .BASE_NOTE      (7'd60),
        .MATRIX_MODE    (1)
    ) dut (
        .sys_clk            (clk),
        .rst_n              (rst_n),
        .key_pressed        (key_pressed),
        .key_released       (key_released),
        .key_down           (key_down),
        .velocity_in        (velocity_in),
        .event_req_valid    (event_req_valid),
        .event_req_ready    (event_req_ready),
        .event_req_type     (event_req_type),
        .event_req_note     (event_req_note),
        .event_req_velocity (event_req_velocity),
        .octave_offset      (octave_offset),
        .waveform_sel       (waveform_sel),
        .base_note          (base_note),
        .active_note_mask   (active_note_mask)
    );

    //-------------------------------------------------------------------------
    // 事件监视器
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && event_req_valid && event_req_ready) begin
            evt_type[ev_count] = event_req_type;
            evt_note[ev_count] = event_req_note;
            $display("[%0t] EVENT #%0d type=%0d note=%0d",
                     $time, ev_count, event_req_type, event_req_note);
            ev_count++;
        end
    end

    //-------------------------------------------------------------------------
    // 按键任务
    //-------------------------------------------------------------------------
    task automatic press_key(input int idx);
        @(negedge clk);
        key_down[idx]    = 1'b1;
        key_pressed[idx] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        key_pressed[idx] = 1'b0;
    endtask

    task automatic release_key(input int idx);
        @(negedge clk);
        key_down[idx]    = 1'b0;
        key_released[idx] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        key_released[idx] = 1'b0;
    endtask

    task automatic check_base(input logic [6:0] exp, input string msg);
        if (base_note !== exp) begin
            $display("FAIL [%s]: base_note=%0d, expected %0d",
                     msg, base_note, exp);
            errors++;
        end else begin
            $display("PASS [%s]: base_note=%0d", msg, base_note);
        end
    endtask

    task automatic check_no_event(input string msg);
        if (event_req_valid !== 1'b0) begin
            $display("FAIL [%s]: unexpected event type=%0d note=%0d",
                     msg, event_req_type, event_req_note);
            errors++;
        end else begin
            $display("PASS [%s]: no NOTE_ON", msg);
        end
    endtask

    //-------------------------------------------------------------------------
    // 主测试
    //-------------------------------------------------------------------------
    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        check_base(7'd60, "reset root C4");
        check_no_event("reset");

        //---------------------------------------------------------------------
        // K2 -> D4 (62)，不发声
        //---------------------------------------------------------------------
        press_key(2);
        repeat (2) @(posedge clk);
        check_base(7'd62, "K2 selects D4");
        check_no_event("K2 config only");
        release_key(2);
        repeat (2) @(posedge clk);
        check_no_event("K2 release");

        //---------------------------------------------------------------------
        // K13 -> 八度 +1，根音 D5 = 74
        //---------------------------------------------------------------------
        press_key(13);
        release_key(13);
        repeat (2) @(posedge clk);
        if (octave_offset !== 4'sd1) begin
            $display("FAIL: octave_offset=%0d, expected +1", octave_offset);
            errors++;
        end
        check_base(7'd74, "octave +1 root D5");
        check_no_event("octave key");

        //---------------------------------------------------------------------
        // K0 -> 根音 C5 = 72
        //---------------------------------------------------------------------
        press_key(0);
        release_key(0);
        repeat (2) @(posedge clk);
        check_base(7'd72, "K0 at octave +1 -> C5");
        check_no_event("K0 config only");

        //---------------------------------------------------------------------
        // K15 -> 八度 -1，根音 C4 = 60
        //---------------------------------------------------------------------
        press_key(15);
        release_key(15);
        repeat (2) @(posedge clk);
        if (octave_offset !== 4'sd0) begin
            $display("FAIL: octave_offset=%0d, expected 0", octave_offset);
            errors++;
        end
        check_base(7'd60, "octave back to 0");

        //---------------------------------------------------------------------
        // K14 -> 波形 0 -> 1
        //---------------------------------------------------------------------
        press_key(14);
        release_key(14);
        repeat (2) @(posedge clk);
        if (waveform_sel !== 2'b01) begin
            $display("FAIL: waveform_sel=%0d, expected 1", waveform_sel);
            errors++;
        end else begin
            $display("PASS: waveform_sel=1 after K14");
        end

        //---------------------------------------------------------------------
        // K12 -> ALL_NOTES_OFF
        //---------------------------------------------------------------------
        press_key(12);
        repeat (3) @(posedge clk);
        release_key(12);
        repeat (3) @(posedge clk);

        if (ev_count < 1) begin
            $display("FAIL: no ALL_NOTES_OFF event");
            errors++;
        end else if (evt_type[0] !== 2'b11) begin
            $display("FAIL: event0 type=%0d, expected ALL_OFF", evt_type[0]);
            errors++;
        end else begin
            $display("PASS: K12 produced ALL_NOTES_OFF");
        end

        if (errors == 0) begin
            $display("TEST PASSED: tb_matrix_config");
        end else begin
            $display("TEST FAILED: tb_matrix_config, %0d error(s)", errors);
        end
        $finish;
    end

    initial begin
        #50_000;
        $display("TEST TIMEOUT: tb_matrix_config");
        $finish;
    end

endmodule
