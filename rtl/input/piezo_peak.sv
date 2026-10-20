//=============================================================================
// 文件   : piezo_peak.sv
// 归属   : 成员 2（交互输入与演奏事件模块）
// 功能   : 5 路压电片峰值触发、力度映射、自动 NOTE_OFF、峰值电容放电。
//
// 【它在系统中的位置】
//
//   压电片 -> 保护/峰值保持(硬件) -> ADS7830 CH2~CH6
//                                      │
//                                      ▼
//                              本模块(峰值/阈值/事件)
//                                      │
//                                      ├─► NOTE_ON  + note_id + velocity
//                                      ├─► NOTE_OFF (定时自动)
//                                      └─► peak_rst[4:0] -> 2N7002 放电
//
// 【为什么需要峰值保持和本模块】
//   1. 压电片受迫产生的是微秒~毫秒级尖峰，ADS7830 是轮流采样，直接采会漏峰值。
//      硬件用 BAT85 + 100nF 把峰值保持住，本模块再慢慢读。
//   2. 压电片没有可靠的“松开”信号，所以 NOTE_OFF 必须由本模块定时产生。
//   3. 一次拨动可能产生多次振铃，必须用“防重复触发”窗口压住。
//
// 【每路的生命周期】
//
//   ARMED(可触发)
//      │ 采样到 peak >= THRESHOLD
//      ▼
//   NOTE_ON 入队 + 启动 NOTE_OFF 定时 + 启动防重复触发定时
//      │
//      ├─ 防重复触发定时到 -> 回到 ARMED（可以再次触发）
//      └─ NOTE_OFF 定时到 -> NOTE_OFF 入队
//
//   注意：如果 NOTE_OFF 定时还没到就再次触发，会重触发同一路，
//         更新 note_id / velocity，并重新开始 NOTE_OFF 定时。
//         成员 1 的 voice_manager 应把“同 note_id 的 NOTE_ON”当作重触发。
//
// 【音符映射】
//   P0 -> base_note + 0   (C)
//   P1 -> base_note + 2   (D)
//   P2 -> base_note + 4   (E)
//   P3 -> base_note + 7   (G)
//   P4 -> base_note + 9   (A)
//   即大调五声音阶。base_note 已包含当前八度。
//
// 【事件仲裁】
//   本模块每拍最多输出 1 个事件，按通道号从小到大优先。
//   与矩阵事件共用 event_queue 时，由 input_top 做仲裁：
//   ALL_NOTES_OFF 最高，其次是压电触发，最后是矩阵事件。
//
// 【硬件资源】
//   - 5 组 8 位峰值寄存器
//   - 5 组 NOTE_OFF / 防重复 / 放电定时器（约 5 x 56 bit）
//   - 5 个事件 pending 槽位
//   对 Tang Nano 20K 来说资源很小。
//=============================================================================
`include "project_params.svh"
`include "audio_defs.svh"

