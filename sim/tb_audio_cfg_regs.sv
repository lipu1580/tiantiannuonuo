`timescale 1ns/1ns

// 仅测试寄存器模块；地址译码、总线握手和清尾音命令由 core 的 TB 验证。
module cfg_regs_test_case #(
    parameter int DEPTH = 4096
)(
    output logic done = 0,
    output int errors = 0
);
    logic sys_clk = 0;
    logic rst_n = 0;
    logic [5:0] wr_en = 0;
    logic [31:0] wr_data = 0;
    logic [7:0] vibrato_depth, wet_gain, feedback_gain;
    logic [15:0] vibrato_rate;
    logic [1:0] fx_mode;
    logic [11:0] delay_samples;
    wire [31:0] observed [0:5];
    logic [31:0] expected [0:5];
    int failures [0:5];
    int checks = 0;
    bit model_valid = 0;
    string names [0:5] = '{"vibrato_depth", "vibrato_rate", "fx_mode",
                           "wet_gain", "delay_samples", "feedback_gain"};
    logic [31:0] lower_bound [0:5] = '{0, 256, 0, 0, 1, 0};
    logic [31:0] upper_bound [0:5] = '{100, 2048, 3, 128, 32'(DEPTH-1), 128};

    audio_cfg_regs #(.FX_DELAY_DEPTH(DEPTH)) dut (.*);
    assign observed[0] = {24'd0, vibrato_depth};
    assign observed[1] = {16'd0, vibrato_rate};
    assign observed[2] = {30'd0, fx_mode};
    assign observed[3] = {24'd0, wet_gain};
    assign observed[4] = {20'd0, delay_samples};
    assign observed[5] = {24'd0, feedback_gain};
    always #5 sys_clk = ~sys_clk;

    task automatic compare_outputs(input string label_text);
        for (int index = 0; index < 6; index++) begin
            checks++;
            if (observed[index] !== expected[index]) begin
                errors++;
                failures[index]++;
                if (failures[index] <= 3)
                    $display("FAIL depth=%0d %s %s: expected=%0d got=%0d (wr_en=%b data=%h)",
                             DEPTH, label_text, names[index], expected[index], observed[index], wr_en, wr_data);
            end
        end
    endtask

    task automatic step(
        input bit reset_active,
        input logic [5:0] enable,
        input logic [31:0] data,
        input string label_text
    );
        @(negedge sys_clk);
        rst_n = !reset_active;
        wr_en = enable;
        wr_data = data;
        #1;
        // 写入和复位都只能在上升沿生效；输入变化不应直接改变输出。
        if (model_valid) compare_outputs({label_text, " before edge"});
        @(posedge sys_clk);
        if (reset_active) begin
            expected[0] = 0;
            expected[1] = 1280; // Q8.8 的 5 Hz。
            expected[2] = 0;
            expected[3] = 0;
            expected[4] = (DEPTH-1 < 1920) ? 32'(DEPTH-1) : 32'd1920;
            expected[5] = 0;
        end
        else begin
            // 合法输入为零或独热写使能；其他寄存器必须保持。
            for (int index = 0; index < 6; index++) begin
                if (enable[index]) begin
                    if (data < lower_bound[index]) expected[index] = lower_bound[index];
                    else if (data > upper_bound[index]) expected[index] = upper_bound[index];
                    else expected[index] = data;
                end
            end
        end
        model_valid = 1;
        #1;
        compare_outputs(label_text);
    endtask

    initial begin
        logic [31:0] random_state;
        for (int index = 0; index < 6; index++) failures[index] = 0;
        step(1, 6'b000000, 0, "reset defaults");
        step(0, 6'b000000, 32'hffffffff, "hold after reset");

        // 每个寄存器均验证上下限、边界邻近值、内部值及完整 32 位无符号限幅。
        for (int index = 0; index < 6; index++) begin
            step(0, 6'b000001 << index, 0, "write zero");
            step(0, 6'b000001 << index, lower_bound[index], "minimum");
            if (lower_bound[index] > 0)
                step(0, 6'b000001 << index, lower_bound[index]-1, "below minimum");
            if (lower_bound[index] < upper_bound[index])
                step(0, 6'b000001 << index, lower_bound[index]+1, "above minimum");
            step(0, 6'b000001 << index,
                 (lower_bound[index]+upper_bound[index])/2, "interior value");
            if (upper_bound[index] > lower_bound[index])
                step(0, 6'b000001 << index, upper_bound[index]-1, "below maximum");
            step(0, 6'b000001 << index, upper_bound[index], "maximum");
            step(0, 6'b000001 << index, upper_bound[index]+1, "above maximum");
            step(0, 6'b000001 << index, 32'h00010001, "high bits must not be discarded");
            step(0, 6'b000001 << index, 32'h80000000, "unsigned sign-bit input");
            step(0, 6'b000001 << index, 32'hffffffff, "maximum unsigned input");
            step(0, 6'b000000, 0, "disabled write holds all registers");
        end

        // 小数编码应原样保留，不应在寄存器里先右移或转换单位。
        step(0, 6'b000010, 1280, "5 Hz encoding");
        step(0, 6'b000010, 1408, "5.5 Hz encoding");
        step(0, 6'b001000, 128, "wet gain 0.5 encoding");
        step(0, 6'b100000, 64, "feedback 0.25 encoding");
        step(0, 6'b000100, 256, "mode 256 must clamp to 3");

        // 每周期均可接受一笔写入，无需插入空闲周期。
        // 固定种子的混合序列同时检查地址之间的写入隔离与状态保持。
        random_state = 32'h12ab5678;
        for (int cycle = 0; cycle < 120; cycle++) begin
            random_state = random_state * 32'd1664525 + 32'd1013904223;
            step(0, 6'b000001 << (cycle % 6),
                 cycle % 2 == 0 ? random_state : random_state % 32'd4097,
                 "consecutive mixed writes");
        end
        step(1, 6'b111111, 32'hffffffff, "reset overrides writes");
        step(1, 6'b000010, 32'd2048, "held reset overrides writes");
        step(0, 6'b000000, 0, "hold reset defaults");
        step(0, 6'b000001, 32'd50, "resume after reset");

        $display("RESULT depth=%0d checks=%0d errors=%0d per-register=%0d/%0d/%0d/%0d/%0d/%0d",
                 DEPTH, checks, errors, failures[0], failures[1], failures[2],
                 failures[3], failures[4], failures[5]);
        done = 1;
    end
endmodule

module tb_audio_cfg_regs;
    wire [3:0] done;
    wire signed [31:0] errors [0:3];
    // 覆盖默认容量、小容量、最小容量和默认延迟的临界容量。
    cfg_regs_test_case #(.DEPTH(4096)) full_depth (.done(done[0]), .errors(errors[0]));
    cfg_regs_test_case #(.DEPTH(1024)) small_depth (.done(done[1]), .errors(errors[1]));
    cfg_regs_test_case #(.DEPTH(2)) minimum_depth (.done(done[2]), .errors(errors[2]));
    cfg_regs_test_case #(.DEPTH(1921)) boundary_depth (.done(done[3]), .errors(errors[3]));

    initial begin
        wait (&done);
        if (errors[0]+errors[1]+errors[2]+errors[3] != 0)
            $fatal(1, "audio_cfg_regs protocol checks FAILED: %0d mismatches",
                   errors[0]+errors[1]+errors[2]+errors[3]);
        $display("PASS tb_audio_cfg_regs: defaults, clamp boundaries, unsigned data, hold, isolation, reset priority");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "tb_audio_cfg_regs timeout");
    end
endmodule
