//=============================================================================
// 文件   : fsr_trigger.sv
// 归属   : 成员 2（交互输入与演奏事件模块）
// 功能   : 5 路 FSR 触发（无前端电路，FSR 直接接 ADS7830 通道）
//
// 【它在系统中的位置】
//
//   FSR 一端接 3.3V，另一端接 ADS7830 CH2~CH6（实测无需额外前端）
//                            │
//                            ▼
//                 本模块（阈值 / 迟滞 / 释放 / 事件）
//                            │
//                            ├─► NOTE_ON  + note_id + velocity
//                            └─► NOTE_OFF（电平释放判定）
//
// 【和旧压电方案的区别】
//   压电：尖峰只存在几 ms，必须硬件峰值保持 + 定时 NOTE_OFF；
//   FSR ：压力存在多久，电压就存在多久 → 可以直接判“按住 / 松开”，
//         不需要峰值保持、不需要放电 MOSFET、不需要钳位保护。
//
// 【每路生命周期】
//
//   ARMED ──(level >= THRESHOLD 且不是正在发声)──► ACTIVE
//                                                  │ 发 NOTE_ON，锁存 note/velocity
//     ▲                                            │
//     │                                            │ level < RELEASE_TH 连续 N 个样本
//     │                                            ▼
//     │                                       发 NOTE_OFF
//     │                                            │
//     └──── 物理松开(level < RELEASE_TH)且防重复窗口结束 ◄┘
//
//   关键约定（修复评审清单第 3、4 项）：
//   1. 防重复窗口到期**不再自动重新武装**。只要手指还压着（电平高于释放
//      阈值），armed 就保持 0，因此长按只产生一次 NOTE_ON。
//   2. 重新武装必须看到 level < RELEASE_TH，也就是必须真实松开。
//   3. ALL_NOTES_OFF 之后武装状态清零。若手指仍压着，下一个高电平样本
//      不会立刻重新发声，必须先松开再按下。
//   4. 触发时锁存 note_id，NOTE_OFF 用它。防重复窗口期间的重复电平
//      不会改写 note_latched，所以“长按中切换根音”不会漏发旧音符的 OFF。
//
//   兜底：ACTIVE 期间若长时间没有新样本（ADC 卡死 / 断线），
//         NOTE_OFF 定时器到期后强制发 NOTE_OFF，避免声部挂死。
//
// 【音符映射】五声音阶 +0/+2/+4/+7/+9
// 【事件仲裁】每拍最多 1 个事件，通道号小者优先（与 key_event_decoder 一致）
// 【待发槽位】每路 2 个：NOTE_ON 还没被接收时到来的 NOTE_OFF 不会被覆盖。
//=============================================================================
import audio_defs_pkg::EVENT_NOP;
import audio_defs_pkg::EVENT_NOTE_ON;
import audio_defs_pkg::EVENT_NOTE_OFF;

