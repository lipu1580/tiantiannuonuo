# event_router 仿真说明

运行全部场景：

```sh
make sim WAIT_TB_NAME=event_router RTL_NAME=event_router
```

结束时终端会显示中文总结，并写入 `/tmp/tb_event_router_summary.txt`。
失败时会在打印总结之后返回非零退出码。每类错误只即时打印前三条，
完整计数和首个错误保留在总结里，避免重复故障刷屏。

需要波形时：

```sh
make sim WAIT_TB_NAME=event_router RTL_NAME=event_router VFLAGS='--binary --timing --trace -Wno-fatal'
build/verilator/event_router/Vtb_event_router +waves
```

即使第一条命令因 RTL 检查失败而返回非零，只要编译成功，仍可执行第二条。
波形文件为 `/tmp/tb_event_router.vcd`。单独运行已编译程序时，
可以添加 `+summary=/tmp/my_event_router_summary.txt` 修改总结路径。

## 验收约定

- 使用此前讨论的单条事件缓存，不要求固定的输出延迟或内部状态编码。
- 缓存占用时暂停接收；模式不一致或释放过程中，两个输入 ready 都为 0。
- 模式切换先完成缓存事件，再完成一次内部 ALL_NOTES_OFF，最后接收新源。
- 已开始的释放不因 test_mode 改回而取消；释放握手时采用最新 test_mode。
- 复位恢复外部模式，清除待发送事件。复位期间丢弃缓存事件是预期行为。
- 不检查 valid=0 时的输出字段；内部释放命令的 note/velocity 不规定数值，
  但在 valid=1 且 ready=0 时必须与 type 一起保持。

TB 在下降沿驱动、上升沿检查握手，不读取 DUT 的内部寄存器。
两个上游都保持未被接收的 valid 和字段，只有握手或复位才能撤销。
计分板保存实际输入握手的事件，核对输出字段及顺序；内部释放另行检查。
固定种子随机测试可复现。每个等待最多 24 拍，超时后继续后面的场景。

## 怎样读错误总结

| 类别 | 优先检查 |
|---|---|
| RESET | 实际模式和 valid 是否复位，复位后能否接收外部源 |
| READY | 未选源、缓存占用或模式切换时是否错误允许接收 |
| DATA | 是否在输入握手沿保存字段，是否在 valid 有效时就输出缓存 |
| HOLD | 阻塞后是否提前撤销 valid，字段是否被 ready 或模式改变 |
| SWITCH | 是否先排空旧事件，释放是否保持到握手，是否正确启用新源 |
| TIMEOUT | 事件是否没写入缓存，valid 是否只维持一拍导致无法继续 |
| COUNT | 是否多发一拍、丢事件，或未收到输入却产生普通输出 |

失败次数是失败检查点数量，不等于独立 bug 数量。先修复首个根因，再重跑，
不要按失败次数逐条修改。后续错误可能是同一个早期故障的连锁结果。
随机用例在严重死锁时可能无法覆盖全部行为，应结合覆盖统计和定向场景判断。

Verilator 通常采用二态仿真，未初始化变量可能碰巧为 0。
本 TB 也会在切到测试模式后再次复位，以检查实际模式是否恢复，
但通过测试仍不能代替对复位赋值的代码检查。
