# 成员 2 职责与交付范围（最终方案版）

版本：2.0  
日期：2026-10-19  
适用方案：4×4 矩阵选音区/音色，5 片压电片触发，1 片 FSR 做持续表情，电位器做滑音，
ADS7830 做模拟采集，成员 1 的 `audio_core` 做合成，成员 3 做 I2S/功放/板级。

---

## 0. 当前阶段决策（2026-10-20）

**先实现最基本的 4 个 voice（赛题基础复音数），5 指/扫弦/轮指需要的更多 voice 作为后续升级点。**

| 项目 | 当前决定 |
|---|---|
| `audio_core.VOICE_COUNT` | 4（基础版） |
| 输入侧压电片 | 仍保留 5 片，ADC 仍按 5 路压电规划 |
| 5 个音同时触发 | 成员 1 做 voice stealing 或丢弃，允许第 5 个音抢占 |
| `VOICE_COUNT` | 必须参数化，不写死 |
| 后续升级 | 若演示需要五指同时发声/减少抢音，改成 6~8 voice |
| 事件协议 | 不变，仍为 `event_type/note_id/velocity` |

> 这里的“四路”指 **4 个 audio voice**，不是只做 4 片压电。
> 输入侧仍按 5 片压电 + 1 FSR + 1 电位器设计，ADS7830 用 7 个通道。

---

## 1. 一句话定位

成员 2 负责**把物理演奏动作变成成员 1 能直接使用的标准事件和表情控制字**：

```text
按键/压电/FSR/电位器
        ↓
  扫描、保护、ADC、滤波、阈值、映射
        ↓
event_*（NOTE_ON / NOTE_OFF / ALL_OFF）
expr_*（expression / pitch_bend / waveform_sel）
        ↓
成员 1 的 audio_core
```

**成员 1 不接收原始 ADC 值，也不需要知道 ADS7830 的通道号。**  
成员 2 必须把“CH2 的 137”翻译成“第 3 片压电被重击，NOTE_ON C4，velocity=180”。

---

## 2. 输入设备与职责

| 设备 | 数量 | 在最终方案中的职责 | 成员 1 看到什么 |
|---|---|---|---|
| 4×4 矩阵 | 1 | 选根音/音区、八度、波形、ALL_NOTES_OFF | `event_type=ALL_OFF`、`waveform_sel`、内部 `base_note` |
| 压电片 | 5 | 检测拨动/敲击，峰值决定力度 | `NOTE_ON + note_id + velocity` |
| FSR402 | 1 | 演奏中持续加力/减力（全局表情） | `expression[7:0]` |
| 电位器 | 1 | 滑音 | `pitch_bend[11:0]` |
| ADS7830 | 1 | 把上述模拟电压转成 8 位数字量 | 不直接可见 |

> ADS7830 是 **ADC（模数转换器）**，不是 DAC。它把 0~3.3 V 模拟电压转成 0~255，
> FPGA 通过 I2C 读取。压电片的原始尖峰不能直接进 ADC，必须先做限流/钳位/峰值保持。

---

## 3. 最终数据流

```text
4x4 矩阵 ──► key_scan ──► key_debounce ──► matrix_config_decoder
                                              │
                                              ├─► base_note / octave / waveform
                                              └─► ALL_NOTES_OFF ──┐
                                                                  │
5 路压电 ──► 保护/峰值保持 ──► ADS7830 CH2~CH6 ──► adc_scheduler ──┤
                                                                  ├─► event_encoder ──► event_queue ──► event_* ──► audio_core
1 路 FSR ──► 分压/滤波 ──► ADS7830 CH0 ──► fsr_filter ──► expression ──────────────────────────────────► audio_core
电位器   ──► 分压/滤波 ──► ADS7830 CH1 ──► expression_mapper ──► pitch_bend ───────────────────────────► audio_core
```

关键点：

- **矩阵不再直接发 NOTE_ON**。它负责“现在按什么调/音区/音色”，压电片负责“什么时候发声”。
- 压电片没有可靠“松开”信号，所以 NOTE_OFF 由成员 2 的定时器自动产生。
- 矩阵配置键（八度/音色）直接更新寄存器，不占用事件 FIFO。
- 只有 NOTE_ON / NOTE_OFF / ALL_NOTES_OFF 进入 `event_queue`。

---

## 4. 对成员 1 的正式接口

### 4.1 事件

