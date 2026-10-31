# 评审清单（20 项）处理记录 —— 成员 2 范围

日期：2026-10-31  
依据：`代码问题审查清单.md`（20 项）  
处理原则：**只改成员 2 负责的 `rtl/input/`、`rtl/common` 输入侧参数、`sim/` 输入侧
testbench 与 `docs/`**；成员 1（`rtl/audio/`、`rtl/audio_out/`）与成员 3
（`rtl/top/`、`constraints/`）的代码未改动。

- 回归：`make sim` → 11/11 `TEST PASSED`（Icarus Verilog 12.0）
- `make lint`（Verilator）本轮开发机未安装，未运行；改动未引入三态/inout

---

## 1. 统计

| 归属 | 条目 | 数量 |
|---|---|---|
| 成员 2（已修复） | 1, 3, 4, 5, 6, 7（输入侧部分）, 8（输入侧部分）, 16, 17, 18（逻辑侧）, 19（输入侧部分）, 20（回归脚本） | 12 |
| 成员 1（音频） | 2, 9, 12, 13, 14, 15 | 6 |
| 成员 3 / 联调 | 10, 11 | 2 |
| 仍需硬件决定 | 18（矩阵二极管）、19（整机链路测试） | — |

---

## 2. 已修复（成员 2）

### 2.1 第 1 项：ADS7830 通道编码错误（P1）

- **问题**：把逻辑通道号直接写进命令字的 `C2:C0`，物理通道变成
  `0,2,4,6,1,3,5,7`；CH1/CH2、CH3/CH4、CH5/CH6 两两互换。ADC 模型重复了
  同样的错误，所以测试假通过。
- **修复**：`rtl/input/adc_ads7830.sv` 增加 `ch_code()`：
  `C2:C0 = {ch[0], ch[2], ch[1]}`（数据手册 Table 2）。
  对外端口 `adc_channel_req/sample_channel` 仍是物理通道号 0~7。
  `sim/ads7830_model.sv` 改为按数据手册解码，不再复刻驱动错误。
- **验证**：`tb_adc_ads7830` 增加 CH0~CH7 全通道覆盖（每通道不同数据），
  旧实现会在 CH1/CH2 处报错。

### 2.2 第 3 项：FSR 长按重复触发 / 切根音漏发 OFF（P1）

- **问题**：防重复定时器到期后无条件 `armed <= 1`，长按每 20 ms 重发一次
  `NOTE_ON`；重触发会覆盖 `note_latched`，松手只发得到新音符的 `OFF`。
- **修复**：`rtl/input/fsr_trigger.sv`
  - 窗口到期**不再自动重新武装**，必须看到样本低于释放阈值（真实松手）才
    `armed <= 1`；定时器到期时也要检查 `last_raw < RELEASE_TH`。
  - 触发条件从 `armed && !pend_valid` 改为 `armed && !active_q`，
    并在已发声时不再改写 `note_latched`。
- **验证**：`tb_fsr_trigger`
  - 5b：持续按压跨过窗口 → 不重触发（旧实现会多出事件）
  - 5c：长按中把 `base_note` 从 C4 改到 D4 → 松手仍是 `NOTE_OFF 60`

### 2.3 第 4 项：ALL_NOTES_OFF 后被按住的 FSR 立即复燃（P1）

- **问题**：`all_off` 时把 `armed` 全部置 1，仍按住的手指下一个高电平样本就
  重新发 `NOTE_ON`，静音保持不住。
- **修复**：`fsr_trigger.sv` 里 `all_off` 改为 `armed <= ~active_q`：
  正在发声的通道清零（要求先松手），空闲通道保持武装（否则 all_off 之后
  第一下按压会被漏掉）。
- **验证**：`tb_fsr_trigger` 8b：ALL_OFF 后持续送高电平样本保持静音；
  松手再按能正常触发。

### 2.4 第 5 项：切换 test_mode 破坏事件握手（P1）

- **问题**：`event_valid` 在 stub / queue 之间组合直切；切换时既不保留
  在途事件，也不补 `ALL_NOTES_OFF`，还会直接排空真实队列。
- **修复**：`rtl/input/input_top.sv` 增加三态切换流程
  `M_RUN → M_WAIT → M_ALLOFF → 换源`：
  - `M_WAIT` 只把当前呈现的事件送出去，等下游接收（绝不撤销）；
  - `M_ALLOFF` 发一个合成的 `ALL_NOTES_OFF`，释放上一来源的音符；
  - 换源后复位测试序列（`input_event_stub.restart`）；
  - `test_mode/test_pattern` 增加两级同步。
