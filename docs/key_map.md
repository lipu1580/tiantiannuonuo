# 按键映射表

对应 RTL：`rtl/input/note_map.sv`  
默认 `BASE_NOTE = 60`（C4），八度偏移范围 -2 ~ +2。

---

## 1. 物理键号

矩阵扫描顺序为行优先：

```text
key_index = row * 4 + col
```

```text
             col0     col1     col2     col3
row0  K0      K0       K1       K2       K3
row1  K4      K4       K5       K6       K7
row2  K8      K8       K9       K10      K11
row3  K12     K12      K13      K14      K15
```

`raw_key_state[15:0]` 与 `key_down[15:0]` 的 bit 位置就是上表的
`key_index`。

---

## 2. 模式 0：矩阵当键盘（`MATRIX_MODE=0`，默认）

| 键号 | 功能 | 说明 |
|---|---|---|
| K0 | MIDI 60 (C4) | 音符 |
| K1 | MIDI 61 (C#4) | 音符 |
| K2 | MIDI 62 (D4) | 音符 |
| K3 | MIDI 63 (D#4) | 音符 |
| K4 | MIDI 64 (E4) | 音符 |
| K5 | MIDI 65 (F4) | 音符 |
| K6 | MIDI 66 (F#4) | 音符 |
| K7 | MIDI 67 (G4) | 音符 |
| K8 | MIDI 68 (G#4) | 音符 |
| K9 | MIDI 69 (A4) | 音符 |
| K10 | MIDI 70 (A#4) | 音符 |
| K11 | MIDI 71 (B4) | 音符 |
| K12 | ALL_NOTES_OFF | 释放全部声部 |
| K13 | 八度 +1 | 范围 -2 ~ +2 |
| K14 | 波形切换 | 0 → 1 → 2 → 0（上限由 `WAVEFORM_MAX_SEL` 控制，默认 0） |
| K15 | 八度 -1 | 范围 -2 ~ +2 |

---

## 2.1 模式 1：矩阵选根音 + FSR 触发（`MATRIX_MODE=1`）

正式演奏模式。**K0~K11 不再发言符事件**，只更新根音 `base_note`；
发声由 5 片 FSR402 完成（一端接 3.3 V，另一端接 ADC，每路 1 个 10 kΩ 到 GND）。

| 键号 | 功能 |
|---|---|
| K0~K11 | 选根音 MIDI 60~71（C4~B4），只改 `base_note` |
| K12 | ALL_NOTES_OFF |
| K13 | 八度 +1（范围 -2 ~ +2） |
| K14 | 波形切换 0→1→2→3→0 |
| K15 | 八度 -1（范围 -2 ~ +2） |

FSR 触发映射（大调五声音阶）：

| FSR | ADC 通道 | 偏移 | 根音 C4 时 |
|---|---|---|---|
| P0 | CH2 | +0 | 60 (C4) |
| P1 | CH3 | +2 | 62 (D4) |
| P2 | CH4 | +4 | 64 (E4) |
| P3 | CH5 | +7 | 67 (G4) |
| P4 | CH6 | +9 | 69 (A4) |

```text
note_id = clamp(base_note + TRIG_OFFSET[i], 0, 127)
base_note = clamp(60 + root_pitch_class + 12 * octave_offset, 0, 127)
```

- 音高在**触发瞬间锁存**，之后切换根音/八度不影响已发声的声部。
- 初始 `base_note` 为 60；上电未选根音时直接可用。

---

## 3. 八度偏移后的音高

| 八度偏移 | K0 音符 | K11 音符 |
|---|---|---|
| +2 | 84 (C6) | 95 (B6) |
| +1 | 72 (C5) | 83 (B5) |
| 0 | 60 (C4) | 71 (B4) |
| -1 | 48 (C3) | 59 (B3) |
| -2 | 36 (C2) | 47 (B2) |

规则：

- 八度键按下立即生效，只影响之后按下的音符。
- 已经按住的音符在释放时使用按下瞬间锁存的 `note_id`，不会发错音。
- 超出 0~127 的极值会被限幅。

---

## 4. ALL_NOTES_OFF 行为

K12 按下时：

1. 生成一次 `event_type=2'b11` 事件，优先级高于所有待发音符事件；
2. 清空尚未发送的普通事件；
3. 对当前按住的音符键设置释放抑制；
4. 这些键稍后松开时不再产生 `NOTE_OFF`。

这避免了“ALL_OFF 之后又收到旧音符 OFF”造成的状态混乱。

---

## 5. 波形切换

K14 每按下一次循环一次：

```text
0 (正弦) → 1 (方波) → 2 (锯齿) → 0 ...
```

- 切换只改变 `waveform_sel`，不修改已经入队的事件。
- `test_mode=1` 时 `waveform_sel` 强制为 0（正弦），便于测试。

---

## 6. 改为白键音阶（可选）

如果想把 K0~K11 改成 C 大调白键：

```systemverilog
// note_map.sv
if (int'(key_index) < NOTE_KEY_COUNT) begin
    is_note_key = 1'b1;
    note_calc   = int'(BASE_NOTE)
                  + WHITE_KEY_OFFSET[int'(key_index)]
                  + 12 * int'(octave_offset);
end
```

其中偏移表为：

```text
0, 2, 4, 5, 7, 9, 11, 12, 14, 16, 17, 19
```

修改时只改 `note_map.sv`，不要修改：
- `event_type` 编码
- `event_note_id` 位宽
- `event_valid/event_ready` 握手
- `input_top` 端口名

---

## 7. 自定义键位

物理键号到功能的映射集中在 `note_map.sv` 的 `case` 中。若要交换两个
音符键，只需交换对应 `key_index` 的判断，扫描器和事件协议都不需要动。

若矩阵实际行列方向与 PCB 相反，可修改 `input_top` 实例化时的
`ROW_ACTIVE_LOW/COL_ACTIVE_LOW`，或在 `key_scan` 中交换行/列索引。
