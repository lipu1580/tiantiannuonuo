# 成员 1 扩展音频接口协议（V1.1 修订版）

取代：V0.1（2026-11-02 草案）
修订日期：2026-11-02
配套文件：`rtl/audio/audio_core_expr.sv`、`rtl/audio/audio_fx_chain.sv`
（当前两个文件**只有端口，没有内部逻辑**，输出无驱动，不能播放。）

> **V1.1 关键约定**（完整变更见 §9）
> 1. **效果恢复为 4 种**，编码沿用原方案：`0=旁路 1=延迟 2=合唱 3=混响`。
>    （V1.0 曾因键位不足删掉合唱，现改为 K15 复用键，合唱回来了。）
> 2. **颤音恢复**，但只是"cfg 可配 + 档位切换"，不做独立按键：
>    `0x24` 深度（0~100 音分，实际按 0/25/50/100 四档写入）、
>    `0x28` 速率（默认 5 Hz，本轮不写）。
> 3. **按键复用由成员 2 在输入侧完成**（K15 短按=合唱、长按=颤音档位），
>    成员 1 **完全不需要知道**是短按还是长按，只收到普通的寄存器写。
> 4. `pitch_bend` 是**连续值**线性弯音（0=-2 半音，2048=0，4095=+2 半音）。
> 5. **波形由 3 个按键直接选择**（0/1/2）；`waveform_sel=11`（静音）编码保留但本轮无实体键。
> 6. `cfg_ready`：**除 `fx_clear` 未完成外必须保持 1**。
> 7. 成员 2 的**权威写入序列**见 §6。

---

## 0. 成员 1 交付清单（先看这一节）

这一节把「谁提供什么、谁改什么」钉死。**其余章节都是细节，本节是索引。**

### 0.1 前置条件（不满足则本轮无法联调）

| # | 前置条件 | 当前状态 | 动作 |
|---|---|---|---|
| P1 | `rtl/audio/audio_core_expr.sv` 骨架进 main | ❌ **只在 `SWX-dev` 的 `0a582fa`** | 成员 1 先把这个提交并入 `dev/v2` |
| P2 | `rtl/audio/audio_fx_chain.sv` 骨架进 main | ❌ 同上 | 同上 |
| P3 | `organ_1024.hex` / `pluck_1024.hex` 波表进 main | ❌ **只在 `SWX-dev` 的 `52c5450`** | 同上（**不要**带 `0a582fa` 之外的其它骨架改动） |
| P4 | `audio_defs.svh` 波形枚举改名 | ❌ 同上（`52c5450`） | 见 §0.3，**改名是破坏性变更** |

> 成员 2 的 `key_event_decoder` 现在 `import audio_defs_pkg::WAVE_SAWTOOTH`。
> P4 一旦合入，这行会编译失败。**改名前请先在群里说一声**，成员 2 会同步改成
> `WAVE_PLUCK`（只改 1 行）。双方任何一方先合入都会短暂红一次，属正常。

### 0.2 成员 1 将要**提供**的东西（新增文件 / 新增实现）

| 交付物 | 类型 | 验收方式 |
|---|---|---|
| `audio_core_expr.sv` 内部实现（旧 `audio_core` 内容 + cfg 译码 + fx 集成） | 新增实现 | `tb_cfg_decode` PASS，`make lint-all` 0 error |
| `audio_fx_chain.sv` 内部实现（延迟 RAM / 合唱 / 混响 / 旁路 / 控制状态机） | 新增实现 | `tb_audio_fx_chain` PASS |
| `organ_1024.hex`、`pluck_1024.hex` 与 `waveform_rom` 的 `casez` 分支 | 新增资源 | `tb_waveform_rom` PASS（≥4096 checks） |
| `sim/tb_cfg_decode.sv`、`sim/tb_audio_fx_chain.sv` | 新增 TB | `make sim-audio` 全绿 |
| **接线说明**（见 §10） | 文档 | 成员 3 能照抄改顶层 |

### 0.3 成员 1 将要**更改**的东西（改动 / 破坏性变更）

| 文件 | 改什么 | 会不会影响别人 |
|---|---|---|
| `rtl/audio/waveform_rom.sv` | 补 `01`（管风琴）/ `10`（拨弦）分支，`11` 输出 0 | 不影响，纯内部 |
| `rtl/common/audio_defs.svh` | `WAVE_SQUARE→WAVE_ORGAN`、`WAVE_SAWTOOTH→WAVE_PLUCK` | ⚠️ **影响成员 2**：`key_event_decoder.sv` 有 `import ... WAVE_SAWTOOTH` |
| `audio_core_expr.sv` 骨架里的 `pitch_bend` 注释 | `0/2048/4095 对应 -2/0/+2 半音` → **改为「连续值，0=-2 半音，2048=0，4095=+2 半音」** | 不影响编译，但**必须改**，否则实现时容易写成三档 |
| `audio_core_expr.sv` 骨架里的 `MASTER_GAIN` 注释 | `本轮不接配置总线` → 保持（`0x00` 本轮确实不开放） | 无 |
| `audio_core_expr.sv` 骨架里的 `waveform_sel` 注释 | 确认写的是 `00 正弦 / 01 管风琴类 / 10 拨弦类 / 11 静音` | 无 |

