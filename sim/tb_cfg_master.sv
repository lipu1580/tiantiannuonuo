//=============================================================================
// 文件   : tb_cfg_master.sv
// 功能   : cfg 总线主控（验收项 A4 / A4c / A5 / A6 / A6b / A7 / A13）
//
//   覆盖：
//     1. 四条效果序列的地址/数据/顺序/笔数
//     2. 颤音档位循环 25 -> 50 -> 100 -> 0 -> 25
//     3. 背压：cfg_ready=0 期间 valid/addr/wdata 保持不变
//     4. 抢占：延迟序列第 2 步按混响 -> 立刻从混响第 0 步重跑
//     5. 颤音不抢占：延迟序列执行中长按 -> 先发完延迟，再发 0x24
//     6. 复位：序列中途复位 -> valid=0、busy=0，复位后可完整重跑
//     7. 复位默认：vib_step=0、vib_depth=0、fx_mode_latched=0
//=============================================================================
`timescale 1ns/1ps

module tb_cfg_master;

    localparam logic [7:0] A_WET  = 8'h30;
    localparam logic [7:0] A_MODE = 8'h2C;
    localparam logic [7:0] A_DLY  = 8'h34;
    localparam logic [7:0] A_FB   = 8'h38;
    localparam logic [7:0] A_VIB  = 8'h24;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    logic       fx_req = 1'b0;
    logic [1:0] fx_mode_req = 2'd0;
    logic       vib_req = 1'b0;

    logic        cfg_valid;
    logic        cfg_write;
    logic [7:0]  cfg_addr;
    logic [31:0] cfg_wdata;
    logic        cfg_ready = 1'b1;
    logic [31:0] cfg_rdata = 32'd0;

    logic        cfg_busy;
    logic [1:0]  fx_mode_latched;
    logic [1:0]  vib_step;
    logic [7:0]  vib_depth;

    int errors = 0;
    int checks = 0;

    always #5 clk = ~clk;

    cfg_master dut (
        .sys_clk        (clk),
        .rst_n          (rst_n),
        .fx_req         (fx_req),
        .fx_mode_req    (fx_mode_req),
        .vib_req        (vib_req),
        .cfg_valid      (cfg_valid),
        .cfg_write      (cfg_write),
        .cfg_addr       (cfg_addr),
        .cfg_wdata      (cfg_wdata),
        .cfg_ready      (cfg_ready),
        .cfg_rdata      (cfg_rdata),
        .cfg_busy       (cfg_busy),
        .fx_mode_latched(fx_mode_latched),
        .vib_step       (vib_step),
        .vib_depth      (vib_depth)
    );

    //-------------------------------------------------------------------------
    // 事务记录
    //-------------------------------------------------------------------------
    logic [7:0]  rec_addr [0:63];
    logic [31:0] rec_data [0:63];
    int          rec_cnt = 0;

    always @(posedge clk) begin
        if (rst_n && cfg_valid && cfg_ready) begin
            rec_addr[rec_cnt] = cfg_addr;
            rec_data[rec_cnt] = cfg_wdata;
            $display("  [%0t] CFG wr addr=0x%02h data=%0d", $time, cfg_addr, cfg_wdata);
            rec_cnt++;
        end
    end

    task automatic clear_rec;
        rec_cnt = 0;
    endtask

    task automatic do_fx(input logic [1:0] mode);
        @(negedge clk);
        fx_req      = 1'b1;
        fx_mode_req = mode;
        @(negedge clk);
        fx_req      = 1'b0;
        // 等序列跑完
        while (cfg_busy) @(posedge clk);
        repeat (2) @(posedge clk);
    endtask

    task automatic do_vib;
        @(negedge clk);
        vib_req = 1'b1;
        @(negedge clk);
        vib_req = 1'b0;
        repeat (4) @(posedge clk);
    endtask

    // 检查一笔
    task automatic chk(input int idx, input logic [7:0] a, input logic [31:0] d,
                       input string msg);
        checks++;
        if (idx >= rec_cnt) begin
            $display("FAIL [%s]: 缺少第 %0d 笔", msg, idx);
            errors++;
        end else if (rec_addr[idx] !== a || rec_data[idx] !== d) begin
            $display("FAIL [%s]: 第 %0d 笔 = 0x%02h<-%0d, 期望 0x%02h<-%0d",
                     msg, idx, rec_addr[idx], rec_data[idx], a, d);
            errors++;
        end else begin
            $display("PASS [%s]: 第 %0d 笔 = 0x%02h<-%0d", msg, idx, a, d);
        end
    endtask

    task automatic chk_cnt(input int exp, input string msg);
        checks++;
        if (rec_cnt != exp) begin
            $display("FAIL [%s]: %0d 笔, 期望 %0d 笔", msg, rec_cnt, exp);
            errors++;
        end else begin
            $display("PASS [%s]: %0d 笔", msg, rec_cnt);
        end
    endtask

    initial begin
        $display("========================================");
        $display(" tb_cfg_master: cfg 序列发生器");
        $display("========================================");

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        //---------------------------------------------------------------------
        // A13 复位默认
        //---------------------------------------------------------------------
        checks++;
        if (vib_step !== 2'd0 || vib_depth !== 8'd0 ||
            fx_mode_latched !== 2'd0 || cfg_busy !== 1'b0 || cfg_valid !== 1'b0) begin
            $display("FAIL [A13 复位默认]: vib_step=%0d vib_depth=%0d mode=%0d busy=%0b valid=%0b",
                     vib_step, vib_depth, fx_mode_latched, cfg_busy, cfg_valid);
            errors++;
        end else begin
            $display("PASS [A13 复位默认]: 全 0");
        end

        //---------------------------------------------------------------------
        // 1) 旁路 mode=0：2 笔
        //---------------------------------------------------------------------
        clear_rec;
        do_fx(2'd0);
        chk_cnt(2, "旁路笔数");
        chk(0, A_WET,  32'd0, "旁路");
        chk(1, A_MODE, 32'd0, "旁路");

        //---------------------------------------------------------------------
        // 2) 延迟 mode=1：5 笔
        //---------------------------------------------------------------------
        clear_rec;
        do_fx(2'd1);
        chk_cnt(5, "延迟笔数");
        chk(0, A_WET, 32'd0,    "延迟");
        chk(1, A_DLY, 32'd1920, "延迟");
        chk(2, A_FB,  32'd64,   "延迟");
        chk(3, A_MODE, 32'd1,   "延迟");
        chk(4, A_WET, 32'd64,   "延迟");

        //---------------------------------------------------------------------
        // 3) 合唱 mode=2：3 笔
        //---------------------------------------------------------------------
        clear_rec;
        do_fx(2'd2);
        chk_cnt(3, "合唱笔数");
        chk(0, A_WET,  32'd0,  "合唱");
        chk(1, A_MODE, 32'd2,  "合唱");
        chk(2, A_WET,  32'd64, "合唱");

        //---------------------------------------------------------------------
        // 4) 混响 mode=3：3 笔
        //---------------------------------------------------------------------
        clear_rec;
        do_fx(2'd3);
        chk_cnt(3, "混响笔数");
        chk(0, A_WET,  32'd0,  "混响");
        chk(1, A_MODE, 32'd3,  "混响");
        chk(2, A_WET,  32'd64, "混响");

        checks++;
        if (fx_mode_latched !== 2'd3) begin
            $display("FAIL [fx_mode_latched]: %0d, 期望 3", fx_mode_latched);
            errors++;
        end else begin
            $display("PASS [fx_mode_latched]: 3");
        end

        //---------------------------------------------------------------------
        // A4c 颤音档位循环：25 -> 50 -> 100 -> 0 -> 25
        //---------------------------------------------------------------------
        clear_rec;
        do_vib;                       // 第 1 次
        do_vib;                       // 第 2 次
        do_vib;                       // 第 3 次
        do_vib;                       // 第 4 次
        do_vib;                       // 第 5 次
        chk_cnt(5, "颤音 5 次笔数");
        chk(0, A_VIB, 32'd25,  "颤音档位");
        chk(1, A_VIB, 32'd50,  "颤音档位");
        chk(2, A_VIB, 32'd100, "颤音档位");
        chk(3, A_VIB, 32'd0,   "颤音档位");
        chk(4, A_VIB, 32'd25,  "颤音档位");

        checks++;
        if (vib_depth !== 8'd25) begin
            $display("FAIL [vib_depth]: %0d, 期望 25", vib_depth);
            errors++;
        end else begin
            $display("PASS [vib_depth]: 25");
        end

        //---------------------------------------------------------------------
        // A6 抢占：延迟序列第 2 笔之后按混响
        //---------------------------------------------------------------------
        clear_rec;
        @(negedge clk);
        fx_req      = 1'b1;
        fx_mode_req = 2'd1;
        @(negedge clk);
        fx_req      = 1'b0;
        // 等 2 笔握手完成
        while (rec_cnt < 2) @(posedge clk);
        @(negedge clk);
        fx_req      = 1'b1;
        fx_mode_req = 2'd3;
        @(negedge clk);
        fx_req      = 1'b0;
        while (cfg_busy) @(posedge clk);
        repeat (2) @(posedge clk);

        // 合法状态：延迟的前 2 笔 + 可能多出的 1 笔在途（见下），最后 3 笔必须是混响。
        //
        //   为什么允许 6 笔：fx_req 与某笔握手落在同一拍时，那笔 valid 已经被
        //   对端接收，无法撤回（valid/ready 协议本来就不允许撤销）。
        //   所以"抢占"的语义是"下一笔起切换"，最坏多写 1 笔。多写的这一笔
        //   属于旧序列的中间步，不会破坏"湿声关->参数->模式->湿声开"的结构。
        checks++;
        if (rec_cnt < 5 || rec_cnt > 6) begin
            $display("FAIL [A6 抢占]: 总笔数 %0d, 期望 5 或 6", rec_cnt);
            errors++;
        end else begin
            $display("PASS [A6 抢占]: 总笔数 %0d", rec_cnt);
        end
        chk(0, A_WET, 32'd0,    "抢占前(延迟)");
        chk(1, A_DLY, 32'd1920, "抢占前(延迟)");
        // 最后 3 笔必须完整是混响序列
        chk(rec_cnt - 3, A_WET,  32'd0,  "抢占后(混响)");
        chk(rec_cnt - 2, A_MODE, 32'd3,  "抢占后(混响)");
        chk(rec_cnt - 1, A_WET,  32'd64, "抢占后(混响)");

        //---------------------------------------------------------------------
        // A6b 颤音不抢占：延迟序列执行到一半时长按 K15
        //---------------------------------------------------------------------
        clear_rec;
        @(negedge clk);
        fx_req      = 1'b1;
        fx_mode_req = 2'd1;
        @(negedge clk);
        fx_req      = 1'b0;
        while (rec_cnt < 2) @(posedge clk);
        // 此刻插一笔颤音
        @(negedge clk);
        vib_req = 1'b1;
        @(negedge clk);
        vib_req = 1'b0;
        // 等所有事情结束
        while (cfg_busy) @(posedge clk);
        repeat (6) @(posedge clk);

        // 前 5 笔必须是完整的延迟序列，第 6 笔才是 0x24
        chk(0, A_WET,  32'd0,    "不抢占(延迟)");
        chk(1, A_DLY,  32'd1920, "不抢占(延迟)");
        chk(2, A_FB,   32'd64,   "不抢占(延迟)");
        chk(3, A_MODE, 32'd1,    "不抢占(延迟)");
        chk(4, A_WET,  32'd64,   "不抢占(延迟)");
        chk(5, A_VIB,  32'd50,   "不抢占(颤音排在其后)");
        chk_cnt(6, "不抢占总笔数");

        //---------------------------------------------------------------------
        // A5 背压：cfg_ready=0 期间字段必须保持不变
        //---------------------------------------------------------------------
        clear_rec;
        cfg_ready = 1'b0;
        @(negedge clk);
        fx_req      = 1'b1;
        fx_mode_req = 2'd1;
        @(negedge clk);
        fx_req      = 1'b0;
        repeat (5) @(posedge clk);

        begin
            logic [7:0]  a0;
            logic [31:0] d0;
            logic        v0;
            a0 = cfg_addr;  d0 = cfg_wdata;  v0 = cfg_valid;
            repeat (20) @(posedge clk);
            checks++;
            if (cfg_valid !== v0 || cfg_addr !== a0 || cfg_wdata !== d0) begin
                $display("FAIL [A5 背压]: valid/addr/data 在 ready=0 期间变化了");
                errors++;
            end else if (cfg_valid !== 1'b1) begin
                $display("FAIL [A5 背压]: ready=0 时 valid 应保持 1");
                errors++;
            end else if (rec_cnt != 0) begin
                $display("FAIL [A5 背压]: ready=0 期间不应有握手");
                errors++;
            end else begin
                $display("PASS [A5 背压]: 0x%02h<-%0d 稳定保持 20 拍",
                         cfg_addr, cfg_wdata);
            end
        end

        // 放开背压后序列继续跑完
        cfg_ready = 1'b1;
        while (cfg_busy) @(posedge clk);
        repeat (2) @(posedge clk);
        chk_cnt(5, "背压解除后延迟序列跑完");
        chk(0, A_WET,  32'd0,    "背压恢复");
        chk(4, A_WET,  32'd64,   "背压恢复");

        //---------------------------------------------------------------------
        // A5b 背压 + 抢占：未握手的请求字段绝不能变
        //   协议 §4.1 规则 2：cfg_valid=1 && cfg_ready=0 时
        //   valid/write/addr/wdata 必须保持稳定。
        //   所以"被背压卡住时又按了别的效果键"，必须先把当前这笔送完，
        //   再换新序列——不能把对端正在看的这笔偷偷改掉。
        //---------------------------------------------------------------------
        clear_rec;
        cfg_ready = 1'b0;
        @(negedge clk);
        fx_req      = 1'b1;
        fx_mode_req = 2'd1;          // 延迟
        @(negedge clk);
        fx_req      = 1'b0;
        repeat (5) @(posedge clk);

        begin
            logic [7:0]  a0;
            logic [31:0] d0;
            a0 = cfg_addr;  d0 = cfg_wdata;

            // 卡住期间再按混响
            @(negedge clk);
            fx_req      = 1'b1;
            fx_mode_req = 2'd3;
            @(negedge clk);
            fx_req      = 1'b0;
            repeat (30) @(posedge clk);

            checks++;
            if (cfg_addr !== a0 || cfg_wdata !== d0 || !cfg_valid) begin
                $display("FAIL [A5b 背压+抢占]: 未握手时字段被改动 (%0d->0x%02h<-%0d)",
                         a0, cfg_addr, cfg_wdata);
                errors++;
            end else if (rec_cnt != 0) begin
                $display("FAIL [A5b 背压+抢占]: ready=0 期间不应有握手");
                errors++;
            end else begin
                $display("PASS [A5b 背压+抢占]: 0x%02h<-%0d 保持稳定", a0, d0);
            end
        end

        // 放开背压：先送完被卡的那一笔，再从混响第 0 步重跑
        cfg_ready = 1'b1;
        while (cfg_busy) @(posedge clk);
        repeat (4) @(posedge clk);

        checks++;
        if (rec_cnt != 4) begin
            $display("FAIL [A5b 恢复]: %0d 笔, 期望 4（1 笔在途 + 混响 3 笔）",
                     rec_cnt);
            errors++;
        end else begin
            $display("PASS [A5b 恢复]: 4 笔（1 笔在途 + 混响 3 笔）");
        end
        chk(0, A_WET, 32'd0, "A5b 在途的一笔");
        chk(1, A_WET,  32'd0,  "A5b 之后是混响");
        chk(2, A_MODE, 32'd3,  "A5b 之后是混响");
        chk(3, A_WET,  32'd64, "A5b 之后是混响");

        //---------------------------------------------------------------------
        // A7 复位：序列中途复位
        //---------------------------------------------------------------------
        clear_rec;
        @(negedge clk);
        fx_req      = 1'b1;
        fx_mode_req = 2'd1;
        @(negedge clk);
        fx_req      = 1'b0;
        while (rec_cnt < 2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        checks++;
        if (cfg_valid !== 1'b0 || cfg_busy !== 1'b0) begin
            $display("FAIL [A7 复位]: valid=%0b busy=%0b, 期望 0/0",
                     cfg_valid, cfg_busy);
            errors++;
        end else begin
            $display("PASS [A7 复位]: valid=0 busy=0");
        end
        @(negedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // 复位后能完整重跑
        clear_rec;
        do_fx(2'd1);
        chk_cnt(5, "复位后重跑延迟");

        $display("========================================");
        if (errors == 0) begin
            $display("TEST PASSED: tb_cfg_master (%0d checks)", checks);
        end else begin
            $display("TEST FAILED: tb_cfg_master, %0d error(s)", errors);
        end
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
