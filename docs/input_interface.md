# 成员 2 输入侧接口说明

版本：1.1  
对应 RTL：`rtl/input/input_top.sv`  
适用开发板：Sipeed Tang Nano 20K（27 MHz 主时钟）

---

## 1. 范围

`input_top` 把以下原始输入转换成成员 1 可直接使用的演奏事件和表情数据：

- 4x4 按键矩阵（选根音/音区/音色）
- 5 片 FSR402（触发 + 力度，直接接 ADC，无前端电路）
- 1 片 FSR402（持续表情）
- ADS7830 8 位 ADC（2 片 FSR 用途 + 电位器 + 5 路触发）
- 板级 `test_mode` / `test_pattern` 测试控制

成员 1 只例化 `input_top`，不直接访问扫描器、ADC、滤波器内部信号。

---

## 2. 时钟与复位

```systemverilog
input logic sys_clk;   // Tang Nano 20K 27 MHz
input logic rst_n;     // 低有效，所有 always_ff 同步复位
```

- 全部逻辑工作在 `sys_clk` 单时钟域。
- 按键列输入、I2C SDA 回读均在模块内部做两级同步。
- `rst_n` 建议由板级顶层提供经 PLL 锁定后的同步复位。

---

## 3. 演奏事件接口

### 3.1 端口

```systemverilog
output logic       event_valid;
input  logic       event_ready;
output logic [1:0] event_type;
output logic [6:0] event_note_id;
output logic [7:0] event_velocity;
```

**第 2 轮起，键盘不产生任何事件**。进入这条总线的只有两路：
5 路 FSR 触发（NOTE_ON / 电平释放 NOTE_OFF），以及「事件源切换到测试模式」时
合成的一次 ALL_NOTES_OFF。键盘只负责选根音 / 波形 / 效果（见 §4、§5）。

### 3.2 编码

| `event_type` | 含义 | `event_note_id` | `event_velocity` |
|---|---|---|---|
| `2'b00` | NOP | 无意义 | 无意义 |
| `2'b01` | NOTE_ON | MIDI 0~127 | 1~255 |
| `2'b10` | NOTE_OFF | 被释放音符 | 0 |
| `2'b11` | ALL_NOTES_OFF | 0 | 0 |

### 3.3 握手规则

一个事件在 `event_valid && event_ready` 的 `sys_clk` 上升沿完成传输。

当 `event_valid=1 && event_ready=0`：

- `event_type/event_note_id/event_velocity` 必须保持稳定；
- 事件保留在 `event_queue` 中，不会丢失；
- 新的按键事件继续进入队列，直到队列和源侧槽位都满。

### 3.3.1 事件为什么不会丢

事件在输入侧经过三级存储，每一级都是“保持式”的：

```text
按键译码器 / FSR 触发器             event_queue          input_top 输出
每键 / 每通道 2 个待发槽位   ->   深度 8 的 FIFO   ->   直接驱动 event_valid
```

- **源侧每键 2 个槽位**：`NOTE_ON` 还没被接收时到来的 `NOTE_OFF` 进第二个槽位，
  不会覆盖 `NOTE_ON`（这也是“持续音”问题的根源）。
- **FIFO 深度 8**（`EVENT_FIFO_DEPTH`）：写入由 `wr_ready` 门控，满时不会丢；
- **`input_overflow`**：只有源侧槽位也满了（同键短时间内积压 3 个事件）才置 1，
  并保持到复位。此时在队事件仍不会被破坏，只丢弃新事件。

因此 `input_overflow=1` 是真丢事件，不是“下游暂时忙”的提示。

### 3.4 事件产生规则（第 2 轮）

**键盘不产生任何音符事件。** `MATRIX_MODE` 参数已删除，只剩一种演奏模式：

1. 9 个根音键（K0,K1,K2,K4,K5,K6,K8,K9,K10）只更新 `base_note`，
   **不发 NOTE_ON/OFF**。
