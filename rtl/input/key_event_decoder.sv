//=============================================================================
// 文件   : key_event_decoder.sv
// 功能   : 将消抖后的按键边沿翻译成标准演奏事件，并维护八度/波形状态。
// 说明   :
//   1. 音符键按下 -> NOTE_ON，释放 -> NOTE_OFF；释放使用按下时锁存的
//      note_id，因此中途切换八度也不会发错音。
//   2. ALL_NOTES_OFF 优先级最高：按下时清除尚未发出的普通事件，
//      并抑制当前按住音符键稍后产生的 NOTE_OFF。
//   3. 本模块每周期最多向 event_queue 提交一个事件；同一周期多键按下时
//      按键号从小到大依次送出（通过 pending 表自然实现）。
//   4. FSR 力度由外部在按下瞬间提供并在此锁存。
//=============================================================================
`include "project_params.svh"
`include "audio_defs.svh"

module key_event_decoder #(
    parameter integer     KEY_COUNT      = `KEY_COUNT,
    parameter integer     NOTE_KEY_COUNT = 12,
    parameter logic [6:0] BASE_NOTE      = `NOTE_BASE_C4,
    parameter logic [7:0] DEFAULT_VEL    = `DEFAULT_VELOCITY
)(
    input  logic                    sys_clk,
    input  logic                    rst_n,

    input  logic [KEY_COUNT-1:0]    key_pressed,
    input  logic [KEY_COUNT-1:0]    key_released,
    input  logic [KEY_COUNT-1:0]    key_down,
    input  logic [7:0]              velocity_in,

    // 事件请求（接 event_queue 写端口）
    output logic                    event_req_valid,
    input  logic                    event_req_ready,
    output logic [1:0]              event_req_type,
    output logic [6:0]              event_req_note,
    output logic [7:0]              event_req_velocity,

    // 表情状态
    output logic signed [3:0]       octave_offset,
    output logic [1:0]              waveform_sel,

    // 调试
    output logic [KEY_COUNT-1:0]    active_note_mask
);

    localparam integer IDX_W = (KEY_COUNT <= 1) ? 1 : $clog2(KEY_COUNT + 1);

    //-------------------------------------------------------------------------
    // 每个按键一个映射器；key_index 为常量，综合时会被优化成小表
    //-------------------------------------------------------------------------
    logic [6:0]  map_note        [KEY_COUNT];
    logic        map_is_note     [KEY_COUNT];
    logic        map_all_off     [KEY_COUNT];
    logic        map_wave        [KEY_COUNT];
    logic        map_oct_up      [KEY_COUNT];
    logic        map_oct_down    [KEY_COUNT];

    logic [KEY_COUNT-1:0] note_key_mask;
    logic [KEY_COUNT-1:0] all_off_mask;
    logic [KEY_COUNT-1:0] wave_mask;
    logic [KEY_COUNT-1:0] oct_up_mask;
    logic [KEY_COUNT-1:0] oct_down_mask;

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
    //-------------------------------------------------------------------------
    logic [KEY_COUNT-1:0] pend_valid;
    logic [1:0]           pend_type [KEY_COUNT];
    logic [6:0]           pend_note [KEY_COUNT];
    logic [7:0]           pend_vel  [KEY_COUNT];

    logic [KEY_COUNT-1:0] suppress_release;
    logic [6:0]           latched_note [KEY_COUNT];

    logic                 pend_all_off;
    logic [IDX_W-1:0]     event_req_sel;

    //-------------------------------------------------------------------------
    // 全局功能键（组合判断）
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
            // 1) 先处理握手清除，后面的新事件可覆盖同槽位（新事件优先）
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
                    latched_note[i] <= map_note[i];
                    pend_valid[i]   <= 1'b1;
                    pend_type[i]    <= `EVENT_NOTE_ON;
                    pend_note[i]    <= map_note[i];
                    pend_vel[i]     <= (velocity_in == 8'd0) ? DEFAULT_VEL
                                                             : velocity_in;
                end

                if (key_released[i] && map_is_note[i]) begin
                    if (suppress_release[i]) begin
                        suppress_release[i] <= 1'b0;
                    end else begin
                        pend_valid[i] <= 1'b1;
                        pend_type[i]  <= `EVENT_NOTE_OFF;
                        pend_note[i]  <= latched_note[i];
                        pend_vel[i]   <= 8'd0;
                    end
                end
            end

            //-----------------------------------------------------------------
            // 3) 八度 / 波形 / ALL_NOTES_OFF
            //-----------------------------------------------------------------
            if (press_oct_up && octave_offset < 4'sd2) begin
                octave_offset <= octave_offset + 4'sd1;
            end
            if (press_oct_down && octave_offset > -4'sd2) begin
                octave_offset <= octave_offset - 4'sd1;
            end
            if (press_wave) begin
                waveform_sel <= (waveform_sel == `WAVE_SAW) ? `WAVE_SINE
                                                            : waveform_sel + 1'b1;
            end

            // ALL_NOTES_OFF 最后执行，保证同周期普通事件被清除
            if (press_all_off) begin
                pend_all_off     <= 1'b1;
                pend_valid       <= '0;
                suppress_release <= (key_down | key_pressed) & note_key_mask;
            end
        end
    end

    //-------------------------------------------------------------------------
    // 事件选择：ALL_NOTES_OFF > 最小键号
    //-------------------------------------------------------------------------
    always_comb begin
        event_req_valid    = 1'b0;
        event_req_type     = `EVENT_NOP;
        event_req_note     = 7'd0;
        event_req_velocity = 8'd0;
        event_req_sel      = '0;

        if (pend_all_off) begin
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

    assign active_note_mask = key_down & note_key_mask;

endmodule
