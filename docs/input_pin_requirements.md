# 输入侧引脚与电气连接需求（给成员 3）

对应模块：`rtl/input/input_top.sv`  
目标板：Sipeed Tang Nano 20K  
电平：3.3 V LVCMOS

本文件只定义**逻辑端口与电气连接要求**。具体 FPGA 封装引脚号由成员 3 在
最终 `.cst` 中分配，不要硬编码到输入模块里。

---

## 1. 端口清单

### 1.1 按键矩阵

| 端口 | 方向 | 位宽 | 有效电平 | 说明 |
|---|---|---|---|---|
| `key_row[3:0]` | FPGA → 矩阵 | 4 | 低有效 | 同一时刻只有一行为低 |
| `key_col[3:0]` | 矩阵 → FPGA | 4 | 低有效 | 按键按下时把对应列拉低 |

### 1.2 ADS7830（I2C）

| 端口 | 方向 | 说明 |
|---|---|---|
| `adc_scl` | FPGA → ADC | I2C 时钟，约 400 kHz |
| `adc_sda_oe` | FPGA 内部 | 1 = 拉低 SDA，0 = 释放 |
| `adc_sda_i` | ADC → FPGA | SDA 回读 |

板级顶层需要生成真正的双向 SDA：

```systemverilog
inout wire adc_sda;

assign adc_sda    = adc_sda_oe ? 1'b0 : 1'bz;
assign adc_sda_i  = adc_sda;
```

> 注意：任务书中的 `adc_cs_n/adc_sclk/adc_mosi/adc_miso` 是 SPI 命名，
> ADS7830 实际为 I2C 器件，不能按 SPI 接线。

### 1.3 其他

| 端口 | 方向 | 说明 |
|---|---|---|
| `test_mode` | 板级 → FPGA | 拨码开关或按键，1=内部测试音源 |
| `test_pattern[1:0]` | 板级 → FPGA | 两位拨码，选择测试序列 |
| `expr_valid` | FPGA → 成员 1 | 表情有效 |
| `expression[7:0]` | FPGA → 成员 1 | FSR 持续压力 |
| `pitch_bend[11:0]` | FPGA → 成员 1 | 滑音 |
| `waveform_sel[1:0]` | FPGA → 成员 1 | 音色 |
| `key_down[15:0]` | 调试 | 可接 16 个 LED 或逻辑分析仪 |
| `fsr_filtered[7:0]` | 调试 | 可接逻辑分析仪 |
| `input_state[3:0]` | 调试 | `{test_mode, pressure_valid, adc_busy, event_valid}` |
| `adc_bus_error` | 调试 | I2C 错误指示 |
| `input_overflow` | 调试 | 事件 FIFO 溢出 |
| `piezo_peak_rst[4:0]` | 保留 | 旧压电方案遗留，当前恒为 0，可不连接 |
| `piezo_hit_debug[4:0]` | 调试 | 5 路 FSR 电平是否超过阈值 |
| `piezo_active_debug[4:0]` | 调试 | 5 路 FSR 是否正在发声 |
| `base_note_debug[6:0]` | 调试 | 当前根音（含八度） |

---

## 2. 4x4 按键矩阵

### 2.1 推荐接法

```text
              key_col[0]   key_col[1]   key_col[2]   key_col[3]
                  │            │            │            │
                上拉         上拉         上拉         上拉      3.3V
                  │            │            │            │
key_row[0] ──┬── K0 ──────── K1 ──────── K2 ──────── K3
             │
key_row[1] ──┼── K4 ──────── K5 ──────── K6 ──────── K7
             │
key_row[2] ──┼── K8 ──────── K9 ──────── K10 ─────── K11
             │
key_row[3] ──┴── K12 ─────── K13 ─────── K14 ─────── K15
```

- 行线由 FPGA 驱动，默认输出高；扫描到某行时输出低。
- 列线为输入，必须上拉。若矩阵模块自带 10k 上拉，可直接使用；
  否则在 `.cst` 中启用内部上拉（Gowin `PULL_MODE=UP`）或外接 10k。
- 每个按键串联 100~220 Ω 可降低扫描瞬态干扰（可选）。

### 2.2 扫描时序

- 单行驻留 125 us，整帧 500 us（刷新率 2 kHz）。
- 行切换后等待 8 个时钟再采样列线。
- 列输入两级同步。

### 2.3 鬼键说明

基础版本按“最多 4 键同时按下、且不出现三键构成的 L 形组合”使用。
若要支持全键无冲，需要在每个按键两端加二极管，或在软件层做组合限制。
演奏和弦时建议选择同一行或不同行但不同列的键位组合。

---

## 3. ADS7830

### 3.1 基本连接

| ADS7830 引脚 | 连接 |
|---|---|
| VDD | 3.3 V |
| GND | GND |
| SCL | FPGA `adc_scl` |
| SDA | FPGA 双向 SDA，4.7k 上拉到 3.3 V |
| A0/A1（若模块引出） | GND |

- 7 位 I2C 地址：`0x48`（写字节 `0x90`，读字节 `0x91`）。
- I2C 速率：约 400 kHz（`I2C_QUARTER_DIV=16~17` @27 MHz）。
- SDA 必须外部上拉，FPGA 只做开漏拉低，不主动输出高电平。
- 不要用 5 V 上拉，ADC 与 FPGA 均为 3.3 V 系统。

### 3.2 通道分配

| 通道 | 用途 | 建议 |
|---|---|---|
| CH0 | FSR402（持续表情） | `FSR_ADC_CHANNEL=0` |
| CH1 | 电位器 | `POT_ADC_CHANNEL=1` |
| CH2~CH6 | 5 路 FSR 触发 | 每路 1 个 10 kΩ 分压即可 |
| CH7 | 备用 | 可扩展第二 FSR、滑音条等 |