### 0.4 成员 1 **不要动**的东西

| 路径 | 归属 |
|---|---|
| `rtl/input/*` | 成员 2（本轮改键位 + 新增 `cfg_master`） |
| `rtl/top/tang_nano20k_top.sv` | 成员 3 |
| `constraints/*` | 成员 3 |
| 旧 `rtl/audio/audio_core.sv` | 保持可回退，不要删、不要改端口 |

### 0.5 **端口层面：成员 1 需要动哪些端口？**

结论先说：**`audio_core_expr` 一个端口都不用增删**，`0a582fa` 的骨架端口集合已经是最终形态。

| 端口组 | 数量 | 是否要改 |
|---|---|---|
| 时钟/复位/`audio_ce` | 3 | 不改 |
| 事件 `event_*` | 5 | 不改 |
| 表情 `expr_valid/expression/pitch_bend/waveform_sel` | 4 | 不改（**只改 `pitch_bend` 注释**） |
| **cfg `cfg_*`** | **6** | **不改**（骨架已有，成员 2 的 `input_top` 会输出同样 6 根） |
| PCM `pcm_*` | 4 | 不改 |
| 测试 `test_mode/test_pattern` | 2 | 不改 |
| 状态 `active_voice_count/voice_active` | 2 | 不改 |

**成员 1 唯一需要「通知别人」的端口级事项**：`input_top` 新增的 6 根 `cfg_*`
（成员 2 提供）要接到 `audio_core_expr` 的 6 根 `cfg_*`，方向刚好互补：

```
input_top            audio_core_expr
cfg_valid   ────────► cfg_valid
cfg_write   ────────► cfg_write
cfg_addr    ────────► cfg_addr
cfg_wdata   ────────► cfg_wdata
cfg_ready   ◄──────── cfg_ready
cfg_rdata   ◄──────── cfg_rdata   （成员 2 本轮不读，可先不接）
```

完整端口权威清单见 **§10.1**。


---

## 1. 本轮范围与分工

本轮方案：**新增功能走配置总线，已有功能维持原控制方式，旧地址只预留不迁移。**

| 内容 | 本轮约定 |
|---|---|
| 演奏控制 | **三维**：力度 `velocity`、连续滑音 `pitch_bend`（原接口），**颤音**（`0x24` 档位，由 K15 长按驱动） |
| 持续表情音量 | 保留 `expression` 输入，不与力度重复计算 |
| 两种新增音色 | 通过两套波表实现管风琴类、拨弦类，用原 `waveform_sel` 切换（成员 2 直选） |
| 包络 | 继续使用固定 ADSR 参数；本轮不同音色不配不同包络 |
| 效果 | **旁路 / 延迟 / 合唱 / 混响 四选一**，无串联需求 |
| 新增配置 | 效果参数 + 颤音参数走 cfg 总线 |
| 原功能配置 | `0x00~0x1C` 保留地址与用途，本轮不开放总线控制/读回 |
| 暂不采用 | 独立 `instrument_id`、`extension_enable`、乐器预设控制模块 |

> **为什么是 3 种效果**：4×4 键盘 16 个键已全部分配（9 根音 + 4 波形 + 3 效果），
> 没有第 4 个键给合唱。合唱留到后续（可用「长按」或独立按键扩展）。

成员职责：

| 成员 | 提供 |
|---|---|
| 成员 2 | 音符事件、表情字段（`expression`/`pitch_bend`/`waveform_sel`）、**cfg 写请求**（效果参数） |
| 成员 3 | 采样节拍 `audio_ce`、I2S 对接，其余与原核心相同 |
| 成员 1 | 扩展核心内完成总线译码、颤音、效果器与音频链路集成 |

**旧 `audio_core` 的端口和用法保持不变**，本轮不修改它。扩展顶层以后改为例化
`audio_core_expr`；两者可以并存，便于回退。

---

## 2. 结构、时钟与参数

```text
事件接口 ──────────────> 声部分配 ───────────┐
表情接口 ──────────────> 表情/音高/波形控制 ─┤
cfg 总线 -> 统一译码 ──> 颤音参数 ──────────┤
                        效果参数快照 ───────┼──────────────┐
                                           v              v
                                      四路 voice -> mixer -> audio_fx_chain
                                                               |
                                                               v
                                                     pcm_stream_adapter
                                                               |
                                                               v
                                                         左/右 PCM
```

全部端口同一个 `sys_clk` 域；`rst_n` 低有效同步复位。跨时钟域与按键消抖由发送方处理。
`audio_ce` 是一个 `sys_clk` 周期宽的采样使能，不是时钟，频率必须等于 `SAMPLE_RATE`。