- **验证**：`tb_input_top` 第 11 项：背压下切换 `test_mode`，
  `event_valid/type/note` 保持 200 拍不变，接收后才出现
  `ALL_NOTES_OFF → 新序列首事件`。

### 2.5 第 6 项：测试序列切换撤销未接收事件（P1）

- **问题**：`test_pattern` 变化时直接 `valid_r <= 0` 并重启序列。
- **修复**：`rtl/input/input_event_stub.sv` 改为“延迟重启”：
  记录 `restart_req`，当前事件送完后先发 `ALL_NOTES_OFF`，再从 0 ms 重新开始；
  新增 `restart` 端口供 `input_top` 在换源时立即复位。
- **验证**：`tb_input_event_stub` 第 3 项：背压中切 pattern，
  事件字段不变（旧实现会 `valid` 掉）。

### 2.6 第 7 项（输入侧）：背压期间丢事件、溢出标志失效（P1）

- **问题**：每键/每触发通道只有一个待发槽位，后来的 `NOTE_OFF` 覆盖未发出的
  `NOTE_ON`（丢音 + 持续音）；`queue_wr_valid` 被 `wr_ready` 门控，
  `event_queue` 的 `wr_valid && !wr_ready` 永不成立，报警失效。
- **修复**：
  - `key_event_decoder.sv` / `fsr_trigger.sv`：每键/每通道改为 **2 槽位小队列**，
    新增 `event_overflow`（粘滞）报告真正的丢弃。
  - `input_top.sv`：去掉 1 深度 skid buffer，改为“源保持式 + `wr_valid` 由
    `wr_ready` 门控”，`input_overflow = 源侧溢出汇总`。
  - 语义明确：`input_overflow=1` 表示**真丢过事件**，不是“下游暂时忙”。
- **验证**：
  - `tb_key_event_decoder` 第 3 项 / `tb_fsr_trigger` 第 9 项：
    背压下 ON/OFF 依次送出；
  - 同键第 3 个事件 → `event_overflow=1`，但在队 2 个事件完好；
  - `tb_input_top` 第 10 项：FIFO 满时不误报 overflow。

### 2.7 第 8 项（输入侧）：切波形导致静音（P1）

- **问题**：`waveform_rom` 只实现正弦；输入侧却会循环 0→1→2，两次按键后整路静音。
- **修复**：新增 `project_params_pkg::WAVEFORM_MAX_SEL`（默认 0），
  `key_event_decoder` 只在 `0..MAX` 内循环。成员 1 补齐方波/锯齿后把它改成 2
  即可恢复三档循环，输入侧事件协议不变。
- **验证**：`tb_input_top` 第 8 项（默认值：按 K14 不变）；
  `tb_matrix_config`（显式置 2：仍能 0→1→2→0）。

### 2.8 第 16 项：I2C 频率 422 kHz 超规格（P2）

- **问题**：`SYS_CLK_HZ/(I2C_HZ*4)` 整数截断得 16 → 421.9 kHz，`t_LOW`≈1.19 us
  （Fast Mode 要求 ≤400 kHz、`t_LOW` ≥ 1.3 us）。
- **修复**：`adc_ads7830.sv` 自动计算 `QDIV`：
  `QDIV ≥ ceil(f/(4·I2C_HZ))` 且 `2·QDIV/f ≥ 1.3 us`；
  27 MHz 下 `QDIV=18` → 375 kHz、`t_LOW`≈1.33 us。`input_top` 的
  `I2C_QUARTER_DIV` 默认改为 0（自动）。

### 2.9 第 17 项：SDA 被拉死时伪造成功采样（P2）

- **修复**：`adc_ads7830.sv`
  - 事务开始前检查总线空闲（SDA=1），否则报 `bus_error` 并走 9 个 SCL 的
    总线恢复（最多重试 2 次，绝不产生样本）；
  - 事务期间 quarter tick 超时保护；超时强制 STOP 并报错；
  - STOP 之后再次确认 SDA 回到高电平，确认通过才输出 `sample_valid`；
  - `sample_req` 改成锁存式（单拍脉冲不会漏）。
  - `input_top` 增加采样请求看门狗（1 ms）：ADC 卡死时跳过该通道，
    置 `adc_timeout_debug`，轮询不会永久冻结。
  - 附带修复：`req_latched` 与 `sample_req` 的判断顺序错误会让状态机在
    “上游电平保持”时死循环，已调整为 `req_latched` 优先。
- **验证**：`tb_adc_ads7830` 的 `NACK path` / `SDA stuck low` 两个用例
  （旧实现会给出 `sample_valid=1, data=0, bus_error=0`）。

