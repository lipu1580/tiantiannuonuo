# 成员 2 第 2 轮任务书 —— 键位重排 + 配置总线主控

版本：V1.1（2026-11-02，K15 改为合唱/颤音复用键）
对应协议：`docs/member1_round2_protocol.md`（V1.1，取代成员 1 的 V0.1 草案）
适用代码：`rtl/input/`（本轮**只改这里**）、`sim/`、`docs/`
回归基线：`main @ 2af8859`

---

## 1. 本轮要做什么

一句话：**把 4×4 键盘的 16 个键重新分配成「9 根音 + 3 波形 + 3 效果 + 1 复用键」，
并新增一个 cfg 总线主控，把效果键/颤音键翻译成寄存器写序列发给成员 1 的扩展核心。**

本轮结束后，整机应该能这样弹：

```
按 row1..row3 的 9 个键  → 选根音（C / C# / D / E / F / F# / G# / A / A#）
捏 5 片触发 FSR          → 在以该根音为基的五声音阶上发声 + 力度
按 col4 的 K3/K7/K11     → 直接切波形：正弦 / 管风琴 / 拨弦
按 row4 的 K12/K13/K14   → 切效果：旁路 / 延迟 / 混响
K15 短按 / 长按          → 合唱 / 颤音档位（0→25→50→100 音分）
捏表情 FSR / 转电位器     → 持续表情 / 滑音（不变）
```

**三个演奏维度**：力度（FSR 电平）、滑音（电位器）、颤音（K15 长按档位）。

### 本轮**不做**（明确划边界）

| 不做的事 | 原因 / 归属 |
|---|---|
| 不改 `rtl/audio/`、`rtl/audio_out/`、`rtl/top/` | 成员 1 / 成员 3 的范围 |
| 不改 `rtl/common/`（`project_params.svh`、`audio_defs.svh`） | 公共包，需三人同意。本轮所需常量临时放在 `rtl/input/cfg_master.sv` 内部 |
| 不做八度键 | 9 个键直接选根音，不需要八度概念 |
| 不做 `ALL_NOTES_OFF` | 输入侧不再产生该事件；FSR 松手已逐个 `NOTE_OFF` |
| **不做"静音"实体键** | `waveform_sel=11` 编码保留（供调试/降级用），但不占键；K15 改为功能键 |
| 不改事件/表情/PCM 三个既有接口的语义 | 协议 §3 明确保持不变 |

---

## 2. 硬件约束：16 个键的唯一正确用法

矩阵行优先编号 `K = row*4 + col`（`key_scan` 的 `raw_key_state[row*COL_COUNT+col]`）。

|  | **col1** | **col2** | **col3** | **col4** |
|---|---|---|---|---|
| **row1** | K0 根音 C | K1 根音 C# | K2 根音 D | **K3 波形=正弦(0)** |
| **row2** | K4 根音 E | K5 根音 F | K6 根音 F# | **K7 波形=管风琴(1)** |
| **row3** | K8 根音 G# | K9 根音 A | K10 根音 A# | **K11 波形=拨弦(2)** |
| **row4** | **K12 效果=旁路(0)** | **K13 效果=延迟(1)** | **K14 效果=混响(3)** | **K15 短按=合唱(2) / 长按=颤音** |

### 2.1 为什么是这 9 个根音

3×3 区块（col1~col3）保留原有映射，因此根音音级是
`0,1,2, 4,5,6, 8,9,10`（对应 C, C#, D, E, F, F#, G#, A, A#）。

> ⚠️ 已知取舍：这个集合缺 D#(3)、G(7)、B(11)，因为它们的键位被 col4 占用了。
> 演奏上仍然够用：FSR 触发的是「根音 + 0/+2/+4/+7/+9」五声音阶，
> 9 个根音各自带 5 个音，合起来覆盖 MIDI **60~79** 这一段（C4~G5），
> 升降调式的常见需求都在里面。
> 如果后续想改成「9 个音阶根音」而不是「9 个半音」，**只改 `note_map.sv`
> 一张表**，扫描/消抖/事件协议都不用动。

### 2.2 与旧键位对照

