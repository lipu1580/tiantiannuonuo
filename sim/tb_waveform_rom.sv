`timescale 1ns/1ns
module tb_waveform_rom;
    logic clk = 0;
    always #5 clk = ~clk;
    logic [9:0] address = 0;
    logic [1:0] sel = 0;
    logic signed [15:0] sample;
    logic signed [15:0] reference_sine [0:1023];
    logic signed [15:0] reference_organ [0:1023];
    logic signed [15:0] reference_pluck [0:1023];
    int checks = 0;

    waveform_rom DUT (.sys_clk(clk), .address(address),
                      .waveform_sel(sel), .waveform_sample(sample));

    initial begin
        logic signed [15:0] held, expected;
        $readmemh("rtl/audio/sine_1024.hex", reference_sine);
        $readmemh("rtl/audio/organ_1024.hex", reference_organ);
        $readmemh("rtl/audio/pluck_1024.hex", reference_pluck);
        @(posedge clk); #1;
        for (int i = 0; i < 1024; i++) begin
            for (int wave_id = 0; wave_id < 4; wave_id++) begin
                @(negedge clk);
                held = sample;
                address = 10'(i);
                sel = 2'(wave_id);
                case (wave_id)
                    0: expected = reference_sine[i];
                    1: expected = reference_organ[i];
                    2: expected = reference_pluck[i];
                    default: expected = 0;
                endcase
                #1;
                if (sample !== held)
                    $fatal(1, "ROM output changed before clock edge");
                @(posedge clk); #1;
                if (sample !== expected)
                    $fatal(1, "wave=%0d address=%0d expected=%0d got=%0d",
                           wave_id, i, expected, sample);
                checks++;
            end
        end
        $display("PASS tb_waveform_rom: %0d synchronous address/selection checks", checks);
        $finish;
    end
endmodule
