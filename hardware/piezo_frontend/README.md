# 压电单通道前端板（v1）

版本：v1.0  
日期：2026-10-22  
用途：先验证 **1 路压电** 的钳位、峰值保持、MOS 放电和 ADC 读数，再扩展到 5 路。

---

## 1. 这一版的范围

本板只做 **1 路模拟前端**：

```text
压电片 P0
  -> 1k 限流
  -> BAT54S + BZX84C3V3 钳位
  -> BAT85 峰值检波
  -> 100nF 峰值保持
  -> 2N7002 放电
  -> 100Ω 隔离
  -> ADC_CH2
```

ADS7830 使用现成模块，**模块单独放在面包板/另一块板上**，本板只输出 `ADC_CH2` 模拟电压。FPGA 的 I2C 直接接 ADS7830 模块，不经过本板。

这样做的原因：

1. 本板是纯模拟前端，和 FPGA 的直接数字关系只有 `PIEZO_RST0`；
2. 模拟电压 `ADC_CH2` 交给 ADS7830 数字化，FPGA 通过 I2C 读 ADC；
3. 避免第一次画板就踩 ADS7830 芯片/模块引脚顺序的坑。

### 系统边界

```text
FPGA RTL ──PIEZO_RST0──► 本板 MOS 放电
本板 ADC_CH2 ──模拟电压──► ADS7830 CH2 ──I2C──► FPGA RTL
```

FPGA 的 `piezo_peak` 读的是 `adc_ads7830` 输出的 `sample_data/sample_channel`，它看不到 `ADC_CH2` 这根模拟线。

---

## 2. 对外接口

| 接口 | 类型 | 引脚 | 网络 | 说明 |
|---|---|---|---|---|
| `J1` | 2P 螺钉端子 | 1 | `PIEZO0_P` | 压电片正极 |
| `J1` | 2P 螺钉端子 | 2 | `GND` | 压电片负极，板内接 GND |
| `J2` | 1x2 排针 | 1 | `PIEZO_RST0` | 接 FPGA `piezo_peak_rst[0]` |
| `J2` | 1x2 排针 | 2 | `GND` | 地 |
| `J3` | 1x4 排针 | 1 | `3V3` | ADS7830 模块 VCC |
| `J3` | 1x4 排针 | 2 | `GND` | ADS7830 模块 GND |
| `J3` | 1x4 排针 | 3 | `ADC_CH2` | 接模块 CH2 |
| `J3` | 1x4 排针 | 4 | `GND` | ADC 地 |

> `PIEZO0_N` 就是 `GND`，在 `J1` 附近单点接到地平面，不要悬空。

---

## 3. 与 RTL 的对应关系

| 硬件 | RTL |
|---|---|
| `PIEZO0_P` | 无直接端口，本板输出 `ADC_CH2` 到 ADS7830 CH2 |
| `PIEZO_RST0` | `piezo_peak_rst[0]`，这是本板唯一直接来自 FPGA 的数字控制 |
| `ADC_CH2` | 不是 FPGA 端口；ADS7830 采样后由 `adc_ads7830` 变成 `sample_data` |
| `3V3` / `GND` | 板级电源与地 |

> `I2C_SCL` / `I2C_SDA` 是 FPGA 与 ADS7830 模块之间的总线，不经过本板。FPGA 侧仍是 `adc_scl` / `adc_sda`。

RTL 默认参数：

```text
PIEZO_BASE_CH = 2
PIEZO_THRESH  = 20
PIEZO_OFF_MS  = 500
PIEZO_RETRIG_MS = 50
```

---

## 4. 文件说明

| 文件 | 内容 |
|---|---|
| `netlist.csv` | 逐器件、逐引脚的连接表，可直接照着在立创EDA里连线 |
| `BOM.csv` | 位号、参数、封装、数量 |
| `layout.md` | 布局、走线、地平面和测试点建议 |
| `../../docs/piezo_frontend_check.md` | 上电前检查、上电测试、RTL 联调步骤 |

---

## 5. 立创EDA注意事项

1. **输入/输出端口不是封装**，不会出现在 3D；请用 `J1`~`J3` 这些实际连接器。
2. 所有 GND 用 **GND 电源符号**，不要每个地都造一个端口。
3. 网络名建议统一使用本文件的英文名，避免中文、空格和斜杠。
4. `BAT54S` 的 Pin3 是公共端，接 `CLAMP0`；Pin1 接 GND；Pin2 接 3V3。
5. `BZX84C3V3` 的 A（阳极）接 GND，K（阴极）接 `CLAMP0`，NC 悬空。按本数据手册（R+O BZX84C2V4~C75）：Pin1=A、Pin2=NC、Pin3=K。
6. `2N7002` 的 Pin1=G、Pin2=S、Pin3=D；S 必须接 GND。
7. `J3` 只输出 `ADC_CH2` 和电源；ADS7830 模块的 SCL/SDA 直接接 FPGA，不经过本板。
8. 如果以后把 ADS7830 模块固定在本板上，再增加 SCL/SDA 排针和 4.7k 上拉。
