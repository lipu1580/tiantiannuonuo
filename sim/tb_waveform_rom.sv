module tb_waveform_rom;

logic clk = 1'b0;
always #5 clk = ~clk;

parameter integer ADDR_W   = 10; // 波形相位地址位宽
parameter integer SAMPLE_W = 16; // 波形样本位宽

logic [ADDR_W - 1:0] address;
logic [1:0] sel;
logic [SAMPLE_W - 1:0] sample;

waveform_rom #(
    .ADDR_W (ADDR_W),
    .SAMPLE_W (SAMPLE_W)
) DUT (
    .sys_clk (clk),
    .address (address),
    .waveform_sel (sel),
    .waveform_sample (sample)
); //实例化

    int error_count = 0;
    int pass = 0;

initial begin

    address = 10'd1; sel = 2'b0; @(posedge clk); #1;
    if (sample == 16'h00C9) begin
        pass++;
    end else begin
        error_count++;
        $display("LUT is wrong");
    end

    address = 10'd1022; sel = 2'b00; @(posedge clk); #1;
    if (sample == 16'hFE6E) begin
        pass++;
    end else begin
        error_count++;
        $display("LUT is wrong");
    end

    address = 10'd1022; sel = 2'b01; @(posedge clk); #1;
    if (sample == 16'h0) begin
        pass++;
    end else begin
        error_count++;
        $display("sel is wrong");
    end

    address = 10'd1022; sel = 2'b10; @(posedge clk); #1;
    if (sample == 16'h0) begin
        pass++;
    end else begin
        error_count++;
        $display("sel is wrong");
    end

    #1;

    if (pass == 4) begin
        $display("PASS");
        $finish;
    end
    if (error_count != 0) begin
        $fatal;
    end

end

endmodule
