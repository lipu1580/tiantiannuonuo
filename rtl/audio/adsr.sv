`timescale 1ns/1ns

module adsr #(
    parameter logic [15:0] ATTACK_STEP   = 16'd500,   // 每个采样周期的起音增量
    parameter logic [15:0] DECAY_STEP    = 16'd30,    // 每个采样周期的衰减量
    parameter logic [15:0] SUSTAIN_LEVEL = 16'd42000, // 延音阶段目标电平
    parameter logic [15:0] RELEASE_STEP  = 16'd40,     // 每个采样周期的释放量
    parameter logic [15:0] MAX_VALUE     = 16'd65535   //包络最大值
)(
    input  logic         sys_clk, // 系统主时钟
    input  logic         rst_n,   // 低有效复位
    input  logic         audio_ce, // 推进一次包络更新
    input  logic         note_on, // 开始起音阶段
    input  logic         note_off, // 开始释放阶段
    input  logic [7:0]   velocity, // NOTE_ON 时锁存的力度
    input  logic [7:0]   expression, // 持续音量/力度控制
    output logic [15:0]  envelope_value, // 当前包络幅度
    output logic         active // 包络非零或仍处于释放阶段
);
    typedef enum  logic [2:0] {IDLE = 0, ATTACK, DECAY, SUSTAIN, RELEASE} state_t;
    state_t state, next_state;

    typedef enum logic [1:0] {CMD_NONE = 0, CMD_ON, CMD_OFF} cmd_t;
    cmd_t pending_cmd;
    cmd_t effective_cmd;

    logic [15 : 0] level;
    logic [7 : 0] pending_vel;

    always_comb begin : FSM
    next_state = state;
        case (state)
            IDLE: begin
                if (effective_cmd == CMD_ON) begin
                    next_state = ATTACK;
                end else begin
                    next_state = IDLE;
                end
            end 
            ATTACK: begin
                if (effective_cmd == CMD_ON) begin
                    next_state = ATTACK;
                end else if (effective_cmd == CMD_OFF) begin
                    next_state = RELEASE;
                end else if (level == MAX_VALUE) begin
                    next_state = DECAY;
                end
            end
            DECAY: begin
                if (effective_cmd == CMD_ON) begin
                    next_state = ATTACK;
                end else if (effective_cmd == CMD_OFF) begin
                    next_state = RELEASE;
                end else if (level == SUSTAIN_LEVEL) begin
                    next_state = SUSTAIN;
                end
            end
            SUSTAIN: begin
                if (effective_cmd == CMD_ON) begin
                    next_state = ATTACK;
                end else if (effective_cmd == CMD_OFF) begin
                    next_state = RELEASE;
                end
            end
            RELEASE: begin
                if (effective_cmd == CMD_ON) begin
                    next_state = ATTACK;
                end else if (effective_cmd == CMD_OFF) begin
                    next_state = RELEASE;
                end else if (level == 0) begin
                    next_state = IDLE;
                end
            end
            default: next_state = IDLE;
        endcase
    end

    always_ff @( posedge sys_clk ) begin : FSM_STATE
        if (!rst_n) begin
            state <= IDLE;
            level <= 16'd0;
        end
        else if (audio_ce) begin
            state <= next_state;
            case (state)
                IDLE: begin
                    level <= level;
                end 
                ATTACK: begin
                    if ({1'b0, level} + {1'b0, ATTACK_STEP} >= MAX_VALUE) begin
                        level <= MAX_VALUE;
                    end else begin
                        level <= level + ATTACK_STEP;
                    end
                end
                DECAY: begin
                    if ({1'b0, level} <= {1'b0, DECAY_STEP} + {1'b0, SUSTAIN_LEVEL}) begin
                        level <= SUSTAIN_LEVEL;
                    end else begin
                        level <= level - DECAY_STEP;
                    end
                end
                SUSTAIN: begin
                    level <= level;
                end
                RELEASE: begin
                    if (level < RELEASE_STEP) begin
                        level <= 16'd0;
                    end else begin
                        level <= level - RELEASE_STEP;
                    end
                end
                default: level <= 16'd0;
            endcase
        end
    end

    always_ff @( posedge sys_clk ) begin : data
        if (!rst_n) begin
            pending_vel <= '0;
            pending_cmd <= CMD_NONE;
        end
        else if (audio_ce) begin
            pending_cmd <= CMD_NONE;
            if (note_on) begin
                pending_vel  <= velocity;
            end
        end
        else if (note_on) begin
            pending_cmd <= CMD_ON;
            pending_vel <= velocity;
        end else if (note_off) begin
            pending_cmd <= CMD_OFF;
        end
    end

    always_comb begin : data2
        if (note_on) begin
            effective_cmd = CMD_ON;
        end else if (note_off) begin
            effective_cmd = CMD_OFF;
        end else begin
            effective_cmd = pending_cmd;
        end
    end

    assign envelope_value = (32'(level) * 32'(pending_vel) * 32'(expression)) >> 16; //先乘后除防截断
    assign active = (state !== IDLE) || (level !== 0); 
endmodule
