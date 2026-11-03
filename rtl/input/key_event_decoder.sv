//=============================================================================
// 文件   : key_event_decoder.sv
// 归属   : 成员 2
// 功能   : 消抖后的按键状态 -> 演奏参数（根音 / 波形）+ 效果请求脉冲。
//
// 【第 2 轮的重大简化】
//   第 1 轮这个模块要把按键翻译成 NOTE_ON/NOTE_OFF/ALL_NOTES_OFF 事件，
//   所以内部有「每键 2 个待发槽位」的事件表、ALL_OFF 优先级、八度偏移……
//   第 2 轮起，**键盘只用来选根音 / 波形 / 效果，一个音符事件都不发**：
//
//     4x4 键盘  -> 根音 / 波形 / 效果（本模块）
//     5 路 FSR  -> NOTE_ON / NOTE_OFF（fsr_trigger，力度来自 FSR 电平）
//
//   于是整个待发事件表、ALL_NOTES_OFF 通路、八度概念全部删除。
//   本模块退化成"几个锁存寄存器 + 一个请求脉冲"，逻辑简单到不会出错。
//
// 【输出语义】
//   base_note        : 当前根音（= NOTE_BASE_C4 + 音级），供 fsr_trigger 采样。
//                      已经发出的音保持原音高（fsr_trigger 内部锁存），
//                      改根音只影响之后新触发的音。
//   waveform_sel     : 波形直选（不是循环！按一次锁定，长按不变）。
//   fx_req / fx_mode_req : 效果键按下时的单周期脉冲 + 目标模式，成对锁存，
//                      直接喂给 cfg_master。K15 不在此列（它是复用键）。
//
// 【为什么删掉八度】
//   9 个键直接选根音，音区由根音本身覆盖；想更高/更低直接换根音键。
//   octave_offset 端口与 +12*octave 项一并删除，base_note 只由音级决定。
//
// 【多键同按】
//   同一拍按下多个根音键 / 多个效果键时，**键号大的生效**（循环顺序决定）。
//   演奏时应只按一个；这种取舍只为让行为确定，不是缺陷。
//=============================================================================
import audio_defs_pkg::WAVE_SINE;

