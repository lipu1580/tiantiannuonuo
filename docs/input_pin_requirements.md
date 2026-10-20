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
| `piezo_peak_rst[4:0]` | FPGA → 压电调理 | 5 路峰值电容放电，接 2N7002 栅极（高有效） |
| `piezo_hit_debug[4:0]` | 调试 | 5 路峰值是否超过阈值 |
| `piezo_active_debug[4:0]` | 调试 | 5 路是否正在发声 |
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
| CH0 | FSR402 | `FSR_ADC_CHANNEL=0` |
| CH1 | 电位器 | `POT_ADC_CHANNEL=1` |
| CH2~CH6 | 5 路压电峰值 | 每路独立峰值保持 + 复位 |
| CH7 | 备用 | 可扩展第二 FSR、滑音条等 |

> 该映射与当前 `project_params.svh` 和 testbench 一致。若改用
> `docs/device_Info_path.md` 的“CH0~CH4 压电”方案，必须同步修改 RTL 常量和
> 采样调度，详见 `docs/hardware_list.md` 第 6 节。

### 3.3 采样节奏

- FSR 与电位器交替采样，每个通道约 1.4 kHz。
- 单次 I2C 事务约 100 us（400 kHz）。
- 每次事务完成后等待 `SAMPLE_INTERVAL`（默认 250 us）再采样下一个通道。
- 扩展到 7 通道（5 压电 + FSR + 电位器）时，建议把 `SAMPLE_INTERVAL` 降到
  20~50 us，一轮扫描约 1~1.5 ms；压电峰值保持电路保证不会漏掉短脉冲。

### 3.4 压电输入（5 路）

压电片受迫时可能输出 ±几十伏的短脉冲，**不能直接接 ADS7830 或 FPGA**。
每路必须加：

```text
压电片 → 1kΩ 串联 → BAT54S 钳位到 0/3.3V → 3.3V TVS/Zener
       → 1nF 到地 → BAT85 峰值检波 → 100nF 保持 → 100Ω → ADS7830 CHx
```

另外，5 路峰值保持电容的放电端（2N7002 漏极）需要 5 根 FPGA GPIO：

```text
FPGA piezo_peak_rst[4:0] ── 100Ω ── 2N7002 栅极
                                     源极 ── GND
                                     漏极 ── 100nF 峰值电容
                                     栅极 ── 100kΩ ── GND
```

`piezo_peak_rst` 高有效：FPGA 读完峰值后拉高一段（默认 50 us），
把 100 nF 放电，为下一次触发做准备。

具体要求见 `docs/hardware_list.md` 第 4 节。关键点：

- 压电片两端并 1 MΩ 泄放；
- 钳位必须在连接器/面包板入口处；
- 5 路峰值保持电容互相独立；
- 峰值电容由 FPGA GPIO 控制 2N7002 放电后再进行下一次触发；
- 不要用电感去“中和”压电尖峰，电感会与压电片电容谐振。

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
6. 压电片信号进入 FPGA/ADC 前必须先经过限流+钳位，见
   `docs/hardware_list.md` 第 4 节。
7. `piezo_peak_rst[4:0]` 需要 5 根 GPIO，接到 5 路 2N7002 栅极；
   若引脚不足，可优先保证 5 路全部保留，或把调试信号减少。

---

## 8. 交付给成员 3 的检查表

- [ ] 4 行 + 4 列引脚已分配
- [ ] 列线上拉已确认
- [ ] SCL/SDA 引脚已分配，SDA 为双向
- [ ] SDA 4.7k 上拉到 3.3 V
- [ ] ADS7830 地址确认为 0x48
- [ ] CH0 接 FSR 分压，CH1 接电位器
- [ ] `test_mode`、`test_pattern[1:0]` 有拨码或按键
- [ ] `adc_bus_error`、`input_overflow` 可观测
