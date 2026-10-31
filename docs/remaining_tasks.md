# 成员 2 剩余工作清单（缺口盘点）

> 逐项的现状、目标、缺失内容、验收标准和测试方案见
> `docs/仍未完成的功能详情.md`。本文件只保留快速清单。

盘点日期：2026-10-29（上次盘点 2026-10-27）  
依据：成员 2 任务书 V1.0、`docs/device_Info_path.md`、`docs/hardware_list.md`、当前 RTL/仿真。

> **2026-10-29 变更**：触发源由压电片改为 5 路 FSR402（一端 3.3 V、另一端直接接 ADC，
> 每路 1 个 10 kΩ 到 GND），`piezo_peak.sv` 由 `fsr_trigger.sv` 替代。
> 本文件下半部分的压电条目保留作历史记录，实际以 FSR 方案为准。

---

## 0. 结论

当前已经完成并验证的是：

- 4×4 矩阵扫描、消抖、12 音符键、ALL_NOTES_OFF、八度、波形
- `MATRIX_MODE=1`：矩阵选根音/音区，不直接发 NOTE_ON
- 事件译码、事件 FIFO、valid/ready 背压
- ADS7830 I2C 驱动（CH0 FSR 表情 / CH1 电位器 / CH2~CH6 FSR 触发）
- 5 路 FSR 阈值/迟滞/力度/电平释放/兜底 NOTE_OFF
- 7 通道 ADC 轮询
- FSR 滤波/力度、电位器 pitch_bend
- `input_event_stub` 测试事件源
- **9 个 testbench 全部通过**

剩余工作的重点已经从“RTL 功能”转移到“P1 可靠性 + 板级联调”。

> **2026-10-27 复核**：`make lint` = 0 警告，`make sim` = 9/9 `TEST PASSED`，
> P0 全部完成且未回退。本次新增三项代码级隐患 **F-16 / F-17 / F-18**
> （详见 `docs/仍未完成的功能详情.md` 第 3 章末尾）：
> 同键 pending 槽位覆盖、背压期间事件字段漂移、I²C 速率 422 kHz 超规格。

---

## 1. P0：上板演示前必须完成

### 1.1 5 路 FSR 触发 RTL

- [x] `fsr_trigger.sv`（2026-10-29 替代 `piezo_peak.sv`）：
  - [x] 读取 5 路触发通道 ADC 电平
  - [x] 阈值 + 释放回差
  - [x] 电平 -> `velocity` 映射，满量程可标定
  - [x] 超过阈值 -> `NOTE_ON`
  - [x] 连续 N 个样本低于释放阈值 -> `NOTE_OFF`（真实松开）
  - [x] 2 s 无样本兜底 `NOTE_OFF`
  - [x] 防重复触发窗口
- [x] 5 路 FSR -> 音符映射（大调五声音阶 +0/+2/+4/+7/+9）
- [x] FSR 触发与矩阵事件共用 `event_queue` 的仲裁规则
- [x] 移除峰值保持/放电相关硬件依赖（`piezo_peak_rst` 恒为 0）

### 1.2 7 通道 ADC 调度

- [x] `input_top` 的 ADC 调度扩展为 7 通道轮询
- [x] 通道映射定案：CH0 FSR 表情、CH1 电位器、CH2~CH6 FSR 触发、CH7 备用
- [x] `SAMPLE_INTERVAL` 降到 20 us，一轮扫描约 0.84 ms

### 1.3 联调必需

- [ ] `rtl/top/tang_nano20k_top.sv`（成员 3 牵头，联合例化 `input_top` + `audio_core` + `i2s_tx`）
- [ ] `constraints/tang_nano20k.cst` 实际引脚约束（成员 3）
- [ ] `audio_ce` 48 kHz 使能生成（顶层）
- [ ] 与成员 1 的 `audio_core` 上板联调
- [ ] 端到端延迟实测（目标 ≤10 ms）

---

## 2. P1：可靠性与比赛指标

### 2.1 代码健壮性

