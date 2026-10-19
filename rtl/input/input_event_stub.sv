//=============================================================================
// 文件   : input_event_stub.sv
// 功能   : 无按键/无 ADC 时的固定演示事件源，用于成员 1/3 提前联调。
// 说明   :
//   1. 严格遵守 event_valid/event_ready 握手；未握手成功时字段保持不变。
//   2. test_pattern 选择不同序列：
//        0 = 四音和弦（C4/E4/G4/C5），默认
//        1 = 音阶琶音
//        2 = 单音重复（延迟测试）
//        3 = ALL_NOTES_OFF 压力测试
//   3. 所有序列循环播放；切换 test_pattern 会从 0 ms 重新开始。
//   4. 本模块只产生事件，不产生 PCM，也不能绕过成员 1 的 audio_core。
//=============================================================================
`include "project_params.svh"
`include "audio_defs.svh"

module input_event_stub #(
    parameter integer SYS_CLK_HZ = `SYS_CLK_HZ,
    parameter logic [7:0] TEST_VELOCITY = 8'd180
)(
    input  logic       sys_clk,
    input  logic       rst_n,

    input  logic [1:0] test_pattern,

    output logic       event_valid,
    input  logic       event_ready,
    output logic [1:0] event_type,
    output logic [6:0] event_note_id,
    output logic [7:0] event_velocity
);

    //-------------------------------------------------------------------------
    // 1 ms 时基
    //-------------------------------------------------------------------------
    localparam integer MS_DIV = (SYS_CLK_HZ / 1000 < 1) ? 1 : SYS_CLK_HZ / 1000;

    logic [15:0] ms_div;
    logic        ms_tick;

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            ms_div  <= '0;
            ms_tick <= 1'b0;
        end else if (ms_div == 16'(MS_DIV - 1)) begin
            ms_div  <= '0;
            ms_tick <= 1'b1;
        end else begin
            ms_div  <= ms_div + 1'b1;
            ms_tick <= 1'b0;
        end
    end

    //-------------------------------------------------------------------------
    // 序列表
    // entry = {time_ms[15:0], type[1:0], note[6:0], velocity[7:0]}
    //-------------------------------------------------------------------------
    logic [32:0] entry;
    logic [4:0]  seq_len;
    logic [4:0]  seq_idx;

    always_comb begin
        entry   = {16'd0, `EVENT_NOP, 7'd0, 8'd0};
        seq_len = 5'd1;

        case (test_pattern)
            //-----------------------------------------------------------------
            2'd0: begin
                seq_len = 5'd9;
                case (seq_idx)
                    5'd0: entry = {16'd100,  `EVENT_NOTE_ON,  7'd60, TEST_VELOCITY};
                    5'd1: entry = {16'd200,  `EVENT_NOTE_ON,  7'd64, TEST_VELOCITY};
                    5'd2: entry = {16'd300,  `EVENT_NOTE_ON,  7'd67, TEST_VELOCITY};
                    5'd3: entry = {16'd400,  `EVENT_NOTE_ON,  7'd72, TEST_VELOCITY};
                    5'd4: entry = {16'd1000, `EVENT_NOTE_OFF, 7'd60, 8'd0};
                    5'd5: entry = {16'd1100, `EVENT_NOTE_OFF, 7'd64, 8'd0};
                    5'd6: entry = {16'd1200, `EVENT_NOTE_OFF, 7'd67, 8'd0};
                    5'd7: entry = {16'd1300, `EVENT_NOTE_OFF, 7'd72, 8'd0};
                    5'd8: entry = {16'd1500, `EVENT_ALL_NOTES_OFF, 7'd0, 8'd0};
                    default: entry = {16'd1500, `EVENT_ALL_NOTES_OFF, 7'd0, 8'd0};
                endcase
            end

            //-----------------------------------------------------------------
            2'd1: begin
                seq_len = 5'd16;
                case (seq_idx)
                    5'd0:  entry = {16'd100,  `EVENT_NOTE_ON,  7'd60, TEST_VELOCITY};
                    5'd1:  entry = {16'd250,  `EVENT_NOTE_ON,  7'd62, TEST_VELOCITY};
                    5'd2:  entry = {16'd400,  `EVENT_NOTE_ON,  7'd64, TEST_VELOCITY};
                    5'd3:  entry = {16'd550,  `EVENT_NOTE_ON,  7'd65, TEST_VELOCITY};
                    5'd4:  entry = {16'd700,  `EVENT_NOTE_ON,  7'd67, TEST_VELOCITY};
                    5'd5:  entry = {16'd850,  `EVENT_NOTE_ON,  7'd69, TEST_VELOCITY};
                    5'd6:  entry = {16'd1000, `EVENT_NOTE_ON,  7'd71, TEST_VELOCITY};
                    5'd7:  entry = {16'd1150, `EVENT_NOTE_ON,  7'd72, TEST_VELOCITY};
                    5'd8:  entry = {16'd1550, `EVENT_NOTE_OFF, 7'd60, 8'd0};
                    5'd9:  entry = {16'd1700, `EVENT_NOTE_OFF, 7'd62, 8'd0};
                    5'd10: entry = {16'd1850, `EVENT_NOTE_OFF, 7'd64, 8'd0};
                    5'd11: entry = {16'd2000, `EVENT_NOTE_OFF, 7'd65, 8'd0};
                    5'd12: entry = {16'd2150, `EVENT_NOTE_OFF, 7'd67, 8'd0};
                    5'd13: entry = {16'd2300, `EVENT_NOTE_OFF, 7'd69, 8'd0};
                    5'd14: entry = {16'd2450, `EVENT_NOTE_OFF, 7'd71, 8'd0};
                    5'd15: entry = {16'd2600, `EVENT_NOTE_OFF, 7'd72, 8'd0};
                    default: entry = {16'd2600, `EVENT_NOTE_OFF, 7'd72, 8'd0};
                endcase
            end

            //-----------------------------------------------------------------
            2'd2: begin
                seq_len = 5'd6;
                case (seq_idx)
                    5'd0: entry = {16'd200,  `EVENT_NOTE_ON,  7'd69, 8'd200};
                    5'd1: entry = {16'd400,  `EVENT_NOTE_OFF, 7'd69, 8'd0};
                    5'd2: entry = {16'd700,  `EVENT_NOTE_ON,  7'd72, 8'd220};
                    5'd3: entry = {16'd900,  `EVENT_NOTE_OFF, 7'd72, 8'd0};
                    5'd4: entry = {16'd1200, `EVENT_NOTE_ON,  7'd65, 8'd160};
                    5'd5: entry = {16'd1400, `EVENT_NOTE_OFF, 7'd65, 8'd0};
                    default: entry = {16'd1400, `EVENT_NOTE_OFF, 7'd65, 8'd0};
                endcase
            end

            //-----------------------------------------------------------------
            default: begin
                seq_len = 5'd10;
                case (seq_idx)
                    5'd0: entry = {16'd100,  `EVENT_NOTE_ON, 7'd60, 8'd180};
                    5'd1: entry = {16'd100,  `EVENT_NOTE_ON, 7'd64, 8'd200};
                    5'd2: entry = {16'd100,  `EVENT_NOTE_ON, 7'd67, 8'd220};
                    5'd3: entry = {16'd100,  `EVENT_NOTE_ON, 7'd72, 8'd240};
                    5'd4: entry = {16'd600,  `EVENT_ALL_NOTES_OFF, 7'd0, 8'd0};
                    5'd5: entry = {16'd900,  `EVENT_NOTE_ON, 7'd60, 8'd180};
                    5'd6: entry = {16'd900,  `EVENT_NOTE_ON, 7'd64, 8'd200};
                    5'd7: entry = {16'd900,  `EVENT_NOTE_ON, 7'd67, 8'd220};
                    5'd8: entry = {16'd1200, `EVENT_ALL_NOTES_OFF, 7'd0, 8'd0};
                    5'd9: entry = {16'd1500, `EVENT_ALL_NOTES_OFF, 7'd0, 8'd0};
                    default: entry = {16'd1500, `EVENT_ALL_NOTES_OFF, 7'd0, 8'd0};
                endcase
            end
        endcase
    end

    //-------------------------------------------------------------------------
    // 发送状态机
    //-------------------------------------------------------------------------
    logic [1:0]  pattern_d;
    logic [15:0] t_ms;
    logic        valid_r;
    logic [1:0]  type_r;
    logic [6:0]  note_r;
    logic [7:0]  vel_r;

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            seq_idx    <= '0;
            pattern_d  <= 2'd0;
            t_ms       <= 16'd0;
            valid_r    <= 1'b0;
            type_r     <= `EVENT_NOP;
            note_r     <= 7'd0;
            vel_r      <= 8'd0;
        end else if (test_pattern != pattern_d) begin
            pattern_d <= test_pattern;
            seq_idx   <= '0;
            t_ms      <= 16'd0;
            valid_r   <= 1'b0;
        end else begin
            if (ms_tick) begin
                t_ms <= t_ms + 1'b1;
            end

            if (valid_r && event_ready) begin
                valid_r <= 1'b0;
                if ((seq_idx + 1'b1) >= seq_len) begin
                    seq_idx <= '0;
                    t_ms    <= 16'd0;
                end else begin
                    seq_idx <= seq_idx + 1'b1;
                end
            end else if (!valid_r) begin
                if (t_ms >= entry[32:17]) begin
                    valid_r <= 1'b1;
                    type_r  <= entry[16:15];
                    note_r  <= entry[14:8];
                    vel_r   <= entry[7:0];
                end
            end
        end
    end

    assign event_valid    = valid_r;
    assign event_type     = type_r;
    assign event_note_id  = note_r;
    assign event_velocity = vel_r;

endmodule