| 旧键位 | 旧功能 | 新功能 |
|---|---|---|
| K0~K11 | 12 个半音（MATRIX_MODE=1 时选根音） | 只剩 K0,K1,K2,K4,K5,K6,K8,K9,K10 选根音 |
| K3, K7, K11 | 半音 D#, G, B | **改为波形键** |
| K12 | ALL_NOTES_OFF | **改为效果=旁路** |
| K13 | 升八度 | **改为效果=延迟** |
| K14 | 波形循环切换 | **改为效果=混响（mode=3）** |
| K15 | 降八度 | **改为复用键：短按=合唱（mode=2）/ 长按=颤音档位** |

---

## 3. 功能需求

### 3.1 根音选择（K0,K1,K2,K4,K5,K6,K8,K9,K10）

- 键盘**只用来选根音**，任何时候都不发 `NOTE_ON` / `NOTE_OFF`
  （`MATRIX_MODE` 参数本轮删除，见 §9.1）。
- `base_note = NOTE_BASE_C4(60) + 音级`，限幅到 0~127。
- 已经发出的音**保持原音高**，只有之后新触发的 FSR 音用它（`fsr_trigger` 已锁存 `note_latched`，无需改动）。
- **没有八度概念**：`base_note = NOTE_BASE_C4 + root_pitch_class`，
  `octave_offset` 端口与 `+12*octave_offset` 项**一并删除**。
  想要更高/更低的音区，直接选别的根音键。

### 3.2 波形选择（K3, K7, K11）—— **直接选择，不再循环**

| 键 | `waveform_sel` | 含义 |
|---|---|---|
| K3 | `2'b00` | 正弦 |
| K7 | `2'b01` | 管风琴类波表 |
| K11 | `2'b10` | 拨弦类波表 |
| —（无键） | `2'b11` | 静音，**仅保留编码**，本轮不提供按键 |


- 按键一次即**锁定**到该值，长按不变化（不是循环，不需要 `WAVEFORM_MAX_SEL` 上限）。
- 通过既有 `expr_valid` 接口输出：`input_top` 已经把 `waveform_sel` 挂在
  `expression_mapper` 上连续送出，此机制不变。
- **删除** `key_event_decoder` 里的 `WAVEFORM_MAX_SEL` 循环逻辑与
  `waveform_sel + 1` 自增。
- 前提：成员 1 的 `organ_1024.hex` / `pluck_1024.hex` 已合入。若尚未合入，
  `2'b01/2'b10` 会静音——**验收时必须以成员 1 分支为准**（见 §9）。

### 3.3 效果模式选择（K12, K13, K14, K15 短按）—— 走 cfg 总线

按下一个效果键，`cfg_master` 自动发出**一整段**寄存器写序列（顺序不能乱），
原因见协议 §4.3：切换模式前必须先关湿声，切完再开，避免爆音。

| 键 | 目标模式 | 写序列（地址 ← 数据） |
|---|---|---|
| K12 旁路 | `fx_mode=0` | `0x30←0`, `0x2C←0` |
| K13 延迟 | `fx_mode=1` | `0x30←0`, `0x34←1920`, `0x38←64`, `0x2C←1`, `0x30←64` |
| **K15 短按 合唱** | `fx_mode=2` | `0x30←0`, `0x2C←2`, `0x30←64` |
| K14 混响 | `fx_mode=3` | `0x30←0`, `0x2C←3`, `0x30←64` |

> ⚠️ 注意模式编号和按键顺序**不一致**：K14 是混响 = **3**，K15 短按是合唱 = **2**。
> 编码沿用成员 1 原方案的 `0旁路/1延迟/2合唱/3混响`，不要按按键顺序去推。

参数取值理由：
- `0x34←1920` → 1920 / 48000 = **40 ms** 延迟
- `0x38←64` → 64/256 = **0.25** 反馈
- `0x30←64` → 64/256 = **0.25** 湿声比例（协议上限 128=0.5，取一半留余量）
- 旁路时湿声置 0，切回来时序列会重新把它设成 64

> 这些数值只是**默认预设**，全部做成 `cfg_master` 的常量表，方便改。

### 3.4 K15 短按 / 长按识别（严格互斥）

