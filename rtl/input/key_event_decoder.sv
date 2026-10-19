//=============================================================================
// 文件   : key_event_decoder.sv
// 功能   : 将消抖后的按键边沿翻译成标准演奏事件，并维护八度/波形状态。
//
// 【输入】
//   key_pressed / key_released : key_debounce 输出的单周期边沿
//   key_down                   : 当前稳定按下状态（用于 ALL_OFF 抑制）
//   velocity_in                : 当前 FSR 力度（按下瞬间锁存）
//
// 【内部结构：两阶段】
//
//   阶段 1：事件生成（always_ff）
//     把每个按键边沿写进“每键一个槽位”的 pending 表。
//     同一拍多个键按下也不会互相覆盖，因为每个键有自己的槽位。
//
//   阶段 2：事件选择（always_comb）
//     每拍从 pending 表里选一个事件送到 event_queue。
//     优先级：ALL_NOTES_OFF > 最小键号。
//     选中事件握手成功后，下一拍清除对应槽位。
//
// 【为什么释放要锁存 note_id】
//   按住 K0（C4）后把八度 +1，再释放 K0。如果释放时重新查表，
//   会得到 C5 的 NOTE_OFF，而 C4 永远收不到 OFF。因此按下时把
//   note_id 存进 latched_note[]，释放时用它。
//
// 【ALL_NOTES_OFF】
//   1. 优先级最高；
//   2. 按下时清空所有待发普通事件；
//   3. 对当前按住的音符键置 suppress_release，避免它们稍后释放时
//      又发出 NOTE_OFF。
//
// 【重要】
//   本模块每拍最多输出 1 个事件；多键同时按下时会按键号从小到大
//   依次送出。下游若长时间不 ready，槽位可能被后来的同键事件覆盖，
//   这属于 FIFO 溢出前的极端情况，可用 input_overflow 监控。
//=============================================================================
`include "project_params.svh"
`include "audio_defs.svh"

