`timescale 1ns/1ns

module audio_test_source #(
    parameter integer NOTE_W = 7,          // 音符编号位宽
    parameter integer SAMPLE_RATE = 48_000 // 用于生成测试事件间隔
)(
    input  logic                  sys_clk, // 系统主时钟
    input  logic                  rst_n,   // 低有效复位
    input  logic                  audio_ce, // 按采样率推进序列计时
    input  logic                  enable, // 允许生成测试事件
    input  logic [1:0]            test_pattern, // 测试序列编号

    output logic                  event_valid, // 当前测试事件有效
    input  logic                  event_ready, // 下游可以接收事件
    output logic [1:0]            event_type, // 测试事件类型
    output logic [NOTE_W-1:0]     event_note_id, // 测试音符编号
    output logic [7:0]            event_velocity // 测试触发力度
);
    localparam TRIGGER = 2'd0;
    localparam WAIT = 2'd1;
    localparam RELEASE = 2'd2;
    localparam ARR_DEPTH = 4;
    localparam ARR_INDEX_W = 4;
    localparam     NOTE_ON       = 2'd1;
    localparam     NOTE_OFF      = 2'd2;
    localparam C4 = 7'd60,
    E4 = 7'd64,
    G4 = 7'd67,
    C5 = 7'd72;

    logic [NOTE_W-1:0] test_arr [0:ARR_DEPTH-1] = '{C4, E4, G4, C5};
    int audio_ce_cnt;
    logic [3:0] rd_index, _100ms_cnt;
    logic _100ms_vaild, _600ms_vaild;
    logic [1:0] state, next_state;
    logic hd_suc;
    logic enable_d;
    logic enable_rise;

    assign _100ms_vaild = (audio_ce_cnt == SAMPLE_RATE-1);
    assign _600ms_vaild = (_100ms_cnt == 5);
    assign hd_suc = event_ready && event_valid;
    assign enable_rise = enable && !enable_d;

    always_ff @(posedge sys_clk) begin
        if (!rst_n)
            enable_d <= 1'b0;  // 复位时认为上一拍 enable=0
        else
            enable_d <= enable; // 保存当前值，下一拍作为“上一拍值”
    end

    always_comb begin
        if (!rst_n) begin
            next_state = TRIGGER;
        end
        else begin
            case (state)
                TRIGGER: begin
                    if (hd_suc && rd_index == ARR_INDEX_W'(ARR_DEPTH - 1)) begin
                        next_state = WAIT;
                    end
                    else next_state = TRIGGER;
                end 
                WAIT: begin
                    if (_600ms_vaild) begin
                        next_state = RELEASE;
                    end
                    else next_state = WAIT;
                end
                RELEASE: begin
                    if (hd_suc && rd_index == ARR_INDEX_W'(ARR_DEPTH - 1)) begin
                        next_state = TRIGGER;
                    end
                    else next_state = RELEASE;
                end
                default: next_state = TRIGGER;
            endcase
        end
    end

    always_ff @(posedge sys_clk) begin
        if (!rst_n)
            state <= TRIGGER;
        else if (enable_rise && !event_valid)
            state <= TRIGGER;
        else if (enable)
            state <= next_state;
    end

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            audio_ce_cnt <= 'b0;
        end
        else if (enable_rise && !event_valid) begin
            audio_ce_cnt <= '0;
        end
        else if (audio_ce && enable) begin
            audio_ce_cnt <= (audio_ce_cnt + 1) % SAMPLE_RATE;
        end
    end

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            _100ms_cnt <= 'b0;
        end
        else if (enable_rise && !event_valid) begin
            _100ms_cnt <= '0;
        end
        else if (state == WAIT) begin
            if (enable && audio_ce && _100ms_vaild) begin
                _100ms_cnt <= (_100ms_cnt + 1) % 6;
            end
        end
    end

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            rd_index <= 'b0;
            event_valid <= 'b0;
        end
        else if (enable_rise && !event_valid) begin
            rd_index <= '0;
            event_valid <= '0;
        end
        else if (hd_suc) begin
            event_valid <= 'b0;
            rd_index <= (rd_index + 1) % ARR_DEPTH;
        end
        else if (enable && !event_valid && audio_ce && _100ms_vaild) begin
            event_note_id <= test_arr[rd_index];
            event_velocity <= 8'd100;
            event_valid <= 'b1;
            if (state == TRIGGER) begin
                event_type <= NOTE_ON;
            end
            else if (state == RELEASE) begin
                event_type <= NOTE_OFF;
            end
            else begin
                event_valid <= 'b0;
                event_note_id <= 'b0;
                event_velocity <= 'b0;
                event_type <= 'b0;
            end
        end
    end
    // audio_ce 用于按采样次数计时；事件握手在每个 sys_clk 上升沿处理。
    // enable=0 停止生成新事件；已呈现的有效事件必须保留到握手完成。
    // test_pattern 变化在序列重启时生效，不修改阻塞中的事件。
endmodule