```systemverilog
output logic       event_valid;
input  logic       event_ready;
output logic [1:0] event_type;      // 00=NOP 01=NOTE_ON 10=NOTE_OFF 11=ALL_OFF
output logic [6:0] event_note_id;   // MIDI 0~127
output logic [7:0] event_velocity;  // 1~255
```

握手：`event_valid && event_ready` 的时钟上升沿传输。  
`event_ready=0` 时字段保持不变，事件由 FIFO 缓存。

### 4.2 表情

```systemverilog
output logic        expr_valid;
output logic [7:0]  expression;     // FSR 持续表情
output logic [11:0] pitch_bend;     // 0~4095，中点 2048
output logic [1:0]  waveform_sel;   // 0=正弦 1=方波 2=锯齿
```

### 4.3 明确不给成员 1 的东西

- 原始 ADC 值、通道号、I2C 时序；
- 压电片原始尖峰；
- 矩阵扫描行/列电平；
- FSR 分压电压。

这些都属于成员 2 内部实现。

---

## 5. 矩阵与压电的最终映射建议

### 5.1 矩阵

建议把 16 个键定义为：

| 键 | 功能 |
|---|---|
| K0~K11 | 选择根音 C4~B4（12 个半音） |
| K12 | ALL_NOTES_OFF |
| K13 | 八度 +1 |
| K14 | 波形切换 0→1→2→0 |
| K15 | 八度 -1 |

按下 K0~K11 时**不发声**，只更新内部 `base_note`。  
八度和波形只影响之后新触发的音符；已经发声的音保持原音高/音色，避免跳音。

### 5.2 压电片

5 片压电片按大调五声音阶排列：

| 压电片 | 相对根音偏移 | 根音 C4 时 |
|---|---|---|
| P0 | +0 | C4 (60) |
| P1 | +2 | D4 (62) |
| P2 | +4 | E4 (64) |
| P3 | +7 | G4 (67) |
| P4 | +9 | A4 (69) |

触发时：

```text
note_id = clamp(base_note + PIEZO_OFFSET[piezo_index] + 12 * octave_offset, 0, 127)
```

`note_id` 在触发瞬间锁存，自动 NOTE_OFF 使用同一个编号。

### 5.3 力度

- 每路压电峰值 ADC 值 -> 减去该路阈值 -> 映射到 1~255。
- 每路可有独立的阈值/增益校准参数。
- 峰值低于阈值不触发。
- 防重复触发时间建议 30~80 ms。
- 自动 NOTE_OFF 时间建议 300~800 ms，可参数化。

### 5.4 表情

- FSR 滤波值 -> `expression`，建议映射到 `EXPR_MIN~255`（例如 64~255），
  避免松开 FSR 后整件乐器完全无声。
- 一个 FSR 是全局表情，作用于所有正在发声的声部。

### 5.5 滑音

- 电位器中点死区（例如 ±4 ADC LSB）防止手不动时音高漂移。
- 死区外线性映射到 0~4095，中点 2048。

---

## 6. 需要实现的 RTL 模块

| 模块 | 当前状态 | 最终方案需要做什么 |
|---|---|---|
| `key_scan.sv` | 已完成 | 保持 |
| `key_debounce.sv` | 已完成 | 保持 |
| `note_map.sv` | 已完成 | 保留键位映射；MATRIX_MODE=1 时由译码器用键号选根音 |
| `key_event_decoder.sv` | 已完成 | 支持 `MATRIX_MODE=0/1`，输出 `base_note` |
| `event_queue.sv` | 已完成 | 保持，供 NOTE_ON/OFF/ALL_OFF 使用 |
| `adc_ads7830.sv` | 已完成 | 保持 I2C 驱动；7 通道调度在 `input_top` |
| `input_top.sv` ADC 调度 | 已完成 | 7 通道轮询，压电优先 |
| `piezo_peak.sv` | 已完成 | 5 路峰值/阈值/力度/自动 NOTE_OFF/放电控制 |
| `fsr_filter.sv` | 已完成 | 可增加零点/满量程校准（P1） |
| `expression_mapper.sv` | 已完成 | 可增加中心死区、`EXPR_MIN`（P1） |
| `input_event_stub.sv` | 已完成 | 可增加压电测试序列（P1） |
| `input_top.sv` 顶层 | 已完成 | 已接入 7 通道、piezo_peak、事件仲裁 |

### 6.1 新增的顶层端口

