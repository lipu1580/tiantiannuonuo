# 基于 FPGA 的实时多音色合成电子乐器引擎

河南理工大学“甜甜糯糯欧尼酱”队 —— 2026 全国大学生嵌入式芯片与系统设计竞赛
FPGA 创新设计赛道（高云半导体）选题二。

本仓库当前完成 **成员 2：交互输入与演奏事件模块**。成员 1（音频合成）和
成员 3（I2S/功放/板级）通过本仓库约定的公共接口并行开发。

---

## 1. 成员 2 的工作范围

```text
4x4 按键矩阵 ──┐
FSR402 压力  ──┼─► input_top ──► event_* (NOTE_ON/OFF/ALL_OFF)
ADS7830 ADC ──┘                 └► expr_*  (expression/pitch_bend/waveform_sel)
```

- 硬件完成：矩阵扫描、消抖、键位映射、按下/释放检测、八度切换、波形切换。
- 硬件完成：ADS7830 I2C 驱动、FSR 滤波与力度映射、电位器滑音映射。
- 协议完成：`event_valid/event_ready` 握手；下游阻塞时事件保存在 FIFO 中，
  字段保持不变。
- 不负责：DDS、波表、ADSR、混音、I2S、功放。

---

## 2. 目录结构

```text
.
├── rtl/
│   ├── common/
│   │   ├── audio_defs.svh          # 事件编码、波形编码（公共协议）
│   │   └── project_params.svh      # 27 MHz、48 kHz、声部数、输入参数
│   └── input/                      # 成员 2
│       ├── input_top.sv            # ★ 唯一公开顶层
│       ├── key_scan.sv             # 4x4 行扫描
│       ├── key_debounce.sv         # 逐键消抖
│       ├── note_map.sv             # 键号 -> MIDI 音符/功能键
│       ├── key_event_decoder.sv    # 边沿 -> 标准事件
│       ├── event_queue.sv          # 事件 FIFO(valid/ready)
│       ├── adc_ads7830.sv          # ADS7830 I2C 驱动
│       ├── piezo_peak.sv           # 5 路压电峰值/触发/NOTE_OFF
│       ├── fsr_filter.sv           # FSR 滤波/门限/力度
│       ├── expression_mapper.sv    # 电位器 -> pitch_bend
│       └── input_event_stub.sv     # 无硬件测试事件源
├── sim/
│   ├── ads7830_model.sv            # ADS7830 I2C 从机模型
│   ├── tb_key_scan.sv
│   ├── tb_key_debounce.sv
│   ├── tb_adc_ads7830.sv
│   ├── tb_fsr_filter.sv
│   ├── tb_event_queue.sv
│   ├── tb_piezo_peak.sv            # 5 路压电触发/自动 NOTE_OFF
│   ├── tb_matrix_config.sv         # MATRIX_MODE=1 配置模式
│   ├── tb_input_event_stub.sv
│   └── tb_input_top.sv             # 系统级联调仿真
├── docs/
│   ├── input_interface.md          # 接口与握手详细说明
│   ├── input_pin_requirements.md   # 给成员 3 的引脚/电气需求
│   ├── hardware_list.md            # 更新版硬件清单（压电保护/调理/电源）
│   ├── key_map.md                  # 按键映射表
│   ├── integration_guide.md        # 与 audio_core 的最小联调示例
│   ├── member2_scope.md            # 成员 2 最终职责、接口与待实现项
│   ├── remaining_tasks.md          # 未实现/未覆盖项盘点（P0/P1/P2）
│   ├── 仍未完成的功能详情.md        # 逐项：现状/目标/缺失/验收/测试
│   └── test_record.md              # 仿真记录与硬件测试清单
├── Makefile
└── README.md
```

---

## 3. 快速开始

需要 Icarus Verilog 12+ 与 Verilator 5+。

```bash
make lint               # Verilator 语法/位宽检查
make sim                # 编译并运行全部 testbench，日志在 build/*.log
make run-tb_input_top   # 只运行系统级仿真
make clean
```

当前回归结果：9 个 testbench 全部 `TEST PASSED`。

---

## 4. 对外接口速查

### 4.1 演奏事件（成员 2 → 成员 1）

| 信号 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `event_valid` | out | 1 | 事件有效 |
| `event_ready` | in | 1 | 下游可接收 |
| `event_type` | out | 2 | 00=NOP, 01=NOTE_ON, 10=NOTE_OFF, 11=ALL_NOTES_OFF |
| `event_note_id` | out | 7 | MIDI 0~127 |
| `event_velocity` | out | 8 | 0~255，NOTE_OFF 时为 0 |

传输条件：`event_valid && event_ready` 的 `sys_clk` 上升沿。
`event_valid=1 && event_ready=0` 时，所有事件字段保持稳定，事件不丢失。

### 4.2 表情接口（成员 2 → 成员 1）