2. 3 个波形键（K3,K7,K11）只改 `waveform_sel`，见 §4。
3. 3 个效果键（K12,K13,K14）+ K15 短按只产生 cfg 写序列，见 §4.5。
4. K15 长按只产生一笔 cfg 写（颤音深度）。
5. 音符事件**全部**由 5 路 FSR 触发产生，见 §3.5。
6. 根音变化只影响之后新触发的音符；已发声音符保持原音高
   （`fsr_trigger` 在按下的瞬间锁存 `note_latched`）。
7. `event_velocity` 由 `fsr_trigger` 从触发时的 FSR 电平换算
   （`VEL_FULL_SCALE` 为满量程参考）。

`ALL_NOTES_OFF` 在输入侧只有一个来源：**事件源切换到测试模式**时，
`input_top` 内部合成的释放命令（清掉上一来源留下的音符）。
键盘按键永远不产生 `ALL_NOTES_OFF`。

### 3.5 FSR 触发规则

```text
note_id = clamp(base_note + TRIG_OFFSET[i], 0, 127)
TRIG_OFFSET = {0, 2, 4, 7, 9}   // 大调五声音阶
```

1. 某路 ADC 电平 >= `TRIGGER_THRESHOLD` 且该路处于 ARMED 时产生一次 `NOTE_ON`。
2. `velocity` 由触发时的 ADC 值线性映射到 1~255，满量程由
   `TRIGGER_VEL_FULL_SCALE` 标定（实测重击 ADC 值）。
3. 按住期间电平持续高于 `THRESHOLD - HYST`，不会重复触发。
4. 连续 `TRIGGER_RELEASE_SAMPLES` 个样本低于释放阈值后发 `NOTE_OFF`：
   **真实松开才释放**，不再依赖定时器。
5. 触发后进入 `TRIGGER_RETRIGGER_MS` 防重复窗口，窗口内同一路不会重复触发。
   **窗口到期也不会自动重新武装**：必须真实松手（样本低于释放阈值）后才重新
   ARMED，因此长按只会产生一次 `NOTE_ON`。
6. 兜底：ACTIVE 期间若长时间没有新样本（ADC 卡死/断线），
   `TRIGGER_NOTE_OFF_MS` 到期后强制发 `NOTE_OFF`。
7. `ALL_NOTES_OFF` 会清掉所有触发活跃状态和待发事件；
   **正在发声的通道要松手后才能再次触发**（否则“全部释放”按下去也停不住）。
8. 触发瞬间锁存 `note_id`，`NOTE_OFF` 用它。长按期间切换根音不会漏发旧音符的 `OFF`。

FSR 触发事件与矩阵普通事件共用 `event_queue`，仲裁优先级：

```text
ALL_NOTES_OFF > FSR 触发 > 矩阵普通事件
```

---

## 4. 表情接口

```systemverilog
output logic        expr_valid;
output logic [7:0]  expression;
output logic [11:0] pitch_bend;
output logic [1:0]  waveform_sel;
```

| 信号 | 说明 |
|---|---|
| `expr_valid` | FSR 已完成至少一次有效采样 |
| `expression` | FSR 滤波后的持续压力，映射到 `EXPR_MIN`~255（默认 96~255） |
| `pitch_bend` | 电位器映射值 0~4095，2048 为不弯音 |
| `waveform_sel` | 0=正弦，1=管风琴类，2=拨弦类，3=静音（保留编码，本轮无键） |

映射关系：

```text
pitch_bend = clamp(2048 + (pot_raw - 128) * 16, 0, 4095)
```

| `pot_raw` | `pitch_bend` |
|---|---|
| 0 | 0 |
| 64 | 1024 |
| 128 | 2048 |
| 192 | 3072 |
| 255 | 4080 |

`waveform_sel` 由 **3 个键直选**（不是循环）：