module key_event_decoder #(
    parameter integer     KEY_COUNT      = `KEY_COUNT,       // 按键数
    parameter integer     NOTE_KEY_COUNT = 12,               // 音符键数
    parameter logic [6:0] BASE_NOTE      = `NOTE_BASE_C4,    // K0 起始音
    parameter logic [7:0] DEFAULT_VEL    = `DEFAULT_VELOCITY // 力度缺失时的默认值
)(
    input  logic                    sys_clk,
    input  logic                    rst_n,

    // 按键边沿（单周期脉冲）与稳定状态
    input  logic [KEY_COUNT-1:0]    key_pressed,
    input  logic [KEY_COUNT-1:0]    key_released,
    input  logic [KEY_COUNT-1:0]    key_down,
    // 当前 FSR 力度，NOTE_ON 时锁存
    input  logic [7:0]              velocity_in,

    // 事件请求（接 event_queue 写端口）
    output logic                    event_req_valid,
    input  logic                    event_req_ready,
    output logic [1:0]              event_req_type,
    output logic [6:0]              event_req_note,
    output logic [7:0]              event_req_velocity,

    // 表情状态（送给 input_top 的表达式接口）
    output logic signed [3:0]       octave_offset, // -2~+2
    output logic [1:0]              waveform_sel,  // 0/1/2

    // 调试：当前按住的音符键
    output logic [KEY_COUNT-1:0]    active_note_mask
);

    // event_req_sel 需要能表示 0~KEY_COUNT；0 专门表示 ALL_OFF
    localparam integer IDX_W = (KEY_COUNT <= 1) ? 1 : $clog2(KEY_COUNT + 1);

    //-------------------------------------------------------------------------
    // 每个按键一个 note_map 实例
    //   key_index 是 generate 常量，综合后等价于一张小查找表。
    //   同时把各功能标志汇总成 16 位掩码，方便用位运算判断“哪类键被按了”。
    //-------------------------------------------------------------------------
    logic [6:0]  map_note        [KEY_COUNT];
    logic        map_is_note     [KEY_COUNT];
    logic        map_all_off     [KEY_COUNT];
    logic        map_wave        [KEY_COUNT];
    logic        map_oct_up      [KEY_COUNT];
    logic        map_oct_down    [KEY_COUNT];

    logic [KEY_COUNT-1:0] note_key_mask;   // 哪些键是音符键
    logic [KEY_COUNT-1:0] all_off_mask;    // 哪些键是 ALL_NOTES_OFF
    logic [KEY_COUNT-1:0] wave_mask;       // 哪些键是波形切换
    logic [KEY_COUNT-1:0] oct_up_mask;     // 哪些键是升八度
    logic [KEY_COUNT-1:0] oct_down_mask;   // 哪些键是降八度

    genvar g;
    generate
        for (g = 0; g < KEY_COUNT; g++) begin : g_note_map
            note_map #(
                .NOTE_KEY_COUNT (NOTE_KEY_COUNT),
                .BASE_NOTE      (BASE_NOTE)
            ) u_note_map (
                .key_index        (4'(g)),
                .octave_offset    (octave_offset),
                .is_note_key      (map_is_note[g]),
                .is_all_notes_off (map_all_off[g]),
                .is_waveform_key  (map_wave[g]),
                .is_octave_up     (map_oct_up[g]),
                .is_octave_down   (map_oct_down[g]),
                .note_id          (map_note[g])
            );

            assign note_key_mask[g] = map_is_note[g];
            assign all_off_mask[g]  = map_all_off[g];
            assign wave_mask[g]     = map_wave[g];
            assign oct_up_mask[g]   = map_oct_up[g];
            assign oct_down_mask[g] = map_oct_down[g];
        end
    endgenerate

    //-------------------------------------------------------------------------
    // 待发事件表：每个物理键一个槽位
    //   pend_valid[i] : 第 i 个键有事件待发
    //   pend_type/note/vel : 事件字段
    //   这样同一拍按下的多个键各自占一个槽位，不会互相覆盖。
    //-------------------------------------------------------------------------
    logic [KEY_COUNT-1:0] pend_valid;
    logic [1:0]           pend_type [KEY_COUNT];
    logic [6:0]           pend_note [KEY_COUNT];
    logic [7:0]           pend_vel  [KEY_COUNT];

    // ALL_OFF 后抑制这些键的释放事件
    logic [KEY_COUNT-1:0] suppress_release;
    // 按下时锁存的音符编号，释放时用它
    logic [6:0]           latched_note [KEY_COUNT];

    // ALL_NOTES_OFF 单独一个待发标志，拥有最高优先级
    logic                 pend_all_off;
    // 当前选中的槽位：0=ALL_OFF，1~KEY_COUNT=对应按键
    logic [IDX_W-1:0]     event_req_sel;

    //-------------------------------------------------------------------------
    // 全局功能键（组合判断）
    //   key_pressed 是 16 位单周期脉冲，与对应功能掩码按位与后再或归约，
    //   就得到“本拍是否按下了某类功能键”。
    //-------------------------------------------------------------------------
    logic press_all_off;
    logic press_wave;
    logic press_oct_up;
    logic press_oct_down;

    assign press_all_off  = |(key_pressed & all_off_mask);
    assign press_wave     = |(key_pressed & wave_mask);
    assign press_oct_up   = |(key_pressed & oct_up_mask);
    assign press_oct_down = |(key_pressed & oct_down_mask);

    //-------------------------------------------------------------------------
    // 状态更新
    //-------------------------------------------------------------------------
    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            pend_valid       <= '0;
            pend_all_off     <= 1'b0;
            suppress_release <= '0;
            octave_offset    <= 4'sd0;
            waveform_sel     <= `WAVE_SINE;
            for (int i = 0; i < KEY_COUNT; i++) begin
                pend_type[i]    <= `EVENT_NOP;
                pend_note[i]    <= 7'd0;
                pend_vel[i]     <= 8'd0;
                latched_note[i] <= 7'd0;
            end
        end else begin
            //-----------------------------------------------------------------
            // 1) 先处理握手清除
            //    如果本拍选中事件被 FIFO 接收，就清除对应槽位。
            //    清除写在前、新事件写在后：同一拍同槽位的新事件会覆盖清除，
            //    保证“新事件优先”。
            //-----------------------------------------------------------------
            if (event_req_valid && event_req_ready) begin
                if (event_req_sel == '0) begin
                    pend_all_off <= 1'b0;
                end else begin
                    pend_valid[event_req_sel-1] <= 1'b0;
                end
            end

            //-----------------------------------------------------------------
            // 2) 音符键按下/释放
            //-----------------------------------------------------------------
            for (int i = 0; i < KEY_COUNT; i++) begin
                if (key_pressed[i] && map_is_note[i]) begin
                    // 按下：锁存音符，填入 NOTE_ON 槽位
                    latched_note[i] <= map_note[i];
                    pend_valid[i]   <= 1'b1;
                    pend_type[i]    <= `EVENT_NOTE_ON;
                    pend_note[i]    <= map_note[i];
                    // velocity=0 会被成员 1 当作无声，这里兜底为默认力度
                    pend_vel[i]     <= (velocity_in == 8'd0) ? DEFAULT_VEL
                                                             : velocity_in;
                end

                if (key_released[i] && map_is_note[i]) begin
                    // 释放：如果该键被 ALL_OFF 抑制，就只清标志，不发 OFF
                    if (suppress_release[i]) begin
                        suppress_release[i] <= 1'b0;
                    end else begin
                        pend_valid[i] <= 1'b1;
                        pend_type[i]  <= `EVENT_NOTE_OFF;
                        pend_note[i]  <= latched_note[i]; // 用按下时锁存的音高
                        pend_vel[i]   <= 8'd0;
                    end
                end
            end

            //-----------------------------------------------------------------
            // 3) 八度 / 波形 / ALL_NOTES_OFF
            //-----------------------------------------------------------------
            if (press_oct_up && octave_offset < 4'sd2) begin
                octave_offset <= octave_offset + 4'sd1;   // 上限 +2
            end
            if (press_oct_down && octave_offset > -4'sd2) begin
                octave_offset <= octave_offset - 4'sd1;   // 下限 -2
            end
            if (press_wave) begin
                // 0 -> 1 -> 2 -> 0，3 保留
                waveform_sel <= (waveform_sel == `WAVE_SAW) ? `WAVE_SINE
                                                            : waveform_sel + 1'b1;
            end

            // ALL_NOTES_OFF 最后执行，保证同周期普通事件被清除：
            //   - 置 ALL_OFF 待发标志
            //   - 清空所有普通槽位
            //   - 把当前按住的音符键标记为“释放时不再发 OFF”
            if (press_all_off) begin
                pend_all_off     <= 1'b1;
                pend_valid       <= '0;
                suppress_release <= (key_down | key_pressed) & note_key_mask;
            end
        end
    end

    //-------------------------------------------------------------------------
    // 事件选择：ALL_NOTES_OFF > 最小键号
    //   倒序扫描 pending 表：越小的键号越晚赋值，最终拥有更高优先级。
    //   输出组合逻辑直接读取 pend_*，因此选中事件在握手前保持稳定。
    //-------------------------------------------------------------------------
    always_comb begin
        event_req_valid    = 1'b0;
        event_req_type     = `EVENT_NOP;
        event_req_note     = 7'd0;
        event_req_velocity = 8'd0;
        event_req_sel      = '0;

        if (pend_all_off) begin
            // ALL_OFF 最高优先级；sel=0 是它的专用编号
            event_req_valid = 1'b1;
            event_req_type  = `EVENT_ALL_NOTES_OFF;
            event_req_sel   = '0;
        end else begin
            // 倒序扫描，使最小键号拥有最高优先级
            for (int i = KEY_COUNT - 1; i >= 0; i--) begin
                if (pend_valid[i]) begin
                    event_req_valid    = 1'b1;
                    event_req_type     = pend_type[i];
                    event_req_note     = pend_note[i];
                    event_req_velocity = pend_vel[i];
                    event_req_sel      = IDX_W'(i + 1);
                end
            end
        end
    end

    // 当前真正按住的音符键（不含功能键）
    assign active_note_mask = key_down & note_key_mask;

endmodule
