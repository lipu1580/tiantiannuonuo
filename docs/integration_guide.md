# 与成员 1 / 成员 3 的联调示例

本文件给出一个最小顶层连接示例，用于：
1. 成员 1 在没有真实按键时，用 `input_top.test_mode=1` 注入固定事件验证 4 路复音；
2. 成员 2 用 `input_event_stub` 先打通事件接口；
3. 成员 3 把 `input_top` 与 `audio_core`、`i2s_tx` 接到同一个 `sys_clk`。

> 实际的板级顶层由成员 3 维护（`rtl/top/tang_nano20k_top.sv`）。
> 本示例只用于说明端口连接，不包含具体引脚约束。

---

## 1. 顶层信号

```systemverilog
import project_params_pkg::*;
import audio_defs_pkg::*;

module tang_nano20k_top (
    input  logic        sys_clk,      // 27 MHz
    input  logic        rst_n,        // 低有效

    // 4x4 矩阵
    output logic [3:0]  key_row,
    input  logic [3:0]  key_col,

    // ADS7830 I2C
    output logic        adc_scl,
    inout  wire         adc_sda,

    // 旧压电方案遗留端口：当前恒为 0，可不连接
    output logic [4:0]  piezo_peak_rst,

    // 成员 2 测试事件源选择（input_event_stub）
    input  logic        test_mode,
    input  logic [1:0]  test_pattern,

    // 调试
    output logic [3:0]  led,
    output logic        i2s_bclk,
    output logic        i2s_lrclk,
    output logic        i2s_data
);

    //---------------------------------------------------------------------
    // 时钟使能：27 MHz -> 48 kHz（精确小数分频）
    //---------------------------------------------------------------------
    logic        audio_ce;
    logic [31:0] ce_acc;

    always_ff @(posedge sys_clk) begin
        if (!rst_n) begin
            ce_acc   <= 32'd0;
            audio_ce <= 1'b0;
        end else if (ce_acc + 32'd48_000 >= 32'd27_000_000) begin
            ce_acc   <= ce_acc + 32'd48_000 - 32'd27_000_000;
            audio_ce <= 1'b1;
        end else begin
            ce_acc   <= ce_acc + 32'd48_000;
            audio_ce <= 1'b0;
        end
    end

    //---------------------------------------------------------------------
    // 成员 2 -> 成员 1
    //---------------------------------------------------------------------
    logic        event_valid;
    logic        event_ready;
    logic [1:0]  event_type;
    logic [6:0]  event_note_id;
    logic [7:0]  event_velocity;

    logic        expr_valid;
    logic [7:0]  expression;
    logic [11:0] pitch_bend;
    logic [1:0]  waveform_sel;

    logic        adc_sda_oe;
    logic        adc_sda_i;

    assign adc_sda   = adc_sda_oe ? 1'b0 : 1'bz;
    assign adc_sda_i = adc_sda;

    input_top #(
        .SYS_CLK_HZ (SYS_CLK_HZ),
        .MATRIX_MODE (1)          // 1=矩阵选根音/音区，5 路 FSR 触发
    ) u_input_top (
        .sys_clk        (sys_clk),
        .rst_n          (rst_n),
        .key_row        (key_row),
        .key_col        (key_col),
        .adc_scl        (adc_scl),
        .adc_sda_oe     (adc_sda_oe),
        .adc_sda_i      (adc_sda_i),
        .piezo_peak_rst (piezo_peak_rst),
        .event_valid    (event_valid),
        .event_ready    (event_ready),
        .event_type     (event_type),
        .event_note_id  (event_note_id),
        .event_velocity (event_velocity),
        .expr_valid     (expr_valid),
        .expression     (expression),
        .pitch_bend     (pitch_bend),
        .waveform_sel   (waveform_sel),
        .test_mode      (test_mode),
        .test_pattern   (test_pattern),
        .key_down       (),
        .fsr_raw        (),
        .fsr_filtered   (),
        .input_state    (),
        .adc_busy       (),
        .adc_valid      (),
        .adc_bus_error  (),
        .input_overflow (),
        .octave_debug   (),
        .piezo_hit_debug    (),
        .piezo_active_debug (),
        .base_note_debug    ()
    );

    //---------------------------------------------------------------------
    // 成员 1：音频核心
    //---------------------------------------------------------------------
    logic        pcm_valid;
    logic        pcm_ready;
    logic signed [15:0] pcm_left;
    logic signed [15:0] pcm_right;

    logic [2:0]  active_voice_count;
    logic [3:0]  voice_active;

    audio_core #(
        .VOICE_COUNT (VOICE_COUNT),
        .NOTE_W      (NOTE_W),
        .SAMPLE_W    (SAMPLE_W)
    ) u_audio_core (
        .sys_clk        (sys_clk),
        .rst_n          (rst_n),
        .audio_ce       (audio_ce),

        .event_valid    (event_valid),
        .event_ready    (event_ready),
        .event_type     (event_type),
        .event_note_id  (event_note_id),
        .event_velocity (event_velocity),

        .expr_valid     (expr_valid),
        .expression     (expression),
        .pitch_bend     (pitch_bend),
        .waveform_sel   (waveform_sel),

        .pcm_valid      (pcm_valid),
        .pcm_ready      (pcm_ready),
        .pcm_left       (pcm_left),
        .pcm_right      (pcm_right),

        // 使用成员 2 的事件源时，必须关闭成员 1 的内部测试音源，
        // 否则两套事件会同时注入。详见第 3 节。
        .test_mode      (1'b0),
        .test_pattern   (test_pattern),

        .active_voice_count (active_voice_count),
        .voice_active       (voice_active)
    );

    //---------------------------------------------------------------------
    // 成员 3：I2S 输出
    //---------------------------------------------------------------------
    i2s_tx u_i2s_tx (
        .sys_clk   (sys_clk),
        .rst_n     (rst_n),
        .pcm_valid (pcm_valid),
        .pcm_ready (pcm_ready),
        .pcm_left  (pcm_left),
        .pcm_right (pcm_right),
        .i2s_bclk  (i2s_bclk),
        .i2s_lrclk (i2s_lrclk),
        .i2s_data  (i2s_data)
    );

    //---------------------------------------------------------------------
    // 调试 LED：低 4 位显示活跃声部数（active_voice_count 为 3 位）
    //---------------------------------------------------------------------
    assign led = {1'b0, active_voice_count};

endmodule
```

