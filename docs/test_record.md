# 成员 2 测试记录

日期：2026-10-19  
工具链：
- Icarus Verilog 12.0
- Verilator 5.020
- GTKWave（可选）

---

## 1. 仿真回归结果

执行：

```bash
make lint
make sim
```

Verilator `-Wall` 无警告（`PINCONNECTEMPTY` 为有意留空的调试端口，已在
Makefile 中豁免）。

| Testbench | 覆盖内容 | 结果 | 日志 |
|---|---|---|---|
| `tb_key_scan` | 行扫描顺序、行列映射、同一行多键 | PASS | `build/tb_key_scan.log` |
| `tb_key_debounce` | 抖动抑制、单次按下/释放、长按不重复、多键独立 | PASS | `build/tb_key_debounce.log` |
| `tb_adc_ads7830` | I2C START/地址/命令/Repeated START/读数据 | PASS | `build/tb_adc_ads7830.log` |
| `tb_fsr_filter` | 滤波、噪声门限、轻/中/重按映射、通道隔离 | PASS | `build/tb_fsr_filter.log` |
| `tb_event_queue` | 顺序、背压稳定、溢出标志、满时同拍读写 | PASS | `build/tb_event_queue.log` |
| `tb_input_event_stub` | 演示序列、背压、pattern 切换 | PASS | `build/tb_input_event_stub.log` |
| `tb_input_top` | 系统级：测试模式、ADC/FSR、单键、和弦、背压、ALL_OFF、八度、波形 | PASS | `build/tb_input_top.log` |

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
- FIFO 满时置 `input_overflow`，不覆盖已入队事件。
- 满时同拍读写不会丢失吞吐。

### 2.3 ADC / FSR

- ADS7830 模型返回 8 个通道的可编程值，驱动能正确读取 CH0/CH1/CH3/CH4/CH7。
- 通道号与命令字 `0x84 | (ch<<4)` 一致。
- FSR=64 时，`fsr_filtered=64`，`event_velocity=60`。
- POT=192 时，`pitch_bend=3072`，证明 CH1 确实被采样。
- 非 FSR 通道样本不会污染 FSR 滤波状态。

### 2.4 八度与波形

- K13 升八度后 K0 发出 MIDI 72。
- K15 降两次后 K0 发出 MIDI 48。
- 八度偏移限幅在 -2~+2。
- K14 循环 0→1→2→0。

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

当前版本在 Icarus Verilog 12.0 和 Verilator 5.020 下均无功能性告警。
Verilator 的 `PINCONNECTEMPTY` 仅针对有意留空的调试端口，已在 Makefile
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