- [ ] `adc_ads7830` 增加总线超时/恢复：SDA 被拉死时不能永远卡在状态机
- [ ] `adc_ads7830` 的 NACK 错误路径仿真（当前 TB 只测成功读取）
- [ ] `expression_mapper` 增加中心死区，防止旋钮静止时 pitch_bend 抖动
- [ ] `fsr_filter` 增加零点/满量程校准参数（当前只有固定 `NOISE_GATE`）
- [ ] `event_queue` 的 `overflow` 提供系统级清除方式（当前 `overflow_clear` 接 0）
- [ ] 明确矩阵鬼键支持范围；若要 16 键全键无冲，增加 16 只 1N4148
- [ ] **F-16** `key_event_decoder` 每键仅一个 pending 槽位，`NOTE_OFF` 会覆盖未发出的
      `NOTE_ON`，快速按放时丢音
- [ ] **F-17** `key_event_decoder` 的 `event_req_*` 是组合输出，背压期间同键新事件会
      改写字段，违反 valid/ready 协议
- [ ] **F-18** `ADC_I2C_HZ=400k` 实际算出 SCL≈422 kHz，超出 ADS7830 的 400 kHz 上限，
      建议改为 300 kHz

### 2.2 仿真覆盖

- [ ] 同一时钟沿多键同时按下/释放（当前和弦测试是逐拍按下）
- [ ] 运行中复位（当前只在开头复位）
- [ ] `note_map` 八度极值/限幅独立测试
- [ ] `expression_mapper` 独立测试（中心、两端、死区）
- [ ] `key_event_decoder` 独立测试（ALL_OFF 与 pending 事件竞争）
- [ ] `adc_ads7830` NACK/超时测试
- [x] 7 通道调度（`tb_input_top` / `tb_adc_ads7830`）
- [x] 5 路 FSR 独立触发/力度/松开释放（`tb_fsr_trigger`）
- [ ] 5 路 FSR **同时**触发/快速连击真并发（当前 TB 是逐路触发）

### 2.3 当前 `tb_fsr_filter.sv` 的缺口

- [ ] 运行中复位测试
- [ ] 边界值：`filtered=4/5/6`（迟滞门限）、`0`、`255`
- [ ] 快速起音阈值：`delta=31` 与 `delta=32` 的行为差异
- [ ] `ready` 输出首次采样前后状态
- [ ] 非 FSR 通道在 `ready=0` 时不能初始化滤波器
- [ ] VCD/FST 波形输出（当前只有日志）

---

## 3. P2：交付质量

- [ ] 每个模块增加 VCD 波形输出或关键波形截图
- [ ] 生成 Gowin 综合/时序报告，确认 27 MHz 时序收敛
- [ ] 电源预算（MAX98357 峰值电流、3.3 V 余量）
- [ ] FSR 机械安装/按压力度与手感说明（硬质圆片分散压力、引线应力释放）
- [ ] 更新 `docs/test_record.md` 的硬件测试结果（当前全部“待测”）
- [ ] 补充实际引脚表 `docs/pin_map.md`（成员 3）

---

## 4. 已明确不属于成员 2 的工作

| 项目 | 负责 |
|---|---|
| `audio_core`、DDS、ADSR、混音 | 成员 1 |
| `i2s_tx`、MAX98357、板级顶层、`.cst` | 成员 3 |
| 最终外壳/结构件 | 团队 |

---

## 5. 建议的下一步

P0 的 RTL 已全部完成，剩下的是 P1 可靠性与板级联调：

1. **优先做**：`adc_ads7830` 总线超时/恢复（F-07）。这是目前唯一会让
   整个输入模块永久卡死的隐患：SDA 一被拉死，状态机可能停在等待 ACK。
2. **次优**：`key_event_decoder` 同键 pending 槽位覆盖（F-16）—— 会直接丢音。
3. `expression_mapper` 中心死区（F-06）+ 背压字段锁存（F-17）。
4. `ADC_I2C_HZ` 改 300 kHz（F-18）—— 上板前必改。
5. 补 `adc_ads7830` 的 NACK/超时仿真路径，以及 `overflow_clear`（F-09）。
6. 补独立 TB：`tb_note_map`、`tb_expression_mapper`、`tb_key_event_decoder`。
7. `fsr_filter` 零点校准（F-08）。
8. 与成员 1/3 做顶层联调，测端到端延迟。
