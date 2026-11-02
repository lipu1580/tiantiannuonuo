// 成员三：同步立体声 PCM FIFO。所有逻辑均在 sys_clk 域内。
// 一次握手 = valid && ready 在 sys_clk 上升沿同时为 1。
// 左右声道一起入队/出队，不会错配。FIFO_DEPTH 必须 >= 1。
module pcm_sink #(
    parameter integer SAMPLE_W = 16,
    parameter integer FIFO_DEPTH = 8
)(
    input  logic sys_clk,
    input  logic rst_n,
    input  logic signed [SAMPLE_W-1:0] in_left,
    input  logic signed [SAMPLE_W-1:0] in_right,
    input  logic in_valid,
    output logic in_ready,
    output logic signed [SAMPLE_W-1:0] out_left,
    output logic signed [SAMPLE_W-1:0] out_right,
    output logic out_valid,
    input  logic out_ready,
    // 保留旧端口名以兼容封装；现在表示“输入违反握手协议”。
    // 单纯 valid=1、ready=0 是正常等待，不会报警，也不会写入/丢弃数据。
    // 若等待时发送方撤销 valid 或改变数据，此标志置 1，直到复位。
    output logic overflow
);
    localparam integer PTR_W = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH);
    localparam integer COUNT_W = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH + 1);
    localparam logic [PTR_W-1:0] LAST_PTR = FIFO_DEPTH - 1;
    localparam logic [COUNT_W-1:0] FULL_COUNT = FIFO_DEPTH;

    logic signed [SAMPLE_W-1:0] left_mem [0:FIFO_DEPTH-1];
    logic signed [SAMPLE_W-1:0] right_mem [0:FIFO_DEPTH-1];
    logic [PTR_W-1:0] wr_ptr, rd_ptr;
    logic [COUNT_W-1:0] count;
    logic push, pop;
    logic stalled;
    logic signed [SAMPLE_W-1:0] held_left, held_right;

    assign out_valid = rst_n && (count != 0);
    assign out_left  = out_valid ? left_mem[rd_ptr] : '0;
    assign out_right = out_valid ? right_mem[rd_ptr] : '0;
    // 已满但同一拍出队时，可用腾出的空间接收一份新样本。
    assign in_ready = rst_n && ((count < FULL_COUNT) || pop);
    assign push = in_valid && in_ready;
    assign pop  = out_valid && out_ready;

    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count <= '0;
            stalled <= 1'b0;
            held_left <= '0;
            held_right <= '0;
            overflow <= 1'b0;
        end else begin
            // 只复位指针和计数即可；旧存储内容会被 out_valid 屏蔽。
            if (push) begin
                left_mem[wr_ptr] <= in_left;
                right_mem[wr_ptr] <= in_right;
                wr_ptr <= (wr_ptr == LAST_PTR) ? '0 : wr_ptr + 1'b1;
            end
            if (pop)
                rd_ptr <= (rd_ptr == LAST_PTR) ? '0 : rd_ptr + 1'b1;

            case ({push, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count; // 同时进出时数量不变
            endcase

            // 检查上一拍被阻塞的数据是否保持到了这一拍（包括恢复握手的拍）。
            if (stalled && (!in_valid || in_left != held_left || in_right != held_right))
                overflow <= 1'b1;
            stalled <= in_valid && !in_ready;
            if (in_valid && !in_ready) begin
                held_left <= in_left;
                held_right <= in_right;
            end
        end
    end

    // synthesis translate_off
    initial begin
        if (FIFO_DEPTH < 1 || SAMPLE_W < 1)
            $fatal(1, "pcm_sink: invalid FIFO_DEPTH or SAMPLE_W");
    end
    // synthesis translate_on
endmodule