`audio_core_expr` 参数（与骨架一致）：`VOICE_COUNT=4`、`NOTE_W=7`、
`SAMPLE_W=16`、`SAMPLE_RATE=48000`、`PHASE_W=32`、`WAVE_ADDR_W=10`、
`VOICE_W=24`、`INPUT_W=24`、`OUTPUT_W=24`、`PCM_FIFO_DEPTH=4`、
`MASTER_GAIN=255`、`ATTACK_STEP=500`、`DECAY_STEP=30`、`SUSTAIN_LEVEL=42000`、
`RELEASE_STEP=40`、**`FX_DELAY_DEPTH=4096`**。

`audio_fx_chain` 参数：`SAMPLE_W=24`、`SAMPLE_RATE=48000`、`DELAY_DEPTH=4096`，
分别接核心的 `OUTPUT_W`、`SAMPLE_RATE`、`FX_DELAY_DEPTH`。效果器的 `SAMPLE_W`
是内部样本位宽，与对外 PCM 的 `SAMPLE_W` 含义不同。

约束：`INPUT_W=OUTPUT_W`、`VOICE_W=OUTPUT_W`、`OUTPUT_W>=SAMPLE_W>=2`、
`VOICE_COUNT>=1`、`PCM_FIFO_DEPTH>=1`、`SAMPLE_RATE>0`、`DELAY_DEPTH` 范围 2~4096。

> **音频标度（务必遵守）**：内部 24 位只是扩展容器，**沿用现有 16 位 PCM 数值标度**。
> 当前 `pcm_stream_adapter` 的 `MIX_SHIFT=0`，即 mixer 的输出已经可以直接当 16 位 PCM 用。
> 效果器**不得**再做一次 `>>>8`，否则整机掉 48 dB。

---

## 3. 保留的公共接口（与旧核心完全一致）

### 3.1 音符事件

| 信号 | 方向 | 位宽 | 含义 |
|---|---|---|---|
| `event_valid` | in | 1 | 当前事件有效 |
| `event_ready` | out | 1 | 核心可接受 |
| `event_type` | in | 2 | 00 NOP / 01 NOTE_ON / 10 NOTE_OFF / 11 ALL_NOTES_OFF |
| `event_note_id` | in | NOTE_W | MIDI 编号 |
| `event_velocity` | in | 8 | 0~255，NOTE_ON 时锁存 |

`sys_clk` 上升沿 `event_valid && event_ready` 接受一次事件；阻塞期间发送方保持
`event_valid=1` 且字段稳定。`NOTE_OFF`/`ALL_NOTES_OFF` 只让包络进入释放，
**不直接清除效果尾音**（尾音由 `0x3C` 清除命令控制）。

> **本轮输入侧不再发送 `ALL_NOTES_OFF`**（键盘 16 键已全部重新分配）。
> 编码 `11` 与核心现有处理**保持不变**，成员 1 不需要删代码；只是实际收不到。

### 3.2 表情与音色

`expr_valid=1` 时**同时**锁存下列三个字段（没有 ready）：

| 字段 | 位宽 | 取值与复位 | 备注 |
|---|---|---|---|
| `expression` | 8 | 0~255，复位 255 | 成员 2 实际送 **`EXPR_MIN(96)~255`**，不会送 0 |
| `pitch_bend` | 12 | 复位 2048 | **连续值**：0=-2 半音，2048=0，4095=+2 半音，中间线性 |
| `waveform_sel` | 2 | 复位 00 | 00 正弦 / 01 管风琴 / 10 拨弦 / 11 静音 |

- 弯音保持当前音符与相位连续，**不产生新的 NOTE_ON**。
- `waveform_sel` 由成员 2 的 **3 个按键直接选择**（K3/K7/K11 → 0/1/2），不是循环切换；
  `11`（静音）编码保留，但**本轮没有实体键**，成员 2 不会主动选它。
- 两种新音色只用不同波表，共用固定 ADSR。

### 3.3 PCM、测试与状态

`pcm_valid && pcm_ready` 在 `sys_clk` 上升沿传输一对左右声道样本；
`SAMPLE_W` 位有符号补码，单声道复制到左右。`pcm_valid && !pcm_ready` 时保持
`valid` 与左右样本。FIFO 只能吸收有限背压；效果器初始化/切换不得造成音频停顿。
`pcm_valid` 只表示"有一份待接收数据"，高电平宽度不代表样本数。

`test_mode` / `test_pattern[1:0]` 保留原测试源选择方式；
`active_voice_count` / `voice_active` 保留原含义，**不包含效果尾音**（全声部释放后
仍可能有余响，核心需继续产出零输入样本）。

---

## 4. cfg 配置总线

内部简单同步寄存器接口，**不是 AXI/APB**，也不必映射到 CPU 地址空间。
本轮约定**一个发送方**（成员 2 的 `cfg_master`）。

