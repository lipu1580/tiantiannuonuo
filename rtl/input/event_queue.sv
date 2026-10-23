//=============================================================================
// 文件   : event_queue.sv
// 功能   : 演奏事件小 FIFO，隔离按键译码与 audio_core 的握手背压。
//
// 【为什么需要 FIFO】
//   按键消抖后可能在很短时间内产生多个事件（和弦、快速按放），而
//   audio_core 可能因为声部分配/内部状态机短暂拉低 event_ready。
//   有 FIFO 就不会丢事件，也不会修改已经提交的事件字段。
//
// 【存储格式】
//   mem[wr_ptr] = {type[1:0], note[6:0], velocity[7:0]}  // 共 17 位
//   读侧直接把当前 rd_ptr 指向的表项组合输出（show-ahead）：
//     rd_valid=1 就表示“表项有效”，不需要额外的读使能。
//   在 rd_valid=1 && rd_ready=0 期间，rd_ptr 不变化，所以字段天然稳定。
//
// 【满时同拍读写】
//   wr_ready = (count < DEPTH) || (rd_valid && rd_ready)
//   即：FIFO 满时，如果同一拍正好有一个读出，仍允许写入一个事件，
//   这样不会白白损失一拍吞吐。
//
// 【溢出策略】
//   FIFO 满时继续写：写入被忽略，overflow 置 1 并保持（锁存），
//   直到 overflow_clear 或复位。已入队的事件不会被覆盖。
//=============================================================================
module event_queue #(
    parameter integer DEPTH  = 8,   // FIFO 深度
    parameter integer NOTE_W = 7    // MIDI 音符位宽
)(
    input  logic                    sys_clk,
    input  logic                    rst_n,

    //-------------------------------------------------------------------------
    // 写端口（来自 key_event_decoder）
    //-------------------------------------------------------------------------
    input  logic                    wr_valid,
    output logic                    wr_ready,   // 1=本拍可写入
    input  logic [1:0]              wr_type,
    input  logic [NOTE_W-1:0]       wr_note,
    input  logic [7:0]              wr_vel,

    //-------------------------------------------------------------------------
    // 读端口（接 audio_core 的 event_*）
    //   传输条件：rd_valid && rd_ready 的时钟沿
    //-------------------------------------------------------------------------
    output logic                    rd_valid,   // 1=有事件待发
    input  logic                    rd_ready,   // 下游能否接收
    output logic [1:0]              rd_type,
    output logic [NOTE_W-1:0]       rd_note,
    output logic [7:0]              rd_vel,

    //-------------------------------------------------------------------------
    // 调试
    //-------------------------------------------------------------------------
    output logic                    overflow,       // 曾经发生写溢出
    input  logic                    overflow_clear, // 手动清溢出标志
    output logic [$clog2(DEPTH+1)-1:0] level         // 当前事件数
);

    localparam integer EVENT_W = 2 + NOTE_W + 8;                     // 17
    localparam integer ADDR_W  = (DEPTH <= 1) ? 1 : $clog2(DEPTH);   // 指针位宽
    localparam integer CNT_W   = (DEPTH <= 1) ? 1 : $clog2(DEPTH + 1);// 计数位宽

    logic [EVENT_W-1:0]          mem [DEPTH];   // 事件存储
    logic [ADDR_W-1:0]           wr_ptr;        // 写指针
    logic [ADDR_W-1:0]           rd_ptr;        // 读指针
    logic [CNT_W-1:0]            count;         // 当前事件数

    logic                        wr_fire;       // 本拍真正写入
    logic                        rd_fire;       // 本拍真正读出
    logic [EVENT_W-1:0]          rd_entry;      // 当前队首表项

    //-------------------------------------------------------------------------
    // show-ahead 读：队首数据直接组合输出
    //-------------------------------------------------------------------------
    assign rd_entry = mem[rd_ptr];
    assign rd_valid = (count != '0);
    assign rd_type  = rd_entry[EVENT_W-1 -: 2];
    assign rd_note  = rd_entry[NOTE_W+7 -: NOTE_W];
    assign rd_vel   = rd_entry[7:0];

    //-------------------------------------------------------------------------
    // 握手与满时同拍读写
    //-------------------------------------------------------------------------
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
                // 写入事件，写指针环形前进
                mem[wr_ptr] <= {wr_type, wr_note, wr_vel};
                wr_ptr      <= (wr_ptr == ADDR_W'(DEPTH - 1)) ? '0 : wr_ptr + 1'b1;
            end

            if (rd_fire) begin
                // 读出一个事件，读指针环形前进
                rd_ptr <= (rd_ptr == ADDR_W'(DEPTH - 1)) ? '0 : rd_ptr + 1'b1;
            end

            // 同拍读+写：计数不变；只写+1；只读-1
            case ({wr_fire, rd_fire})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;
            endcase

            // 溢出标志：写请求未被接受时置位；clear 优先
            if (overflow_clear) begin
                overflow <= 1'b0;
            end else if (wr_valid && !wr_ready) begin
                overflow <= 1'b1;
            end
        end
    end

endmodule
