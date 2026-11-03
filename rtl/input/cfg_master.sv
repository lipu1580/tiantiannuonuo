//=============================================================================
// 文件   : cfg_master.sv
// 归属   : 成员 2
// 功能   : cfg 总线主控。把「效果键 / 长按键」翻译成寄存器写序列。
//
// 【为什么需要它】
//   成员 1 的 audio_core_expr 用一条简单的 cfg 总线收配置：
//   cfg_valid/cfg_ready 握手，一笔请求 = 一个地址。
//   但一次「切到延迟」不是一个寄存器能表达的——必须先关湿声、设延迟量、
//   设反馈、切模式、再开湿声。顺序错了会爆音。
//   把这个序列固化在这里，成员 1 那边就只需要老老实实存寄存器。
//
// 【四条序列（协议 §6 权威版）】
//
//   旁路 mode=0  0x30<-0                               (2 笔)
//                0x2C<-0
//
//   延迟 mode=1  0x30<-0    关湿声
//                0x34<-3840  每段 80 ms，三段共 240 ms
//                0x38<-128    0.5 反馈
//                0x2C<-1     切到延迟
//                0x30<-128    开湿声 0.5        (5 笔)
//
//   合唱 mode=2  0x30<-0 / 0x2C<-2 / 0x30<-128        (3 笔)
//   混响 mode=3  0x30<-0 / 0x2C<-3 / 0x30<-128        (3 笔)
//
//   颤音（K15 长按）0x24<-depth，深度档位 0/25/50/100 循环。
//   速率不写，用成员 1 的复位默认 5 Hz（0x28）。
//
// 【抢占规则（重要）】
//   效果序列执行中又按了另一个效果键：
//     立刻终止当前序列，从新序列第 0 步重新开始。
//   安全性来自「每条序列都以湿声 0 开头、湿声 128 结尾」，
//   中途打断再重跑不会把湿声卡在 0，也不会让模式只写一半。
//
//   ⚠️ 有一个无法避免的边界：若 fx_req 与某笔的握手落在**同一拍**，
//      那笔 valid 已经被对端接收，协议不允许撤销，于是旧序列会多写出
//      1 笔（该笔仍是旧序列的合法中间步）。所以抢占的准确语义是
//      「**下一笔起**切换到新序列第 0 步」，最坏多 1 笔，结构仍完整。
//
//   颤音写入**不参与抢占**：vib_req 只把「待发深度」记进一个寄存器，
//   等当前效果序列跑完再发 0x24。否则长按 K15 会把正在进行的模式切换
//   打断，听感上是「按一下颤音，效果没了」。
//
// 【握手规则（协议 §4.1）】
//   cfg_valid && cfg_ready 的上升沿算一笔完成。
//   cfg_valid=1 && cfg_ready=0 期间 addr/wdata 必须保持不变——
//   本模块用「寄存器化」的 seq_mode/step 组合译码，天然满足，不需要 skid buffer。
//
// 【为什么不读 0x44(fx_status)】
//   本轮不做「等效果切完再弹」的逻辑；纯开环下发。读回口保留但不使用。
//=============================================================================
module cfg_master (
    input  logic        sys_clk,
    input  logic        rst_n,           // 低有效，同步复位

    //-------------------------------------------------------------------------
    // 来自 key_event_decoder：单周期脉冲 + 目标模式（已配对锁存）
    //-------------------------------------------------------------------------
    input  logic        fx_req,
    input  logic [1:0]  fx_mode_req,     // 0 旁路 / 1 延迟 / 2 合唱 / 3 混响

    //-------------------------------------------------------------------------
    // 来自 key_tap_hold 长按：单周期脉冲，档位在模块内部循环
    //-------------------------------------------------------------------------
    input  logic        vib_req,

    //-------------------------------------------------------------------------
    // cfg 总线（对成员 1 的 audio_core_expr）
    //-------------------------------------------------------------------------
    output logic        cfg_valid,
    output logic        cfg_write,       // 恒 1：本轮只写不读
    output logic [7:0]  cfg_addr,
    output logic [31:0] cfg_wdata,
    input  logic        cfg_ready,
    input  logic [31:0] cfg_rdata,       // 本轮不使用，仅做位或消费避免告警

    //-------------------------------------------------------------------------
    // 调试 / 验收观测
    //-------------------------------------------------------------------------
    output logic        cfg_busy,        // 序列进行中
    output logic [1:0]  fx_mode_latched, // 当前目标效果模式
    output logic [1:0]  vib_step,        // 颤音档位 0~3
    output logic [7:0]  vib_depth        // 当前音分 0 / 25 / 50 / 100
);

    //-------------------------------------------------------------------------
    // 寄存器地址（协议 §4.3）
    //   本轮不改 rtl/common，所以先放本地；成员 1 把地址写进 audio_defs.svh
    //   之后再迁过去。
    //-------------------------------------------------------------------------
    localparam logic [7:0] CFG_VIBRATO_DEPTH = 8'h24; // 0 / 25 / 50 / 100 音分
    localparam logic [7:0] CFG_FX_MODE       = 8'h2C; // 0 旁路 1 延迟 2 合唱 3 混响
    localparam logic [7:0] CFG_WET_GAIN      = 8'h30; // Q0.8，0~128
    localparam logic [7:0] CFG_DELAY_SAMPLES = 8'h34; // 1 ~ DEPTH-1
    localparam logic [7:0] CFG_FEEDBACK_GAIN = 8'h38; // Q0.8，0~128

    //-------------------------------------------------------------------------
    // 预设值（改这里就能改默认音色）
    //-------------------------------------------------------------------------
    localparam logic [31:0] WET_OFF         = 32'd0;    // 湿声全关
    localparam logic [31:0] WET_ON          = 32'd128;  // 128/256 = 0.5，增强与旁路的听感差异
    localparam logic [31:0] DELAY_STAGE_80MS      = 32'd3840; // 每段 3840 样本；总延迟 3*3840/48000 = 240 ms
    localparam logic [31:0] FEEDBACK_0P50   = 32'd128;  // 128/256 = 0.5，保留多次可辨识回声

    //-------------------------------------------------------------------------
    // 颤音档位 -> 音分
    //-------------------------------------------------------------------------
    function automatic logic [7:0] depth_of(input logic [1:0] step);
        case (step)
            2'd0:    depth_of = 8'd0;    // 关闭
            2'd1:    depth_of = 8'd25;
            2'd2:    depth_of = 8'd50;
            default: depth_of = 8'd100;
        endcase
    endfunction

    // 序列长度：旁路 2 笔、延迟 5 笔、合唱/混响 3 笔
    function automatic logic [2:0] seq_len(input logic [1:0] mode);
        case (mode)
            2'd0:    seq_len = 3'd2;
            2'd1:    seq_len = 3'd5;
            default: seq_len = 3'd3;
        endcase
    endfunction

    //-------------------------------------------------------------------------
    // 状态
    //-------------------------------------------------------------------------
    logic       busy;             // 效果序列进行中
    logic [1:0] seq_mode;         // 当前执行的序列（目标模式）
    logic [2:0] step;             // 当前步号

    logic       vib_pending_valid;// 有一笔颤音写排队
    logic [7:0] vib_pending_data; // 待写深度

    logic       fx_pend_valid;    // 有一个效果请求待启动（背压时不丢弃）
    logic [1:0] fx_pend_mode;     // 待启动的目标模式

    logic [2:0] seq_last;         // 当前序列最后一步的步号

    assign seq_last = seq_len(seq_mode) - 3'd1;

    //-------------------------------------------------------------------------
    // 组合译码：由 (seq_mode, step) 得到 (addr, wdata)
    //   结构上刻意保持「每笔序列都是：湿声关 -> 参数 -> 模式 -> 湿声开」。
    //   step==0                : 0x30 <- 0
    //   step==last (mode!=0)   : 0x30 <- 128
    //   step==last (mode==0)   : 0x2C <- 0
    //   中间三步 (仅 mode==1)  : 0x34<-3840, 0x38<-128, 0x2C<-1
    //   中间一步 (mode 2/3)    : 0x2C <- mode
    //-------------------------------------------------------------------------
    logic        seq_active;      // 正在发效果序列
    logic        vib_active;      // 正在发颤音那一笔
    logic [7:0]  seq_addr;
    logic [31:0] seq_wdata;

    always_comb begin
        seq_active  = busy;
        vib_active  = (!busy) && vib_pending_valid;
        seq_addr    = CFG_WET_GAIN;
        seq_wdata   = WET_OFF;

        if (step == 3'd0) begin
            // 统一入口：先关湿声，避免切模式时爆音
            seq_addr  = CFG_WET_GAIN;
            seq_wdata = WET_OFF;
        end else if (step == seq_last) begin
            // 统一出口：旁路不需要开湿声，其它模式开湿声
            if (seq_mode == 2'd0) begin
                seq_addr  = CFG_FX_MODE;
                seq_wdata = 32'd0;
            end else begin
                seq_addr  = CFG_WET_GAIN;
                seq_wdata = WET_ON;
            end
        end else if (seq_mode == 2'd1) begin
            // 延迟中间三步
            case (step)
                3'd1: begin seq_addr = CFG_DELAY_SAMPLES; seq_wdata = DELAY_STAGE_80MS;    end
                3'd2: begin seq_addr = CFG_FEEDBACK_GAIN; seq_wdata = FEEDBACK_0P50; end
                default: begin
                    seq_addr  = CFG_FX_MODE;
                    seq_wdata = 32'd1;
                end
            endcase
        end else begin
            // 合唱/混响中间一步：直接写模式号
            seq_addr  = CFG_FX_MODE;
            seq_wdata = {30'd0, seq_mode};
        end
    end

    //-------------------------------------------------------------------------
    // 总线输出
    //   序列优先；序列空闲时才发排队的颤音写。
    //-------------------------------------------------------------------------
    always_comb begin
        cfg_write = 1'b1;              // 本轮只写不读
        cfg_valid = seq_active || vib_active;
        if (seq_active) begin
            cfg_addr  = seq_addr;
            cfg_wdata = seq_wdata;
        end else begin
            cfg_addr  = CFG_VIBRATO_DEPTH;
            cfg_wdata = {24'd0, vib_pending_data};
        end
    end

    //-------------------------------------------------------------------------
    // 状态机
    //-------------------------------------------------------------------------
    logic handshake;

    assign handshake = cfg_valid && cfg_ready;

    //-------------------------------------------------------------------------
    // 抢占时机门控（协议硬约束）
    //
    //   协议 §4.1 规则 2：cfg_valid=1 && cfg_ready=0 时，发送方必须保持
    //   valid/write/addr/wdata 稳定。所以效果键**不能**在“本笔还没被接收”
    //   的时候直接换序列——那会把已经展示给对端的一笔偷偷改掉。
    //
    //   做法：新请求先进 1 深度待决寄存器（fx_pend_*），只有总线不再受阻
    //   的那一拍才真正换序列。放在待决寄存器里也就自然获得了“合并”行为：
    //   连续按键时最终采用最后一次，符合协议 §4.3。
    //-------------------------------------------------------------------------
    logic bus_stalled;   // 当前这一笔还没被接收
    logic start_fx;      // 可以启动/切换到待决序列

    assign bus_stalled = cfg_valid && !cfg_ready;
    assign start_fx    = fx_pend_valid && !bus_stalled;

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            busy              <= 1'b0;
            seq_mode          <= 2'd0;
            step              <= 3'd0;
            vib_pending_valid <= 1'b0;
            vib_pending_data  <= 8'd0;
            vib_step          <= 2'd0;
            fx_mode_latched   <= 2'd0;
            fx_pend_valid     <= 1'b0;
            fx_pend_mode      <= 2'd0;
        end else begin
            //-----------------------------------------------------------------
            // 1) 启动 / 切换到新序列
            //    - 总线空闲时：新请求**当拍**就被采纳，下一拍开始发第 0 步
            //      （保持 1 拍延迟，与“无背压”时手感一致）
            //    - 总线被卡住时：不采纳，先记进 fx_pend_*（见下面第 2 段）
            //    抢占语义：从新序列第 0 步重跑。若本拍恰有一笔旧序列被接收，
            //    那笔已经无法撤回（valid/ready 不允许），于是旧序列最多多写
            //    1 笔中间步，结构仍完整。
            //-----------------------------------------------------------------
            if (fx_req && !bus_stalled) begin
                seq_mode        <= fx_mode_req;
                fx_mode_latched <= fx_mode_req;
                step            <= 3'd0;
                busy            <= 1'b1;
                fx_pend_valid   <= 1'b0;   // 新请求覆盖任何旧待决
            end else if (start_fx) begin
                seq_mode        <= fx_pend_mode;
                fx_mode_latched <= fx_pend_mode;
                step            <= 3'd0;
                busy            <= 1'b1;
                fx_pend_valid   <= 1'b0;
            end else if (busy) begin
                if (handshake) begin
                    if (step == seq_last) begin
                        busy <= 1'b0;
                        step <= 3'd0;
                    end else begin
                        step <= step + 3'd1;
                    end
                end
            end

            //-----------------------------------------------------------------
            // 2) 总线被卡住时到来的效果键：只记录，不动总线字段
            //    （与上面第 1 段互斥：bus_stalled 为 1 时第 1 段不会改写
            //      fx_pend_valid，所以两处的赋值不会冲突）
            //-----------------------------------------------------------------
            if (fx_req && bus_stalled) begin
                fx_pend_mode  <= fx_mode_req;
                fx_pend_valid <= 1'b1;
            end

            //-----------------------------------------------------------------
            // 2) 长按键：只排队，不抢占
            //    vib_step 每次 +1 循环；深度在本拍就更新（调试口立即可见），
            //    实际写总线要等序列跑完。
            //-----------------------------------------------------------------
            if (vib_req) begin
                vib_step          <= vib_step + 2'd1;
                vib_pending_data  <= depth_of(vib_step + 2'd1);
                vib_pending_valid <= 1'b1;
            end else if (vib_active && handshake) begin
                vib_pending_valid <= 1'b0;
            end
        end
    end

    //-------------------------------------------------------------------------
    // 输出
    //-------------------------------------------------------------------------
    assign cfg_busy  = busy;
    assign vib_depth = depth_of(vib_step);

    // cfg_rdata 本轮不参与决策；位或消费一次，避免"未使用输入"告警。
    logic unused_rdata;
    assign unused_rdata = ^cfg_rdata;

endmodule