module piezo_peak #(
    // 固定 5 路压电。这里刻意不用 PIEZO_COUNT 作为参数名，
    // 因为 project_params.svh 里已有同名宏，预处理会冲突。
    parameter integer NUM_PIEZO         = 5,
    parameter integer SYS_CLK_HZ       = `SYS_CLK_HZ,           // 27 MHz
    parameter logic [7:0] THRESHOLD    = `PIEZO_THRESHOLD,      // 触发阈值
    parameter integer NOTE_OFF_MS      = `PIEZO_NOTE_OFF_MS,    // 自动 NOTE_OFF 时间
    parameter integer RETRIGGER_MS     = `PIEZO_RETRIGGER_MS,   // 防重复触发窗口
    parameter integer PEAK_RST_CYCLES  = `PIEZO_PEAK_RST_CYCLES,// 峰值电容放电脉冲
    parameter integer NOTE_W           = 7
)(
    input  logic                    sys_clk,
    input  logic                    rst_n,

    //-------------------------------------------------------------------------
    // ADC 样本流（来自 adc_ads7830，所有通道共用）
    //-------------------------------------------------------------------------
    input  logic                    sample_valid,      // 单周期有效
    input  logic [2:0]              sample_channel,    // 本次样点通道
    input  logic [7:0]              sample_data,       // 8 位 ADC 值
    input  logic [2:0]              piezo_ch_base,     // P0 所在通道（默认 CH2）

    //-------------------------------------------------------------------------
    // 当前根音（已包含八度），来自 key_event_decoder
    //-------------------------------------------------------------------------
    input  logic [NOTE_W-1:0]       base_note,

    //-------------------------------------------------------------------------
    // ALL_NOTES_OFF：清掉所有活跃压电音符和待发事件
    //-------------------------------------------------------------------------
    input  logic                    all_off,

    //-------------------------------------------------------------------------
    // 峰值保持电容放电：高有效，接 5 路 2N7002 栅极
    //-------------------------------------------------------------------------
    output logic [NUM_PIEZO-1:0]  peak_rst,

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
    output logic [NUM_PIEZO-1:0]  hit_debug,     // 峰值超过阈值
    output logic [NUM_PIEZO-1:0]  active_debug   // 正在发声
);

    //-------------------------------------------------------------------------
    // 时间参数换算
    //-------------------------------------------------------------------------
    localparam integer NOTE_OFF_CYCLES = (SYS_CLK_HZ / 1000) * NOTE_OFF_MS;
    localparam integer RETRIG_CYCLES   = (SYS_CLK_HZ / 1000) * RETRIGGER_MS;
    localparam integer OFF_W = (NOTE_OFF_CYCLES <= 1) ? 1 : $clog2(NOTE_OFF_CYCLES + 1);
    localparam integer RT_W  = (RETRIG_CYCLES   <= 1) ? 1 : $clog2(RETRIG_CYCLES   + 1);
    localparam integer RST_W = (PEAK_RST_CYCLES <= 1) ? 1 : $clog2(PEAK_RST_CYCLES + 1);
    localparam integer IDX_W = (NUM_PIEZO     <= 1) ? 1 : $clog2(NUM_PIEZO + 1);

    //-------------------------------------------------------------------------
    // 每路状态
    //-------------------------------------------------------------------------
    logic [NUM_PIEZO-1:0] armed;       // 1=可以触发
    logic [NUM_PIEZO-1:0] active_q;    // 1=该路正在发声

    logic [NOTE_W-1:0] note_latched [NUM_PIEZO]; // 触发时锁存的音符
    logic [OFF_W-1:0]  off_timer    [NUM_PIEZO]; // NOTE_OFF 倒计时
    logic [RT_W-1:0]   retrig_timer [NUM_PIEZO]; // 防重复触发倒计时
    logic [RST_W-1:0]  rst_timer    [NUM_PIEZO]; // 峰值放电倒计时
    logic [7:0]        peak_q       [NUM_PIEZO]; // 最近一次峰值（调试）

    //-------------------------------------------------------------------------
    // 待发事件表：每路一个槽位
    //-------------------------------------------------------------------------
    logic [NUM_PIEZO-1:0] pend_valid;
    logic [1:0]             pend_type [NUM_PIEZO];
    logic [NOTE_W-1:0]      pend_note [NUM_PIEZO];
    logic [7:0]             pend_vel  [NUM_PIEZO];

    logic [IDX_W-1:0]       sel;   // 0=无事件，1..NUM_PIEZO=对应通道

    //-------------------------------------------------------------------------
    // 音符映射函数：大调五声音阶
    //   P0 +0, P1 +2, P2 +4, P3 +7, P4 +9
    //-------------------------------------------------------------------------
    function automatic logic [NOTE_W-1:0] calc_note(
        input integer              idx,
        input logic [NOTE_W-1:0]   base
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
    // 力度映射函数：峰值 -> 1~255
    //   peak <= THRESHOLD        -> 1（理论上不会走到，因为不触发）
    //   peak >= 255              -> 255
    //   中间线性映射
    //-------------------------------------------------------------------------
    function automatic logic [7:0] calc_velocity(input logic [7:0] peak);
        integer d;
        integer span;
        begin
            span = 255 - int'(THRESHOLD);
            if (int'(peak) <= int'(THRESHOLD)) begin
                calc_velocity = 8'd1;
            end else begin
                d = int'(peak) - int'(THRESHOLD);
                if (d >= span) begin
                    calc_velocity = 8'd255;
                end else begin
                    calc_velocity = 8'((d * 255) / span);
                    if (calc_velocity == 8'd0) begin
                        calc_velocity = 8'd1;
                    end
                end
            end
        end
    endfunction

    //-------------------------------------------------------------------------
    // 事件选择：通道号越小优先级越高
    //   与 key_event_decoder 的实现方式一致：倒序扫描，最后赋值的是最小号。
    //-------------------------------------------------------------------------
    always_comb begin
        event_req_valid    = 1'b0;
        event_req_type     = `EVENT_NOP;
        event_req_note     = '0;
        event_req_velocity = 8'd0;
        sel                = '0;

        for (int i = NUM_PIEZO - 1; i >= 0; i--) begin
            if (pend_valid[i]) begin
                event_req_valid    = 1'b1;
                event_req_type     = pend_type[i];
                event_req_note     = pend_note[i];
                event_req_velocity = pend_vel[i];
                sel                = IDX_W'(i + 1);
            end
        end
    end

    //-------------------------------------------------------------------------
    // 峰值放电输出：定时器非 0 期间拉高
    //-------------------------------------------------------------------------
    always_comb begin
        for (int i = 0; i < NUM_PIEZO; i++) begin
            peak_rst[i] = (rst_timer[i] != '0);
        end
    end

    //-------------------------------------------------------------------------
    // 主状态机
    //-------------------------------------------------------------------------
    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            armed     <= {NUM_PIEZO{1'b1}};  // 上电即可触发
            active_q  <= '0;
            pend_valid <= '0;
            for (int i = 0; i < NUM_PIEZO; i++) begin
                note_latched[i] <= '0;
                off_timer[i]    <= '0;
                retrig_timer[i] <= '0;
                rst_timer[i]    <= '0;
                peak_q[i]       <= 8'd0;
                pend_type[i]    <= `EVENT_NOP;
                pend_note[i]    <= '0;
                pend_vel[i]     <= 8'd0;
            end
        end else begin
            //-----------------------------------------------------------------
            // 1) 先处理事件握手清除；后面的新事件可覆盖同槽位
            //-----------------------------------------------------------------
            if (event_req_valid && event_req_ready) begin
                if (sel != '0) begin
                    pend_valid[sel-1] <= 1'b0;
                end
            end

            //-----------------------------------------------------------------
            // 2) 每路定时器
            //-----------------------------------------------------------------
            for (int i = 0; i < NUM_PIEZO; i++) begin
                // 防重复触发：计时结束后重新允许触发
                if (retrig_timer[i] != '0) begin
                    retrig_timer[i] <= retrig_timer[i] - 1'b1;
                    if (retrig_timer[i] == 1) begin
                        armed[i] <= 1'b1;
                    end
                end

                // 自动 NOTE_OFF：计时结束时发 NOTE_OFF
                if (off_timer[i] != '0) begin
                    off_timer[i] <= off_timer[i] - 1'b1;
                    if ((off_timer[i] == 1) && active_q[i]) begin
                        pend_valid[i] <= 1'b1;
                        pend_type[i]  <= `EVENT_NOTE_OFF;
                        pend_note[i]  <= note_latched[i];
                        pend_vel[i]   <= 8'd0;
                        active_q[i]   <= 1'b0;
                    end
                end

                // 峰值放电定时器
                if (rst_timer[i] != '0) begin
                    rst_timer[i] <= rst_timer[i] - 1'b1;
                end
            end

            //-----------------------------------------------------------------
            // 3) 处理本拍 ADC 样点
            //    piezo_ch_base + i 对应第 i 路压电
            //-----------------------------------------------------------------
            if (sample_valid) begin
                for (int i = 0; i < NUM_PIEZO; i++) begin
                    if (sample_channel == 3'(piezo_ch_base + 3'(i))) begin
                        peak_q[i] <= sample_data;

                        // 读完峰值后给保持电容放电，为下一次触发做准备
                        rst_timer[i] <= RST_W'(PEAK_RST_CYCLES);

                        if (armed[i] && (sample_data >= THRESHOLD)) begin
                            // 触发：锁存音符/力度，启动 NOTE_OFF 和防重复定时
                            note_latched[i] <= calc_note(i, base_note);

                            pend_valid[i] <= 1'b1;
                            pend_type[i]  <= `EVENT_NOTE_ON;
                            pend_note[i]  <= calc_note(i, base_note);
                            pend_vel[i]   <= calc_velocity(sample_data);

                            active_q[i]     <= 1'b1;
                            off_timer[i]    <= OFF_W'(NOTE_OFF_CYCLES);
                            armed[i]        <= 1'b0;
                            retrig_timer[i] <= RT_W'(RETRIG_CYCLES);
                        end
                    end
                end
            end

            //-----------------------------------------------------------------
            // 4) ALL_NOTES_OFF 最后执行：清掉所有活跃状态和待发事件
            //-----------------------------------------------------------------
            if (all_off) begin
                active_q   <= '0;
                pend_valid <= '0;
                armed      <= {NUM_PIEZO{1'b1}};
                for (int i = 0; i < NUM_PIEZO; i++) begin
                    off_timer[i]    <= '0;
                    retrig_timer[i] <= '0;
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // 调试：峰值是否超过阈值
    //-------------------------------------------------------------------------
    always_comb begin
        for (int i = 0; i < NUM_PIEZO; i++) begin
            hit_debug[i] = (peak_q[i] >= THRESHOLD);
        end
    end

    assign active_debug = active_q;

endmodule