| 键 | `waveform_sel` |
|---|---|
| K3 | `2'b00` 正弦 |
| K7 | `2'b01` 管风琴类 |
| K11 | `2'b10` 拨弦类 |
| —（无键） | `2'b11` 静音 |

按一次即锁定，长按不变。`WAVEFORM_MAX_SEL` 参数**已删除**。

> **前提**：成员 1 的 `organ_1024.hex` / `pluck_1024.hex` 必须已合入
> （协议 §0.1 前置条件 P3），否则 K7/K11 会静音。

`test_mode=1` 时强制输出正弦波。

`expression` 映射（松手不为 0）：

```text
expression = EXPR_MIN + (fsr_filtered × (255 - EXPR_MIN)) >> 8
EXPR_MIN 默认 96
```

若不抬高基线，`expression=0` 会让 `adsr` 的包络乘 0，整件乐器无声。

---

## 4.5 cfg 配置总线（第 2 轮新增）

`input_top` 新增 6 根 cfg 端口，直接对接成员 1 `audio_core_expr` 的 6 根同名端口。
由内部 `cfg_master` 驱动，把「效果键 / K15 长按」翻译成寄存器写序列。

```systemverilog
output logic        cfg_valid;   // 请求有效
output logic        cfg_write;   // 恒 1：本轮只写不读
output logic [7:0]  cfg_addr;    // 字节偏移
output logic [31:0] cfg_wdata;   // 写数据
input  logic        cfg_ready;   // 目标可接收
input  logic [31:0] cfg_rdata;   // 组合读回（本轮不使用）
```

### 握手

`cfg_valid && cfg_ready` 的 `sys_clk` 上升沿完成一笔。
`cfg_valid=1 && cfg_ready=0` 期间 `cfg_addr` / `cfg_wdata` **保持不变**
（内部由寄存器化的 `seq_mode/step` 组合译码，天然满足）。

### 写入序列（协议 §6 权威版）

| 入口 | 目标模式 | 序列（地址 ← 数据） | 笔数 |
|---|---|---|---|
| K12 | 0 旁路 | `0x30←0`, `0x2C←0` | 2 |
| K13 | 1 延迟 | `0x30←0`, `0x34←1920`, `0x38←64`, `0x2C←1`, `0x30←64` | 5 |
| K15 短按 | 2 合唱 | `0x30←0`, `0x2C←2`, `0x30←64` | 3 |
| K14 | 3 混响 | `0x30←0`, `0x2C←3`, `0x30←64` | 3 |
| K15 长按 | — | `0x24←25/50/100/0` | 1 |

### 抢占

- 效果序列执行中又按了另一个效果键：**下一笔起**切换到新序列第 0 步。
  最坏会多写出 1 笔旧序列的中间步——因为那一笔的 `valid` 已经在同一拍被对端
  接收，`valid/ready` 协议不允许撤销。旧序列的中间步不会破坏
  「湿声关 → 参数 → 模式 → 湿声开」的结构，安全。
- **颤音不抢占**：`vib_req` 只把待发深度记进一个寄存器，等当前效果序列
  全部握手完成后再发 `0x24`。代价是几微秒，听不出来。

### 未接入 `audio_core_expr` 时

板级顶层把 `cfg_ready` 接常量 `1'b1`、`cfg_rdata` 接 `32'd0`。
此时序列会瞬间写完、无副作用，**成员 2 的 RTL 一行都不用改**。

### 成员 3 接线清单

| `input_top` | 方向 | 接到 |
|---|---|---|
| `cfg_valid` | out | `audio_core_expr.cfg_valid` |
| `cfg_write` | out | `audio_core_expr.cfg_write` |
| `cfg_addr[7:0]` | out | `audio_core_expr.cfg_addr` |
| `cfg_wdata[31:0]` | out | `audio_core_expr.cfg_wdata` |
| `cfg_ready` | in | `audio_core_expr.cfg_ready`（未接入时 `1'b1`） |
| `cfg_rdata[31:0]` | in | `audio_core_expr.cfg_rdata`（未接入时 `32'd0`） |