| 信号 | 方向（相对核心） | 位宽 | 含义 |
|---|---|---|---|
| `cfg_valid` | in | 1 | 当前请求有效 |
| `cfg_ready` | out | 1 | 当前请求可接受 |
| `cfg_write` | in | 1 | 1 写 / 0 读 |
| `cfg_addr` | in | 8 | 字节偏移，已分配地址按 4 字节对齐 |
| `cfg_wdata` | in | 32 | 写数据，无字节写使能 |
| `cfg_rdata` | out | 32 | 当前地址的**组合**读回，无独立 rvalid |

### 4.1 规则

1. 上升沿 `cfg_valid && cfg_ready` 接受一笔请求；写入还需 `cfg_write=1`。
2. `cfg_valid && !cfg_ready` 时，发送方保持 `valid/write/addr/wdata` 稳定。
3. 一笔握手对应一个地址；改多个参数需发多笔。
4. 读请求保持 `cfg_write=0`，在握手上升沿采样 `cfg_rdata`，没有后续响应。
5. 读回表示该上升沿之前已提交的状态。
6. 写握手成功 = 目标寄存器已保存，**不代表效果已切换完成**；进度看 `fx_status`。
7. 复位期间 `cfg_ready=0`；解除复位后才接受访问。
8. 参数字段按完整 32 位无符号**限幅**后保存，不能先截低位造成回绕；读回高位补 0。

> **`cfg_ready` 硬性要求（本轮新增）**
> 除「已接受一条 `fx_clear` 且尚未完成」这一种情况外，`cfg_ready` **必须保持 1**。
> 成员 2 一次按键会连发 2~5 笔写，若你在普通参数写入时拉低 `cfg_ready`，
> 会把按键响应拖到几十毫秒，表现为"按效果键没反应"。

### 4.2 原有地址：只预留，不迁移

本轮规定这些地址**读回 0、写入忽略、请求正常握手**：

| 地址 | 保留用途 | 本轮真实来源 |
|---|---|---|
| 0x00 | master_gain | `MASTER_GAIN` 参数 |
| 0x04 | attack_step | `ATTACK_STEP` 参数 |
| 0x08 | decay_step | `DECAY_STEP` 参数 |
| 0x0C | sustain_level | `SUSTAIN_LEVEL` 参数 |
| 0x10 | release_step | `RELEASE_STEP` 参数 |
| 0x14 | waveform_sel | 原 `waveform_sel` 端口（`expr_valid` 锁存），**总线不开放** |
| 0x18 | 测试模式 | 原 `test_mode` / `test_pattern` 端口 |
| 0x1C | 活跃声部数（只读用途） | 原 `active_voice_count` / `voice_active` 输出 |

### 4.3 新增地址：本轮要实现

| 地址 | 名称 | 访问 | 编码 / 范围 | 复位目标 |
|---|---|---|---|---|
| 0x20 | 保留 | — | 读 0、写忽略 | 0 |
| **0x24** | `vibrato_depth` | 读写 | 音分，整数 0~100；**成员 2 只写 0/25/50/100 四档** | **0（关闭）** |
| **0x28** | `vibrato_rate` | 读写 | 无符号 Q8.8 Hz，0x0100~0x0800（1~8 Hz） | **0x0500（5 Hz）**；成员 2 本轮不写 |
| **0x2C** | `fx_mode` | 读写 | **0 旁路 / 1 延迟 / 2 合唱 / 3 混响**；写入 >3 限幅为 3，不按低两位回绕 | **0** |
| **0x30** | `wet_gain` | 读写 | 无符号 Q0.8，0~128（0~0.5） | **0** |
| **0x34** | `delay_samples` | 读写 | 1~`FX_DELAY_DEPTH-1`（样本），仅延迟模式使用 | **min(1920, FX_DELAY_DEPTH-1)** |
| **0x38** | `feedback_gain` | 读写 | 无符号 Q0.8，0~128（0~0.5），仅延迟模式使用 | **0** |
| 0x3C | `fx_clear` | 读 / 命令写 | 写 bit0=1 请求清除尾音，bit0=0 无操作 | 0 |
| 0x40 | 保留 | — | 读 0、写忽略 | 0 |
| **0x44** | `fx_status` | 只读 | 见下表，写入忽略 | 见 §4.4 |

其他未分配 / 非对齐地址同样"读 0、写忽略、正常握手"；本接口没有错误响应信号。

`fx_clear`：只解释写数据 bit0；读回 bit0=1 表示命令尚未完成，完成后自动归 0。
最多保留一条未完成命令——前一条未完成时新的 `fx_clear` 用 `cfg_ready=0` 回压，
发送方必须保持请求，不能握手后静默丢弃。

### 4.4 `fx_status`（0x44）