门槛 **600 ms**，由成员 2 在输入侧完成，成员 1 完全感知不到：

```
按下 K15
   │
   ├── 600 ms 之前松开 ──────────────► 短按 → 切合唱（cfg 序列）
   └── 到达 600 ms 仍未松开 ─────────► 立即触发一次长按 → 颤音档位 +1
                                      之后松开**不再**触发短按
```

规则细节：

| 情况 | 行为 |
|---|---|
| 提前松开（< 600 ms） | 只发短按脉冲，长按不触发 |
| 到点（= 600 ms） | **当拍立即**发一次长按脉冲；松手时不再补短按 |
| 按住很久（> 2 s） | 只在到点那一次触发，**不周期重复** |
| 松开后 | 计时清零，可再次按下 |
| 复位中 | 计时清零、不产生任何脉冲 |

实现建议：新增 `rtl/input/key_tap_hold.sv`

```systemverilog
module key_tap_hold #(
    parameter integer SYS_CLK_HZ = project_params_pkg::SYS_CLK_HZ,
    parameter integer HOLD_MS    = 600
)(
    input  logic sys_clk,
    input  logic rst_n,
    input  logic key_down,      // 消抖后的电平（1=按住）
    output logic tap_pulse,     // 单周期：短按
    output logic hold_pulse     // 单周期：长按（到点即出，不等松手）
);
```
- 输入直接用 `key_down[15]`（`key_debounce` 已给出，含 2 ms 按下 / 5 ms 释放消抖）。
- 计数到 `HOLD_MS` 后饱和；用 `hold_fired` 标志保证一次按压只出一次长按。
- 松开时若 `hold_fired=0` → 出 `tap_pulse`；若 `hold_fired=1` → 什么也不出。

### 3.5 颤音（K15 长按）—— 只写一个寄存器

深度档位循环（4 档）：

| 档位 | 音分 | 写操作 |
|---|---|---|
| 0（关） | 0 | `0x24 ← 0` |
| 1 | 25 | `0x24 ← 25` |
| 2 | 50 | `0x24 ← 50` |
| 3 | 100 | `0x24 ← 100` |
| → 回 0 | 0 | `0x24 ← 0` |

- 速率固定用**复位默认 5 Hz**（`0x28` 复位值 `0x0500`），本轮**不写 `0x28`**。
- 长按**不改变**当前效果模式（不碰 `0x2C`），所以旁路/延迟/合唱/混响下都能单独演示颤音。
- 档位计数保存在 `cfg_master` 内部，复位为 0（关闭）。
- **不抢占效果序列**：若此刻有一段效果序列正在发，颤音写排在其后
  （用一个"待发颤音值"寄存器，序列结束后再发），避免效果模式写一半被打断。
  实际延迟只有几微秒，听不出来。

### 3.6 力度 / 表情 / 滑音（保持不变）

| 项 | 来源 | 说明 |
|---|---|---|
| velocity | 触发 FSR 的 ADC 电平 | `fsr_trigger` 内映射，本轮不动 |
| expression | 表情 FSR（CH0） | 送 `EXPR_MIN(96)~255`，**不会送 0** |
| pitch_bend | 电位器（CH1） | 0~4095，2048 中心 = 不弯音 |

协议 §3.2 要求 `expr_valid=1` 时三个字段**同时**锁存，所以
`input_top` 必须保持「持续送、三字段始终有效」的现有行为，不能只在按键时送。

---

## 4. 新增模块：`rtl/input/cfg_master.sv`

### 4.1 端口

```systemverilog
module cfg_master #(
    parameter integer SYS_CLK_HZ = project_params_pkg::SYS_CLK_HZ
)(
    input  logic        sys_clk,
    input  logic        rst_n,

    // 来自按键译码：单周期脉冲 + 目标模式
    input  logic        fx_req,
    input  logic [1:0]  fx_mode_req,   // 0 旁路 / 1 延迟 / 2 合唱 / 3 混响

    // 来自 K15 长按：单周期脉冲，档位在模块内部循环
    input  logic        vib_req,

    // cfg 总线（对成员 1 的 audio_core_expr）
    output logic        cfg_valid,
    output logic        cfg_write,     // 恒 1，本轮只写不读
    output logic [7:0]  cfg_addr,
    output logic [31:0] cfg_wdata,
    input  logic        cfg_ready,
    input  logic [31:0] cfg_rdata,     // 本轮不使用

    output logic        cfg_busy,        // 调试：序列进行中
    output logic [1:0]  fx_mode_latched, // 当前目标效果模式
    output logic [1:0]  vib_step,        // 调试：颤音档位 0~3
    output logic [7:0]  vib_depth        // 调试：当前音分 0/25/50/100
);
```