---

## 5. 调试信号

| 信号 | 位宽 | 含义 |
|---|---|---|
| `key_down` | 16 | 消抖后的按键状态，1=按下 |
| `fsr_raw` | 8 | 最近一次 FSR 原始 ADC 值 |
| `fsr_filtered` | 8 | FSR 滤波值 |
| `input_state` | 4 | `{test_mode, pressure_valid, adc_busy, event_valid}`（test_mode 为同步后的值） |
| `adc_busy` | 1 | ADS7830 正在转换/传输 |
| `adc_valid` | 1 | ADC 样本有效单周期脉冲 |
| `adc_bus_error` | 1 | I2C NACK / 总线不空闲 / 事务超时；下一次事务开始时清除 |
| `adc_timeout_debug` | 1 | 采样请求看门狗超时（总线钳死、从机无响应），保持到复位 |
| `input_overflow` | 1 | 源侧待发槽位真的丢过事件，保持到复位 |
| `piezo_peak_rst` | 5 | 旧压电方案遗留，当前恒为 0 |
| `piezo_hit_debug` | 5 | 5 路 FSR 电平是否超过阈值 |
| `piezo_active_debug` | 5 | 5 路 FSR 是否正在发声 |
| `base_note_debug` | 7 | 当前根音 MIDI 编号（= 60 + 音级，无八度概念） |
| `key_ghost_debug` | 1 | 2x2 矩形内出现 ≥3 个按键：存在鬼键组合 |
| `key_conflict_debug` | 1 | 同列跨行 ≥2 个按键：行驱动互相争用（无二极管矩阵的电学风险） |

调试信号可以接 LED、逻辑分析仪或仿真波形，不影响事件握手。

---

## 6. 输入参数

`input_top` 的常用参数（均有默认值）：

| 参数 | 默认值 | 说明 |
|---|---|---|
| `SYS_CLK_HZ` | 27_000_000 | 系统时钟 |
| `ROW_COUNT/COL_COUNT` | 4/4 | 矩阵规模 |
| `ROW_DWELL_CYC` | 3375 | 单行驻留 ≈125 us |
| `PRESS_CYCLES` | 54000 | 2 ms 按下确认 |
| `RELEASE_CYCLES` | 135000 | 5 ms 释放确认 |
| `ROW_ACTIVE_LOW` | 1 | 行低有效 |
| `COL_ACTIVE_LOW` | 1 | 列低有效 |
| `I2C_QUARTER_DIV` | 0 | 0=自动：满足 f_SCL≤400 kHz 且 t_LOW≥1.3 us，27 MHz 下得 18（SCL≈375 kHz） |
| `SAMPLE_INTERVAL` | 540 | 20 us 间隔，7 通道轮询 |
| `REQ_TIMEOUT` | 27000 | 采样请求看门狗（1 ms），超时跳过当前通道 |
| `FSR_CHANNEL` | 0 | ADS7830 CH0 |
| `POT_CHANNEL` | 1 | ADS7830 CH1 |
| `EXPR_MIN` | 96 | 表情最小值：松手时的基线音量，避免整件乐器无声 |
| `TRIG_BASE_CH` | 2 | 触发 P0 所在通道，P0~P4 = CH2~CH6 |
| `TRIG_THRESH` | 20 | 触发阈值（ADC 码） |
| `TRIG_HYST` | 4 | 释放回差 |
| `TRIG_REL_SAMP` | 3 | 连续几个样本低于释放阈值判定松开 |
| `TRIG_OFF_MS` | 2000 | 无样本时的兜底 NOTE_OFF |
| `TRIG_RETRIG_MS` | 20 | 防重复触发窗口 |
| `TRIG_VEL_FULL` | 200 | 力度满量程 ADC 值 |
| `TAP_HOLD_MS` | 600 | K15 短按/长按门槛（毫秒）；仿真可覆盖 |
| `EVENT_FIFO_DEPTH` | 8 | 事件 FIFO 深度 |
| `BASE_NOTE` | 60 | K0 对应 C4 |