| 位 | 名称 | 含义 |
|---|---|---|
| 0 | `busy` | 效果器正在初始化 / 切换 / 清理 |
| 1 | `initialized` | 效果工作存储已就绪，允许使用湿声 |
| 3:2 | `active_mode` | 已完成应用的模式，编码与 `fx_mode` 相同 |
| 4 | `pending` | 核心内仍有未被效果器接受的控制快照或清理命令 |
| 31:5 | 保留 | 读 0 |

复位时 `mode=旁路`、`initialized=0`、`busy=1`、`pending=0`，之后由实际进度更新。
初始化期间持续输出干声；`initialized=0` 时禁止把未初始化 RAM 当湿声读出。
切换中 `active_mode` 保持上一次已完成值，应用完成后更新。
判断目标模式生效：`busy=0 && pending=0 && active_mode==目标`。

### 4.5 忙时写入与应用边界

- 效果参数先更新目标寄存器，再作为控制快照提交给效果器。
- 同一参数连续写入时，未提交的旧目标可被新目标替代，最终应用最近一次值。
- **颤音参数**在写握手时更新目标寄存器，在后续采样边界用于音高计算；
  深度为 0 即关闭颤音，此时音高等于 `pitch_bend` 单独作用的结果。
- 颤音与效果模式互不影响：写 `0x24` **不改变** `0x2C`。
- 效果器 busy 期间**仍允许**总线写入普通目标参数，不重启正在进行的切换。
- 已发出的内部快照在握手前必须稳定；新写入留在目标寄存器，后续另发快照。

---

## 5. 效果器内部接口 `audio_fx_chain`

只由成员 1 内部使用，队友通过核心的公共 cfg 接口控制。地址译码只在核心做一次。

### 5.1 音频数据

| 信号 | 方向 | 位宽 | 连接 |
|---|---|---|---|
| `in_valid` | in | 1 | 接 `mixer.mixed_valid` |
| `in_sample` | in | SAMPLE_W | 接 `mixer.mixed_sample`（有符号单声道） |
| `out_valid` | out | 1 | 接 `pcm_stream_adapter.sample_valid` |
| `out_sample` | out | SAMPLE_W | 接 `pcm_stream_adapter.mixed_sample` |

**没有 ready**：每个 `in_valid` 上升沿恰好接收一个样本，最终恰好产生一个输出、顺序不变。
无有效输入时不推进延迟索引。第一版输入按 48 kHz 均匀到达，不要求每周期都能接收；
但旁路、初始化、清尾音、模式切换都**不能丢失输入样本**。
效果器不直接读 `audio_ce`（mixer 输出可能晚于 `audio_ce`）。
旁路与 `wet_gain=0` 时输出为经过流水线延迟的干声；算法延迟由实现记录。
旁路与模式切换不得清空下游 PCM FIFO。

### 5.2 译码后的控制快照

| 信号 | 方向 | 位宽 | 含义 |
|---|---|---|---|
| `ctrl_valid` | in | 1 | 一组完整控制参数有效 |
| `ctrl_ready` | out | 1 | 可接受当前快照 |
| `ctrl_mode` | in | 2 | **0 旁路 / 1 延迟 / 2 合唱 / 3 混响** |
| `ctrl_wet_gain` | in | 8 | 已限幅 0~128 的 Q0.8 干湿系数 |
| `ctrl_delay_samples` | in | 12 | 已限幅 1~`DELAY_DEPTH-1` 的延迟读距 |
| `ctrl_feedback_gain` | in | 8 | 已限幅 0~128 的 Q0.8 反馈系数 |
| `ctrl_clear` | in | 1 | 本快照附带一次清尾音命令 |
| `fx_busy` / `fx_initialized` / `fx_active_mode` | out | 1/1/2 | 状态回送 |

`ctrl_valid && ctrl_ready` 接受整组字段（含 `ctrl_clear`）；等待期间核心保持字段稳定，
同一快照只提交一次。初始化/切换期间 `ctrl_ready=0`；复位期间 `ctrl_ready=0`、
`out_valid=0`，音频干声路径继续工作。`ctrl_clear` 是**一次性命令**，不是电平。

混音公式：`w = wet_gain/256`，`y = (1-w)*dry + w*wet`；旁路忽略湿声。
`ctrl_mode=2`（**合唱**）与 `ctrl_mode=3`（**混响**）都用固定内部预设，
只开放「模式 + `wet_gain`」两项；`delay_samples` / `feedback_gain` 在其他模式下
仍保存目标值，切回延迟模式时生效。
修改模式或延迟读距时优先保证干声连续；第一版不要求保留旧模式尾音。

---

## 6. 成员 2 会发来的写入序列（权威）

按效果键时，`cfg_master` 会**连发**下列序列，每笔都等 `cfg_valid && cfg_ready`：

