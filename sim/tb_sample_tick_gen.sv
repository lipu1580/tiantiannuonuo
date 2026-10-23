`timescale 1ns/1ns

module tb_sample_tick_gen;
    //1.参数
    parameter  CLK_PERIOD = 10;
    parameter  RESET_DURATION = 30;
    parameter  SAMPLE_RATE = 3;

    //声明信号
    logic sys_clk;
    logic rst_n;
    logic audio_ce;

    //时钟生成
    always begin
        sys_clk = 0; #(CLK_PERIOD / 2);
        sys_clk = 1; #(CLK_PERIOD / 2);
    end

    //DUT实例化
    sample_tick_gen #(
    .SYS_CLK_HZ  (10),
    .SAMPLE_RATE (SAMPLE_RATE)
    ) DUT (
    .sys_clk  (sys_clk),
    .rst_n    (rst_n),
    .audio_ce (audio_ce)
    );

    //采样
    int pulse_count;
    int cycle_count;
    int last_pulse_cycle = -1;
    logic prev_audio_ce;
    //在下降沿采样可以避开NBA时间，防止读到旧值
    always @(negedge sys_clk) begin
        if (!rst_n) begin
            pulse_count = 0;
            cycle_count = 0;
            last_pulse_cycle = -1;
            prev_audio_ce = 0;
        end else begin
            cycle_count++;
            if (prev_audio_ce && audio_ce) begin
                $error("Audio_ce can't stable for multipy period\n");
            end
            if (audio_ce) begin
                pulse_count++;
                if (last_pulse_cycle >= 0) begin
                    int interval;
                    interval = cycle_count - last_pulse_cycle;
                    if (interval < 3 || interval > 4) begin
                        $error("interval=%0d ERROR @cycle %0d", interval, cycle_count);
                    end
                end
                last_pulse_cycle = cycle_count;
            end
            prev_audio_ce = audio_ce;
        end
    end

    //主激励事件
    initial begin
        rst_n = 0;
        #(RESET_DURATION);
        #1; //防止监视块和主激励块竞争
        rst_n = 1;

        repeat (40) @(posedge sys_clk);
        @(negedge sys_clk);
        #1; //同上

        if (pulse_count < 11 || pulse_count > 13) begin
            $error("Expect:12, now: %0d ", pulse_count);
        end

        $display("pusle_count = %0d cycle_count = %0d", pulse_count, cycle_count);
        $finish;
    end    
endmodule