> 该映射与 `project_params.svh` 中的 `TRIGGER_ADC_CHANNEL_BASE=2` 一致。
> 触发通道与表情通道的接法相同：都是一端接 3.3 V、另一端接 ADC，
> 并加一个 10 kΩ 到 GND。

### 3.3 采样节奏

- 7 通道轮询：`CH2 CH3 CH4 CH5 CH6`（FSR 触发）→ `CH0`（FSR 表情）→ `CH1`（电位器）。
- 单次 I2C 事务约 100 us（400 kHz）。
- 每次事务完成后等待 `SAMPLE_INTERVAL`（默认 20 us）再采样下一个通道。
- 一轮扫描约 0.84 ms，即每个通道约 1.2 kHz。FSR 电压是持续量，
  不依赖峰值保持，1.2 kHz 的采样率对按压动作完全够用。
- 触发通道排在最前，以保证触发延迟最低；表情/电位器变化慢，放在后面。

### 3.4 FSR 触发输入（5 路）

FSR402 是两端可变电阻，本身不产生电压，因此每路只需要一个分压电阻：

```text
3.3V ── FSR402 ──┬── ADS7830 CHx（CH2~CH6）
                 │
                10kΩ
                 │
                GND
```

- **不需要**钳位二极管、峰值保持电容、BAT85、2N7002 或运放。
- 无压力时 FSR 阻值 >1 MΩ，通道电压接近 0（ADC < 10）。
- 压力增大时阻值下降到 1~3 kΩ，通道电压升到 2.5~3.0 V（ADC 190~240）。
- 在通道与 GND 之间并联 100 nF 可抑制引线噪声（可选）。
- 若实际“不按时接近 3.3 V”，说明缺少到地的 10 kΩ 分压电阻，必须补上。

> 5 路使用各自的 10 kΩ，不要共用一个电阻：共用会把 5 路信号短接。

---

## 4. FSR402 力度传感器

### 4.1 推荐分压

```text
3.3V ── FSR402 ──┬── ADS7830 CH0
                 │
                10kΩ
                 │
                GND
```

- 无压力时 FSR 阻值很高，CH0 接近 0。
- 压力增大时 FSR 阻值下降，CH0 电压上升。
- 在 CH0 与 GND 之间并联 0.1 uF 电容可抑制噪声（可选）。
- 若实际方向相反（无压力接近 3.3 V），把 FSR 与 10k 位置对调，并在
  `fsr_filter` 中调整映射方向。

### 4.2 力度映射

```text
ADC 原始值
  → 一阶指数滤波(alpha=1/4)
  → 迟滞噪声门限(默认 6，回差 2)
  → 线性映射到 0~255
```

- 大阶跃（>32 LSB）时快速起音，保证按键瞬间力度响应。
- 释放时慢速衰减，避免噪声造成力度跳变。
- 轻按约 20~45，中按约 100~135，重按约 235~255。

### 4.3 校准

上电后不按压，观察 `fsr_filtered` 应接近 0。若存在偏置：

1. 调整 `rtl/common/project_params.svh` 中的 `FSR_NOISE_GATE`；
2. 或在 `fsr_filter` 参数中修改 `NOISE_GATE`、`FILTER_SHIFT`。

---

## 5. 电位器

```text
3.3V
  │
 10kΩ 电位器
  │
  ├── ADS7830 CH1（中间抽头）
  │
 GND
```

- 推荐 10k 线性电位器。
- 中点应接近 ADC 128，对应 `pitch_bend=2048`。
- 若中点偏差较大，可修改 `expression_mapper` 的 `CENTER_RAW`。

---

## 6. 复位与时钟

- `sys_clk`：Tang Nano 20K 板载 27 MHz。
- `rst_n`：低有效。建议板级用按键复位 + PLL 锁定信号同步后产生。
- 若使用 PLL 生成音频时钟，PCM 交接仍使用公共 `pcm_valid/pcm_ready`
  接口，输入侧不参与音频时钟域。

---

## 7. 约束文件注意事项

1. `adc_sda` 顶层必须声明为 `inout`，不要约束成普通 output。
2. `adc_scl` 建议配置为强驱动（默认即可）。
3. 矩阵列输入启用内部上拉；行输出默认高电平。
4. 所有输入引脚分配在同一 bank，避免跨 bank 电平不匹配。
5. 调试信号若引脚不足，可只保留 `key_down[3:0]`、`adc_bus_error`、
   `input_overflow`。
6. 5 路 FSR 触发只占用 ADC 的 CH2~CH6，不需要额外 GPIO。
7. `piezo_peak_rst[4:0]` 为旧方案遗留端口，当前恒为 0，可以不分配引脚；
   若 `.cst` 已存在，保留也无副作用。

---

## 8. 交付给成员 3 的检查表

- [ ] 4 行 + 4 列引脚已分配
- [ ] 列线上拉已确认
- [ ] SCL/SDA 引脚已分配，SDA 为双向
- [ ] SDA 4.7k 上拉到 3.3 V
- [ ] ADS7830 地址确认为 0x48
- [ ] CH0 接 FSR 表情分压，CH1 接电位器
- [ ] CH2~CH6 各接 1 片 FSR 触发，每路 1 个 10 kΩ 到 GND
- [ ] 不按任何 FSR 时，7 个通道电压都接近 0 V（确认分压存在）
- [ ] `test_mode`、`test_pattern[1:0]` 有拨码或按键
- [ ] `adc_bus_error`、`input_overflow` 可观测
