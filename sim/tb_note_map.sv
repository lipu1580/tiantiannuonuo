//=============================================================================
// 文件   : tb_note_map.sv
// 功能   : 逐键核对第 2 轮键位表（16 个键，一个不漏）。
//
//   验收项 A1 / A3 / A4 的键位部分：
//     K0,K1,K2,K4,K5,K6,K8,K9,K10 -> 根音音级 0,1,2,4,5,6,8,9,10
//     K3,K7,K11                   -> 波形 0,1,2
//     K12,K13,K14                 -> 效果 0,1,3
//     K15                         -> is_dual_key（不是效果键！）
//=============================================================================
`timescale 1ns/1ps

module tb_note_map;

    logic [3:0] key_index;

    logic       is_root_key;
    logic [3:0] root_pitch_class;
    logic       is_wave_key;
    logic [1:0] wave_sel;
    logic       is_fx_key;
    logic [1:0] fx_mode;
    logic       is_dual_key;

    int errors = 0;
    int checks = 0;

    note_map dut (
        .key_index        (key_index),
        .is_root_key      (is_root_key),
        .root_pitch_class (root_pitch_class),
        .is_wave_key      (is_wave_key),
        .wave_sel         (wave_sel),
        .is_fx_key        (is_fx_key),
        .fx_mode          (fx_mode),
        .is_dual_key      (is_dual_key)
    );

    // 期望表
    logic [3:0] exp_root_pc [0:15];
    logic [1:0] exp_wave    [0:15];
    logic [1:0] exp_fx      [0:15];
    logic       exp_root_k  [0:15];
    logic       exp_wave_k  [0:15];
    logic       exp_fx_k    [0:15];
    logic       exp_dual_k  [0:15];

    task automatic check(input int k, input string tag);
        checks++;
        if (is_root_key !== exp_root_k[k] ||
            root_pitch_class !== exp_root_pc[k] ||
            is_wave_key !== exp_wave_k[k] ||
            wave_sel !== exp_wave[k] ||
            is_fx_key !== exp_fx_k[k] ||
            fx_mode !== exp_fx[k] ||
            is_dual_key !== exp_dual_k[k]) begin
            $display("FAIL K%-2d %-10s root=%0b(pc=%0d) wave=%0b(%0d) fx=%0b(%0d) dual=%0b",
                     k, tag,
                     is_root_key, root_pitch_class,
                     is_wave_key, wave_sel,
                     is_fx_key, fx_mode, is_dual_key);
            errors++;
        end else begin
            $display("PASS K%-2d %-10s root=%0b(pc=%0d) wave=%0b(%0d) fx=%0b(%0d) dual=%0b",
                     k, tag,
                     is_root_key, root_pitch_class,
                     is_wave_key, wave_sel,
                     is_fx_key, fx_mode, is_dual_key);
        end
    endtask

    initial begin
        // 全表先置"无功能"
        for (int i = 0; i < 16; i++) begin
            exp_root_k[i] = 1'b0;  exp_root_pc[i] = 4'd0;
            exp_wave_k[i] = 1'b0;  exp_wave[i]    = 2'd0;
            exp_fx_k[i]   = 1'b0;  exp_fx[i]      = 2'd0;
            exp_dual_k[i] = 1'b0;
        end

        // 根音：0,1,2 / 4,5,6 / 8,9,10
        exp_root_k[0]  = 1'b1; exp_root_pc[0]  = 4'd0;
        exp_root_k[1]  = 1'b1; exp_root_pc[1]  = 4'd1;
        exp_root_k[2]  = 1'b1; exp_root_pc[2]  = 4'd2;
        exp_root_k[4]  = 1'b1; exp_root_pc[4]  = 4'd4;
        exp_root_k[5]  = 1'b1; exp_root_pc[5]  = 4'd5;
        exp_root_k[6]  = 1'b1; exp_root_pc[6]  = 4'd6;
        exp_root_k[8]  = 1'b1; exp_root_pc[8]  = 4'd8;
        exp_root_k[9]  = 1'b1; exp_root_pc[9]  = 4'd9;
        exp_root_k[10] = 1'b1; exp_root_pc[10] = 4'd10;

        // 波形：3->0 正弦, 7->1 管风琴, 11->2 拨弦
        exp_wave_k[3]  = 1'b1; exp_wave[3]  = 2'd0;
        exp_wave_k[7]  = 1'b1; exp_wave[7]  = 2'd1;
        exp_wave_k[11] = 1'b1; exp_wave[11] = 2'd2;

        // 效果：12->0 旁路, 13->1 延迟, 14->3 混响（注意不是 2）
        exp_fx_k[12] = 1'b1; exp_fx[12] = 2'd0;
        exp_fx_k[13] = 1'b1; exp_fx[13] = 2'd1;
        exp_fx_k[14] = 1'b1; exp_fx[14] = 2'd3;

        // K15 复用键
        exp_dual_k[15] = 1'b1;

        $display("========================================");
        $display(" tb_note_map: 第 2 轮 16 键映射核对");
        $display("========================================");

        for (int k = 0; k < 16; k++) begin
            key_index = 4'(k);
            #1;
            check(k, "");
        end

        // K15 只能是复用键：不能同时被当成效果键/波形键/根音键
        //   （否则短按/长按逻辑会被"直接发合唱"抢先，K15 就失效了）
        key_index = 4'd15;
        #1;
        checks++;
        if (is_fx_key || is_wave_key || is_root_key) begin
            $display("FAIL: K15 必须只置 is_dual_key，实际 root=%0b wave=%0b fx=%0b",
                     is_root_key, is_wave_key, is_fx_key);
            errors++;
        end else begin
            $display("PASS: K15 只置 is_dual_key");
        end

        $display("========================================");
        if (errors == 0) begin
            $display("TEST PASSED: tb_note_map (%0d checks)", checks);
        end else begin
            $display("TEST FAILED: tb_note_map, %0d error(s)", errors);
        end
        $finish;
    end

endmodule
