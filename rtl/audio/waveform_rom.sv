module waveform_rom #(
    parameter integer ADDR_W   = 10, // 波形相位地址位宽
    parameter integer SAMPLE_W = 16,  // 波形样本位宽
    parameter INIT_FILE = "rtl/audio/sine_1024.hex"
)(
    input  logic [ADDR_W-1:0]             address, // 当前波形相位地址
    input  logic [1:0]                    waveform_sel, // 波形类型选择
    output logic signed [SAMPLE_W-1:0]    waveform_sample // 对应相位的有符号幅值
);

    localparam integer TABLE_DEPTH = 1 << ADDR_W;
    logic signed [SAMPLE_W-1:0] sine_table [0:TABLE_DEPTH-1];//初始化查找表


    always_comb begin : waveform_rom
        casez (waveform_sel)
            2'b00: waveform_sample = sine_table[address]; //暂时只支持正弦波 
            default: waveform_sample = 'b0;
        endcase
    end


    initial begin
        $readmemh(INIT_FILE, sine_table);//读取
    end
    // 组合查表接口，无寄存器延迟；address 为完整一周期波形的等分相位。
    // 0=正弦、1=方波、2=锯齿、3=静音；输出为有符号补码。
endmodule
