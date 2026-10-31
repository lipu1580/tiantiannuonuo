`timescale 1ns/1ns

module voice_manager #(
    parameter integer VOICE_COUNT = 4, // 管理的声部数量
    parameter integer NOTE_W      = 7  // 音符编号位宽
)(
    input  logic                              sys_clk, // 系统主时钟
    input  logic                              rst_n,   // 低有效复位

    input  logic                              event_valid, // 输入事件有效
    output logic                              event_ready, // 事件可被接收
    input  logic [1:0]                        event_type, // 事件类型
    input  logic [NOTE_W-1:0]                 event_note_id, // 目标音符编号
    input  logic [7:0]                        event_velocity, // 新音符力度

    input  logic [VOICE_COUNT-1:0]            voice_active, // 各声部活跃状态
    input  logic [15:0]                       voice_envelope [0:VOICE_COUNT-1], // 各声部包络电平

    output logic [VOICE_COUNT-1:0]            voice_start, // 各声部启动脉冲
    output logic [VOICE_COUNT-1:0]            voice_release, // 各声部释放脉冲
    output logic [NOTE_W-1:0]                 voice_note_id [0:VOICE_COUNT-1], // 分配给各声部的音符
    output logic [7:0]                        voice_velocity [0:VOICE_COUNT-1], // 分配给各声部的力度
    output logic [$clog2(VOICE_COUNT+1)-1:0]  active_voice_count // 活跃声部数量
);

    localparam     NOP           = 2'd0;
    localparam     NOTE_ON       = 2'd1;
    localparam     NOTE_OFF      = 2'd2;
    localparam     ALL_NOTES_OFF = 2'd3;


    logic [VOICE_COUNT-1:0] occupied;
    logic accepet_note_on, accepet_note_off, accepet_all_notes_off, accepet_nop;
    logic [VOICE_COUNT-1:0] target, same_note_id_target, free_target, full_target;
    // LRU 顺序表：打包成向量，避免在 for 循环内对非打包数组做非阻塞赋值
    // （iverilog/Verilator/部分综合工具对后者的支持不一致）
    localparam integer ORD_W = (VOICE_COUNT <= 1) ? 1 : $clog2(VOICE_COUNT);
    logic [VOICE_COUNT*ORD_W-1:0] order_flat;
    logic [VOICE_COUNT*ORD_W-1:0] order_next;

    function automatic logic [ORD_W-1:0] ord_get(input integer idx);
        ord_get = order_flat[idx*ORD_W +: ORD_W];
    endfunction
    int target_pos, same_target_pos, free_target_pos, full_target_pos;
    logic off_found, same_note_id, free_fond;

    assign accepet_note_on = event_ready && event_valid && (event_type == NOTE_ON);
    assign accepet_note_off = event_ready && event_valid && (event_type == NOTE_OFF);
    assign accepet_all_notes_off = event_ready && event_valid && (event_type == ALL_NOTES_OFF);
    assign accepet_nop = event_ready && event_valid && (event_type ==NOP);
    assign event_ready = rst_n;

    always_comb begin
        target = 'b0;
        target_pos = 'b0;
        off_found = 1'b0;
        same_note_id = 1'b0;
        free_fond = 1'b0;
        same_note_id_target = 'b0;
        free_target = 'b0;
        full_target = 'b0;
        same_target_pos = 'b0;
        free_target_pos = 'b0;
        full_target_pos = 'b0;
        if (rst_n) begin
            if (accepet_note_on) begin
                // 注意：不使用 break/continue，保证 iverilog 与综合工具都能处理。
                for (int i = 0; i < VOICE_COUNT; i++) begin
                    if (occupied[ord_get(i)] || voice_active[ord_get(i)]) begin
                        // 同音符优先重触发：只记录第一个匹配
                        if (!same_note_id &&
                            (voice_note_id[ord_get(i)] == event_note_id)) begin
                            same_note_id_target = ord_get(i);
                            same_target_pos = i;
                            same_note_id = 1'b1;
                        end
                    end
                    else begin
                        // 保留最后一个空闲声部
                        free_target = ord_get(i);
                        free_target_pos = i;
                        free_fond = 1'b1;
                    end
                end
                // 全部占用且没有同音符：抢占 order[0]
                if (!same_note_id && !free_fond) begin
                    full_target = ord_get(0);
                    full_target_pos = 0;
                end
                target = same_note_id ? same_note_id_target : (free_fond ? free_target : full_target);
                target_pos = same_note_id ? same_target_pos : (free_fond ? free_target_pos : full_target_pos);
            end
            else if (accepet_note_off) begin
                for (int i = 0; i < VOICE_COUNT; i++) begin
                    if ((occupied[ord_get(i)] || voice_active[ord_get(i)]) && (voice_note_id[ord_get(i)] == event_note_id)) begin
                        target = ord_get(i);
                        off_found = 1'b1;
                    end
                end
            end
            else begin
                target = '0;
            end
        end
    end

    
    // LRU 顺序更新：把 target 移到队尾，其余元素前移
    always_comb begin
        order_next = order_flat;
        for (int i = 0; i < VOICE_COUNT-1; i++) begin
            if (i >= target_pos) begin
                order_next[i*ORD_W +: ORD_W] = order_flat[(i+1)*ORD_W +: ORD_W];
            end
        end
        order_next[(VOICE_COUNT-1)*ORD_W +: ORD_W] = target[ORD_W-1:0];
    end

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            voice_release <= 'b0;
            voice_start <= 'b0;
            occupied <= 'b0;
            for (int i = 0; i < VOICE_COUNT; i++) begin
                voice_note_id[i] <= 'b0;
                voice_velocity[i] <= 'b0;
                order_flat[i*ORD_W +: ORD_W] <= ORD_W'(i);
            end
        end
        else begin
            voice_start   <= '0;
            voice_release <= '0;
            if (accepet_note_on) begin
                occupied[target] <= 1'b1;
                voice_start[target] <= 1'b1;
                voice_note_id[target] <= event_note_id;
                voice_velocity[target] <= event_velocity;
                order_flat <= order_next;
            end
            else if (accepet_note_off && off_found) begin
                occupied[target] <= 1'b0;
                voice_release[target] <= 1'b1;
            end
            else if (accepet_all_notes_off) begin
                for (int i = 0; i < VOICE_COUNT; i++) begin
                    occupied[i] <= 1'b0;
                    voice_release[i] <= 1'b1;
                end
            end
        end
    end


    always_comb begin
        active_voice_count = 'b0;
        for (int j= 0; j < VOICE_COUNT; j++) begin
            if (voice_active[j]) begin
                active_voice_count = active_voice_count + 1'b1;
            end
        end
    end
    
    //应该把i做成全局变量，target变成组合逻辑进行赋值，这样才能做到及时更新，不然和active_count没什么区别同时要把对应的信号换成组合逻辑用来给target判断赋值来源于谁

    // TODO: 接收事件后发出单周期 voice_start/voice_release。
    // 优先空闲声部；全满时抢占最早启动者；同音重复 NOTE_ON 重触发现有声部。
    // NOTE_OFF 释放匹配音符；ALL_NOTES_OFF 释放全部；NOP 只完成握手。
    // 分配时须立即预占，避免 voice_active 反馈更新前再次分配同一声部。
    // active_voice_count 包含处于 RELEASE 的声部。
endmodule