| 按键 | 序列（地址 ← 数据，按顺序） | 笔数 |
|---|---|---|
| 旁路（K12） | `0x30←0`，`0x2C←0` | 2 |
| 延迟（K13） | `0x30←0`，`0x34←1920`，`0x38←64`，`0x2C←1`，`0x30←64` | 5 |
| **合唱（K15 短按）** | `0x30←0`，`0x2C←2`，`0x30←64` | 3 |
| 混响（K14） | `0x30←0`，`0x2C←3`，`0x30←64` | 3 |

另外，**K15 长按**只发一笔、且**不改变效果模式**：

| 操作 | 序列 | 说明 |
|---|---|---|
| 长按第 1 次 | `0x24←25` | 颤音 25 音分 |
| 长按第 2 次 | `0x24←50` | 50 音分 |
| 长按第 3 次 | `0x24←100` | 100 音分 |
| 长按第 4 次 | `0x24←0` | 关闭，回到第 1 档循环 |

- 速率不写，用复位默认 5 Hz。
- 若长按时正好有一段效果序列在发，成员 2 会把 `0x24` 那笔**排在序列之后**，
  所以成员 1 可能看到「效果序列 → 颤音写」的连续几笔，属正常。

设计含义：
- 每条序列都以「湿声关」开头、「湿声开」结尾，所以**序列中途被新按键抢占再重跑是安全的**。
- 成员 1 无需为这些写入加队列；`cfg_ready` 保持 1 即可。
- 全部为普通参数写，**本轮不使用 `0x3C`（`fx_clear`）**。
- 一次按键最多 5 笔写，`cfg_ready` 全程为 1 时总耗时约 100 ns 级。

---

## 7. 队友操作示例

### 7.1 选择拨弦类波表

在同一个 `expr_valid` 有效的上升沿发送：

```
expression   = 当前希望保持的表情值
pitch_bend   = 当前希望保持的弯音值（无弯音时 2048）
waveform_sel = 2'b10
```
不写 `0x14`，也不写 `instrument_id`。

### 7.2 颤音（= 长按 K15 一次）

长按 K15 只发一笔：

```
0x24 <- 25        // 25 音分；再按一次是 50，再次 100，再次 0（关闭）
```

`0x28` 不写，用复位默认 `0x0500`（5 Hz）。写 `0x24` **不会改变**当前效果模式，
所以在旁路/延迟/合唱/混响下都能单独听颤音效果。

> 同一时刻若有一段效果序列正在写，成员 2 会把这一笔排在它后面，
> 成员 1 会看到「效果序列 → 0x24」连续几笔，属正常。

### 7.3 设置 40 ms 延迟并开湿声（= 按 K13）

```
0x30 <- 0        // 先关湿声
0x34 <- 1920     // 1920/48000 = 40 ms
0x38 <- 64       // 0.25 反馈
0x2C <- 1        // 延迟模式
0x30 <- 64       // 0.25 湿声
```
读 `0x44` 确认 `busy=0 && pending=0 && initialized=1 && active_mode=1`。
写 `0x2C=0` 回旁路；写 `0x3C=1` 清尾音。

---

## 8. 交付状态与后续

**当前（V1.0 对应代码）**：`audio_core_expr.sv` / `audio_fx_chain.sv` 只有端口，
没有实例化、译码、RAM、效果算法或测试桩。旧 `audio_core`、公共定义、
板级顶层均未改动。

**成员 1 本轮要补**：

1. `audio_core_expr` 内部：把现有 `audio_core` 的内容搬进来 + cfg 译码 + fx 集成
2. `audio_fx_chain` 实现：延迟（RAM + 读距 + 反馈 + 干湿）、混响（固定预设）、旁路、
   `ctrl` 快照/初始化/清尾音状态机、`fx_status` 生成
3. 保持「干声路径永不中断」：初始化、切换、清理期间都要持续出样本
4. 单元 TB：`tb_audio_fx_chain`、`tb_cfg_decode`

**成员 1 不要动**：`rtl/input/`（成员 2）、`rtl/top/`、`constraints/`（成员 3）。

---

## 9. 相对 V0.1 的变更记录