module fsr_trigger #(
    parameter integer     NUM_TRIG        = project_params_pkg::TRIGGER_COUNT,
    parameter integer     SYS_CLK_HZ      = project_params_pkg::SYS_CLK_HZ,
    parameter logic [7:0] THRESHOLD       = project_params_pkg::TRIGGER_THRESHOLD,
    parameter integer     RELEASE_HYST    = project_params_pkg::TRIGGER_RELEASE_HYST,
    parameter integer     RELEASE_SAMPLES = project_params_pkg::TRIGGER_RELEASE_SAMPLES,
    parameter integer     RETRIGGER_MS    = project_params_pkg::TRIGGER_RETRIGGER_MS,
    parameter integer     NOTE_OFF_MS     = project_params_pkg::TRIGGER_NOTE_OFF_MS,
    parameter logic [7:0] VEL_FULL_SCALE  = project_params_pkg::TRIGGER_VEL_FULL_SCALE,
    parameter integer     NOTE_W          = project_params_pkg::NOTE_W
)(
    input  logic                    sys_clk,
    input  logic                    rst_n,

    //-------------------------------------------------------------------------
    // ADC 样本流（来自 adc_ads7830，所有通道共用）
    //-------------------------------------------------------------------------
    input  logic                    sample_valid,   // 单周期有效
    input  logic [2:0]              sample_channel, // 本次样点通道
    input  logic [7:0]              sample_data,    // 8 位 ADC 值
    input  logic [2:0]              trig_ch_base,   // P0 所在通道（默认 CH2）

    //-------------------------------------------------------------------------
    // 当前根音（含八度），来自 key_event_decoder
    //-------------------------------------------------------------------------
    input  logic [NOTE_W-1:0]       base_note,

    //-------------------------------------------------------------------------
    // ALL_NOTES_OFF：清掉所有活跃触发和待发事件
    //-------------------------------------------------------------------------
    input  logic                    all_off,

    //-------------------------------------------------------------------------
    // 事件请求（接 input_top 的事件仲裁器）
    //-------------------------------------------------------------------------
    output logic                    event_req_valid,
    input  logic                    event_req_ready,
    output logic [1:0]              event_req_type,
    output logic [NOTE_W-1:0]       event_req_note,
    output logic [7:0]              event_req_velocity,

    //-------------------------------------------------------------------------
    // 调试
    //-------------------------------------------------------------------------
    output logic [NUM_TRIG-1:0]     hit_debug,    // 当前电平是否超过阈值
    output logic [NUM_TRIG-1:0]     active_debug, // 是否正在发声
    output logic [NUM_TRIG*8-1:0]   level_debug,  // 每路最近一次 ADC 电平（打包）
    output logic                    event_overflow // 待发槽位溢出（粘滞，需复位）
);

    //-------------------------------------------------------------------------
    // 参数换算
    //-------------------------------------------------------------------------
    // 释放阈值：比触发阈值低 RELEASE_HYST，形成迟滞，防止临界抖动
    localparam integer RELEASE_TH = (int'(THRESHOLD) > RELEASE_HYST)
                                    ? (int'(THRESHOLD) - RELEASE_HYST) : 1;
    // 释放需要连续多少个样本低于阈值
    localparam integer REL_SAMP   = (RELEASE_SAMPLES < 1) ? 1 : RELEASE_SAMPLES;
    // 定时器周期数（至少 1，避免零长度定时器）
    localparam integer RETRIG_CYC = (SYS_CLK_HZ / 1000) * RETRIGGER_MS;
    localparam integer OFF_CYC    = (SYS_CLK_HZ / 1000) * NOTE_OFF_MS;
    localparam integer RETRIG_MAX = (RETRIG_CYC < 1) ? 1 : RETRIG_CYC;
    localparam integer OFF_MAX    = (OFF_CYC    < 1) ? 1 : OFF_CYC;

    localparam integer SAMP_W = $clog2(REL_SAMP + 1);
    localparam integer RT_W   = $clog2(RETRIG_MAX + 1);
    localparam integer OFF_W  = $clog2(OFF_MAX + 1);
    localparam integer IDX_W  = (NUM_TRIG <= 1) ? 1 : $clog2(NUM_TRIG + 1);

    //-------------------------------------------------------------------------
    // 每路状态（每个数组都会展开成 NUM_TRIG 份寄存器）
    //-------------------------------------------------------------------------
    logic [NUM_TRIG-1:0] armed;        // 1=可以触发
    logic [NUM_TRIG-1:0] active_q;     // 1=该路正在发声

    logic [NOTE_W-1:0]   note_latched [NUM_TRIG]; // 触发时锁存的音符
    logic [7:0]          last_raw     [NUM_TRIG]; // 最近一次 ADC 电平（调试/迟滞）
    logic [SAMP_W-1:0]   rel_cnt      [NUM_TRIG]; // 释放确认计数（按样本递减）
    logic [RT_W-1:0]     retrig_timer [NUM_TRIG]; // 防重复触发倒计时（按拍递减）
    logic [OFF_W-1:0]    off_timer    [NUM_TRIG]; // 兜底 NOTE_OFF 倒计时（按拍递减）

    //-------------------------------------------------------------------------
    // 待发事件表：每路 2 个槽位的小队列
    //
    //   只有一个槽位时，“NOTE_ON 还没被下游接收，紧接着松手产生 NOTE_OFF”
    //   会把 NOTE_ON 直接覆盖掉：已经发声的音符永远收不到 OFF（持续音）。
    //   这里每路保留 2 个槽位，p0 是更早的事件，p1 是后来的事件。
    //   仍然溢出（同路短时间 3 个事件未被接收）时置 event_overflow，
    //   不静默篡改已经排队的事件。
    //-------------------------------------------------------------------------
    localparam integer EV_W = 2 + NOTE_W + 8;   // {type, note, velocity}

    logic [NUM_TRIG-1:0] p0_valid;
    logic [NUM_TRIG-1:0] p1_valid;
    logic [EV_W-1:0]     p0_ev [NUM_TRIG];
    logic [EV_W-1:0]     p1_ev [NUM_TRIG];

    logic [NUM_TRIG-1:0] pop_mask;   // 本拍被下游取走的通道
    logic                ovf_r;      // 槽位溢出标志（粘滞）

    logic [IDX_W-1:0]    sel;   // 0=无事件，1..NUM_TRIG=对应通道

    //-------------------------------------------------------------------------
    // 音符映射：五声音阶
    //   P0 +0, P1 +2, P2 +4, P3 +7, P4 +9，并限幅到 0~127
    //-------------------------------------------------------------------------
    function automatic logic [NOTE_W-1:0] calc_note(
        input integer            idx,
        input logic [NOTE_W-1:0] base
    );
        integer n;
        begin
            case (idx)
                0:       n = int'(base) + 0;
                1:       n = int'(base) + 2;
                2:       n = int'(base) + 4;
                3:       n = int'(base) + 7;
                default: n = int'(base) + 9;
            endcase

            if (n < 0) begin
                calc_note = '0;
            end else if (n > 127) begin
                calc_note = 7'd127;
            end else begin
                calc_note = NOTE_W'(n);
            end
        end
    endfunction

    //-------------------------------------------------------------------------
    // 力度映射：THRESHOLD..VEL_FULL_SCALE -> 1..255
    //   VEL_FULL_SCALE 用实测“重击时的 ADC 值”标定，保证力度能打满。
    //-------------------------------------------------------------------------
    function automatic logic [7:0] calc_velocity(input logic [7:0] level);
        integer span;
        integer d;
        begin
            span = int'(VEL_FULL_SCALE) - int'(THRESHOLD);
            if (span < 1) begin
                span = 1;
            end

            d = int'(level) - int'(THRESHOLD);
            if (d <= 0) begin
                calc_velocity = 8'd1;               // 阈值附近给最小力度
            end else if (d >= span) begin
                calc_velocity = 8'd255;             // 达到满量程
            end else begin
                calc_velocity = 8'((d * 255) / span);
            end
        end
    endfunction

    //-------------------------------------------------------------------------
    // 事件选择：通道号越小优先级越高
    //   倒序扫描 pending 表：越小的通道越晚赋值，最终拥有更高优先级。
    //   p0_ev 是寄存器，握手前字段天然稳定。
    //-------------------------------------------------------------------------
    always_comb begin
        event_req_valid    = 1'b0;
        event_req_type     = EVENT_NOP;
        event_req_note     = '0;
        event_req_velocity = 8'd0;
        sel                = '0;

        for (int i = NUM_TRIG - 1; i >= 0; i--) begin
            if (p0_valid[i]) begin
                event_req_valid    = 1'b1;
                {event_req_type, event_req_note, event_req_velocity} = p0_ev[i];
                sel                = IDX_W'(i + 1);
            end
        end
    end

    // 本拍被下游取走的通道（弹出一个槽位）
    always_comb begin
        pop_mask = '0;
        if (event_req_valid && event_req_ready && (sel != '0)) begin
            pop_mask[sel - 1'b1] = 1'b1;
        end
    end

    //-------------------------------------------------------------------------
    // 把事件压入第 ch 路的 2 槽位队列
    //   同一拍该路可能正好弹出一个槽位（pop_mask[ch]），可用性按弹出后计算。
    //   每路每拍最多压入一个事件（触发 / 释放 / 兜底 OFF 三条路径互斥）。
    //-------------------------------------------------------------------------
    task automatic push_event(input int ch, input logic [1:0] t,
                              input logic [NOTE_W-1:0] n, input logic [7:0] v);
        if (pop_mask[ch]) begin
            // 弹出后 p0 会被旧 p1 填充；只有旧 p1 也空时 p0 才可用
            if (!p1_valid[ch]) begin
                p0_valid[ch] <= 1'b1;
                p0_ev[ch]    <= {t, n, v};
            end else begin
                p1_valid[ch] <= 1'b1;
                p1_ev[ch]    <= {t, n, v};
            end
        end else if (!p0_valid[ch]) begin
            p0_valid[ch] <= 1'b1;
            p0_ev[ch]    <= {t, n, v};
        end else if (!p1_valid[ch]) begin
            p1_valid[ch] <= 1'b1;
            p1_ev[ch]    <= {t, n, v};
        end else begin
            // 两个槽位都满：宁可丢新事件也要保住在队事件，同时报溢出
            ovf_r <= 1'b1;
        end
    endtask

    //-------------------------------------------------------------------------
    // 主状态机
    //-------------------------------------------------------------------------
    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            armed      <= {NUM_TRIG{1'b1}};   // 上电即可触发
            active_q   <= '0;
            p0_valid   <= '0;
            p1_valid   <= '0;
            ovf_r      <= 1'b0;
            for (int i = 0; i < NUM_TRIG; i++) begin
                p0_ev[i]        <= '0;
                p1_ev[i]        <= '0;
                note_latched[i] <= '0;
                last_raw[i]     <= 8'd0;
                rel_cnt[i]      <= '0;
                retrig_timer[i] <= '0;
                off_timer[i]    <= '0;
            end
        end else begin
            //-----------------------------------------------------------------
            // 1) 先处理握手弹出：p1 -> p0，并清空 p1
            //    后面的新事件写在同一拍时会覆盖这里的赋值（新事件优先）
            //-----------------------------------------------------------------
            for (int i = 0; i < NUM_TRIG; i++) begin
                if (pop_mask[i]) begin
                    p0_valid[i] <= p1_valid[i];
                    p0_ev[i]    <= p1_ev[i];
                    p1_valid[i] <= 1'b0;
                end
            end

            //-----------------------------------------------------------------
            // 2) 每路定时器
            //-----------------------------------------------------------------
            for (int i = 0; i < NUM_TRIG; i++) begin
                // 防重复触发窗口：到期后**只有在手指已经松开时**才重新武装
                if (retrig_timer[i] != '0) begin
                    retrig_timer[i] <= retrig_timer[i] - 1'b1;
                    if ((retrig_timer[i] == 1) && !active_q[i] &&
                        (last_raw[i] < 8'(RELEASE_TH))) begin
                        armed[i] <= 1'b1;
                    end
                end

                // 兜底 NOTE_OFF：长时间没有新样本时强制释放
                //   如果本拍刚到该通道的样本，交给第 3 步处理，避免重复发 OFF
                if ((off_timer[i] != '0) && !(sample_valid &&
                    (sample_channel == 3'(trig_ch_base + 3'(i))))) begin
                    off_timer[i] <= off_timer[i] - 1'b1;
                    if ((off_timer[i] == 1) && active_q[i]) begin
                        push_event(i, EVENT_NOTE_OFF, note_latched[i], 8'd0);
                        active_q[i] <= 1'b0;
                        rel_cnt[i]  <= '0;
                    end
                end
            end

            //-----------------------------------------------------------------
            // 3) 处理本拍 ADC 样点
            //    trig_ch_base + i 对应第 i 路触发输入
            //-----------------------------------------------------------------
            if (sample_valid) begin
                for (int i = 0; i < NUM_TRIG; i++) begin
                    if (sample_channel == 3'(trig_ch_base + 3'(i))) begin
                        last_raw[i] <= sample_data;

                        if (armed[i] && !active_q[i] &&
                            (sample_data >= THRESHOLD)) begin
                            // 触发：锁存音符/力度，启动释放判定和防重复窗口
                            note_latched[i] <= calc_note(i, base_note);

                            push_event(i, EVENT_NOTE_ON,
                                       calc_note(i, base_note),
                                       calc_velocity(sample_data));

                            active_q[i]     <= 1'b1;
                            armed[i]        <= 1'b0;
                            rel_cnt[i]      <= SAMP_W'(REL_SAMP);
                            off_timer[i]    <= OFF_W'(OFF_MAX);
                            retrig_timer[i] <= RT_W'(RETRIG_MAX);
                        end else if (active_q[i]) begin
                            if (sample_data >= 8'(RELEASE_TH)) begin
                                // 仍按住：重置释放计数和兜底定时
                                rel_cnt[i]   <= SAMP_W'(REL_SAMP);
                                off_timer[i] <= OFF_W'(OFF_MAX);
                            end else if (rel_cnt[i] <= 1) begin
                                // 连续 N 个样本低于释放阈值：松开
                                push_event(i, EVENT_NOTE_OFF,
                                           note_latched[i], 8'd0);
                                active_q[i]  <= 1'b0;
                                rel_cnt[i]   <= '0;
                                off_timer[i] <= '0;
                                // 物理已松开：防重复窗口若已结束，立刻重新武装
                                armed[i]     <= (retrig_timer[i] == '0);
                            end else begin
                                rel_cnt[i] <= rel_cnt[i] - 1'b1;
                            end
                        end else if (!armed[i] && (sample_data < 8'(RELEASE_TH))
                                     && (retrig_timer[i] == '0)) begin
                            // 已经真实松开且窗口结束：重新武装。
                            // 这一条同时覆盖“ALL_NOTES_OFF 之后仍按住”的情况：
                            // 手指不松开就不会重新武装。
                            armed[i] <= 1'b1;
                        end
                    end
                end
            end

            //-----------------------------------------------------------------
            // 4) ALL_NOTES_OFF 最后执行：清活跃状态和待发事件
            //    armed 只对“正在发声”的通道清零，也就是要求它先松开；
            //    空闲通道保持武装，否则 all_off 之后第一下按压会被漏掉。
            //    绝不能把所有 armed 置 1 —— 那样仍按住的手指会立刻
            //    产生新的 NOTE_ON，静音状态保持不住。
            //-----------------------------------------------------------------
            if (all_off) begin
                p0_valid   <= '0;
                p1_valid   <= '0;
                armed      <= ~active_q;
                active_q   <= '0;
                for (int i = 0; i < NUM_TRIG; i++) begin
                    off_timer[i]    <= '0;
                    retrig_timer[i] <= '0;
                    rel_cnt[i]      <= '0;
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // 调试输出
    //-------------------------------------------------------------------------
    always_comb begin
        for (int i = 0; i < NUM_TRIG; i++) begin
            hit_debug[i]              = (last_raw[i] >= THRESHOLD);
            level_debug[i*8 +: 8]     = last_raw[i];
        end
    end

    assign active_debug   = active_q;
    assign event_overflow = ovf_r;

endmodule
