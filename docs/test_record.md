# 成员 2 测试记录

日期：2026-10-31（2026-10-20 首版；2026-10-29 触发源改为 FSR；2026-10-31 修复评审清单输入侧缺陷）  
工具链：
- Icarus Verilog 12.0（本轮回归实际使用的工具链）
- Verilator 5.x（`make lint`，本轮开发机未安装，未运行）
- GTKWave（可选）

---

## 1. 仿真回归结果

执行：

```bash
make sim
```

本轮 11 个 testbench 全部 `TEST PASSED`。`make sim` 已改为检查仿真器退出码，
`$fatal`/超时不会再被 `tee` 掉而误判为通过。

| Testbench | 覆盖内容 | 结果 | 日志 |
|---|---|---|---|
| `tb_key_scan` | 行扫描顺序、行列映射、同一行多键 | PASS | `build/tb_key_scan.log` |
| `tb_key_debounce` | 抖动抑制、单次按下/释放、长按不重复、多键独立 | PASS | `build/tb_key_debounce.log` |
| `tb_key_event_decoder` | 单键/和弦、背压下 NOTE_ON 不被覆盖、ALL_OFF 优先+释放抑制、八度上下限、波形循环、槽位溢出 | PASS | `build/tb_key_event_decoder.log` |
| `tb_adc_ads7830` | I2C 时序、CH0~CH7 通道编码全覆盖、NACK、SDA 钳死、总线恢复 | PASS | `build/tb_adc_ads7830.log` |
| `tb_fsr_filter` | 滤波、噪声门限、轻/中/重按映射、通道隔离 | PASS | `build/tb_fsr_filter.log` |
| `tb_expression_mapper` | 中心死区、线性映射、两端限幅、waveform_sel | PASS | `build/tb_expression_mapper.log` |
| `tb_event_queue` | 顺序、背压稳定、溢出标志、满时同拍读写 | PASS | `build/tb_event_queue.log` |
| `tb_fsr_trigger` | 5 路阈值/力度/保持/电平释放/防重复/兜底 NOTE_OFF/ALL_OFF/背压 2 槽位 | PASS | `build/tb_fsr_trigger.log` |
| `tb_matrix_config` | MATRIX_MODE=1：选根音/八度/波形（`WAVEFORM_MAX_SEL=2`）/ALL_OFF，不产生 NOTE_ON | PASS | `build/tb_matrix_config.log` |
| `tb_input_event_stub` | 演示序列、背压、背压中切 pattern 不撤销事件、restart | PASS | `build/tb_input_event_stub.log` |
| `tb_input_top` | 系统级：7 通道 ADC、矩阵、FSR 表情、电位器、FSR 触发、test_mode 切换握手、矩阵告警 | PASS | `build/tb_input_top.log` |

---

## 2. 关键验证点

### 2.1 按键

- 4x4 矩阵扫描帧 40 个仿真时钟（`ROW_DWELL_CYC=8`）。
- 抖动期间不产生事件。
- 稳定按下 3 拍后产生一次 `key_pressed`；长按 100 拍不重复。
- 释放确认 5 拍，只产生一次 `key_released`。
- 不同按键的消抖计数器互相独立。

### 2.2 事件握手

- `event_ready=0` 时，`event_valid` 与全部事件字段保持 100 拍不变。
- 四键和弦产生 4 个 `NOTE_ON`，释放产生 4 个对应 `NOTE_OFF`。
- ALL_NOTES_OFF 优先于待发事件，并抑制按住键的后续 `NOTE_OFF`。
- 背压下“NOTE_ON 未发出就松手”：`NOTE_ON` 留在队首、`NOTE_OFF` 进第二个槽位，
  放开背压后依次送出（旧实现会被覆盖，只剩 `NOTE_OFF`）。
- 同键积压第 3 个事件时置 `event_overflow`，但在队两个事件不被破坏。
- `input_overflow` 不再被“下游暂时忙”误触发（旧实现会）。
- `test_mode` 切换：合成 `ALL_NOTES_OFF` 在背压下保持 200 拍不变，接收后才换源，
  测试序列从 0 ms 重启。
- 背压中切换 `test_pattern`：未接收事件字段不变，之后补 `ALL_NOTES_OFF` 再跑新序列。

### 2.3 ADC / FSR

- ADS7830 模型按数据手册解码 `C2:C0`，驱动 CH0~CH7 逐个请求都能拿到本通道的值：
  这才能真正验到通道编码（旧实现的驱动和模型同样错，测试假通过）。
- 命令字：CH0=0x84、CH1=0x94、CH2=0xA4 …CH7=0xF4（`C2:C0 = {ch[0],ch[2],ch[1]}`）。
- FSR=64 时，`fsr_filtered=64`，`event_velocity=60`。
- POT=192 时，`pitch_bend=3072`，证明 CH1 确实被采样。
- 非 FSR 通道样本不会污染 FSR 滤波状态。
- 7 通道轮询：CH2~CH6 FSR 触发、CH0 FSR 表情、CH1 POT，一轮约 1 ms（默认参数，375 kHz I2C）。
- NACK：报 `bus_error`，不产生 `sample_valid`；恢复后能继续正常采样。
- SDA 被持续拉低：报 `bus_error`，不伪造 `sample_valid=1/data=0`；恢复后能继续采样。

