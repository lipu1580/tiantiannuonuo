module waveform_rom #(
    parameter integer ADDR_W   = 10, // 波形相位地址位宽
    parameter integer SAMPLE_W = 16,  // 波形样本位宽
    parameter INIT_FILE = "rtl/audio/sine_1024.hex"
)(
    input  logic                          sys_clk,
    input  logic [ADDR_W-1:0]             address, // 时钟沿采样的波表地址
    input  logic [1:0]                    waveform_sel, // 时钟沿采样的波形类型
    output logic signed [SAMPLE_W-1:0]    waveform_sample // 上一次采样地址对应的波形值
);

    localparam integer TABLE_DEPTH = 1 << ADDR_W;
    // 只读波形存储阵列；综合时可映射到 FPGA 的 ROM 或块 RAM。
    logic signed [SAMPLE_W-1:0] sine_table [0:TABLE_DEPTH-1];


    // 同步读 ROM：在 sys_clk 上升沿采样 address 和 waveform_sel，
    // waveform_sample 在该时钟沿之后更新，因此相对于地址存在一个时序阶段。
    always_ff @(posedge sys_clk) begin : waveform_rom
        casez (waveform_sel)
            2'b00: waveform_sample <= sine_table[address]; //暂时只支持正弦波
            default: waveform_sample <= 'b0;
        endcase
    end


    initial begin
        $readmemh(INIT_FILE, sine_table);//读取
    end
    // 同步查表接口：在 clk 上升沿采样 address 和 waveform_sel，输出随后更新。
    // address 为完整一周期波形的等分相位。
    // 0=正弦、1=方波、2=锯齿、3=静音；输出为有符号补码。
endmodule
