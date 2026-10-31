//这个模块接受进来的是消抖模块处理过后的，从键盘输出出来的按键状态，以及FSR吧。这个模块要做的事就是把这个按键状态，转化为事件信息输出传出去，除了事件信息，还要传出去八度偏移值，当前根音。
//这件事情具体是怎么完成的呢？
//本模块内部有11个内部信号，在100行附近，其中有5个是键盘的逻辑分区的掩码，每个掩码都是16位但只有自己的逻辑分区那几位为1。
//紧接着我们引入了映射表note_map，并批量地将将0-15这16个按键都创建了各自的note_map，note_map是干什么的呢，它就是一个映射表，你告诉我你是第几个按键，我告诉你你这个物理位置上的按键在逻辑功能上是谁。在父模块中用上面说的内部信号中的另外6个来接收note_map映射后的结果，再传给mask，这时候，mask变得可用。

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
//   依次送出。每个键有 2 个待发槽位，所以“NOTE_ON 还没被下游接收就
//   松手”不会再丢掉 NOTE_ON；极端情况下同键短时间内积压 3 个事件才会
//   丢弃新事件并置 event_overflow（不静默覆盖已排队的事件）。
//
// 【MATRIX_MODE 两种模式】
//   0 = 矩阵当键盘（当前测试模式）：K0~K11 直接发 NOTE_ON/NOTE_OFF。
//   1 = 矩阵做配置（最终演奏模式）：K0~K11 只选择根音，不发 NOTE_ON；
//       5 片压电片负责触发，音符由 base_note + 五声音阶偏移得到。
//
// 【base_note】
//   当前根音（已包含八度），供 piezo_peak 计算压电音符：
//     base_note = clamp(BASE_NOTE + root_pitch_class + 12*octave_offset, 0, 127)
//   root_pitch_class 由 K0~K11 在 MATRIX_MODE=1 时更新：
//     K0 -> 0 (C), K1 -> 1 (C#), ... K11 -> 11 (B)
//=============================================================================
import audio_defs_pkg::EVENT_NOP;
import audio_defs_pkg::EVENT_NOTE_ON;
import audio_defs_pkg::EVENT_NOTE_OFF;
import audio_defs_pkg::EVENT_ALL_NOTES_OFF;
import audio_defs_pkg::WAVE_SINE;
import audio_defs_pkg::WAVE_SAWTOOTH;
import audio_defs_pkg::DEFAULT_VELOCITY;