| 信号 | 位宽 | 说明 |
|---|---|---|
| `expr_valid` | 1 | FSR 已完成至少一次采样 |
| `expression` | 8 | FSR 稳定压力值 0~255 |
| `pitch_bend` | 12 | 电位器 0~4095，中点 2048 |
| `waveform_sel` | 2 | 0=正弦，1=方波，2=锯齿，3=预留 |

### 4.3 板级接口

| 信号 | 说明 |
|---|---|
| `key_row[3:0]` | 矩阵行，低有效（参数可改） |
| `key_col[3:0]` | 矩阵列，低有效，需上拉（参数可改） |
| `adc_scl` | ADS7830 SCL |
| `adc_sda_oe` | SDA 开漏使能：1=拉低，0=释放 |
| `adc_sda_i` | SDA 回读 |
| `piezo_peak_rst[4:0]` | 5 路峰值电容放电，接 2N7002 栅极 |
| `piezo_hit_debug[4:0]` | 5 路峰值是否超过阈值 |
| `piezo_active_debug[4:0]` | 5 路是否正在发声 |
| `base_note_debug[6:0]` | 当前根音（含八度） |
| `test_mode` | 1=使用内部测试事件源 |
| `test_pattern[1:0]` | 测试序列选择 |

ADC 通道分配：`CH0=FSR`、`CH1=电位器`、`CH2~CH6=5 路压电`、`CH7=备用`。

`MATRIX_MODE` 参数：

- `0`：矩阵当键盘，K0~K11 直接发 NOTE_ON（当前测试模式）；
- `1`：矩阵选根音/音区，5 路压电触发（最终演奏模式）。

SDA 在板级顶层接成双向：

```systemverilog
assign adc_sda = adc_sda_oe ? 1'b0 : 1'bz;
assign adc_sda_i = adc_sda;
```

---

## 5. 重要说明 / 与任务书的差异

1. **ADS7830 是 I2C 器件，不是 SPI 器件。**
   任务书建议的 `adc_cs_n/adc_sclk/adc_mosi/adc_miso` 对 ADS7830 不适用，
   因此 `input_top` 使用 `adc_scl/adc_sda_oe/adc_sda_i`。接线方式见
   `docs/input_pin_requirements.md`。

2. **K15 用于降八度，而不是测试模式切换。**
   `test_mode` 是板级输入，应由成员 3 的拨码开关/按键直接驱动。
   若希望用 K15 切换演示模式，可在板级顶层把 `key_down[15]` 接到模式
   选择逻辑，不需要修改事件协议。

3. **`rtl/common/audio_defs.svh` 与 `project_params.svh` 是兼容副本。**
   原始“所有参数标准”文件未同步进本仓库，本副本严格按任务书 V1.0 的
   编码/位宽编写。若成员 1 的正式版本使用 package 或不同宏名，请以正式
   文件为准并同步替换；事件编码与位宽不得改变。

4. **消抖时间默认 2 ms 按下 / 5 ms 释放**，而不是任务书建议的 5~20 ms。
   这是为了给“控制到音频输出 ≤ 10 ms”留出余量：输入侧最坏约 3 ms，
   剩余预算交给 audio_core + I2S。可通过参数调整。

5. **当前版本按任务书使用 1 路 FSR 作为力度维度。**
   硬件清单中的 16 片 FSR 若要做“每键独立力度”，可扩展为两片 ADS7830
   （每片 8 通道）或增加模拟多路复用。`fsr_filter` 与事件译码接口不需要
   改变，只需把力度来源改为当前按键对应的 ADC 通道。

6. **成员 1 的 `audio_core` 内部也有测试音源。**
   上板联调时 `input_top.test_mode` 与 `audio_core.test_mode` 只能二选一：
   用成员 2 的固定序列时前者置 1、后者置 0；用成员 1 自己的测试音源时相反。
   详见 `docs/integration_guide.md` 第 3.1 节。

---

## 6. 当前状态

- [x] 4x4 矩阵扫描、逐键消抖、按下/释放事件
- [x] 12 音符键 + ALL_NOTES_OFF + 八度 + 波形
- [x] `MATRIX_MODE=1`：矩阵选根音/音区，不再直接发 NOTE_ON
- [x] FSR → ADS7830 → 力度，按下瞬间锁存
- [x] 电位器 → pitch_bend
- [x] 四键和弦、背压保持、ALL_OFF 释放抑制
- [x] 5 路压电峰值/阈值/力度/自动 NOTE_OFF/峰值放电
- [x] 7 通道 ADC 轮询（CH2~CH6 压电、CH0 FSR、CH1 电位器）
- [x] 无硬件 `input_event_stub` 演示序列
- [x] 9 个 testbench 全部通过
- [ ] 实物接线与引脚约束（成员 3）
- [ ] 与成员 1 `audio_core` 上板联调（当前阶段先做 4 voice）
- [ ] 端到端延迟实测
- [ ] ADC 总线超时恢复、电位器中心死区、FSR 校准（P1）

> 当前阶段按 `VOICE_COUNT=4` 联调；5 指同时触发/扫弦的 8 voice 作为后续升级点，
> `audio_core.VOICE_COUNT` 必须参数化，不能写死。


