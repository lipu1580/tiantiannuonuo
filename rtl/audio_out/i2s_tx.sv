// I2S master transmitter for MAX98357A.
// 16-bit PCM is sent in 32-bit left/right slots at 48 kHz.
module i2s_tx #(
    parameter integer SYS_CLK_HZ = 27_000_000,
    parameter integer SAMPLE_RATE = 48_000,
    parameter integer SAMPLE_W = 16,
    parameter integer SLOT_W = 32
)(
    input  logic sys_clk,
    input  logic rst_n,
    input  logic signed [SAMPLE_W-1:0] pcm_left,
    input  logic signed [SAMPLE_W-1:0] pcm_right,
    input  logic pcm_valid,
    output logic pcm_ready,
    output logic i2s_bclk,
    output logic i2s_lrclk,
    output logic i2s_din,
    output logic underrun
);
    localparam integer BCLK_HZ = SAMPLE_RATE * 2 * SLOT_W;
    localparam integer TOGGLE_HZ = BCLK_HZ * 2;

    logic [31:0] frac_acc;
    logic [6:0] bit_pos;
    logic request_pending;
    logic pending_valid;
    logic signed [SAMPLE_W-1:0] pending_left, pending_right;
    logic signed [SAMPLE_W-1:0] active_left, active_right;

    assign pcm_ready = request_pending;

    function automatic logic sample_bit(
        input logic signed [SAMPLE_W-1:0] sample,
        input integer index
    );
        if ((index >= 0) && (index < SAMPLE_W))
            sample_bit = sample[SAMPLE_W-1-index];
        else
            sample_bit = 1'b0;
    endfunction

    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            frac_acc        <= 32'd0;
            bit_pos         <= 7'd63;
            i2s_bclk        <= 1'b0;
            i2s_lrclk       <= 1'b0;
            i2s_din         <= 1'b0;
            request_pending <= 1'b1;
            pending_valid   <= 1'b0;
            pending_left    <= '0;
            pending_right   <= '0;
            active_left     <= '0;
            active_right    <= '0;
            underrun        <= 1'b0;
        end else begin
            if (request_pending && pcm_valid) begin
                pending_left    <= pcm_left;
                pending_right   <= pcm_right;
                pending_valid   <= 1'b1;
                request_pending <= 1'b0;
            end

            // Fractional divider: 27 MHz -> approximately 3.072 MHz BCLK.
            if (frac_acc + TOGGLE_HZ >= SYS_CLK_HZ) begin
                frac_acc <= frac_acc + TOGGLE_HZ - SYS_CLK_HZ;
                i2s_bclk <= ~i2s_bclk;

                // Update data on BCLK falling edges; MAX98357A samples on rising edges.
                if (i2s_bclk) begin
                    if (bit_pos == 7'd63) begin
                        bit_pos   <= 7'd0;
                        i2s_lrclk <= 1'b0;
                        i2s_din   <= 1'b0; // I2S one-bit delay dummy slot

                        if (pending_valid) begin
                            active_left   <= pending_left;
                            active_right  <= pending_right;
                            pending_valid <= 1'b0;
                        end else begin
                            underrun <= 1'b1;
                        end
                        request_pending <= 1'b1;
                    end else if (bit_pos == 7'd31) begin
                        bit_pos   <= 7'd32;
                        i2s_lrclk <= 1'b1;
                        i2s_din   <= 1'b0;
                    end else begin
                        bit_pos <= bit_pos + 7'd1;
                        if ((bit_pos >= 7'd0) && (bit_pos < 7'd16))
                            i2s_din <= sample_bit(active_left, bit_pos);
                        else if ((bit_pos >= 7'd32) && (bit_pos < 7'd48))
                            i2s_din <= sample_bit(active_right, bit_pos - 7'd32);
                        else
                            i2s_din <= 1'b0;
                    end
                end
            end else begin
                frac_acc <= frac_acc + TOGGLE_HZ;
            end
        end
    end
endmodule