如果采用“峰值保持 + 2N7002 放电”方案，`input_top` 需要新增：

```systemverilog
output logic [4:0] piezo_peak_rst;   // 5 路峰值电容放电，高有效
```

可选（如果加比较器做低延迟触发）：

```systemverilog
input  logic [4:0] piezo_hit;        // 5 路比较器输出
```

这些端口必须同步给成员 3，写入最终 `.cst`。

---

## 7. 关键参数建议

| 参数 | 建议值 | 说明 |
|---|---|---|
| ADC 通道 | CH0 FSR、CH1 POT、CH2~CH6 压电、CH7 备用 | 与当前 RTL 兼容 |
| `SAMPLE_INTERVAL` | 20~50 us | 7 通道一轮扫描 <1.5 ms |
| 压电阈值 | 每路单独校准 | 轻拨不误触，重击不削顶 |
| 防重复触发 | 30~80 ms | 防止一次拨动发多个 NOTE_ON |
| 自动 NOTE_OFF | 300~800 ms | 压电片无松开信号 |
| FSR 滤波 | alpha=1/4 | 当前已实现 |
| FSR 快速起音 | delta>32 | 当前已实现 |
| FSR 噪声门限 | 6（回差 2） | 当前已实现 |
| 电位器死区 | ±4 LSB | 需要新增 |
| 力度映射 | 1~255 | 0 会被当成无声 |

---

## 8. 验收标准

- [ ] 5 路压电都能独立触发，互不串扰
- [ ] 轻/中/重击的 velocity 明显不同
- [ ] 压电触发到 NOTE_ON 的延迟 <2 ms（不含音频核心）
- [ ] 自动 NOTE_OFF 时间可调，不会长鸣
- [ ] 连续快速拨动不会重复触发
- [ ] 矩阵选根音/八度/波形正确，且不影响已发声音符
- [ ] FSR 能连续改变所有活跃声部强弱
- [ ] 电位器中点稳定，无抖动
- [ ] `event_ready=0` 时事件不丢失
- [ ] 7 通道 ADC 一轮扫描 <1.5 ms
- [ ] 与成员 1 联调后，控制到音频输出 ≤10 ms

---

## 9. 最终方案与实现状态（重点）

最终方案已在 RTL 中落地（2026-10-20），只剩硬件/联调：

| 最终方案要求 | 实现位置 | 状态 |
|---|---|---|
| 矩阵 K0~K11 只更新根音，不发 NOTE_ON | `key_event_decoder.sv` `MATRIX_MODE=1` | ✅ |
| 5 路压电峰值 -> NOTE_ON + velocity | `piezo_peak.sv` | ✅ |
| 压电自动 NOTE_OFF | `piezo_peak.sv` `PIEZO_OFF_MS` | ✅ |
| FSR 只做 `expression` | `fsr_filter.sv` + `expression_mapper.sv` | ✅ |
| ADC 扫 7 个通道 | `input_top.sv` `scan_idx` 0~6 | ✅ |
| `input_top` 增加 `piezo_peak_rst[4:0]` | `input_top.sv` 端口 | ✅ |
| 压电保护/峰值保持电路 | 硬件制作 | ⬜ |
| 顶层 + `.cst` + 上板测试 | 成员 3 | ⬜ |

`MATRIX_MODE` 参数保留两种工作方式：

- `MATRIX_MODE=0`：矩阵当键盘的测试模式（默认，兼容旧 testbench）；
- `MATRIX_MODE=1`：矩阵选音区、压电触发的正式演奏模式。

这样不会破坏已经通过的 testbench，也方便上板对比。

---

## 10. 建议实施顺序（后 3 步待完成）

1. ~~定案通道映射（CH0 FSR、CH1 POT、CH2~6 压电）~~ ✅
2. ~~写 `piezo_peak.sv`，仿真验证阈值/力度/自动 NOTE_OFF~~ ✅
3. ~~把 ADC 调度扩到 7 通道~~ ✅
4. ~~改 `note_map` / `key_event_decoder`，支持 `MATRIX_MODE`~~ ✅
5. ~~在 `input_top` 中接入压电事件和 `piezo_peak_rst`~~ ✅
6. ~~增加压电脉冲模型、5 路并发触发 testbench~~ ✅
7. 制作 5 路压电调理板并上板验证。
8. 与成员 1/3 联调，测端到端延迟（目标 ≤10 ms）。
