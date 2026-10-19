//=============================================================================
// 文件   : adc_ads7830.sv
// 功能   : ADS7830 8 位 8 通道 I2C ADC 驱动（单次转换 + 读取）。
// 说明   :
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
//   时序：START + 地址写(0x90) + 命令 + Repeated START + 地址读(0x91)
//         + 读 1 字节 + NACK + STOP。
//   命令字：{1'b1, channel[2:0], 1'b0, 1'b1, 2'b00}，即 0x84 | (ch<<4)。
//
//   sample_req 为单周期脉冲请求；sample_busy 期间忽略新请求。
//   sample_valid 为单周期脉冲，sample_data/sample_channel 与之对齐。
//   NACK 或总线异常时置 bus_error，且不产生 sample_valid。
//=============================================================================
`include "project_params.svh"

module adc_ads7830 #(
    parameter integer SYS_CLK_HZ  = `SYS_CLK_HZ,
    parameter integer I2C_HZ      = `ADC_I2C_HZ,
    parameter integer QUARTER_DIV = SYS_CLK_HZ / (I2C_HZ * 4),
    parameter logic [6:0] SLV_ADDR = 7'h48
)(
    input  logic       sys_clk,
    input  logic       rst_n,

    // 采样请求
    input  logic       sample_req,
    input  logic [2:0] adc_channel_req,
    output logic       sample_busy,
    output logic       sample_valid,
    output logic [7:0] sample_data,
    output logic [2:0] sample_channel,
    output logic       bus_error,

    // I2C 物理接口
    output logic       adc_scl,
    output logic       adc_sda_oe,
    input  logic       adc_sda_i
);

    //-------------------------------------------------------------------------
    // I2C 位速率发生器
    //-------------------------------------------------------------------------
    localparam integer QDIV = (QUARTER_DIV < 2) ? 2 : QUARTER_DIV;

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
    // SDA 输入同步
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

    logic [3:0]  state;
    logic [1:0]  ph;
    logic [2:0]  bit_idx;

    logic [7:0]  tx_shift;
    logic [7:0]  rx_shift;
    logic [7:0]  cmd_byte;
    logic [2:0]  ch_lat;
    logic        ack_n;
    logic        abort;

    logic        scl_r;
    logic        sda_oe_r;

    logic [7:0]  data_r;
    logic [2:0]  ch_r;

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
        end else begin
            // 默认输出脉冲
            sample_valid <= 1'b0;

            if (tick) begin
                case (state)
                    //---------------------------------------------------------
                    S_IDLE: begin
                        scl_r    <= 1'b1;
                        sda_oe_r <= 1'b0;
                        if (sample_req) begin
                            sample_busy <= 1'b1;
                            bus_error   <= 1'b0;
                            abort       <= 1'b0;
                            ch_lat      <= adc_channel_req;
                            // 0x84 | (channel << 4)
                            cmd_byte    <= {1'b1, adc_channel_req, 1'b0, 1'b1, 2'b00};
                            state       <= S_START;
                            ph          <= 2'd0;
                        end else begin
                            sample_busy <= 1'b0;
                        end
                    end

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
                    S_TX_ADDR: begin
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
                                    state <= S_ACK1;
                                end else begin
                                    bit_idx <= bit_idx - 1'b1;
                                end
                            end
                        endcase
                    end

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
                                scl_r <= 1'b1;
                                ph    <= 2'd0;
                                state <= S_IDLE;
                                sample_busy <= 1'b0;
                                if (!abort) begin
                                    data_r       <= rx_shift;
                                    ch_r         <= ch_lat;
                                    sample_valid <= 1'b1;
                                end
                            end
                        endcase
                    end

                    default: begin
                        state <= S_IDLE;
                        ph    <= 2'd0;
                    end
                endcase
            end
        end
    end

    assign adc_scl        = scl_r;
    assign adc_sda_oe     = sda_oe_r;
    assign sample_data    = data_r;
    assign sample_channel = ch_r;

endmodule