---

## 7. 输入侧延迟预算

以默认参数计算：

| 环节 | 最坏延迟 |
|---|---|
| 矩阵扫描（4 行 x 125 us） | 0.5 ms |
| 消抖（按下确认） | 2 ms |
| 事件译码/FIFO | < 0.1 us |
| 7 通道 ADC 一轮扫描（触发优先） | ≈1 ms（375 kHz I2C） |
| FSR 触发到 NOTE_ON（含释放判定） | ≈1 ms |
| FSR 采样与滤波（持续表情） | ≈1 ms |
| **输入侧合计（按键路径）** | **≈3 ms** |

赛题要求“控制到音频输出 ≤ 10 ms”，剩余约 7 ms 留给 `audio_core`、
PCM FIFO 和 I2S 传输。若实测紧张，可把 `KEY_PRESS_MS` 降到 1 ms。

---

## 8. 测试模式

```systemverilog
input logic       test_mode;
input logic [1:0] test_pattern;
```

- `test_mode=1`：事件源切换为 `input_event_stub`，真实按键和 FSR 触发事件被排空丢弃；
  ADS7830/FSR 采样仍在运行，但不会送到成员 1。
- `test_mode=0`：事件源为真实矩阵 + FSR 触发。

### 8.1 切换过程（不会撤销事件）

`test_mode` 与 `test_pattern` 都经过两级同步后再使用。切换事件源不是组合直切，
而是分三步，保证 `event_valid=1 && event_ready=0` 时下游尚未接收的事件不会被撤销：

```text
M_RUN   : 正常输出（真实 FIFO 或测试序列）
   │ test_mode 变化
   ▼
M_WAIT  : 只把当前呈现的事件送出去，等下游接收（可能逐个交付 FIFO 里的事件）
   ▼
M_ALLOFF: 发出一个合成的 ALL_NOTES_OFF，释放上一来源留下的音符
   ▼
换源 + 复位测试序列
```

注意事项：

- `M_WAIT` 会一直等到下游接收当前事件。如果 `audio_core` 长时间不拉高
  `event_ready`，模式切换会停在这里——这是“宁可慢也不丢事件”的取舍。
- 上电后还没输出过事件时切换是直接的，不会多出一个 ALL_NOTES_OFF。
- 切换 `test_pattern`（测试序列编号）不会打断正在等待握手的事件：当前事件送完后
  补一个 ALL_NOTES_OFF，再从 0 ms 重新开始。

| `test_pattern` | 序列 |
|---|---|
| 0 | C4/E4/G4/C5 四音和弦，1000 ms 依次释放，1500 ms ALL_OFF |
| 1 | 8 音琶音，随后依次释放 |
| 2 | 单音重复，用于延迟测试 |
| 3 | 多音 + ALL_NOTES_OFF 压力测试 |

---

## 9. ADS7830 通道号与 I2C 约定（容易踩的坑）

`adc_ads7830` 的端口 `adc_channel_req` / `sample_channel` 始终是**物理通道号 0~7**，
和 `docs/input_pin_requirements.md` 的通道分配表一一对应。命令字里的 `C2:C0`
由驱动内部按数据手册编码，**不是通道号的二进制**：

| 物理通道 | C2 C1 C0 | 命令字 |
|---|---|---|
| CH0 | 000 | 0x84 |
| CH1 | 100 | 0x94 |
| CH2 | 001 | 0xA4 |
| CH3 | 101 | 0xB4 |
| CH4 | 010 | 0xC4 |
| CH5 | 110 | 0xD4 |
| CH6 | 011 | 0xE4 |
| CH7 | 111 | 0xF4 |

