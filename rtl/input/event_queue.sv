//=============================================================================
// 文件   : event_queue.sv
// 功能   : 演奏事件小 FIFO，隔离按键译码与 audio_core 的握手背压。
// 说明   :
//   1. 标准 valid/ready；rd_valid 为“有数据”指示，数据在 rd_valid &&
//      rd_ready 的时钟沿完成传输。
//   2. rd_valid=1 且 rd_ready=0 时，rd_type/rd_note/rd_vel 保持稳定。
//   3. FIFO 满时继续写入不会被接受，overflow 置 1 并保持，直到
//      overflow_clear 或复位；已经入队的事件不会被覆盖。
//   4. 满时若同周期发生读出，仍允许写入一个事件（不丢吞吐）。
//=============================================================================
`include "audio_defs.svh"

module event_queue #(
    parameter integer DEPTH  = 8,
    parameter integer NOTE_W = 7
)(
    input  logic                    sys_clk,
    input  logic                    rst_n,

    // 写端口
    input  logic                    wr_valid,
    output logic                    wr_ready,
    input  logic [1:0]              wr_type,
    input  logic [NOTE_W-1:0]       wr_note,
    input  logic [7:0]              wr_vel,

    // 读端口
    output logic                    rd_valid,
    input  logic                    rd_ready,
    output logic [1:0]              rd_type,
    output logic [NOTE_W-1:0]       rd_note,
    output logic [7:0]              rd_vel,

    // 调试
    output logic                    overflow,
    input  logic                    overflow_clear,
    output logic [$clog2(DEPTH+1)-1:0] level
);

    localparam integer EVENT_W = 2 + NOTE_W + 8;
    localparam integer ADDR_W  = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
    localparam integer CNT_W   = (DEPTH <= 1) ? 1 : $clog2(DEPTH + 1);

    logic [EVENT_W-1:0]          mem [DEPTH];
    logic [ADDR_W-1:0]           wr_ptr;
    logic [ADDR_W-1:0]           rd_ptr;
    logic [CNT_W-1:0]            count;

    logic                        wr_fire;
    logic                        rd_fire;
    logic [EVENT_W-1:0]          rd_entry;

    assign rd_entry = mem[rd_ptr];
    assign rd_valid = (count != '0);
    assign rd_type  = rd_entry[EVENT_W-1 -: 2];
    assign rd_note  = rd_entry[NOTE_W+7 -: NOTE_W];
    assign rd_vel   = rd_entry[7:0];

    assign wr_ready = (count < CNT_W'(DEPTH)) || (rd_valid && rd_ready);
    assign wr_fire  = wr_valid && wr_ready;
    assign rd_fire  = rd_valid && rd_ready;
    assign level    = count;

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            wr_ptr   <= '0;
            rd_ptr   <= '0;
            count    <= '0;
            overflow <= 1'b0;
        end else begin
            if (wr_fire) begin
                mem[wr_ptr] <= {wr_type, wr_note, wr_vel};
                wr_ptr      <= (wr_ptr == ADDR_W'(DEPTH - 1)) ? '0 : wr_ptr + 1'b1;
            end

            if (rd_fire) begin
                rd_ptr <= (rd_ptr == ADDR_W'(DEPTH - 1)) ? '0 : rd_ptr + 1'b1;
            end

            case ({wr_fire, rd_fire})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;
            endcase

            if (overflow_clear) begin
                overflow <= 1'b0;
            end else if (wr_valid && !wr_ready) begin
                overflow <= 1'b1;
            end
        end
    end

endmodule
