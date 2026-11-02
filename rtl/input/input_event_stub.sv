//=============================================================================
// 文件   : input_event_stub.sv
// 功能   : 无按键/无 ADC 时的固定演示事件源，用于成员 1/3 提前联调。
//
// 【为什么需要它】
//   成员 1 的 audio_core 和成员 3 的 I2S 可以不等真实按键/FSR 就开工：
//   把本模块产生的事件接到 audio_core，就能验证 4 路复音、ADSR、混音。
//
// 【输出协议】
//   与真实按键完全相同：event_valid/event_ready 握手，event_type 编码
//   来自 audio_defs.svh。未握手成功时，所有字段保持不变。
//
// 【时间轴】
//   内部用 1 ms tick 计时，序列项格式：
//     {time_ms[15:0], type[1:0], note[6:0], velocity[7:0]}
//   当前时刻 t_ms >= 表项时间且上游 ready 时，发出该事件。
//   同一时间戳的多个事件会背靠背连续发出（每拍一个）。
//
// 【test_pattern】
//   0 = 四音和弦 C4/E4/G4/C5（默认）
//   1 = 8 音琶音
//   2 = 单音重复（延迟测试）
//   3 = 多音 + ALL_NOTES_OFF 压力测试
//   切换 pattern 时不会撤销下游还没接收的事件：当前事件先送完，再补一个
//   ALL_NOTES_OFF 释放上一段序列的音符，然后从 0 ms 重新开始。
//
// 【重要】
//   成员 1 的 audio_core 内部也有 audio_test_source。上板时两套测试源
//   只能二选一：用本模块时 audio_core.test_mode 必须为 0。
//   本模块只产生事件，不产生 PCM，也不能绕过 audio_core。
//=============================================================================
import audio_defs_pkg::EVENT_NOP;
import audio_defs_pkg::EVENT_NOTE_ON;
import audio_defs_pkg::EVENT_NOTE_OFF;
import audio_defs_pkg::EVENT_ALL_NOTES_OFF;