若直接把通道号写进 `C2:C0`，物理通道会变成 `0,2,4,6,1,3,5,7`：电位器和 FSR
整体串位（请求 CH1 实际读到 CH2）。`sim/ads7830_model.sv` 现在按数据手册解码，
所以 `tb_adc_ads7830` 的 CH0~CH7 全通道覆盖能抓到这类错误。

其它 I2C 约定：

- 自动分频：`QDIV ≥ ceil(SYS_CLK_HZ/(4*I2C_HZ))` 且 `2*QDIV/SYS_CLK_HZ ≥ 1.3 us`。
  27 MHz 下 `QDIV=18`，SCL≈375 kHz、`t_LOW`≈1.33 us，都在 Fast Mode 范围内。
  （只做整数截断会得到 16 → 421.9 kHz、`t_LOW`≈1.19 us，超规格。）
- 每个事务开始前必须看到 SDA 为高，否则视为总线被钳死：报 `bus_error`，
  走 9 个 SCL 的总线恢复，最多重试 2 次，绝不把全 0 当成成功样本。
- 事务期间有 quarter tick 超时保护；超时强制 STOP 并报错。
- STOP 之后再次确认 SDA 回到高电平，确认通过才输出 `sample_valid`。
- 上游的采样请求有 1 ms 看门狗（`REQ_TIMEOUT`）：ADC 卡死时跳过该通道继续轮询，
  并置 `adc_timeout_debug`。

---

## 10. 内部模块

| 模块 | 职责 |
|---|---|
| `key_scan` | 行扫描 + 列同步，输出原始 16 位键状态 + 鬼键/同列告警 |
| `key_debounce` | 逐键计数消抖，输出状态和单周期边沿 |
| `note_map` | 键号 → 根音音级 / 波形 / 效果模式 / 复用键（第 2 轮新映射） |
| `key_event_decoder` | 边沿 → 根音、波形（直选）、效果请求脉冲；**不发事件** |
| `key_tap_hold` | K15 短按/长按判决（600 ms，严格互斥） |
| `cfg_master` | 效果序列发生器 + 颤音档位循环 + 不抢占排队 |
| `event_queue` | valid/ready FIFO，背压缓存 |
| `adc_ads7830` | I2C 单次转换读取（通道编码/总线恢复/超时） |
| `fsr_trigger` | 5 路阈值/迟滞/力度/电平释放/兜底 NOTE_OFF，每路 2 槽位 |
| `fsr_filter` | 指数滤波、迟滞门限、力度映射 |
| `expression_mapper` | 电位器滤波、pitch_bend 映射、波形选择 |
| `input_event_stub` | 固定演示事件源（可 restart） |

---

## 11. 仿真

```bash
make lint        # 输入侧
make lint-audio  # 音频侧
make lint-top    # 板级顶层（input + audio + audio_out 全接起来）
make lint-all    # 上面三个
make sim         # 输入侧全部 testbench（iverilog）
make run-<tb>    # 单个 testbench，例如 make run-tb_cfg_master
```

第 2 轮新增的 testbench：

| TB | 覆盖 |
|---|---|
| `tb_note_map` | 16 键映射逐项核对（9 根音 + 3 波形 + 3 效果 + K15 复用） |
| `tb_key_tap_hold` | 600 ms 阈值边界、短/长按互斥、长按不重复、复位不出脉冲 |
| `tb_cfg_master` | 四段序列顺序/数据、颤音档位循环、背压保持、抢占、颤音不抢占、复位 |
| `tb_key_event_decoder` | 根音/波形直选/效果脉冲/K15 不产生 fx_req（重写） |
| `tb_input_top` | 整机：A8/A9 无 ALL_OFF 无音符、根音跟随、效果序列、K15 短长按、cfg 背压（重写） |

已删除：`tb_matrix_config`（`MATRIX_MODE` 概念取消，其覆盖面并入上面两个 TB）。

`make sim` 会检查仿真器退出码和 `TEST PASSED` 标记：`$fatal`/超时不会再被掩盖成“通过”。
