//=============================================================================
// 文件      : project_params.svh
// 归属      : 三人公共参数（成员 1 起草，三人共同确认）
// 说明      : 只存放跨模块共享的常量。成员 2 内部的实现参数放在各自模块中，
//             不放到这里，避免影响成员 1/3。
//=============================================================================
`ifndef PROJECT_PARAMS_SVH
`define PROJECT_PARAMS_SVH

//--------------------------------------------------------------------------
// 系统时钟与音频
//--------------------------------------------------------------------------
`define SYS_CLK_HZ            27_000_000   // Tang Nano 20K 板载晶振
`define AUDIO_SAMPLE_RATE     48_000       // PCM 采样率
`define VOICE_COUNT           4            // 基础复音数
`define NOTE_W                7            // MIDI 音符编号位宽
`define SAMPLE_W              16           // PCM 位宽
`define PHASE_W               32           // DDS 相位累加器位宽

//--------------------------------------------------------------------------
// 成员 2 输入侧参数
//--------------------------------------------------------------------------
`define KEY_ROW_COUNT         4
`define KEY_COL_COUNT         4
`define KEY_COUNT             16
`define MATRIX_FRAME_HZ       2000         // 整张 4x4 矩阵刷新率
`define KEY_PRESS_MS          2            // 按下确认时间（保证总延迟 < 10 ms）
`define KEY_RELEASE_MS        5            // 释放确认时间
`define ADC_I2C_HZ            400_000      // ADS7830 I2C 速率
`define ADC_SAMPLE_INTERVAL_US 20          // 7 通道轮询时，每次事务后的等待间隔
`define FSR_ADC_CHANNEL       3'd0         // ADS7830 CH0 接 FSR
`define POT_ADC_CHANNEL       3'd1         // ADS7830 CH1 接电位器

//--------------------------------------------------------------------------
// 5 路压电输入（CH2~CH6，CH7 备用）
//--------------------------------------------------------------------------
`define PIEZO_COUNT           5
`define PIEZO_ADC_CHANNEL_BASE 3'd2        // P0 从 CH2 开始
`define PIEZO_THRESHOLD       8'd20        // 全局触发阈值，后续可做每路校准
`define PIEZO_NOTE_OFF_MS     500          // 压电片无松开信号，触发后自动释放
`define PIEZO_RETRIGGER_MS    50           // 防重复触发窗口
`define PIEZO_PEAK_RST_CYCLES 1350         // 峰值电容放电 50 us @27 MHz

`define FSR_FILTER_SHIFT      2            // 指数滤波 alpha = 1/4
`define FSR_NOISE_GATE        8'd6         // FSR 噪声门限
`define NOTE_BASE_C4          7'd60        // 默认起始音符 C4
`define EVENT_FIFO_DEPTH      8            // 输入事件 FIFO 深度

`endif // PROJECT_PARAMS_SVH
