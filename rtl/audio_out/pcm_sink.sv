// Stereo PCM FIFO between audio_core and the I2S transmitter.
// The input side uses the member-1 pcm_valid/pcm_ready handshake.
module pcm_sink #(
    parameter integer SAMPLE_W = 16,
    parameter integer FIFO_DEPTH = 8
)(
    input  logic sys_clk,
    input logic rst_n,
    input logic signed [SAMPLE_W-1:0] in_left,
    input logic signed [SAMPLE_W-1:0] in_right,
    input logic in_valid,
    output logic in_ready,
    output logic signed [SAMPLE_W-1:0] out_left,
    output logic signed [SAMPLE_W-1:0] out_right,
    output logic out_valid,
    input logic out_ready,
    output logic overflow
);
    localparam integer PTR_W = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH);
    localparam integer COUNT_W = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH + 1);

    logic signed [SAMPLE_W-1:0] left_mem [0:FIFO_DEPTH-1];
    logic signed [SAMPLE_W-1:0] right_mem[0:FIFO_DEPTH-1];
    logic [PTR_W-1:0] wr_ptr, rd_ptr;
    logic [COUNT_W-1:0] count;
    logic push, pop;

    assign out_valid = (count != 0);
    assign out_left  = out_valid ? left_mem[rd_ptr] : '0;
    assign out_right = out_valid ? right_mem[rd_ptr] : '0;
    assign in_ready = (count < FIFO_DEPTH) || (out_valid && out_ready);
    assign push = in_valid && in_ready;
    assign pop  = out_valid && out_ready;

    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr   <= '0;
            rd_ptr   <= '0;
            count    <= '0;
            overflow <= 1'b0;
        end else begin
            if (push) begin
                left_mem[wr_ptr]  <= in_left;
                right_mem[wr_ptr] <= in_right;
                if (wr_ptr == FIFO_DEPTH-1)
                    wr_ptr <= '0;
                else
                    wr_ptr <= wr_ptr + 1'b1;
            end

            if (pop) begin
                if (rd_ptr == FIFO_DEPTH-1)
                    rd_ptr <= '0;
                else
                    rd_ptr <= rd_ptr + 1'b1;
            end

            case ({push, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase

            if (in_valid && !in_ready)
                overflow <= 1'b1;
        end
    end
endmodule