### 4.2 时序要求（对齐协议 §4）

1. `cfg_valid && cfg_ready` 的 `sys_clk` 上升沿算一次握手。
2. **`cfg_valid=1 && cfg_ready=0` 期间，`cfg_write/cfg_addr/cfg_wdata` 必须保持不变**
   ——和事件 FIFO 的背压规则一样，用"握手前不改字段"的写法，不要再加 skid buffer。
3. 一次按键 → 一段序列 → 全部握手完成 → `cfg_busy=0`。
4. 复位期间 `cfg_valid=0`。

### 4.3 抢占规则（重要）

序列执行中又按了另一个效果键：

- **立刻终止当前序列，从新序列的第 0 步重新开始**。
- 安全原因：每条序列都以 `0x30←0`（关湿声）开头、以 `0x30←64`（开湿声）结尾，
  所以中途打断再重跑不会留下"湿声卡在 0"或"模式写了一半"的状态。
- 不需要排队，也不需要记住被抢占的模式。

**颤音写入不参与抢占**：`vib_req` 只把"待发深度"记进一个 1 深度寄存器，
等当前效果序列（若有）全部握手完成后再发 `0x24←depth`。
这样长按 K15 不会把正在进行的模式切换打断，代价只是几微秒延迟。

### 4.4 与旧核心共存时的处理

成员 1 的 `audio_core_expr` 尚未合入 main，当前板级顶层里的 `audio_core`
**没有 cfg 端口**。规则：

> 在 `audio_core_expr` 接入之前，板级顶层把 `input_top.cfg_ready` 常量置 `1`，
> 并按 `cfg_valid/cfg_write/cfg_addr/cfg_wdata/cfg_rdata` 悬空处理。

这样按键时序列会"立刻写完"，只是没有效果（无副作用）。接入后直连即可，**成员 2 的代码不用再改**。

---

## 5. 文件改动清单（只动 `rtl/input/` 与 `docs/`、`sim/`）

| 文件 | 动作 | 内容 |
|---|---|---|
| `rtl/input/note_map.sv` | **重写** | 16 键新映射；输出 `is_root_key / root_pitch_class / is_wave_key / wave_sel / is_fx_key / fx_mode`；K15 单独标为 `is_dual_key` |
| `rtl/input/key_event_decoder.sv` | **改** | 根音改用 `root_pitch_class`；波形改直接选择；**删除八度键、`octave_offset`、`WAVEFORM_MAX_SEL` 循环、`ALL_NOTES_OFF` 通路、以及键盘发事件的整个待发表**；新增 `fx_req / fx_mode_req` 输出 |
| `rtl/input/key_tap_hold.sv` | **新增** | §3.4 的短按/长按识别（600 ms，互斥） |
| `rtl/input/cfg_master.sv` | **新增** | §4 的序列发生器 + 颤音档位循环 |
| `rtl/input/input_top.sv` | **改** | 例化 `cfg_master`；新增 6 个 `cfg_*` 端口；`fx_req` 接线 |
| `sim/tb_note_map.sv` | **新增** | 16 键映射逐项核对（含 9 根音音级表） |
| `sim/tb_key_tap_hold.sv` | **新增** | 600 ms 阈值边界、短按/长按互斥、长按不重复 |
| `sim/tb_cfg_master.sv` | **新增** | 四段序列的顺序/数据、颤音档位循环与不抢占、背压保持、复位 |
| `sim/tb_key_event_decoder.sv` | **重写** | 去掉八度/循环/ALL_OFF 用例，加波形直选与 fx 脉冲用例 |
| `sim/tb_input_top.sv` | **重写** | 整机：A8/A9、根音跟随、效果序列、K15 短长按、cfg 背压 |
| `sim/tb_matrix_config.sv` | **删除** | `MATRIX_MODE` 概念取消，覆盖面并入上面两个 TB |
| `docs/key_map.md` | **重写** | 新键位表（唯一权威） |
| `docs/input_interface.md` | 改 | 补 §4.5 cfg 端口说明与"成员 3 接线清单" |
| `docs/member2_scope.md` | 改 | 版本升到 3.0，更新职责与模块状态 |
| `Makefile` | **改（超出原计划）** | `TBS` 加 3 个新 TB、删 `tb_matrix_config`；新增 `lint-top` / `lint-all` |
| `rtl/top/tang_nano20k_top.sv` | **改（超出原计划）** | 仅 4 处接线：删 `MATRIX_MODE`/`octave_debug`，加 6 根 cfg。不改逻辑 |

