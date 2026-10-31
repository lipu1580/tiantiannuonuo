//=============================================================================
// 文件      : project_params.svh
// 归属      : 三人公共参数（成员 1 起草，三人共同维护）
// 说明      : 统一使用 package，不再使用宏定义。
//             成员 2 的输入模块通过 import project_params_pkg::*; 使用本文件。
//=============================================================================
`ifndef PROJECT_PARAMS_SVH
`define PROJECT_PARAMS_SVH

/* verilator lint_off DECLFILENAME */
package project_params_pkg;
    //----------------------------------------------------------------------
    // 系统时钟与音频
    //----------------------------------------------------------------------
    parameter integer SYS_CLK_HZ  = 27_000_000; // 系统时钟频率，待板级确认
    parameter integer SAMPLE_RATE = 48_000;     // 音频采样率
    parameter integer VOICE_COUNT = 4;           // 同时发声的声部数
    parameter integer NOTE_W      = 7;           // 音符编号位宽
    parameter integer PCM_W       = 16;          // PCM 样本位宽
    parameter integer PHASE_W     = 32;          // DDS 相位累加器位宽
    parameter integer VOICE_W     = 24;          // 单个声部样本位宽
    parameter integer WAVE_ADDR_W = 10;          // 波表地址位宽
    parameter integer PCM_FIFO_DEPTH = 4;        // PCM 缓冲样本数

    // 兼容旧宏命名，方便其他成员逐步迁移
    parameter integer AUDIO_SAMPLE_RATE = SAMPLE_RATE;
    parameter integer SAMPLE_W = PCM_W;

    parameter logic [7:0]  DEFAULT_EXPRESSION = 8'd255;  // 默认持续力度/音量
    parameter logic [11:0] PITCH_BEND_CENTER  = 12'd2048; // 滑音中点，表示不变
    parameter logic [7:0]  DEFAULT_MASTER_GAIN = 8'd255; // 默认主音量
    parameter logic [15:0] ATTACK_STEP   = 16'd500;      // 包络起音步长
    parameter logic [15:0] DECAY_STEP    = 16'd30;       // 包络衰减步长
    parameter logic [15:0] SUSTAIN_LEVEL = 16'd42000;   // 包络延音电平
    parameter logic [15:0] RELEASE_STEP  = 16'd40;       // 包络释放步长

    //----------------------------------------------------------------------
    // 成员 2 输入侧参数
    //----------------------------------------------------------------------
    parameter integer KEY_ROW_COUNT = 4;          // 矩阵行数
    parameter integer KEY_COL_COUNT = 4;          // 矩阵列数
    parameter integer KEY_COUNT     = 16;         // 总按键数
    parameter integer MATRIX_FRAME_HZ = 2000;     // 整张矩阵刷新率
    parameter integer KEY_PRESS_MS    = 2;        // 按下确认时间
    parameter integer KEY_RELEASE_MS  = 5;        // 释放确认时间

    parameter integer ADC_I2C_HZ = 400_000;       // ADS7830 I2C 速率
    parameter integer ADC_SAMPLE_INTERVAL_US = 20;// 每次事务后的等待间隔
    parameter logic [2:0] FSR_ADC_CHANNEL = 3'd0; // ADS7830 CH0 接 FSR
    parameter logic [2:0] POT_ADC_CHANNEL = 3'd1; // ADS7830 CH1 接电位器

    //----------------------------------------------------------------------
    // 5 路 FSR 触发输入（CH2~CH6，CH7 备用）
    //   新方案：FSR 一端接 3.3V、另一端直接接 ADS7830 通道，
    //   实测无需额外前端电路。RTL 只做阈值 / 迟滞 / 释放判定。
    //----------------------------------------------------------------------
    parameter integer TRIGGER_COUNT = 5;                          // 触发通道数
    parameter logic [2:0] TRIGGER_ADC_CHANNEL_BASE = 3'd2;        // P0 从 CH2 开始
    parameter logic [7:0] TRIGGER_THRESHOLD = 8'd20;              // 触发阈值（ADC 码）
    parameter integer TRIGGER_RELEASE_HYST = 4;                   // 释放回差
    parameter integer TRIGGER_RELEASE_SAMPLES = 3;                // 连续低于阈值几次判定松开
    parameter integer TRIGGER_RETRIGGER_MS = 20;                  // 两次触发最小间隔
    parameter integer TRIGGER_NOTE_OFF_MS = 2000;                 // 无样本时的兜底 NOTE_OFF
    parameter logic [7:0] TRIGGER_VEL_FULL_SCALE = 8'd200;        // 实测重击 ADC 值（力度满量程）

    //----------------------------------------------------------------------
    // 旧压电峰值方案（已由 FSR 触发替代）
    //   仅保留 piezo_peak.sv 的参数依赖，新代码请勿使用。
    //----------------------------------------------------------------------
    parameter integer PIEZO_COUNT = 5;
    parameter logic [2:0] PIEZO_ADC_CHANNEL_BASE = 3'd2; // P0 从 CH2 开始
    parameter logic [7:0] PIEZO_THRESHOLD = 8'd20;       // 全局触发阈值
    parameter integer PIEZO_NOTE_OFF_MS = 500;           // 自动 NOTE_OFF 时间
    parameter integer PIEZO_RETRIGGER_MS = 50;           // 防重复触发窗口
    parameter integer PIEZO_PEAK_RST_CYCLES = 1350;      // 峰值电容放电 50 us @27 MHz

    //----------------------------------------------------------------------
    // FSR / 音符 / 事件 FIFO
    //----------------------------------------------------------------------
    parameter integer FSR_FILTER_SHIFT = 2;       // 指数滤波 alpha = 1/4
    parameter logic [7:0] FSR_NOISE_GATE = 8'd6;  // FSR 噪声门限
    parameter logic [7:0] EXPR_MIN = 8'd96;       // 表情最小值：松手时的基线音量
    parameter logic [6:0] NOTE_BASE_C4 = 7'd60;   // 默认起始音符 C4
    parameter integer EVENT_FIFO_DEPTH = 8;       // 输入事件 FIFO 深度
endpackage
/* verilator lint_on DECLFILENAME */

`endif // PROJECT_PARAMS_SVH