### 2.10 第 18 项（逻辑侧）：矩阵鬼键/行驱动争用（P1，硬件条件限制）

- **问题**：未选中行主动输出高，同列跨行双键会把两个行输出短接（电学争用）；
  L 形三键产生鬼键。代码既无高阻控制也无冲突检测。
- **修复（逻辑侧）**：`key_scan.sv` 新增组合检测：
  - `ghost_detect`：2x2 矩形内 ≥3 键；
  - `row_conflict`：同列跨行 ≥2 键。
  `input_top` 透出 `key_ghost_debug` / `key_conflict_debug` 供 LED/逻辑分析仪观察。
- **修复（文档/硬件侧）**：`docs/input_pin_requirements.md` 明确要求
  **每个按键串一只 1N4148**，并说明不加二极管时哪些键位组合不可用；
  `MATRIX_MODE=1`（单根音键）不受影响。
- **未做**：把未选中行改成高阻需要把 `key_row` 改成 `inout`（板级接口变更），
  叠加二极管后没有必要，故未改。
- **验证**：`tb_input_top` 第 12 项。

### 2.11 第 19 项（输入侧）：测试覆盖不足（P2）

新增/扩充：

| 用例 | 位置 |
|---|---|
| ADC CH0~CH7 编码全覆盖 | `tb_adc_ads7830` |
| ADC NACK / SDA 钳死 / 恢复后继续采样 | `tb_adc_ads7830` |
| FSR 长按跨窗口不重触发、长按切根音、ALL_OFF 后按住不复燃 | `tb_fsr_trigger` |
| 背压下 ON/OFF 不覆盖、槽位溢出 | `tb_fsr_trigger`、`tb_key_event_decoder` |
| 同拍多键、八度上下限、波形循环、ALL_OFF 抑制 | `tb_key_event_decoder`（新增文件） |
| 背压中切 `test_pattern` 不撤销事件 | `tb_input_event_stub` |
| `test_mode` 切换握手 + 合成 ALL_OFF 保持 | `tb_input_top` |
| 矩阵鬼键/同列告警 | `tb_input_top` |

仍未覆盖（属整机/板级）：`tb_system` 空模块、I2S 输出测试缺 `.sv` 扩展名、
`tb_mixer` 未纳入 `sim-all` —— 这些在成员 1/3 的范围内，未改动。

### 2.12 第 20 项：回归脚本可能把失败判成成功（P2）

- **修复**：`Makefile` 的 `sim` / `sim-audio` / `sim-v` 三个目标不再用
  `vvp ... | tee`，改为重定向到日志后再 `cat`，并检查仿真器退出码；
  非 0 直接失败。`grep "TEST PASSED"` 仍保留为第二道检查。
- **验证**：`make sim VVP=false` → `tb_key_scan FAILED (simulator exit status != 0)`，
  make 返回 1。

---

## 3. 未改动（不属于成员 2）

| 项 | 内容 | 归属 |
|---|---|---|
| 2 | 音频链路幅度缩放（`voice/mixer/pcm_stream_adapter`，单音 PCM 只有 ±31） | 成员 1 |
| 9 | `pcm_stream_adapter` 的 FIFO 指针/计数器位宽不随 `FIFO_DEPTH` 变化 | 成员 1 |
| 10 | `tang_nano20k_top` 未例化 `input_top` / `audio_out_top` | 成员 1/3 |
| 11 | 缺 `constraints/*.cst`、`*.sdc` 与板级构建入口 | 成员 3 |
| 12 | `audio_test_source` 时间单位（实际 1 s 而非 100 ms） | 成员 1 |
| 13 | `audio_core.test_pattern` 未使用 | 成员 1 |
| 14 | `pitch_bend` 未参与音高计算（输入侧已正确输出 0~4095） | 成员 1 |
| 15 | 24 位波表负半周符号错误 | 成员 1 |
| 19 剩余 | `tb_system` 空模块、I2S 测试文件扩展名、`tb_mixer` 未入回归 | 成员 1/3 |

> 给队员的接口提示：
> - 输入侧 `waveform_sel` 默认只会是 0（正弦）。`waveform_rom` 支持方波/锯齿后，
>   把 `project_params_pkg::WAVEFORM_MAX_SEL` 改成 2。
> - `input_top` 新增 3 个**只输出**的调试端口（`key_ghost_debug`、
>   `key_conflict_debug`、`adc_timeout_debug`），板级顶层可以悬空。
> - `input_top.I2C_QUARTER_DIV` 默认 0 = 自动分频，不要再在外面写死 16。