**不改**：`rtl/common/*`、`rtl/audio/*`、`rtl/audio_out/*`、`constraints/*`。

> ⚠️ `Makefile` 与 `rtl/top/tang_nano20k_top.sv` 原本写的是"不改"。
> 实际执行时改了，原因：
> 1. 不加 `TBS` 条目，新 TB 永远不会被 `make sim` 跑到；
> 2. 删了 `input_top` 的端口后，板级顶层会直接编译失败——**项目必须能编译**。
> 顶层的改动严格限制在"接线"，不含任何逻辑；成员 3 可随时复核。

---

## 6. 寄存器地址常量（本轮临时放本地）

因为不能改 `rtl/common`，地址在 `cfg_master.sv` 内部定义：

```systemverilog
localparam logic [7:0] CFG_VIBRATO_DEPTH  = 8'h24;  // 0/25/50/100 音分
localparam logic [7:0] CFG_FX_MODE        = 8'h2C;   // 0旁路 1延迟 2合唱 3混响
localparam logic [7:0] CFG_WET_GAIN       = 8'h30;
localparam logic [7:0] CFG_DELAY_SAMPLES  = 8'h34;
localparam logic [7:0] CFG_FEEDBACK_GAIN  = 8'h38;
localparam logic [7:0] CFG_FX_CLEAR       = 8'h3C;  // 本轮无按键，保留
localparam logic [7:0] CFG_FX_STATUS      = 8'h44;  // 只读，本轮不读
```

待成员 1 把这份地址写进 `audio_defs.svh` 后，再迁到公共包。

---

## 7. 验收标准（可测量，逐条打勾）

| # | 项目 | 判据 |
|---|---|---|
| A1 | 9 个根音键 | 逐键按下，`base_note` 依次为 60,61,62,64,65,66,68,69,70 |
| A2 | 根音键不发事件 | 按 9 个键全程 `note_on_cnt` 增量为 0 |
| A3 | 3 个波形键 | K3/K7/K11 → `waveform_sel` 稳定为 0/1/2；`11` 无键可选中 |
| A4 | 4 个效果入口 | K12→0、K13→1、K15 短按→2、K14→3，地址/数据序列与 §3.3 完全一致 |
| A4b | K15 短按/长按互斥 | 按住 500 ms 松开 → 只发合唱序列；按住 700 ms → 只发一次 `0x24←25`，松手不再发合唱；按住 3 s → 仍只发一次 |
| A4c | 颤音档位循环 | 连续长按 5 次 → `0x24` 依次写 25, 50, 100, 0, 25 |
| A5 | 背压 | `cfg_ready=0` 期间 `cfg_addr/cfg_wdata/cfg_valid` 保持不变；恢复后序列继续 |
| A6 | 抢占 | 延迟序列执行到第 2 步时按混响键 → 立刻切到混响序列第 0 步 |
| A6b | 颤音不抢占 | 延迟序列执行中长按 K15 → 先把延迟序列发完，再发 `0x24←depth` |
| A7 | 复位 | 序列中途复位 → `cfg_valid=0`、`cfg_busy=0`，复位后重新按键可完整重跑 |
| A8 | 不再有 `ALL_NOTES_OFF` | 连续按满 16 个键 3 轮，`all_off_cnt` 恒为 0 |
| A9 | 任何键都不发音符 | 按满 16 个键，`note_on_cnt`/`note_off_cnt` 增量均为 0 |
| A10 | 端口清理 | `input_top` 已无 `MATRIX_MODE`、`octave_debug`；新增 6 个 `cfg_*` |
| A11 | 无回归 | `make sim` 全部 TB PASS；`make lint` 0 error |
| A12 | 时序预算 | 单次按键到序列最后一笔握手完成 ≤ 100 µs（实测打印） |
| A13 | 颤音档位默认 | 复位后 `vib_step=0`、`vib_depth=0`；不写 `0x28`（用默认 5 Hz） |

