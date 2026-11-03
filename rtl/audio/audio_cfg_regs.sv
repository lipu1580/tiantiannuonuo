`timescale 1ns/1ns

module audio_cfg_regs  # (
    parameter int FX_DELAY_DEPTH = 4096
)(
    input logic         sys_clk,
    input logic         rst_n,
    input logic [5:0]   wr_en,
    input logic [31:0]  wr_data,
    output logic [7:0]  vibrato_depth,
    output logic [15:0] vibrato_rate,
    output logic [1:0]  fx_mode,
    output logic [7:0]  wet_gain,
    output logic [11:0] delay_samples,
    output logic [7:0]  feedback_gain
);
    logic [31:0]    vibrato_depth_reg,
                    vibrato_rate_reg,
                    fx_mode_reg,
                    wet_gain_reg,
                    delay_samples_reg,
                    feedback_gain_reg;

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            vibrato_depth_reg <= 'b0;
            vibrato_rate_reg <= 'd1280;
            fx_mode_reg <= 'b0;
            wet_gain_reg <= 'b0;
            delay_samples_reg <= ('d1920 < FX_DELAY_DEPTH-1) ? 1920 : FX_DELAY_DEPTH-1;
            feedback_gain_reg <= 'b0;
        end
        else begin
            case (wr_en)
                'b1: begin
                    if (wr_data < 1) begin
                        vibrato_depth_reg <= 'b0;
                    end
                    else if (wr_data > 100) begin
                        vibrato_depth_reg <= 'd100;
                    end
                    else begin
                        vibrato_depth_reg <= wr_data;
                    end
                end 
                'b10: begin
                    if (wr_data < 256) begin
                        vibrato_rate_reg <= 'd256;
                    end 
                    else if (wr_data > 2048) begin
                        vibrato_rate_reg <= 'd2048;
                    end
                    else begin
                        vibrato_rate_reg <= wr_data;
                    end
                end
                'b100: begin
                    if (wr_data < 1) begin
                        fx_mode_reg <= 'b0;
                    end
                    else if (wr_data > 3) begin
                        fx_mode_reg <= 'd3;
                    end
                    else begin
                        fx_mode_reg <= wr_data;
                    end
                end
                'b1000: begin
                    if (wr_data < 1) begin
                        wet_gain_reg <= 'b0;
                    end
                    else if (wr_data > 128) begin
                        wet_gain_reg <= 'd128;
                    end
                    else begin
                        wet_gain_reg <= wr_data;
                    end
                end
                'b10000: begin
                    if (wr_data < 1) begin
                        delay_samples_reg <= 'b1;
                    end
                    else if (wr_data > FX_DELAY_DEPTH-1) begin
                        delay_samples_reg <= FX_DELAY_DEPTH-1;
                    end
                    else begin
                        delay_samples_reg <= wr_data;
                    end
                end
                'b100000: begin
                    if (wr_data < 1) begin
                        feedback_gain_reg <= 'b0;
                    end
                    else if (wr_data > 128) begin
                        feedback_gain_reg <= 'd128;
                    end
                    else begin
                        feedback_gain_reg <= wr_data;
                    end
                end
                default: begin
                    
                end
            endcase
        end
    end    

    assign vibrato_depth = vibrato_depth_reg[7:0];
    assign vibrato_rate = vibrato_rate_reg[15:0];
    assign fx_mode = fx_mode_reg[1:0];
    assign wet_gain = wet_gain_reg[7:0];
    assign delay_samples = delay_samples_reg[11:0];
    assign feedback_gain = feedback_gain_reg[7:0];
endmodule
// 颤音频率采用 Q8.8：保存值除以 256，就是 Hz。0x0500 是十进制 1280，表示 5 Hz。
//干湿和反馈比例采用 Q0.8：保存值除以 256，就是实际比例。128 表示 0.5
