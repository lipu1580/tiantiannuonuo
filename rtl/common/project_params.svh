`ifndef PROJECT_PARAMS_SVH
`define PROJECT_PARAMS_SVH

package project_params_pkg;
    // 时钟暂定值，板级联调时按实际 sys_clk 与约束确认。
    parameter integer SYS_CLK_HZ  = 27_000_000; // 系统时钟频率，待板级确认
    parameter integer SAMPLE_RATE = 48_000;     // 音频采样率
    parameter integer VOICE_COUNT = 4;           // 同时发声的声部数
    parameter integer NOTE_W      = 7;           // 音符编号位宽
    parameter integer PCM_W       = 16;          // PCM 样本位宽
    parameter integer PHASE_W     = 32;          // DDS 相位累加器位宽
    parameter integer VOICE_W     = 24;          // 单个声部样本位宽
    parameter integer WAVE_ADDR_W = 10;          // 波表地址位宽
    parameter integer PCM_FIFO_DEPTH = 4;        // PCM 缓冲样本数

    parameter logic [7:0]  DEFAULT_EXPRESSION = 8'd255;  // 默认持续力度/音量
    parameter logic [11:0] PITCH_BEND_CENTER  = 12'd2048; // 滑音中点，表示不变
    parameter logic [7:0]  DEFAULT_MASTER_GAIN = 8'd255; // 默认主音量
    parameter logic [15:0] ATTACK_STEP   = 16'd500;      // 包络起音步长
    parameter logic [15:0] DECAY_STEP    = 16'd30;       // 包络衰减步长
    parameter logic [15:0] SUSTAIN_LEVEL = 16'd42000;   // 包络延音电平
    parameter logic [15:0] RELEASE_STEP  = 16'd40;       // 包络释放步长
endpackage

`endif