---

## 8. 待决策项（需要三人确认，我先按「默认」写进代码）

| # | 问题 | 我采用的默认 | 备选 |
|---|---|---|---|
| D1 | 9 个根音音级是否合适？ | 保留原映射（0,1,2,4,5,6,8,9,10） | 改成 9 音阶根音（只改 `note_map` 一张表） |
| D2 | 效果预设值（40 ms / 0.25 / 0.25） | 按 §3.3 | 上板试听后调 |

> 已定案（2026-11-02，不再讨论）：
> - **不做 `ALL_NOTES_OFF`**、**不做八度键**；
> - **静音波形不占实体键**（编码保留）；
> - **K15 = 合唱（短按）/ 颤音（长按）**，短长按互斥，600 ms 阈值；
> - 颤音深度档位 0 / 25 / 50 / 100 音分，速率固定 5 Hz。

---

## 9. 交接点

| 对象 | 需要对方提供 | 需要我方提供 |
|---|---|---|
| 成员 1 | `audio_core_expr` 实现完成后的 `cfg_ready/cfg_rdata` 时序；`organ/pluck` 波表合入 main | `cfg_master` 的地址/数据序列与握手波形（TB 日志） |
| 成员 3 | 板级顶层把 `input_top.cfg_*` 接到 `audio_core_expr`；未接入前 `cfg_ready` 置 1 | `cfg_*` 端口方向/位宽说明（`docs/input_interface.md`） |

### 9.1 `input_top` 端口变更 —— 成员 3 必须同步的顶层改动

> **状态（2026-11-02）：已由成员 2 代为改好并 `make lint-top` 通过（0 error）。**
> 成员 3 只需复核，无需重做。下面保留原始清单作为对照。

本轮 `input_top` 的端口有增有删，**板级顶层 `rtl/top/tang_nano20k_top.sv` 需要跟着改**
（我们不动成员 3 的文件，只列出需要改的行）：

| 变化 | `input_top` 端口 / 参数 | 顶层要做的事 |
|---|---|---|
| ➕ 新增 | `cfg_valid`(out) | 接到 `audio_core_expr.cfg_valid`；未接入时悬空 |
| ➕ 新增 | `cfg_write`(out) | 同上 |
| ➕ 新增 | `cfg_addr[7:0]`(out) | 同上 |
| ➕ 新增 | `cfg_wdata[31:0]`(out) | 同上 |
| ➕ 新增 | `cfg_ready`(in) | 接 `audio_core_expr.cfg_ready`；**未接入时请接常量 `1'b1`** |
| ➕ 新增 | `cfg_rdata[31:0]`(in) | 接 `audio_core_expr.cfg_rdata`；未接入时接 `32'd0` |
| ➖ 删除 | `octave_debug` | 顶层例化里的 `.octave_debug(),` **删掉这一行** |
| ➖ 删除 | 参数 `MATRIX_MODE` | 顶层例化里的 `.MATRIX_MODE(...)` **删掉这一行**（以及顶层自己的同名参数） |
| ⚠️ 已存在但未接 | `key_ghost_debug` / `key_conflict_debug` / `adc_timeout_debug` | 现在 `make lint-top` 会报 `PINMISSING`，顺手一起接上或显式留空 |

---

## 10. 实施顺序（建议）