| # | V0.1 | V1.0 | 原因 |
|---|---|---|---|
| 1 | 效果 4 种：旁路/延迟/**合唱**/混响 | ~~3 种，删除合唱~~ → **已被第 14 条推翻，V1.1 恢复 4 种** | 当时判断键位不足；后来改用 K15 复用键解决 |
| 2 | `fx_mode`：0旁路 1延迟 2合唱 3混响 | `0旁路 1延迟 2混响`，**3 = 保留（旁路）** | 编码与按键序号一致，成员 2 映射最简 |
| 3 | `ctrl_mode` 2 位含合唱 | ~~去掉合唱~~ → **V1.1 恢复 0/1/2/3 四值** | 同第 14 条 |
| 4 | §1 "颤音…能够独立演示" | ~~无按键，仅 cfg 可配~~ → **最终决定完全不做颤音**（见第 11 条） | 键位资源不足 + 团队决定砍掉 |
| 5 | `pitch_bend` 写作 0/2048/4095 三档 | 明确为**连续值线性**，三点只是端点 | 实际输入是 0~4095 连续，电位器需要连续响应 |
| 6 | 未提 `cfg_ready` 的可用性 | **除 `fx_clear` 未完成外必须保持 1** | 否则成员 2 的 2~5 笔连发会被拖慢 |
| 7 | 未列成员 2 的具体写序列 | 新增 §6 权威序列表 | 双方对"一次按键发几笔、什么顺序"必须一致 |
| 8 | 未说明波形是循环还是直选 | 明确**4 键直选**，`WAVEFORM_MAX_SEL` 作废 | 避免成员 2 实现成循环、成员 1 又按直选调 |
| 9 | 未说明音频标度风险 | 明确"效果器不得再右移 8 位" | 之前整机掉过 48 dB |
| 10 | 未说明与旧 `audio_core` 的并存期 | 明确两者可并存、便于回退 | 成员 3 切换顶层时需要 |
| 11 | 颤音：cfg 可配 + TB 验证 | **颤音整个取消**，`0x24/0x28` 变为保留地址 | 2026-11-02 团队决定：不做颤音 |
| 12 | `ALL_NOTES_OFF` 由输入侧产生 | 输入侧**不再产生**该事件；事件编码 11 保留、核心实现不用改 | 键盘 16 键已重新分配，无 `ALL_NOTES_OFF` 键 |
| 13 | 八度键切换音区 | 取消八度概念，9 个键直接选根音 | 音区由根音选择本身覆盖 |
| **14** | （V1.0）效果 3 种、无颤音 | **V1.1：效果恢复 4 种（0旁路/1延迟/2合唱/3混响），颤音恢复** | K15 改为「短按=合唱 / 长按=颤音档位」复用键，键位不再冲突 |
| **15** | （V1.0）`0x24`/`0x28` 为保留地址 | **恢复为读写**；深度实际按 0/25/50/100 四档写入，速率用默认 5 Hz 不写 | 颤音回来了，但只做档位、不做独立按键 |
| **16** | （V1.0）波形 4 键直选（含静音） | **波形 3 键直选**（0/1/2）；`11` 静音保留编码、无实体键 | K15 让位给合唱/颤音 |
| **17** | 未说明按键复用归属 | 明确**成员 2 在输入侧完成短按/长按识别（600 ms）**，成员 1 只收普通寄存器写 | 复用逻辑不能泄漏到音频侧 |

---

## 10. 端口权威清单与顶层接线

本节是**唯一权威的端口列表**。前面的表格描述语义，这里描述「照抄什么」。
`0a582fa` 的骨架端口集合已经是最终形态，**不需要增删任何端口**。

### 10.1 `audio_core_expr` 完整端口（成员 1 实现，成员 3 例化）

```systemverilog
module audio_core_expr #(
    parameter integer VOICE_COUNT    = 4,
    parameter integer NOTE_W         = 7,
    parameter integer SAMPLE_W       = 16,
    parameter integer SAMPLE_RATE    = 48_000,
    parameter integer PHASE_W        = 32,
    parameter integer VOICE_W        = 24,
    parameter integer WAVE_ADDR_W    = 10,
    parameter integer PCM_FIFO_DEPTH = 4,
    parameter logic [7:0]  MASTER_GAIN   = 8'd255,
    parameter logic [15:0] ATTACK_STEP   = 16'd500,
    parameter logic [15:0] DECAY_STEP    = 16'd30,
    parameter logic [15:0] SUSTAIN_LEVEL = 16'd42000,
    parameter logic [15:0] RELEASE_STEP  = 16'd40,
    parameter integer INPUT_W        = 24,
    parameter integer OUTPUT_W       = 24,
    parameter integer FX_DELAY_DEPTH = 4096      // 本轮新增
)(
    input  logic        sys_clk,
    input  logic        rst_n,          // 低有效，同步复位
    input  logic        audio_ce,       // 单周期采样使能

    // 事件（与旧 audio_core 完全一致）
    input  logic        event_valid,
    output logic        event_ready,
    input  logic [1:0]  event_type,
    input  logic [NOTE_W-1:0] event_note_id,
    input  logic [7:0]  event_velocity,

    // 表情（与旧 audio_core 完全一致）
    input  logic        expr_valid,
    input  logic [7:0]  expression,
    input  logic [11:0] pitch_bend,     // 连续值：0=-2 半音，2048=0，4095=+2 半音
    input  logic [1:0]  waveform_sel,   // 00 正弦 / 01 管风琴 / 10 拨弦 / 11 静音

    // cfg 配置总线（本轮新增，6 根）
    input  logic        cfg_valid,
    output logic        cfg_ready,
    input  logic        cfg_write,
    input  logic [7:0]  cfg_addr,
    input  logic [31:0] cfg_wdata,
    output logic [31:0] cfg_rdata,

    // PCM
    output logic        pcm_valid,
    input  logic        pcm_ready,
    output logic signed [SAMPLE_W-1:0] pcm_left,
    output logic signed [SAMPLE_W-1:0] pcm_right,

    // 测试与状态
    input  logic        test_mode,
    input  logic [1:0]  test_pattern,
    output logic [$clog2(VOICE_COUNT+1)-1:0] active_voice_count,
    output logic [VOICE_COUNT-1:0] voice_active
);
```

