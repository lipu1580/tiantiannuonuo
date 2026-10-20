`timescale 1ns/1ns
module tb_dds_oscillator;
    //1.参数
    parameter  CLK_PERIOD = 10;
    parameter  RESET_DURATION = 30;
    parameter integer ADDR_W   = 10; // 波形相位地址位宽
    parameter integer SAMPLE_W = 16; // 波形样本位宽
    parameter integer PHASE_W = 10;
    parameter INIT_FILE = "rtl/audio/sine_1024.hex";
    parameter TABLE_DEPTH = 1 << ADDR_W;

    logic sys_clk,
            rst_n,
            audio_ce,
            waveform_valid;
    logic [1:0] waveform_sel;
    logic [PHASE_W-1 : 0] phase_increment = 10'b0000000001;
    logic signed [SAMPLE_W-1:0]    waveform_sample;
    logic signed [SAMPLE_W-1:0] sine_table [0:TABLE_DEPTH-1];
    logic [PHASE_W - 1:0] phase_accumulator;

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

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            phase_accumulator <= 'b0;
        end    
        if (audio_ce) begin
            phase_accumulator <= phase_accumulator + phase_increment;
        end
    end



    initial begin
        rst_n        = 1'b0;
        audio_ce     = 1'b0;
        waveform_sel = 2'b00; // 当前只支持正弦波
        $readmemh(INIT_FILE, sine_table);
        #(RESET_DURATION);

        rst_n = 1;

        repeat (40) begin
        @(negedge sys_clk);
        audio_ce = 1;
        @(posedge sys_clk);
        #1;
        if (waveform_valid !== 1'b0) begin
            $fatal(1, "vaild提前出现");
        end

        @(negedge sys_clk);
        audio_ce = 0;

        @(posedge sys_clk);
        #1;
        if (waveform_valid !== 1'b1) begin
            $fatal(1, "没有收到有效样本");
        end
        if (waveform_sample !== sine_table[phase_accumulator]) begin
            $fatal(1, "没收到正确的样本");
        end

        @(posedge sys_clk);
        #1;
        if (waveform_valid !== 1'b0) begin
            $fatal(1, "没有恢复0");
        end
        end
        $display("PASS-------------------");
        $finish;
    end

endmodule
