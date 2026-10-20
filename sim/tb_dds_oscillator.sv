`timescale 1ns/1ns
module tb_dds_oscillator;
    //1.参数
    parameter  CLK_PERIOD = 10;
    parameter  RESET_DURATION = 30;
    parameter integer ADDR_W   = 4; // 波形相位地址位宽
    parameter integer SAMPLE_W = 16; // 波形样本位宽
    parameter integer PHASE_W = 10;

    logic sys_clk,
            rst_n,
            audio_ce,
            waveform_valid;
    logic [1:0] waveform_sel;
    logic [PHASE_W-1 : 0] phase_increment = 10'b0001000000;
    logic [SAMPLE_W-1 : 0] waveform_sample;

    dds_oscillator #(
        .PHASE_W (PHASE_W),
        .SAMPLE_W (SAMPLE_W),
        .WAVE_ADDR_W (ADDR_W)
    ) DUT (
        .sys_clk (sys_clk),
        .rst_n (rst_n),
        .audio_ce (audio_ce),
        .phase_increment (phase_increment),
        .waveform_sel (waveform_sel),
        .waveform_sample (waveform_sample),
        .waveform_valid (waveform_valid)
    );//实例化

    always begin
        sys_clk = 0; #(CLK_PERIOD / 2);
        sys_clk = 1; #(CLK_PERIOD / 2);
    end //时钟

    int pass_count = 0;
    int error = 0;

    initial begin
        rst_n = 0;
        #(RESET_DURATION);

        rst_n = 1;
        @(negedge sys_clk);

        repeat(40) begin
        audio_ce = 1; #(CLK_PERIOD); #1;
        if (waveform_valid) begin
            pass_count++;
        end else begin
            error++;
        end
        audio_ce = 0;
        repeat (3) #(CLK_PERIOD);
        end
    end

endmodule