相对旧 `audio_core` 的**唯一**差异：多了 6 根 `cfg_*` 和 1 个 `FX_DELAY_DEPTH` 参数。
其余端口名、方向、位宽、语义**逐字相同**，所以成员 3 可以「把例化名从 `audio_core`
改成 `audio_core_expr`，再补 6 根 cfg」就完成切换。

### 10.2 `audio_fx_chain` 只在 `audio_core_expr` 内部例化

```systemverilog
module audio_fx_chain #(
    parameter integer SAMPLE_W      = 24,
    parameter integer SAMPLE_RATE   = 48_000,
    parameter integer DELAY_DEPTH   = 4096
)(
    input  logic sys_clk,
    input  logic rst_n,
    input  logic in_valid,
    input  logic signed [SAMPLE_W-1:0] in_sample,
    output logic out_valid,
    output logic signed [SAMPLE_W-1:0] out_sample,
    input  logic ctrl_valid,
    output logic ctrl_ready,
    input  logic [1:0]  ctrl_mode,
    input  logic [7:0]  ctrl_wet_gain,
    input  logic [11:0] ctrl_delay_samples,
    input  logic [7:0]  ctrl_feedback_gain,
    input  logic        ctrl_clear,
    output logic        fx_busy,
    output logic        fx_initialized,
    output logic [1:0]  fx_active_mode
);
```

**顶层看不到这个模块**。成员 3 不需要例化它，也不要把 `fx_status` 当端口引出——
它只能通过 `cfg_addr=0x44` 读到。

### 10.3 成员 3 改顶层的完整清单

| 动作 | 内容 |
|---|---|
| ➕ 声明 6 根 wire | `cfg_valid / cfg_write / cfg_addr[7:0] / cfg_wdata[31:0] / cfg_ready / cfg_rdata[31:0]` |
| ➕ `input_top` 侧接线 | `.cfg_valid(...)`, `.cfg_write(...)`, `.cfg_addr(...)`, `.cfg_wdata(...)`, `.cfg_ready(cfg_ready)`, `.cfg_rdata(32'd0)` |
| ➕ `audio_core_expr` 侧接线 | 前 4 根同向连过去，`cfg_ready/cfg_rdata` 反向接回 |
| ➖ `input_top` 删除 | 参数 `.MATRIX_MODE(...)`、端口 `.octave_debug()` |
| 🔄 例化替换 | `audio_core u_core(...)` → `audio_core_expr u_core(...)` |
| ⚠️ 补参数 | `.FX_DELAY_DEPTH(4096)` |
| ⚠️ 已有但未接 | `key_ghost_debug` / `key_conflict_debug` / `adc_timeout_debug` 显式留空 |

`input_top` 在 `audio_core_expr` 接入之前，`cfg_ready` 接常量 `1'b1` 即可：
成员 2 的序列会瞬间写完、无副作用，接入后**成员 2 的代码一行都不用改**。

### 10.4 两个必须遵守的时序承诺

| 承诺 | 数值 | 违反了会怎样 |
|---|---|---|
| `cfg_ready` 除 `fx_clear` 未完成外恒为 1 | 全程 | 成员 2 一次按键连贯发 5 笔，被拖成几毫秒 → 按键「没反应」 |
| 效果器初始化时间 | **≤ 1 ms** | 上电后 `busy=1` 期间只能出干声；超过 1 ms 会听出「开头 1 ms 没效果」 |
| `ctrl_ready=0` 期间 `out_valid` 仍须逐样本输出 | 连续 | PCM FIFO 见底 → 爆音/断音 |
| `FX_DELAY_DEPTH` 改动时 `ctrl_delay_samples` 位宽 | `$clog2(DELAY_DEPTH)` | 12 位只在 `4096` 下刚好；改成 8192 需要 13 位 |

### 10.5 hex 波表的路径约定

`waveform_rom.sv` 里的 `$readmemh` 必须用**相对工程根目录**的路径：

```systemverilog
$readmemh("rtl/audio/organ_1024.hex", rom_organ);
$readmemh("rtl/audio/pluck_1024.hex", rom_pluck);
```

- `make sim-audio` 在工程根目录执行，能找到；
- Gowin EDA 综合时需要把 `rtl/audio/` 加入 **Include Path / File List**，并确认
  综合日志里两个 hex 都是 `read 1024 words`，否则板上是静音；
- 若读失败，`waveform_rom` 应**降级为输出正弦**而不是输出 0，
  这样即使 hex 丢了也能出声（便于现场定位）。
