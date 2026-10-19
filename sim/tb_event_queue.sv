//=============================================================================
// 文件   : tb_event_queue.sv
// 功能   : 事件 FIFO 测试：顺序、背压稳定性、溢出标志、满时同拍读写。
//=============================================================================
`timescale 1ns/1ps

module tb_event_queue;

    localparam integer DEPTH  = 4;
    localparam integer NOTE_W = 7;

    logic       clk = 1'b0;
    logic       rst_n = 1'b0;

    logic       wr_valid = 1'b0;
    logic       wr_ready;
    logic [1:0] wr_type = 2'd0;
    logic [6:0] wr_note = 7'd0;
    logic [7:0] wr_vel  = 8'd0;

    logic       rd_valid;
    logic       rd_ready = 1'b0;
    logic [1:0] rd_type;
    logic [6:0] rd_note;
    logic [7:0] rd_vel;

    logic       overflow;
    logic       overflow_clear = 1'b0;
    logic [2:0] level;

    int errors = 0;

    always #5 clk = ~clk;

    event_queue #(
        .DEPTH  (DEPTH),
        .NOTE_W (NOTE_W)
    ) dut (
        .sys_clk        (clk),
        .rst_n          (rst_n),
        .wr_valid       (wr_valid),
        .wr_ready       (wr_ready),
        .wr_type        (wr_type),
        .wr_note        (wr_note),
        .wr_vel         (wr_vel),
        .rd_valid       (rd_valid),
        .rd_ready       (rd_ready),
        .rd_type        (rd_type),
        .rd_note        (rd_note),
        .rd_vel         (rd_vel),
        .overflow       (overflow),
        .overflow_clear (overflow_clear),
        .level          (level)
    );

    task automatic write_event(input logic [1:0] t, input logic [6:0] n,
                               input logic [7:0] v);
        @(negedge clk);
        wr_valid = 1'b1;
        wr_type  = t;
        wr_note  = n;
        wr_vel   = v;
        if (!wr_ready) begin
            $display("FAIL: write_event not ready (level=%0d)", level);
            errors++;
        end
        @(posedge clk);
        @(negedge clk);
        wr_valid = 1'b0;
    endtask

    task automatic check_read(input logic [1:0] t, input logic [6:0] n,
                              input logic [7:0] v, input string msg);
        if (rd_valid !== 1'b1) begin
            $display("FAIL [%s]: rd_valid=0", msg);
            errors++;
        end else if (rd_type !== t || rd_note !== n || rd_vel !== v) begin
            $display("FAIL [%s]: got t=%0d n=%0d v=%0d, exp t=%0d n=%0d v=%0d",
                     msg, rd_type, rd_note, rd_vel, t, n, v);
            errors++;
        end else begin
            $display("PASS [%s]: t=%0d n=%0d v=%0d", msg, t, n, v);
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        if (rd_valid !== 1'b0) begin
            $display("FAIL: rd_valid should be 0 after reset");
            errors++;
        end

        //---------------------------------------------------------------------
        // 填满 4 个事件
        //---------------------------------------------------------------------
        write_event(2'd1, 7'd60, 8'd100);
        write_event(2'd1, 7'd62, 8'd110);
        write_event(2'd2, 7'd60, 8'd0);
        write_event(2'd1, 7'd64, 8'd120);

        @(negedge clk);
        if (level !== 3'd4) begin
            $display("FAIL: level=%0d after fill, expected 4", level);
            errors++;
        end
        if (wr_ready !== 1'b0) begin
            $display("FAIL: wr_ready should be 0 when full");
            errors++;
        end

        //---------------------------------------------------------------------
        // 满时继续写 -> overflow
        //---------------------------------------------------------------------
        wr_valid = 1'b1;
        wr_type  = 2'd1;
        wr_note  = 7'd67;
        wr_vel   = 8'd130;
        @(posedge clk);
        @(negedge clk);
        wr_valid = 1'b0;
        if (overflow !== 1'b1) begin
            $display("FAIL: overflow not set after write when full");
            errors++;
        end else begin
            $display("PASS: overflow set when full");
        end

        //---------------------------------------------------------------------
        // 背压期间字段稳定
        //---------------------------------------------------------------------
        check_read(2'd1, 7'd60, 8'd100, "first entry");
        repeat (10) @(negedge clk);
        check_read(2'd1, 7'd60, 8'd100, "first entry stable under backpressure");

        //---------------------------------------------------------------------
        // 按顺序读出
        //---------------------------------------------------------------------
        @(negedge clk); rd_ready = 1'b1;    // pop 1
        @(negedge clk); rd_ready = 1'b0;
        check_read(2'd1, 7'd62, 8'd110, "second entry");

        @(negedge clk); rd_ready = 1'b1;    // pop 2
        @(negedge clk); rd_ready = 1'b0;
        check_read(2'd2, 7'd60, 8'd0, "third entry");

        @(negedge clk); rd_ready = 1'b1;    // pop 3
        @(negedge clk); rd_ready = 1'b0;
        check_read(2'd1, 7'd64, 8'd120, "fourth entry");

        @(negedge clk); rd_ready = 1'b1;    // pop 4
        @(negedge clk); rd_ready = 1'b0;
        if (rd_valid !== 1'b0 || level !== 3'd0) begin
            $display("FAIL: queue not empty, level=%0d rd_valid=%0d",
                     level, rd_valid);
            errors++;
        end else begin
            $display("PASS: queue empty after drain");
        end

        //---------------------------------------------------------------------
        // 清溢出标志
        //---------------------------------------------------------------------
        @(negedge clk); overflow_clear = 1'b1;
        @(negedge clk); overflow_clear = 1'b0;
        if (overflow !== 1'b0) begin
            $display("FAIL: overflow_clear did not clear flag");
            errors++;
        end

        //---------------------------------------------------------------------
        // 满时同拍读写：wr_ready 应为 1，写入与读出同时发生
        //---------------------------------------------------------------------
        write_event(2'd1, 7'd60, 8'd1);
        write_event(2'd1, 7'd61, 8'd2);
        write_event(2'd1, 7'd62, 8'd3);
        write_event(2'd1, 7'd63, 8'd4);

        @(negedge clk);
        rd_ready = 1'b1;
        wr_valid = 1'b1;
        wr_type  = 2'd1;
        wr_note  = 7'd72;
        wr_vel   = 8'd200;
        #1;                                 // 等组合逻辑稳定
        if (wr_ready !== 1'b1) begin
            $display("FAIL: wr_ready should be 1 when full and rd_ready=1");
            errors++;
        end
        @(posedge clk);
        @(negedge clk);
        rd_ready = 1'b0;
        wr_valid = 1'b0;

        if (level !== 3'd4) begin
            $display("FAIL: level=%0d after simultaneous read/write", level);
            errors++;
        end
        check_read(2'd1, 7'd61, 8'd2, "simultaneous pop head");

        if (errors == 0) begin
            $display("TEST PASSED: tb_event_queue");
        end else begin
            $display("TEST FAILED: tb_event_queue, %0d error(s)", errors);
        end
        $finish;
    end

    initial begin
        #50_000;
        $display("TEST TIMEOUT: tb_event_queue");
        $finish;
    end

endmodule