---

## 2. 联调顺序

1. **成员 1 自测（用成员 2 的固定序列）**：`input_top.test_mode=1`、
   `audio_core.test_mode=0`、`test_pattern=0`，确认 4 个音符
   C4/E4/G4/C5 依次触发，`active_voice_count` 达到 4。
2. **成员 2 自测**：`event_ready` 固定为 1，按 K0~K11 检查
   `event_note_id`，按 K12 检查 ALL_NOTES_OFF。
3. **成员 3 接通 I2S**：先把 `pcm_ready` 固定为 1，确认 PCM 数据变化；
   再接入 MAX98357A，听到测试音。
4. **真实输入**：`input_top.test_mode=0`、`audio_core.test_mode=0`，
   按矩阵键；调整 FSR 力度，确认 `event_velocity` 随压力变化。
5. **表情**：旋转电位器，确认 `pitch_bend` 在 2048 附近到两端变化。
6. **延迟测量**：用逻辑分析仪同时抓 `key_down[0]` 与 I2S 的
   `i2s_lrclk` 数据起点，测量按键到音频输出的总延迟，目标 ≤10 ms。

---

## 3. 注意事项

### 3.1 两套测试源不要同时打开

工程里存在两套互相独立、但输出协议相同的测试事件源：

| 测试源 | 位置 | 使能信号 |
|---|---|---|
| `input_event_stub` | 成员 2，`input_top` 内部 | `input_top.test_mode=1` |
| `audio_test_source` | 成员 1，`audio_core` 内部 | `audio_core.test_mode=1` |

两者都往事件总线上送 NOTE_ON/NOTE_OFF。上板联调时必须只启用其中一套：

| 场景 | `input_top.test_mode` | `audio_core.test_mode` |
|---|---|---|
| 用成员 2 的固定序列测音频核心 | 1 | 0 |
| 用成员 1 自己的测试音源 | 0 | 1 |
| 真实按键演奏 | 0 | 0 |

建议板级用两个独立拨码，或用一个 2 位模式选择信号分别驱动两端。
本文示例默认采用“成员 2 测试源”，因此 `audio_core.test_mode` 固定为 0。

### 3.2 其他注意事项

- `audio_ce` 必须严格为 48 kHz。上面的累加器实现不会长期漂移。
- `input_top` 与 `audio_core` 必须共用同一个 `sys_clk` 和 `rst_n`。
- 事件 FIFO 深度为 8。若成员 1 长时间拉低 `event_ready`，请监控
  `input_overflow`。
- `input_top.test_mode=1` 时真实按键事件会被排空丢弃，但 FSR/电位器仍在采样。
- ADS7830 的 SDA 必须在板级顶层接成双向，不能只接成 output。
- 若成员 1 的 `audio_core` 端口名称有更新，以成员 1 的正式接口为准，
  但 `event_*` / `expr_*` 的位宽和编码不得改变。

---

## 4. 不建议的连接方式

- 不要把 `input_top` 的 `event_valid` 直接接到 `audio_core` 的内部
  声部信号；必须经过 `event_ready` 握手。
- 不要让成员 3 直接修改 `event_type` 或 `event_note_id`。
- 不要在输入模块内部生成音频时钟或 PCM 数据。
- 不要把 `adc_scl/adc_sda` 配置成推挽输出。