module key_event_decoder #(
    parameter integer     KEY_COUNT      = project_params_pkg::KEY_COUNT,       // 按键数，此处为16
    parameter integer     NOTE_KEY_COUNT = 12,               // 音符/根音键数
    parameter logic [6:0] BASE_NOTE      = project_params_pkg::NOTE_BASE_C4,    // K0 起始音
    parameter logic [7:0] DEFAULT_VEL    = audio_defs_pkg::DEFAULT_VELOCITY,// 力度缺失时的默认值
    parameter integer     MATRIX_MODE    = 0,                // 0=键盘模式 1=配置模式
    // 波形键循环的上限：0 = 只有正弦（当前成员 1 的 waveform_rom 只实现正弦），
    // 1 = 正弦/方波，2 = 正弦/方波/锯齿。
    // 成员 1 的波表补平方波、锯齿后再把它改成 2，否则切到未实现的波形会静音。
    parameter logic [1:0] WAVEFORM_MAX_SEL = project_params_pkg::WAVEFORM_MAX_SEL
)(
    input  logic                    sys_clk,
    input  logic                    rst_n,

    // 按键边沿（单周期脉冲）与稳定状态
    input  logic [KEY_COUNT-1:0]    key_pressed,		//16位宽，是从上一个消抖模块出来的确定按下信号
    input  logic [KEY_COUNT-1:0]    key_released,
    input  logic [KEY_COUNT-1:0]    key_down,
    // 当前 FSR 力度，NOTE_ON 时锁存
    input  logic [7:0]              velocity_in,		//速度为8位，在最后的拼接打包数据的低八位

    // 事件请求（接 event_queue 写端口）
    output logic                    event_req_valid,	//我这里有事件要写
    input  logic                    event_req_ready,	//你那边队列能不能接收？准备好了没有？
    output logic [1:0]              event_req_type,		//事件类型
    output logic [6:0]              event_req_note,		//MIDI音高编号
    output logic [7:0]              event_req_velocity,	//敲击速度

    // 表情状态（送给 input_top 的表达式接口）
    output logic signed [3:0]       octave_offset, // -2~+2
    output logic [1:0]              waveform_sel,  // 0/1/2

    // 当前根音（已包含八度），供压电音符映射使用
    output logic [6:0]              base_note,		//当前的根音也要传出去

    // 调试：当前按住的音符键
    output logic [KEY_COUNT-1:0]    active_note_mask,

    // 待发槽位溢出（粘滞，只有复位能清）。为 1 表示极端背压下丢过事件。
    output logic                    event_overflow
);

    // event_req_sel 需要能表示 0~KEY_COUNT；0 专门表示 ALL_OFF
    localparam integer IDX_W = (KEY_COUNT <= 1) ? 1 : $clog2(KEY_COUNT + 1);

    //-------------------------------------------------------------------------
    // 每个按键一个 note_map 实例
    //   key_index 是 generate 常量，综合后等价于一张小查找表。
    //   同时把各功能标志汇总成 16 位掩码，方便用位运算判断“哪类键被按了”。
    //-------------------------------------------------------------------------
    logic [6:0]  map_note        [KEY_COUNT];	//前面是位宽，后面是生成多少个，也就是批量声明数组信号
    logic        map_is_note     [KEY_COUNT];	//批量声明信号
    logic        map_all_off     [KEY_COUNT];
    logic        map_wave        [KEY_COUNT];
    logic        map_oct_up      [KEY_COUNT];
    logic        map_oct_down    [KEY_COUNT];

	//下面五行其实是4x4键盘的逻辑分区
    logic [KEY_COUNT-1:0] note_key_mask;   // 哪些键是音符键
    logic [KEY_COUNT-1:0] all_off_mask;    // 哪些键是 ALL_NOTES_OFF
    logic [KEY_COUNT-1:0] wave_mask;       // 哪些键是波形切换
    logic [KEY_COUNT-1:0] oct_up_mask;     // 哪些键是升八度
    logic [KEY_COUNT-1:0] oct_down_mask;   // 哪些键是降八度

    genvar g;
    generate		//不是循环执行而是批量硬件生成
        for (g = 0; g < KEY_COUNT; g++) begin : g_note_map	//g_note_map是这一整组生成块的名字
							//展开后会有g_note_map[0], g_note_map[1]...
            note_map #(		//模块，note_map是一个别处的模块
                .NOTE_KEY_COUNT (NOTE_KEY_COUNT),
                .BASE_NOTE      (BASE_NOTE)
            ) u_note_map (	//这个是note_map的例化，将当前的g的note_map为模板例化，这个g是在g_note_map这一层被循环生成的
                .key_index        (4'(g)),	//父模块输入子模块
                .octave_offset    (octave_offset),
                .is_note_key      (map_is_note[g]),	//子模块输出给父模块
                .is_all_notes_off (map_all_off[g]),
                .is_waveform_key  (map_wave[g]),
                .is_octave_up     (map_oct_up[g]),
                .is_octave_down   (map_oct_down[g]),
                .note_id          (map_note[g])
            );
			//从这里开始，note_map的例化就结束了，每次例化结束，下面这些
            assign note_key_mask[g] = map_is_note[g];	//父模块中的信号。从子模块的输出拿到信息，再给到父模块的mask
            assign all_off_mask[g]  = map_all_off[g];
            assign wave_mask[g]     = map_wave[g];
            assign oct_up_mask[g]   = map_oct_up[g];
            assign oct_down_mask[g] = map_oct_down[g];
        end
    endgenerate

    //-------------------------------------------------------------------------
    // 待发事件表：每个物理键两个槽位（小队列）
    //   p0 是更早的事件、p1 是后来的事件，同一拍按下的多个键各自占槽位。
    //   只有一个槽位时，“NOTE_ON 还没被下游接收，紧接着松手发出 NOTE_OFF”
    //   会把 NOTE_ON 覆盖掉：那个音符已经发声，却再也收不到 OFF，
    //   于是变成持续音，而 input_overflow 还报不出来（评审清单第 7 项）。
    //-------------------------------------------------------------------------
    localparam integer EV_W = 2 + 7 + 8;      // {type, note, velocity}

    logic [KEY_COUNT-1:0] p0_valid;
    logic [KEY_COUNT-1:0] p1_valid;
    logic [EV_W-1:0]      p0_ev [KEY_COUNT];
    logic [EV_W-1:0]      p1_ev [KEY_COUNT];

    logic [KEY_COUNT-1:0] pop_mask;   // 本拍被取走的键
    logic                 pop_mask_any;
    logic                 ovf_r;      // 槽位溢出（粘滞，复位清除）

    // ALL_OFF 后抑制这些键的释放事件
    logic [KEY_COUNT-1:0] suppress_release;
    // 按下时锁存的音符编号，释放时用它
    logic [6:0]           latched_note [KEY_COUNT];

    // ALL_NOTES_OFF 单独一个待发标志，拥有最高优先级
    logic                 pend_all_off;
    // 当前选中的槽位：0=ALL_OFF，1~KEY_COUNT=对应按键
    logic [IDX_W-1:0]     event_req_sel;

    // MATRIX_MODE=1 时，K0~K11 选择的根音音级 0~11
    logic [3:0]           root_pitch_class;
    integer               root_calc;

    //-------------------------------------------------------------------------
    // 全局功能键（组合判断）
    //   key_pressed 是 16 位单周期脉冲，与对应功能掩码按位与后再或归约，
    //   就得到“本拍是否按下了某类功能键”。
    //-------------------------------------------------------------------------
    logic press_all_off;
    logic press_wave;
    logic press_oct_up;
    logic press_oct_down;

    assign press_all_off  = |(key_pressed & all_off_mask);//按的就是这个键&这个键的掩码=有一个1=塌缩为1
    assign press_wave     = |(key_pressed & wave_mask);
    assign press_oct_up   = |(key_pressed & oct_up_mask);
    assign press_oct_down = |(key_pressed & oct_down_mask);

    //-------------------------------------------------------------------------
    // 把事件压入第 k 个键的 2 槽位队列
    //   同一拍该键可能正好弹出一个槽位（pop_mask[k]），可用性按弹出后计算。
    //   每键每拍最多压入一个事件（按下 / 释放互斥）。
    //-------------------------------------------------------------------------
    task automatic push_event(input int k, input logic [1:0] t,
                              input logic [6:0] n, input logic [7:0] v);
        if (pop_mask[k]) begin
            // 弹出后 p0 会被旧 p1 填充；只有旧 p1 也空时 p0 才可用
            if (!p1_valid[k]) begin
                p0_valid[k] <= 1'b1;
                p0_ev[k]    <= {t, n, v};
            end else begin
                p1_valid[k] <= 1'b1;
                p1_ev[k]    <= {t, n, v};
            end
        end else if (!p0_valid[k]) begin
            p0_valid[k] <= 1'b1;
            p0_ev[k]    <= {t, n, v};
        end else if (!p1_valid[k]) begin
            p1_valid[k] <= 1'b1;
            p1_ev[k]    <= {t, n, v};
        end else begin
            // 两个槽位都满：保住在队事件，丢弃新事件并报警
            ovf_r <= 1'b1;
        end
    endtask

    //-------------------------------------------------------------------------
    // 状态更新
    //-------------------------------------------------------------------------
    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            p0_valid         <= '0;
            p1_valid         <= '0;
            ovf_r            <= 1'b0;
            pend_all_off     <= 1'b0;
            suppress_release <= '0;
            octave_offset    <= 4'sd0;
            waveform_sel     <= WAVE_SINE;
            root_pitch_class <= 4'd0;   // 默认 C
            for (int i = 0; i < KEY_COUNT; i++) begin
                p0_ev[i]        <= '0;
                p1_ev[i]        <= '0;
                latched_note[i] <= 7'd0;
            end
        end else begin
            //-----------------------------------------------------------------
            // 1) 先处理握手弹出：p1 -> p0，并清空 p1
            //    同一拍新事件写回同一槽位时会覆盖这里的赋值（新事件优先）
            //-----------------------------------------------------------------
            if (pop_mask_any) begin
                for (int i = 0; i < KEY_COUNT; i++) begin
                    if (pop_mask[i]) begin
                        p0_valid[i] <= p1_valid[i];
                        p0_ev[i]    <= p1_ev[i];
                        p1_valid[i] <= 1'b0;
                    end
                end
            end

            if (event_req_valid && event_req_ready && (event_req_sel == '0)) begin
                pend_all_off <= 1'b0;
            end

            //-----------------------------------------------------------------
            // 2) 音符键按下/释放
            //    MATRIX_MODE=0：按键直接发 NOTE_ON/OFF（当前测试模式）
            //    MATRIX_MODE=1：K0~K11 只更新 root_pitch_class，不发事件
            //-----------------------------------------------------------------
            for (int i = 0; i < KEY_COUNT; i++) begin
                if (key_pressed[i] && map_is_note[i]) begin
                    if (MATRIX_MODE == 0) begin
                        // 按下：锁存音符，填入 NOTE_ON 槽位
                        latched_note[i] <= map_note[i];
                        // velocity=0 会被成员 1 当作无声，这里兜底为默认力度
                        push_event(i, EVENT_NOTE_ON, map_note[i],
                                   (velocity_in == 8'd0) ? DEFAULT_VEL
                                                         : velocity_in);
                    end else begin
                        // 配置模式：K0~K11 选择根音音级 0~11
                        // 同时按下多个根音键时，循环中最后（最大）键号生效；
                        // 这种情况很少见，演奏时应只按一个根音键。
                        root_pitch_class <= 4'(i);
                    end
                end

                if (key_released[i] && map_is_note[i] && (MATRIX_MODE == 0)) begin
                    // 释放：如果该键被 ALL_OFF 抑制，就只清标志，不发 OFF
                    if (suppress_release[i]) begin
                        suppress_release[i] <= 1'b0;
                    end else begin
                        // 用按下时锁存的音高，避免中途切八度导致 OFF 发错音符
                        push_event(i, EVENT_NOTE_OFF, latched_note[i], 8'd0);
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
                // 只在已实现的波形编号内循环（见 WAVEFORM_MAX_SEL 说明）。
                // 成员 1 的 waveform_rom 目前只实现了正弦波，如果这里照样
                // 切到 1/2，整路音频会静音（评审清单第 8 项）。
                waveform_sel <= (waveform_sel >= WAVEFORM_MAX_SEL)
                                ? WAVE_SINE : (waveform_sel + 1'b1);
            end

            // ALL_NOTES_OFF 最后执行，保证同周期普通事件被清除：
            //   - 置 ALL_OFF 待发标志
            //   - 清空所有普通槽位
            //   - 把当前按住的音符键标记为“释放时不再发 OFF”
            if (press_all_off) begin
                pend_all_off     <= 1'b1;
                p0_valid         <= '0;
                p1_valid         <= '0;
                suppress_release <= (key_down | key_pressed) & note_key_mask;
            end
        end
    end

    // 本拍是否有键被取走（用于跳过整段弹出循环）
    always_comb begin
        pop_mask     = '0;
        pop_mask_any = 1'b0;
        if (event_req_valid && event_req_ready && (event_req_sel != '0)) begin
            pop_mask[event_req_sel - 1'b1] = 1'b1;
            pop_mask_any = 1'b1;
        end
    end

    //-------------------------------------------------------------------------
    // 事件选择：ALL_NOTES_OFF > 最小键号
    //   倒序扫描 pending 表：越小的键号越晚赋值，最终拥有更高优先级。
    //   p0_ev 是寄存器，握手前字段天然稳定。
    //-------------------------------------------------------------------------
    always_comb begin
        event_req_valid    = 1'b0;
        event_req_type     = EVENT_NOP;
        event_req_note     = 7'd0;
        event_req_velocity = 8'd0;
        event_req_sel      = '0;

        if (pend_all_off) begin
            // ALL_OFF 最高优先级；sel=0 是它的专用编号
            event_req_valid = 1'b1;
            event_req_type  = EVENT_ALL_NOTES_OFF;
            event_req_sel   = '0;
        end else begin
            // 倒序扫描，使最小键号拥有最高优先级
            for (int i = KEY_COUNT - 1; i >= 0; i--) begin
                if (p0_valid[i]) begin
                    event_req_valid = 1'b1;
                    {event_req_type, event_req_note, event_req_velocity} = p0_ev[i];
                    event_req_sel   = IDX_W'(i + 1);
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // 当前根音：BASE_NOTE + 根音音级 + 12 个八度
    //   例如 BASE_NOTE=60, root_pitch_class=2(D), octave=+1 -> 74(D5)
    //-------------------------------------------------------------------------
    always_comb begin
        root_calc = int'(BASE_NOTE) + int'(root_pitch_class)
                    + 12 * int'(octave_offset);
        if (root_calc < 0) begin
            base_note = 7'd0;
        end else if (root_calc > 127) begin
            base_note = 7'd127;
        end else begin
            base_note = 7'(root_calc);
        end
    end

    // 当前真正按住的音符键（不含功能键）
    assign active_note_mask = key_down & note_key_mask;
    assign event_overflow   = ovf_r;

endmodule
