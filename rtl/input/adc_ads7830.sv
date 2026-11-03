//=============================================================================
// 文件   : adc_ads7830.sv
// 功能   : ADS7830 8 位 8 通道 I2C ADC 驱动（单次转换 + 读取）。
//
// 【为什么不是 SPI】
//   ADS7830 是 I2C 器件，不是 SPI 器件。任务书中给出的
//   adc_cs_n/adc_sclk/adc_mosi/adc_miso 端口名不适用于该芯片，
//   因此本模块使用标准 I2C 三线接口：
//       adc_scl      -> SCL
//       adc_sda_oe   -> SDA 开漏驱动使能（1 表示拉低，0 表示释放）
//       adc_sda_i    -> SDA 回读（外部 4.7k 上拉）
//   顶层连接方式：
//       assign adc_sda = adc_sda_oe ? 1'b0 : 1'bz;
//       assign adc_sda_i = adc_sda;
//
// 【一次采样的事务帧】
//
//   START
//   0x90  (地址写：0x48<<1 | 0)     ACK
//   命令字 0x84|(ch<<4)              ACK
//   Repeated START
//   0x91  (地址读：0x48<<1 | 1)     ACK
//   data[7:0]                        NACK（主机不应答）
//   STOP
//
// 【命令字位定义】
//   bit7    SD=1       单端输入
//   bit6:4  C2 C1 C0   通道编码（注意：不是通道号！见 ch_code()）
//   bit3    PD1=0
//   bit2    PD0=1      内部基准关、ADC 开
//   bit1:0  X          任意
//
//   ADS7830 单端模式的通道编码（数据手册 Table 2）不是二进制顺序：
//     CH0=000 CH1=100 CH2=001 CH3=101 CH4=010 CH5=110 CH6=011 CH7=111
//   即 C2 = ch[0]、C1 = ch[2]、C0 = ch[1]。
//   若直接把通道号写入 C2:C0，物理通道会变成 0,2,4,6,1,3,5,7 —— 
//   电位器与 FSR 会整体串位（例如请求 CH1 实际读到 CH2）。
//   本模块用 ch_code() 做编码，对外端口 adc_channel_req / sample_channel
//   始终是“物理通道号 0~7”，与其它模块的通道分配表一致。
//
// 【SCL 生成】
//   每个 I2C 位分成 4 个 quarter，每个 quarter 持续 QDIV 个 sys_clk。
//   QDIV 由下方 QDIV_AUTO 自动计算，同时满足 f_SCL ≤ I2C_HZ 和
//   Fast Mode 的 t_LOW ≥ 1.3 us；27 MHz 下得到 QDIV=18，SCL ≈ 375 kHz。
//
// 【总线异常处理】
//   1. 每个事务开始前必须看到 SDA 为高（总线空闲）。若 SDA 被持续拉低，
//      后面所有 ACK 都会读成 0，数据也会读成 0 —— 这不是“成功采样”。
//      本模块在这种情况置 bus_error，并走 9 个 SCL 的总线恢复流程。
//   2. 事务期间用 quarter tick 计数做超时保护，超时后强制 STOP 并报错。
//   3. STOP 之后再次确认 SDA 回到高电平，只有确认通过才输出 sample_valid。
//
// 【相位约定（每个状态内的 ph）】
//   ph=0: SCL=0，改变/准备 SDA
//   ph=1: SCL=1，从机在上升沿采样
//   ph=2: SCL=1，主机在此时采样（读数据 / ACK）
//   ph=3: SCL=0，收尾、移位、进入下一状态
//
// 【接口约定】
//   sample_req 为单周期脉冲请求；sample_busy 期间忽略新请求。
//   sample_valid 为单周期脉冲，sample_data/sample_channel 与之对齐。
//   NACK 或总线异常时置 bus_error，且不产生 sample_valid。
//
// 【限制】
//   不支持 I2C 时钟拉伸（ADS7830 不需要）；SDA 只拉低，不主动输出高。
//=============================================================================
module adc_ads7830 #(
    parameter integer SYS_CLK_HZ  = project_params_pkg::SYS_CLK_HZ,   // 系统时钟
    parameter integer I2C_HZ      = project_params_pkg::ADC_I2C_HZ,   // I2C 速率上限
    // 1/4 位周期的 sys_clk 拍数；0 = 自动计算（满足 400 kHz 上限与 t_LOW ≥1.3us）
    parameter integer QUARTER_DIV = 0,
    parameter logic [6:0] SLV_ADDR = 7'h48                      // ADS7830 地址
)(
    input  logic       sys_clk,
    input  logic       rst_n,

    //-------------------------------------------------------------------------
    // 采样请求/结果
    //-------------------------------------------------------------------------
    input  logic       sample_req,      // 单周期请求
    input  logic [2:0] adc_channel_req, // 请求通道 0~7
    output logic       sample_busy,     // 事务进行中
    output logic       sample_valid,    // 结果有效（单周期）
    output logic [7:0] sample_data,     // ADC 结果
    output logic [2:0] sample_channel,  // 结果对应通道
    output logic       bus_error,       // NACK/异常

    //-------------------------------------------------------------------------
    // I2C 物理接口（开漏）
    //-------------------------------------------------------------------------
    output logic       adc_scl,
    output logic       adc_sda_oe,      // 1=拉低，0=释放
    input  logic       adc_sda_i
);

    //-------------------------------------------------------------------------
    // ADS7830 单端通道编码：C2:C0 不是通道号的二进制表示
    //   数据手册 Table 2（单端模式，SD=1）：
    //     CH0=000  CH1=100  CH2=001  CH3=101
    //     CH4=010  CH5=110  CH6=011  CH7=111
    //   因此 C2 = ch[0]，C1 = ch[2]，C0 = ch[1]。
    //   （直接发送 {ch} 会把逻辑通道映射成物理 0,2,4,6,1,3,5,7。）
    //-------------------------------------------------------------------------
    function automatic logic [2:0] ch_code(input logic [2:0] ch);
        ch_code = {ch[0], ch[2], ch[1]};
    endfunction

    //-------------------------------------------------------------------------
    // I2C 位速率发生器
    //   div_cnt 从 0 数到 QDIV-1，每数满一次产生一个 tick。
    //   tick 就是一个 quarter 的边界；状态机只在 tick 上推进 ph。
    //
    //   QDIV 必须同时满足（ADS7830 Fast Mode，SCL ≤ 400 kHz）：
    //     1. 总线频率：f_SCL = SYS_CLK_HZ / (4*QDIV) ≤ I2C_HZ
    //          -> QDIV ≥ ceil(SYS_CLK_HZ / (4*I2C_HZ))
    //     2. SCL 低电平：状态机里 SCL 低电平占 ph0+ph3 两个 quarter
    //          -> t_LOW = 2*QDIV/SYS_CLK_HZ ≥ 1.3 us
    //          -> QDIV ≥ ceil(SYS_CLK_HZ * 1.3us / 2)
    //   27 MHz / 400 kHz：约束 1 得 17，约束 2 得 18
    //     -> QDIV=18，SCL ≈ 375 kHz，t_LOW ≈ 1.33 us，均在手册范围内。
    //   （只做整数截断会得到 16：SCL ≈ 421.9 kHz、t_LOW ≈ 1.19 us，超规格。）
    //-------------------------------------------------------------------------
    localparam integer QDIV_FREQ = (SYS_CLK_HZ + (I2C_HZ * 4) - 1) / (I2C_HZ * 4);
    // ceil(SYS_CLK_HZ * 13 / 20e6) == ceil(SYS_CLK_HZ * 1.3us / 2)
    localparam integer QDIV_LOW  = (SYS_CLK_HZ * 13 + 19_999_999) / 20_000_000;
    localparam integer QDIV_AUTO = (QDIV_FREQ > QDIV_LOW) ? QDIV_FREQ : QDIV_LOW;
    localparam integer QDIV      = (QUARTER_DIV >= 2) ? QUARTER_DIV
                                 : ((QDIV_AUTO < 2) ? 2 : QDIV_AUTO);

    // 一次完整事务约 156 个 quarter；超时上限取 200 个 tick（留足余量）
    localparam logic [7:0] TICK_MAX = 8'd200;
    // 总线恢复用的 SCL 脉冲个数（I2C 规范建议 9 个）
    localparam logic [3:0] REC_CLKS = 4'd9;
    // 总线恢复最多重试次数，用完即放弃本次请求
    localparam logic [1:0] RETRY_MAX = 2'd2;

    logic [15:0] div_cnt;
    logic        tick;

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            div_cnt <= '0;
            tick    <= 1'b0;
        end else if (div_cnt == 16'(QDIV - 1)) begin
            div_cnt <= '0;
            tick    <= 1'b1;
        end else begin
            div_cnt <= div_cnt + 1'b1;
            tick    <= 1'b0;
        end
    end

    //-------------------------------------------------------------------------
    // SDA 输入同步（两级触发器）
    //   SDA 相对 sys_clk 异步，直接采样可能亚稳态；
    //   实际采样点在一个 quarter 后，2 拍延迟完全可以接受。
    //-------------------------------------------------------------------------
    logic sda_meta;
    logic sda_sync;

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            sda_meta <= 1'b1;
            sda_sync <= 1'b1;
        end else begin
            sda_meta <= adc_sda_i;
            sda_sync <= sda_meta;
        end
    end

    //-------------------------------------------------------------------------
    // 状态机
    //
    //   一次事务的路径：
    //   IDLE -> START -> TX_ADDR -> ACK1 -> TX_CMD -> ACK2
    //        -> RSTART -> TX_RADDR -> ACK3 -> RX_DATA -> NACK -> STOP -> IDLE
    //
    //   状态含义：
    //     START    : 产生 START 条件
    //     TX_ADDR  : 发送 0x90（地址写）
    //     ACK1     : 接收地址写 ACK
    //     TX_CMD   : 发送命令字 0x84|(ch<<4)
    //     ACK2     : 接收命令 ACK
    //     RSTART   : 产生 Repeated START
    //     TX_RADDR : 发送 0x91（地址读）
    //     ACK3     : 接收地址读 ACK
    //     RX_DATA  : 接收 8 位数据（MSB first）
    //     NACK     : 主机回 NACK（不再读第二个字节）
    //     STOP     : 产生 STOP，结束事务
    //-------------------------------------------------------------------------
    localparam logic [3:0] S_IDLE      = 4'd0;
    localparam logic [3:0] S_START     = 4'd1;
    localparam logic [3:0] S_TX_ADDR   = 4'd2;
    localparam logic [3:0] S_ACK1      = 4'd3;
    localparam logic [3:0] S_TX_CMD    = 4'd4;
    localparam logic [3:0] S_ACK2      = 4'd5;
    localparam logic [3:0] S_RSTART    = 4'd6;
    localparam logic [3:0] S_TX_RADDR  = 4'd7;
    localparam logic [3:0] S_ACK3      = 4'd8;
    localparam logic [3:0] S_RX_DATA   = 4'd9;
    localparam logic [3:0] S_NACK      = 4'd10;
    localparam logic [3:0] S_STOP      = 4'd11;
    localparam logic [3:0] S_RECOVER   = 4'd12;

    logic [3:0]  state;     // 主状态
    logic [1:0]  ph;        // 状态内的相位 0~3
    logic [2:0]  bit_idx;   // 当前字节还剩几位（7 -> 0）

    logic [7:0]  tx_shift;  // 发送移位寄存器（MSB first）
    logic [7:0]  rx_shift;  // 接收移位寄存器
    logic [7:0]  cmd_byte;  // 锁存的命令字
    logic [2:0]  ch_lat;    // 锁存的通道号
    logic        ack_n;     // 1 = 从机 NACK
    logic        abort;     // 事务异常，STOP 后不产生 sample_valid

    logic        scl_r;     // 寄存的 SCL
    logic        sda_oe_r;  // 寄存的 SDA 开漏使能

    logic [7:0]  data_r;    // 结果寄存器
    logic [2:0]  ch_r;      // 结果通道寄存器

    // 事务刚结束、等待在 IDLE 里做“STOP 后总线是否空闲”确认
    logic        result_pending;
    // 事务 quarter tick 计数（超时保护）
    logic [7:0]  tick_cnt;
    // 总线恢复脉冲计数
    logic [3:0]  rec_cnt;
    // 请求锁存（保证单拍 sample_req 也能被处理），以及恢复重试计数
    logic        req_latched;
    logic [2:0]  req_ch_latched;
    logic [1:0]  retry_cnt;

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            ph            <= 2'd0;
            bit_idx       <= 3'd7;
            tx_shift      <= 8'd0;
            rx_shift      <= 8'd0;
            cmd_byte      <= 8'd0;
            ch_lat        <= 3'd0;
            ack_n         <= 1'b1;
            abort         <= 1'b0;
            scl_r         <= 1'b1;
            sda_oe_r      <= 1'b0;
            data_r        <= 8'd0;
            ch_r          <= 3'd0;
            sample_valid  <= 1'b0;
            sample_busy   <= 1'b0;
            bus_error     <= 1'b0;
            result_pending <= 1'b0;
            tick_cnt      <= '0;
            rec_cnt       <= '0;
            req_latched   <= 1'b0;
            req_ch_latched <= 3'd0;
            retry_cnt     <= '0;
        end else begin
            // 默认每拍清 sample_valid，只有事务正常收尾且总线确认空闲时才置 1
            sample_valid <= 1'b0;

            // 所有相位/位计数只在 quarter tick 上推进
            if (tick) begin
                case (state)
                    //---------------------------------------------------------
                    // IDLE：等请求。SCL 保持高，SDA 释放（总线空闲）
                    //   收尾动作：
                    //   1) result_pending：先确认 STOP 之后 SDA 真的回到高电平，
                    //      否则数据不可信 —— 报 bus_error，不发 sample_valid；
                    //   2) req_latched：请求锁存后，只有总线空闲（SDA=1）才发起
                    //      事务。总线被钳死时先做 9 个 SCL 的总线恢复再重试，
                    //      重试次数用完才放弃（不产生样本）。
                    //   锁存请求保证 sample_req 只需要 1 拍脉冲。
                    //---------------------------------------------------------
                    S_IDLE: begin
                        scl_r       <= 1'b1;
                        sda_oe_r    <= 1'b0;
                        sample_busy <= 1'b0;

                        if (result_pending) begin
                            result_pending <= 1'b0;
                            if (sda_sync) begin
                                sample_valid <= 1'b1;
                            end else begin
                                // 总线被拉死：读回的值没有意义
                                bus_error <= 1'b1;
                            end
                        end else if (req_latched) begin
                            // 已锁存的请求优先处理（sample_req 可能一直为高，
                            // 上游是电平保持式的，不能反过来把请求丢回去）
                            if (sda_sync) begin
                                // 总线空闲：开始事务
                                sample_busy <= 1'b1;
                                bus_error   <= 1'b0;
                                abort       <= 1'b0;
                                ch_lat      <= req_ch_latched;
                                // 命令字：0x84 | (ch_code << 4)
                                cmd_byte    <= {1'b1, ch_code(req_ch_latched),
                                                1'b0, 1'b1, 2'b00};
                                tick_cnt    <= '0;
                                req_latched <= 1'b0;
                                state       <= S_START;
                                ph          <= 2'd0;
                            end else if (retry_cnt >= RETRY_MAX) begin
                                // 恢复无效：放弃本次请求（不伪造样本）
                                req_latched <= 1'b0;
                                bus_error   <= 1'b1;
                            end else begin
                                retry_cnt <= retry_cnt + 1'b1;
                                bus_error <= 1'b1;
                                rec_cnt   <= '0;
                                ph        <= 2'd0;
                                state     <= S_RECOVER;
                            end
                        end else if (sample_req) begin
                            // 先记住请求，下一拍再统一处理，避免短脉冲被 tick 漏掉
                            req_latched    <= 1'b1;
                            req_ch_latched <= adc_channel_req;
                            retry_cnt      <= '0;
                        end
                    end

                    //---------------------------------------------------------
                    // START：SCL 高时 SDA 高->低
                    //   ph0: 释放 SDA（上拉为高）
                    //   ph1: 拉低 SDA -> START
                    //   ph2: SCL 拉低，准备发第一位
                    //---------------------------------------------------------
                    S_START: begin
                        case (ph)
                            2'd0: begin
                                scl_r    <= 1'b1;
                                sda_oe_r <= 1'b0;   // SDA 释放为高
                                ph       <= 2'd1;
                            end
                            2'd1: begin
                                sda_oe_r <= 1'b1;   // SCL 高时 SDA 下降 = START
                                ph       <= 2'd2;
                            end
                            2'd2: begin
                                scl_r <= 1'b0;
                                ph    <= 2'd3;
                            end
                            default: begin
                                tx_shift <= {SLV_ADDR, 1'b0};
                                bit_idx  <= 3'd7;
                                ph       <= 2'd0;
                                state    <= S_TX_ADDR;
                            end
                        endcase
                    end

                    //---------------------------------------------------------
                    // TX_ADDR：发送 0x90（地址写），MSB first
                    //   ph0 根据最高位决定 SDA：0 拉低，1 释放
                    //   ph1 从机采样，ph3 左移一位
                    //---------------------------------------------------------
                    S_TX_ADDR: begin
                        case (ph)
                            2'd0: begin
                                scl_r    <= 1'b0;
                                // tx_shift[7]=0 -> oe=1 拉低；=1 -> oe=0 释放为上拉高
                                sda_oe_r <= ~tx_shift[7];
                                ph       <= 2'd1;
                            end
                            2'd1: begin
                                scl_r <= 1'b1;
                                ph    <= 2'd2;
                            end
                            2'd2: begin
                                scl_r <= 1'b1;
                                ph    <= 2'd3;
                            end
                            default: begin
                                scl_r    <= 1'b0;
                                tx_shift <= {tx_shift[6:0], 1'b0};
                                ph       <= 2'd0;
                                if (bit_idx == 3'd0) begin
                                    state <= S_ACK1;
                                end else begin
                                    bit_idx <= bit_idx - 1'b1;
                                end
                            end
                        endcase
                    end

                    //---------------------------------------------------------
                    // ACK1：接收地址写 ACK
                    //   ph0 主机释放 SDA，从机拉低
                    //   ph2 主机采样；ph3 判断：高= NACK -> 错误
                    //---------------------------------------------------------
                    S_ACK1: begin
                        case (ph)
                            2'd0: begin
                                scl_r    <= 1'b0;
                                sda_oe_r <= 1'b0;   // 释放 SDA，由从机拉低应答
                                ph       <= 2'd1;
                            end
                            2'd1: begin
                                scl_r <= 1'b1;
                                ph    <= 2'd2;
                            end
                            2'd2: begin
                                ack_n <= sda_sync;
                                ph    <= 2'd3;
                            end
                            default: begin
                                scl_r <= 1'b0;
                                ph    <= 2'd0;
                                if (ack_n) begin
                                    bus_error <= 1'b1;
                                    abort     <= 1'b1;
                                    state     <= S_STOP;
                                end else begin
                                    tx_shift <= cmd_byte;
                                    bit_idx  <= 3'd7;
                                    state    <= S_TX_CMD;
                                end
                            end
                        endcase
                    end

                    //---------------------------------------------------------
                    // TX_CMD：发送命令字 0x84|(ch<<4)
                    //---------------------------------------------------------
                    S_TX_CMD: begin
                        case (ph)
                            2'd0: begin
                                scl_r    <= 1'b0;
                                sda_oe_r <= ~tx_shift[7];
                                ph       <= 2'd1;
                            end
                            2'd1: begin
                                scl_r <= 1'b1;
                                ph    <= 2'd2;
                            end
                            2'd2: begin
                                scl_r <= 1'b1;
                                ph    <= 2'd3;
                            end
                            default: begin
                                scl_r    <= 1'b0;
                                tx_shift <= {tx_shift[6:0], 1'b0};
                                ph       <= 2'd0;
                                if (bit_idx == 3'd0) begin
                                    state <= S_ACK2;
                                end else begin
                                    bit_idx <= bit_idx - 1'b1;
                                end
                            end
                        endcase
                    end

                    //---------------------------------------------------------
                    // ACK2：接收命令 ACK；成功则进入 Repeated START
                    //---------------------------------------------------------
                    S_ACK2: begin
                        case (ph)
                            2'd0: begin
                                scl_r    <= 1'b0;
                                sda_oe_r <= 1'b0;
                                ph       <= 2'd1;
                            end
                            2'd1: begin
                                scl_r <= 1'b1;
                                ph    <= 2'd2;
                            end
                            2'd2: begin
                                ack_n <= sda_sync;
                                ph    <= 2'd3;
                            end
                            default: begin
                                scl_r <= 1'b0;
                                ph    <= 2'd0;
                                if (ack_n) begin
                                    bus_error <= 1'b1;
                                    abort     <= 1'b1;
                                    state     <= S_STOP;
                                end else begin
                                    state <= S_RSTART;
                                end
                            end
                        endcase
                    end

                    //---------------------------------------------------------
                    // RSTART：Repeated START
                    //   SCL 高时 SDA 高->低，不释放总线直接转入地址读
                    //---------------------------------------------------------
                    S_RSTART: begin
                        case (ph)
                            2'd0: begin
                                scl_r    <= 1'b0;
                                sda_oe_r <= 1'b0;   // SDA 拉高
                                ph       <= 2'd1;
                            end
                            2'd1: begin
                                scl_r <= 1'b1;
                                ph    <= 2'd2;
                            end
                            2'd2: begin
                                sda_oe_r <= 1'b1;   // SCL 高时 SDA 下降 = 重复起始
                                ph       <= 2'd3;
                            end
                            default: begin
                                scl_r    <= 1'b0;
                                tx_shift <= {SLV_ADDR, 1'b1};
                                bit_idx  <= 3'd7;
                                ph       <= 2'd0;
                                state    <= S_TX_RADDR;
                            end
                        endcase
                    end

                    //---------------------------------------------------------
                    // TX_RADDR：发送 0x91（地址读）
                    //---------------------------------------------------------
                    S_TX_RADDR: begin
                        case (ph)
                            2'd0: begin
                                scl_r    <= 1'b0;
                                sda_oe_r <= ~tx_shift[7];
                                ph       <= 2'd1;
                            end
                            2'd1: begin
                                scl_r <= 1'b1;
                                ph    <= 2'd2;
                            end
                            2'd2: begin
                                scl_r <= 1'b1;
                                ph    <= 2'd3;
                            end
                            default: begin
                                scl_r    <= 1'b0;
                                tx_shift <= {tx_shift[6:0], 1'b0};
                                ph       <= 2'd0;
                                if (bit_idx == 3'd0) begin
                                    state <= S_ACK3;
                                end else begin
                                    bit_idx <= bit_idx - 1'b1;
                                end
                            end
                        endcase
                    end

                    //---------------------------------------------------------
                    // ACK3：接收地址读 ACK；成功则准备接收数据
                    //---------------------------------------------------------
                    S_ACK3: begin
                        case (ph)
                            2'd0: begin
                                scl_r    <= 1'b0;
                                sda_oe_r <= 1'b0;
                                ph       <= 2'd1;
                            end
                            2'd1: begin
                                scl_r <= 1'b1;
                                ph    <= 2'd2;
                            end
                            2'd2: begin
                                ack_n <= sda_sync;
                                ph    <= 2'd3;
                            end
                            default: begin
                                scl_r   <= 1'b0;
                                ph      <= 2'd0;
                                if (ack_n) begin
                                    bus_error <= 1'b1;
                                    abort     <= 1'b1;
                                    state     <= S_STOP;
                                end else begin
                                    rx_shift <= 8'd0;
                                    bit_idx  <= 3'd7;
                                    state    <= S_RX_DATA;
                                end
                            end
                        endcase
                    end

                    //---------------------------------------------------------
                    // RX_DATA：接收 8 位数据，MSB first
                    //   主机释放 SDA；ph2 在 SCL 高时采样
                    //---------------------------------------------------------
                    S_RX_DATA: begin
                        case (ph)
                            2'd0: begin
                                scl_r    <= 1'b0;
                                sda_oe_r <= 1'b0;   // 主机释放 SDA
                                ph       <= 2'd1;
                            end
                            2'd1: begin
                                scl_r <= 1'b1;
                                ph    <= 2'd2;
                            end
                            2'd2: begin
                                rx_shift <= {rx_shift[6:0], sda_sync};
                                ph       <= 2'd3;
                            end
                            default: begin
                                scl_r <= 1'b0;
                                ph    <= 2'd0;
                                if (bit_idx == 3'd0) begin
                                    state <= S_NACK;
                                end else begin
                                    bit_idx <= bit_idx - 1'b1;
                                end
                            end
                        endcase
                    end

                    //---------------------------------------------------------
                    // NACK：主机回 NACK（释放 SDA，保持高），结束读取
                    //---------------------------------------------------------
                    S_NACK: begin
                        case (ph)
                            2'd0: begin
                                scl_r    <= 1'b0;
                                sda_oe_r <= 1'b0;   // NACK：SDA 保持高
                                ph       <= 2'd1;
                            end
                            2'd1: begin
                                scl_r <= 1'b1;
                                ph    <= 2'd2;
                            end
                            2'd2: begin
                                scl_r <= 1'b1;
                                ph    <= 2'd3;
                            end
                            default: begin
                                scl_r <= 1'b0;
                                ph    <= 2'd0;
                                state <= S_STOP;
                            end
                        endcase
                    end

                    //---------------------------------------------------------
                    // STOP：SCL 高时 SDA 低->高，结束事务
                    //   ph3 把结果写入 data_r/ch_r，并置 result_pending；
                    //   真正的 sample_valid 要等 IDLE 里确认总线已回到空闲。
                    //---------------------------------------------------------
                    S_STOP: begin
                        case (ph)
                            2'd0: begin
                                scl_r    <= 1'b0;
                                sda_oe_r <= 1'b1;   // SDA 拉低
                                ph       <= 2'd1;
                            end
                            2'd1: begin
                                scl_r <= 1'b1;
                                ph    <= 2'd2;
                            end
                            2'd2: begin
                                sda_oe_r <= 1'b0;   // SCL 高时 SDA 上升 = STOP
                                ph       <= 2'd3;
                            end
                            default: begin
                                scl_r       <= 1'b1;
                                ph          <= 2'd0;
                                state       <= S_IDLE;
                                sample_busy <= 1'b0;
                                tick_cnt    <= '0;
                                if (!abort) begin
                                    data_r         <= rx_shift;
                                    ch_r           <= ch_lat;
                                    result_pending <= 1'b1;
                                end
                            end
                        endcase
                    end

                    //---------------------------------------------------------
                    // RECOVER：总线恢复
                    //   SDA 被钳低（从机掉电/短路/上电残留）时，正常时序会把
                    //   全 0 读成“ACK 正常 + 数据 0”，从而伪造成功采样。
                    //   这里只释放 SDA，给出 9 个 SCL 时钟让从机退出当前字节，
                    //   最后补一个 STOP 把总线拉回空闲。
                    //---------------------------------------------------------
                    S_RECOVER: begin
                        case (ph)
                            2'd0: begin
                                scl_r    <= 1'b0;
                                sda_oe_r <= 1'b0;   // 释放 SDA
                                ph       <= 2'd1;
                            end
                            2'd1: begin
                                scl_r <= 1'b1;
                                ph    <= 2'd2;
                            end
                            2'd2: begin
                                scl_r <= 1'b1;
                                ph    <= 2'd3;
                            end
                            default: begin
                                scl_r <= 1'b0;
                                ph    <= 2'd0;
                                if (rec_cnt == REC_CLKS - 1'b1) begin
                                    abort <= 1'b1;      // 恢复过程不产生样本
                                    state <= S_STOP;
                                end else begin
                                    rec_cnt <= rec_cnt + 1'b1;
                                end
                            end
                        endcase
                    end

                    default: begin
                        state <= S_IDLE;
                        ph    <= 2'd0;
                    end
                endcase

                //-------------------------------------------------------------
                // 事务超时保护（放在 case 之后，优先级最高）
                //   SDA 僵死 / 从机不响应时，状态机不能永远停在某个相位。
                //   超时后强制走一次 STOP 收尾并报 bus_error，不产生样本。
                //-------------------------------------------------------------
                if (state == S_IDLE) begin
                    tick_cnt <= '0;
                end else if (tick_cnt >= TICK_MAX) begin
                    tick_cnt  <= '0;
                    abort     <= 1'b1;
                    bus_error <= 1'b1;
                    state     <= S_STOP;
                    ph        <= 2'd0;
                end else begin
                    tick_cnt <= tick_cnt + 1'b1;
                end
            end
        end
    end

    // 输出寄存器到端口
    assign adc_scl        = scl_r;
    assign adc_sda_oe     = sda_oe_r;
    assign sample_data    = data_r;
    assign sample_channel = ch_r;

endmodule