module key_event_decoder #(
    parameter integer     KEY_COUNT = project_params_pkg::KEY_COUNT,        // 16
    parameter logic [6:0] BASE_NOTE = project_params_pkg::NOTE_BASE_C4      // 60 (C4)
)(
    input  logic                 sys_clk,
    input  logic                 rst_n,          // 低有效，同步复位

    // 按键边沿（单周期脉冲）与稳定状态，来自 key_debounce
    input  logic [KEY_COUNT-1:0] key_pressed,    // 消抖后的按下脉冲
    input  logic [KEY_COUNT-1:0] key_down,       // 消抖后的电平

    //-------------------------------------------------------------------------
    // 演奏参数（给 expression_mapper / fsr_trigger）
    //-------------------------------------------------------------------------
    output logic [6:0]           base_note,      // 当前根音 MIDI 编号
    output logic [1:0]           waveform_sel,   // 0 正弦 / 1 管风琴 / 2 拨弦

    //-------------------------------------------------------------------------
    // 效果请求（给 cfg_master）—— 单周期脉冲 + 目标模式，成对出现
    //-------------------------------------------------------------------------
    output logic                 fx_req,
    output logic [1:0]           fx_mode_req,    // 0 旁路 / 1 延迟 / 2 合唱 / 3 混响

    //-------------------------------------------------------------------------
    // 调试
    //-------------------------------------------------------------------------
    output logic [3:0]           root_pitch_class, // 当前音级 0~11
    output logic [KEY_COUNT-1:0] active_root_mask  // 当前按住的根音键
);

    //-------------------------------------------------------------------------
    // 每个按键一个 note_map 实例
    //   key_index 是 generate 常量，综合后等价于一张小查找表。
    //-------------------------------------------------------------------------
    logic [3:0] map_pitch   [KEY_COUNT];
    logic [1:0] map_wave    [KEY_COUNT];
    logic [1:0] map_fx      [KEY_COUNT];
    logic       map_root    [KEY_COUNT];
    logic       map_wave_key[KEY_COUNT];
    logic       map_fx_key  [KEY_COUNT];

    genvar g;
    generate
        for (g = 0; g < KEY_COUNT; g++) begin : g_note_map
            note_map u_note_map (
                .key_index        (4'(g)),
                .is_root_key      (map_root[g]),
                .root_pitch_class (map_pitch[g]),
                .is_wave_key      (map_wave_key[g]),
                .wave_sel         (map_wave[g]),
                .is_fx_key        (map_fx_key[g]),
                .fx_mode          (map_fx[g]),
                .is_dual_key      ()            // K15 由 input_top 的 key_tap_hold 处理
            );
        end
    endgenerate

    //-------------------------------------------------------------------------
    // 状态
    //-------------------------------------------------------------------------
    logic [3:0] pitch_class_r;   // 当前根音音级
    logic [1:0] wave_r;          // 当前波形
    logic [1:0] fx_mode_r;       // 效果请求脉冲期间的目标模式
    logic       fx_req_r;        // 效果请求脉冲
    integer     root_calc;       // base_note 中间计算（用 integer 防止负值回绕）

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            pitch_class_r <= 4'd0;           // 默认 C
            wave_r        <= WAVE_SINE;      // 默认正弦
            fx_mode_r     <= 2'd0;           // 默认旁路
            fx_req_r      <= 1'b0;
        end else begin
            // 脉冲默认归零：只有下面条件成立的当拍才为 1
            fx_req_r <= 1'b0;

            //-----------------------------------------------------------------
            // 根音键：只改根音，不发任何事件
            //-----------------------------------------------------------------
            for (int i = 0; i < KEY_COUNT; i++) begin
                if (key_pressed[i] && map_root[i]) begin
                    pitch_class_r <= map_pitch[i];
                end
            end

            //-----------------------------------------------------------------
            // 波形键：直选锁定（不是循环，所以不需要上限比较）
            //-----------------------------------------------------------------
            for (int i = 0; i < KEY_COUNT; i++) begin
                if (key_pressed[i] && map_wave_key[i]) begin
                    wave_r <= map_wave[i];
                end
            end

            //-----------------------------------------------------------------
            // 效果键：脉冲 + 目标模式必须成对更新
            //   map_fx_key 对 K12/K13/K14 为 1，对 K15 为 0（K15 走 key_tap_hold）
            //-----------------------------------------------------------------
            for (int i = 0; i < KEY_COUNT; i++) begin
                if (key_pressed[i] && map_fx_key[i]) begin
                    fx_req_r  <= 1'b1;
                    fx_mode_r <= map_fx[i];
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // 根音编号：BASE_NOTE + 音级，限幅到 0~127
    //-------------------------------------------------------------------------
    always_comb begin
        root_calc = int'(BASE_NOTE) + int'(pitch_class_r);
        if (root_calc < 0) begin
            base_note = 7'd0;
        end else if (root_calc > 127) begin
            base_note = 7'd127;
        end else begin
            base_note = 7'(root_calc);
        end
    end

    //-------------------------------------------------------------------------
    // 当前按住的根音键掩码（调试用）
    //-------------------------------------------------------------------------
    logic [KEY_COUNT-1:0] root_mask;
    generate
        for (g = 0; g < KEY_COUNT; g++) begin : g_root_mask
            assign root_mask[g] = map_root[g];
        end
    endgenerate

    assign active_root_mask = key_down & root_mask;
    assign waveform_sel     = wave_r;
    assign fx_req           = fx_req_r;
    assign fx_mode_req      = fx_mode_r;
    assign root_pitch_class = pitch_class_r;

endmodule
