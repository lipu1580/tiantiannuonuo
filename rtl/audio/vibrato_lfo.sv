`timescale 1ns/1ns

module vibrato_lfo #(
    parameter integer SAMPLE_RATE = 48_000
)(
    input logic             [31:0] vibrato_rate,
    input logic                    sys_clk,
    input logic                    rst_n,
    input logic                    audio_ce,
    output logic signed [15:0]     lfo_q15
);
    logic [31:0] lfo_step;
    logic [31:0] ifo_phase;
    logic [63:0] step_numerator;
    
    // vibrato_rate 为 32 位，补 32 位零后以 64 位计算，避免移位截断。
    assign step_numerator = ({32'd0, vibrato_rate} << 24) + 64'(SAMPLE_RATE / 2);
    assign lfo_step =32'(step_numerator / 64'(SAMPLE_RATE));

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            ifo_phase <= 'b0;
        end
        else if (audio_ce) begin
            ifo_phase <= ifo_phase + lfo_step;
        end
    end

    lfo_lut lfo_lut (
        .phase_index(ifo_phase[31:22]),
        .lfo_q15    (lfo_q15)
    );

endmodule
