`timescale 1ns/1ns

module event_router #(
    parameter integer NOTE_W = 7 // 音符编号位宽
)(
    input  logic                  sys_clk, // 系统主时钟
    input  logic                  rst_n,   // 低有效复位
    input  logic                  test_mode, // 选择测试源或外部事件源

    input  logic                  event_valid, // 外部事件有效；与 event_ready 同为 1 时完成握手
    output logic                  event_ready, // 路由器可接收外部事件
    input  logic [1:0]            event_type, // 外部事件类型
    input  logic [NOTE_W-1:0]     event_note_id, // 外部音符编号
    input  logic [7:0]            event_velocity, // 外部触发力度

    input  logic                  test_event_valid, // 测试事件有效；与 ready 同为 1 时完成握手
    output logic                  test_event_ready, // 路由器可接收测试事件
    input  logic [1:0]            test_event_type, // 测试事件类型
    input  logic [NOTE_W-1:0]     test_event_note_id, // 测试音符编号
    input  logic [7:0]            test_event_velocity, // 测试触发力度

    output logic                  routed_event_valid, // 转发事件有效；与 ready 同为 1 时完成握手
    input  logic                  routed_event_ready, // 下游可接收转发事件
    output logic [1:0]            routed_event_type, // 转发的事件类型
    output logic [NOTE_W-1:0]     routed_event_note_id, // 转发的音符编号
    output logic [7:0]            routed_event_velocity // 转发的触发力度
);
    localparam IDLE = 2'd0;
    localparam SEND_CAHCE = 2'd1;
    localparam RELEASE = 2'd2;

    logic acitve_mode;
    logic [1:0] state, next_state;
    logic [NOTE_W-1:0] note_id_cache;
    logic [1:0] event_type_cache;
    logic [7:0] velocity_cahce;
    logic event_hs_suc, test_hs_suc, routed_hs_suc;

    assign event_ready = rst_n && !test_mode && (acitve_mode == test_mode) && (state == IDLE);
    assign test_event_ready = rst_n && test_mode && (acitve_mode == test_mode) && (state == IDLE);
    assign event_hs_suc = event_ready && event_valid;
    assign test_hs_suc = test_event_ready && test_event_valid; 
    assign routed_hs_suc = routed_event_ready && routed_event_valid; //handshake success

    always_comb begin
        if (!rst_n) begin
            next_state = IDLE;
        end 
        else begin
            case (state)
                IDLE: begin
                    if (test_hs_suc || event_hs_suc) begin
                        next_state = SEND_CAHCE;
                    end
                    else if (acitve_mode !== test_mode) begin
                        next_state = RELEASE;
                    end 
                    else begin
                        next_state = IDLE;
                    end
                end 
                SEND_CAHCE: begin
                    if (routed_hs_suc) begin
                        next_state = IDLE;
                    end
                    else next_state = SEND_CAHCE;
                end
                RELEASE: begin
                    if (routed_hs_suc) begin
                        next_state = IDLE;
                    end
                    else next_state = RELEASE;
                end
                default: next_state = IDLE;
            endcase
        end
    end

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            state <= IDLE;
        end 
        else begin
            state <= next_state;
        end
    end
    
    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            note_id_cache <= 'b0;
            event_type_cache <= 'b0;
            velocity_cahce <= 'b0;
            acitve_mode <= 'b0;
        end 
        else begin
            if (state == IDLE) begin
                if (event_hs_suc) begin
                    note_id_cache <= event_note_id;
                    event_type_cache <= event_type;
                    velocity_cahce <= event_velocity;
                end
                else if (test_hs_suc) begin
                    note_id_cache <= test_event_note_id;
                    event_type_cache <= test_event_type;
                    velocity_cahce <= test_event_velocity;
                end 
                else begin
                    
                end
            end
            else if (state == RELEASE) begin
                acitve_mode <= test_mode;
            end
            else begin
                
            end
        end
    end

    always_comb begin
        routed_event_valid = 'b0;
        if (!rst_n) begin
            routed_event_note_id = 'b0;
            routed_event_type = 'b0;
            routed_event_velocity = 'b0;
            routed_event_valid = 'b0;
        end
        else begin
            if (state == IDLE) begin
                routed_event_note_id = 'b0;
                routed_event_type = 'b0;
                routed_event_velocity = 'b0;
            end
            else if (state == SEND_CAHCE) begin
                routed_event_valid = 'b1;
                routed_event_note_id = note_id_cache;
                routed_event_type = event_type_cache;
                routed_event_velocity = velocity_cahce;
            end
            else begin
                routed_event_valid = 'b1;
                routed_event_note_id = 'b0;
                routed_event_velocity = 'b0;
                routed_event_type = 'b11;
            end
        end
    end


    // TODO: 两个事件源选一路；未选中源的 ready 为 0。
    // 下游阻塞时锁定当前来源和事件，不能因 test_mode 改变而替换字段。
    // 模式切换先完成已呈现事件，再释放旧模式声部，最后接收新源事件。
endmodule