1. `note_map.sv` 重写 + `tb_note_map`（先把键位钉死，后面才有得测）
2. `key_event_decoder` 改造 + 更新 TB
3. `cfg_master.sv` + `tb_cfg_master`（单独可测，不依赖其它模块）
4. `input_top` 接线 + 扩充 `tb_input_top`
5. 全量 `make lint` / `make sim`
6. 文档同步（`key_map.md` 为主）

---

## 11. 实施结果（2026-11-02 已完成）

### 11.1 交付状态

| 交付物 | 状态 | 验证 |
|---|---|---|
| `rtl/input/note_map.sv` 重写 | ✅ | `tb_note_map` 17 checks PASS |
| `rtl/input/key_tap_hold.sv` 新增 | ✅ | `tb_key_tap_hold` 10 checks PASS |
| `rtl/input/cfg_master.sv` 新增 | ✅ | `tb_cfg_master` 45 checks PASS |
| `rtl/input/key_event_decoder.sv` 重写 | ✅ | `tb_key_event_decoder` 38 checks PASS |
| `rtl/input/input_top.sv` 改造 | ✅ | `tb_input_top` PASS（13 条 A 项全覆盖） |
| 文档 4 份同步 | ✅ | `key_map` / `input_interface` / `member2_scope` / 本文件 |
| 板级顶层接线 | ✅（代为完成） | `make lint-top` 0 error |

### 11.2 回归结果

```text
make lint        0 error
make lint-audio  0 error
make lint-top    0 error
make sim         13/13 TEST PASSED
make sim-audio   PASS（音频侧无回归）
make sim-v       PASS（Verilator 集成无回归）
```

### 11.3 与任务书原设计的 4 处偏差（都是有意的）

| # | 原设计 | 实际实现 | 原因 |
|---|---|---|---|
| 1 | `cfg_master` 带 `SYS_CLK_HZ` 参数 | **删除该参数** | 序列是纯握手驱动，不需要计时；留着会被 lint 报 UNUSEDPARAM |
| 2 | `note_map` 带 `KEY_COUNT` 参数 | **删除该参数** | 映射表是 4 位 `case`，用不到；同样会报 UNUSEDPARAM |
| 3 | 抢占「立刻终止，从第 0 步重跑」 | **语义为「下一笔起切换」** | `fx_req` 与某笔握手同拍时，那笔 `valid` 已被对端接收，`valid/ready` 协议不允许撤销。最坏多写 1 笔旧序列的中间步，不破坏"湿声关→参数→模式→湿声开"结构。已在 `cfg_master.sv` 与 `input_interface.md` 注明 |
| 4 | `input_top` 新增 6 根 cfg、删 `MATRIX_MODE`/`octave_debug` | 同左，**并新增参数 `TAP_HOLD_MS`（默认 600）** | 短按/长按门槛要能在仿真里覆盖，否则 600 ms 要跑 1620 万拍 |

### 11.4 交付给其他成员的接口

**给成员 1**（已写入协议 §0.5 / §10）：

```
input_top.cfg_valid  -> audio_core_expr.cfg_valid
input_top.cfg_write  -> audio_core_expr.cfg_write
input_top.cfg_addr   -> audio_core_expr.cfg_addr
input_top.cfg_wdata  -> audio_core_expr.cfg_wdata
input_top.cfg_ready  <- audio_core_expr.cfg_ready
input_top.cfg_rdata  <- audio_core_expr.cfg_rdata   (本轮不读)
```

成员 1 侧**不需要增删任何端口**，只需保证 `cfg_ready` 除 `fx_clear` 未完成外恒为 1。

**给成员 3**（已写入 §9.1 与本文件 §11.1）：顶层接线已完成，复核即可。

### 11.5 仍未闭环的外部依赖

| 依赖 | 阻塞了什么 | 归属 |
|---|---|---|
| `audio_core_expr.sv` 实现 | 效果/颤音真正出声 | 成员 1 |
| `organ_1024.hex` / `pluck_1024.hex` | K7/K11 两个波形键出声 | 成员 1 |
| `audio_defs.svh` 波形枚举改名 | 编译期会与 `key_event_decoder` 冲突（改 1 行即好） | 成员 1 |
| `.cst` 引脚 + 上板 | 实际演奏 | 成员 3 |
| 5 路 FSR 分压电路 | 触发力度标定 | 硬件 |