### 2.4 FSR 触发 / 矩阵配置

- P0~P4 分别映射到 base_note + 0/+2/+4/+7/+9。
- 电平 150 映射到 velocity 184（阈值 20、满量程 200）；电平 200 映射到 255。
- 按住不放不会重复触发；**跨过防重复窗口继续按住也不会重复触发**（旧实现会每 20 ms 重发一次）。
- 连续 3 个样本低于“阈值−回差”后才产生 `NOTE_OFF`。
- 防重复窗口（20 ms）内第二次按压被忽略；真实松开后窗口外可重触发。
- 长按期间切换 `base_note` 不重触发，松手后 `NOTE_OFF` 用触发时锁存的音符（C4）。
- 2 s 无新样本时兜底 `NOTE_OFF`。
- ALL_NOTES_OFF 清除活跃状态，后续松手不再产生 `NOTE_OFF`；
  **按住不放时 ALL_OFF 之后保持静音，必须先松手才能再次触发**（旧实现会立即复燃）。
- `MATRIX_MODE=1` 时 K0~K11 只改变 `base_note`，不产生 NOTE_ON。
- 矩阵告警：同列跨行双键置 `key_conflict_debug`，L 形三键置 `key_ghost_debug`。

### 2.5 八度与波形

- K13 升八度后 K0 发出 MIDI 72；K15 降两次后 K0 发出 MIDI 48；偏移限幅 -2~+2。
- `WAVEFORM_MAX_SEL=2` 时 K14 循环 0→1→2→0（`tb_matrix_config`）。
- 默认 `WAVEFORM_MAX_SEL=0`（波表只有正弦）：按 K14 不改变 `waveform_sel`，
  不会把整件乐器切静音（`tb_input_top`）。

---

## 3. 输入侧延迟估算

| 环节 | 估算 |
|---|---|
| 矩阵扫描 | ≤0.5 ms |
| 按下消抖 | 2 ms |
| 事件译码/FIFO | <0.1 us |
| FSR 采样/滤波（力度） | 0.5~1 ms |
| **合计** | **≈3 ms** |

剩余约 7 ms 预算留给 `audio_core`、PCM FIFO、I2S 和功放。

---

## 4. 工具告警

- Icarus Verilog 12.0：`iverilog -g2012` 编译输入侧全部 RTL 无 error/warning。
- Verilator：本轮开发机未安装 Verilator，`make lint` 未运行。
  上一轮（2026-10-29）`-Wall` 无功能告警；本轮改动新增的端口都是
  标准 `output logic`，未引入三态/inout，预计仍为 0 警告，**上板前请在
  装好 Verilator 的机器上补跑一次 `make lint`**。
- Verilator 的 `PINCONNECTEMPTY` 只针对有意留空的调试端口，已在 Makefile
  中通过 `-Wno-PINCONNECTEMPTY` 豁免。

若后续添加波形输出，建议：

```bash
make run-tb_input_top
gtkwave build/wave.vcd
```

---

## 5. 硬件测试清单（待上板）

| 项目 | 操作 | 期望 | 结果 |
|---|---|---|---|
| 矩阵扫描 | 逐个按 K0~K15 | `key_down` 对应 bit 置 1 | 待测 |
| 音符映射 | K0~K11 | MIDI 60~71 | 待测 |
| 长按 | 按住 K0 5 s | 只发一次 NOTE_ON | 待测 |
| 和弦 | 同时按 4 个键 | 4 个 NOTE_ON，声部数=4 | 待测 |
| ALL_OFF | 按住音符时按 K12 | 发 ALL_NOTES_OFF，释放不发音 | 待测 |
| 八度 | K13/K15 | 音高 ±12 半音 | 待测 |
| 波形 | K14 | 音色循环变化 | 待测 |
| FSR 轻按 | 轻压 FSR | velocity 约 20~60 | 待测 |
| FSR 中按 | 中压 | velocity 约 100~150 | 待测 |
| FSR 重按 | 重压 | velocity 约 220~255 | 待测 |
| FSR 静置 | 不按压 | velocity=0，无随机 NOTE_ON | 待测 |
| 电位器 | 从一端转到另一端 | pitch_bend 0~4095，中点≈2048 | 待测 |
| I2C | 观察 `adc_bus_error` | 保持 0 | 待测 |
| 溢出 | 长时间拉低 `event_ready` | `input_overflow` 置 1 | 待测 |
| 延迟 | 逻辑分析仪抓按键→I2S | ≤10 ms | 待测 |

---

## 6. 上板记录模板

| 日期 | 测试人 | 板卡 | 现象 | 结论 |
|---|---|---|---|---|
|  |  | Tang Nano 20K |  |  |