module input_event_stub #(
    parameter integer SYS_CLK_HZ = project_params_pkg::SYS_CLK_HZ, // 系统时钟
    parameter logic [7:0] TEST_VELOCITY = 8'd180       // 默认测试力度
)(
    input  logic       sys_clk,
    input  logic       rst_n,

    // 测试序列选择
    input  logic [1:0] test_pattern,

    // 立即复位序列（由 input_top 在事件源切换时给出）
    //   只在“没有未接收事件”的时刻使用，避免撤销下游还没接收的事件。
    input  logic       restart,

    // 标准演奏事件输出
    output logic       event_valid,
    input  logic       event_ready,
    output logic [1:0] event_type,
    output logic [6:0] event_note_id,
    output logic [7:0] event_velocity
);

    //-------------------------------------------------------------------------
    // 1 ms 时基
    //   MS_DIV = 27e6/1000 = 27000 拍；ms_tick 每 27000 拍高 1 拍。
    //   仿真时把 SYS_CLK_HZ 调小，序列会跑得很快。
    //-------------------------------------------------------------------------
    localparam integer MS_DIV = (SYS_CLK_HZ / 1000 < 1) ? 1 : SYS_CLK_HZ / 1000;

    logic [15:0] ms_div;    // 分频计数器
    logic        ms_tick;   // 1 ms 脉冲

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
    //   entry = {time_ms[15:0], type[1:0], note[6:0], velocity[7:0]}  // 33 位
    //   位段：
    //     entry[32:17] = 绝对时间（ms）
    //     entry[16:15] = 事件类型
    //     entry[14:8]  = MIDI 音符
    //     entry[7:0]   = 力度
    //   seq_len 是当前 pattern 的序列长度（表项数），seq_idx 是当前项。
    //-------------------------------------------------------------------------
    logic [32:0] entry;
    logic [4:0]  seq_len;
    logic [4:0]  seq_idx;

    always_comb begin
        entry   = {16'd0, EVENT_NOP, 7'd0, 8'd0};
        seq_len = 5'd1;

        case (test_pattern)
            //-----------------------------------------------------------------
            // pattern 0：四音和弦
            //   100/200/300/400 ms 依次按下 C4/E4/G4/C5，
            //   1000~1300 ms 依次释放，1500 ms ALL_NOTES_OFF。
            //   用于验证 4 路复音和 ADSR。
            //-----------------------------------------------------------------
            2'd0: begin
                seq_len = 5'd9;
                case (seq_idx)
                    5'd0: entry = {16'd100,  EVENT_NOTE_ON,  7'd60, TEST_VELOCITY};
                    5'd1: entry = {16'd200,  EVENT_NOTE_ON,  7'd64, TEST_VELOCITY};
                    5'd2: entry = {16'd300,  EVENT_NOTE_ON,  7'd67, TEST_VELOCITY};
                    5'd3: entry = {16'd400,  EVENT_NOTE_ON,  7'd72, TEST_VELOCITY};
                    5'd4: entry = {16'd1000, EVENT_NOTE_OFF, 7'd60, 8'd0};
                    5'd5: entry = {16'd1100, EVENT_NOTE_OFF, 7'd64, 8'd0};
                    5'd6: entry = {16'd1200, EVENT_NOTE_OFF, 7'd67, 8'd0};
                    5'd7: entry = {16'd1300, EVENT_NOTE_OFF, 7'd72, 8'd0};
                    5'd8: entry = {16'd1500, EVENT_ALL_NOTES_OFF, 7'd0, 8'd0};
                    default: entry = {16'd1500, EVENT_ALL_NOTES_OFF, 7'd0, 8'd0};
                endcase
            end

            //-----------------------------------------------------------------
            // pattern 1：8 音琶音
            //   每 150 ms 上一个音，C4 到 C5；1550 ms 起依次释放。
            //-----------------------------------------------------------------
            2'd1: begin
                seq_len = 5'd16;
                case (seq_idx)
                    5'd0:  entry = {16'd100,  EVENT_NOTE_ON,  7'd60, TEST_VELOCITY};
                    5'd1:  entry = {16'd250,  EVENT_NOTE_ON,  7'd62, TEST_VELOCITY};
                    5'd2:  entry = {16'd400,  EVENT_NOTE_ON,  7'd64, TEST_VELOCITY};
                    5'd3:  entry = {16'd550,  EVENT_NOTE_ON,  7'd65, TEST_VELOCITY};
                    5'd4:  entry = {16'd700,  EVENT_NOTE_ON,  7'd67, TEST_VELOCITY};
                    5'd5:  entry = {16'd850,  EVENT_NOTE_ON,  7'd69, TEST_VELOCITY};
                    5'd6:  entry = {16'd1000, EVENT_NOTE_ON,  7'd71, TEST_VELOCITY};
                    5'd7:  entry = {16'd1150, EVENT_NOTE_ON,  7'd72, TEST_VELOCITY};
                    5'd8:  entry = {16'd1550, EVENT_NOTE_OFF, 7'd60, 8'd0};
                    5'd9:  entry = {16'd1700, EVENT_NOTE_OFF, 7'd62, 8'd0};
                    5'd10: entry = {16'd1850, EVENT_NOTE_OFF, 7'd64, 8'd0};
                    5'd11: entry = {16'd2000, EVENT_NOTE_OFF, 7'd65, 8'd0};
                    5'd12: entry = {16'd2150, EVENT_NOTE_OFF, 7'd67, 8'd0};
                    5'd13: entry = {16'd2300, EVENT_NOTE_OFF, 7'd69, 8'd0};
                    5'd14: entry = {16'd2450, EVENT_NOTE_OFF, 7'd71, 8'd0};
                    5'd15: entry = {16'd2600, EVENT_NOTE_OFF, 7'd72, 8'd0};
                    default: entry = {16'd2600, EVENT_NOTE_OFF, 7'd72, 8'd0};
                endcase
            end

            //-----------------------------------------------------------------
            // pattern 2：单音重复
            //   200 ms ON、400 ms OFF，用于测量按键/事件到音频的延迟。
            //-----------------------------------------------------------------
            2'd2: begin
                seq_len = 5'd6;
                case (seq_idx)
                    5'd0: entry = {16'd200,  EVENT_NOTE_ON,  7'd69, 8'd200};
                    5'd1: entry = {16'd400,  EVENT_NOTE_OFF, 7'd69, 8'd0};
                    5'd2: entry = {16'd700,  EVENT_NOTE_ON,  7'd72, 8'd220};
                    5'd3: entry = {16'd900,  EVENT_NOTE_OFF, 7'd72, 8'd0};
                    5'd4: entry = {16'd1200, EVENT_NOTE_ON,  7'd65, 8'd160};
                    5'd5: entry = {16'd1400, EVENT_NOTE_OFF, 7'd65, 8'd0};
                    default: entry = {16'd1400, EVENT_NOTE_OFF, 7'd65, 8'd0};
                endcase
            end

            //-----------------------------------------------------------------
            // pattern 3：多音 + ALL_NOTES_OFF 压力测试
            //   同一时间戳连续 4 个 NOTE_ON，随后 ALL_OFF；再重复一次。
            //   用于验证事件 FIFO 和 ALL_OFF 优先级。
            //-----------------------------------------------------------------
            default: begin
                seq_len = 5'd10;
                case (seq_idx)
                    5'd0: entry = {16'd100,  EVENT_NOTE_ON, 7'd60, 8'd180};
                    5'd1: entry = {16'd100,  EVENT_NOTE_ON, 7'd64, 8'd200};
                    5'd2: entry = {16'd100,  EVENT_NOTE_ON, 7'd67, 8'd220};
                    5'd3: entry = {16'd100,  EVENT_NOTE_ON, 7'd72, 8'd240};
                    5'd4: entry = {16'd600,  EVENT_ALL_NOTES_OFF, 7'd0, 8'd0};
                    5'd5: entry = {16'd900,  EVENT_NOTE_ON, 7'd60, 8'd180};
                    5'd6: entry = {16'd900,  EVENT_NOTE_ON, 7'd64, 8'd200};
                    5'd7: entry = {16'd900,  EVENT_NOTE_ON, 7'd67, 8'd220};
                    5'd8: entry = {16'd1200, EVENT_ALL_NOTES_OFF, 7'd0, 8'd0};
                    5'd9: entry = {16'd1500, EVENT_ALL_NOTES_OFF, 7'd0, 8'd0};
                    default: entry = {16'd1500, EVENT_ALL_NOTES_OFF, 7'd0, 8'd0};
                endcase
            end
        endcase
    end

    //-------------------------------------------------------------------------
    // 发送状态机
    //   - 每拍最多输出 1 个事件；
    //   - 未握手成功时 valid_r/字段保持不变：**不能**中止或改写下游还没接收
    //     的事件（评审清单第 6 项）；
    //   - test_pattern 变化不打断当前事件：先把手上的事件送完，再补一个
    //     ALL_NOTES_OFF 释放上一段序列留下的音符，然后从 0 ms 重新开始；
    //   - restart=1 由 input_top 在事件源切换时给出，此刻没有未接收事件，
    //     可以立即复位序列。
    //-------------------------------------------------------------------------
    logic [1:0]  pattern_d;   // 上一拍 pattern，用于检测切换
    logic [15:0] t_ms;        // 序列内部毫秒计数
    logic        valid_r;     // 输出事件有效
    logic [16:0] ev_r;        // {type[1:0], note[6:0], velocity[7:0]}
    logic        restart_req; // 有待执行的序列重启
    logic        alloff_r;    // 正在发送重启前的 ALL_NOTES_OFF

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            seq_idx     <= '0;
            pattern_d   <= test_pattern;
            t_ms        <= 16'd0;
            valid_r     <= 1'b0;
            ev_r        <= {EVENT_NOP, 7'd0, 8'd0};
            restart_req <= 1'b0;
            alloff_r    <= 1'b0;
        end else if (restart) begin
            // 立即复位：只在 input_top 完成“排空 + ALL_OFF”之后使用
            seq_idx     <= '0;
            pattern_d   <= test_pattern;
            t_ms        <= 16'd0;
            valid_r     <= 1'b0;
            ev_r        <= {EVENT_NOP, 7'd0, 8'd0};
            restart_req <= 1'b0;
            alloff_r    <= 1'b0;
        end else begin
            // pattern 变化：只记录请求，不打断正在等待握手的事件
            if (test_pattern != pattern_d) begin
                restart_req <= 1'b1;
            end

            if (ms_tick) begin
                t_ms <= t_ms + 1'b1;
            end

            if (valid_r && event_ready) begin
                // 握手成功：本事件完成
                valid_r <= 1'b0;
                if (alloff_r) begin
                    // ALL_NOTES_OFF 已送出 -> 现在真正重启序列
                    alloff_r    <= 1'b0;
                    restart_req <= 1'b0;
                    pattern_d   <= test_pattern;
                    seq_idx     <= '0;
                    t_ms        <= '0;
                end else if ((seq_idx + 1'b1) >= seq_len) begin
                    seq_idx <= '0;
                    t_ms    <= 16'd0;   // 整段循环
                end else begin
                    seq_idx <= seq_idx + 1'b1;
                end
            end else if (!valid_r) begin
                if (restart_req) begin
                    // 先发 ALL_NOTES_OFF，避免上一段序列的持续音留着
                    valid_r  <= 1'b1;
                    ev_r     <= {EVENT_ALL_NOTES_OFF, 7'd0, 8'd0};
                    alloff_r <= 1'b1;
                end else if (t_ms >= entry[32:17]) begin
                    // 时间到了就锁存下一条并置 valid
                    valid_r <= 1'b1;
                    ev_r    <= {entry[16:15], entry[14:8], entry[7:0]};
                end
            end
        end
    end

    assign event_valid    = valid_r;
    assign event_type     = ev_r[16:15];
    assign event_note_id  = ev_r[14:8];
    assign event_velocity = ev_r[7:0];

endmodule
