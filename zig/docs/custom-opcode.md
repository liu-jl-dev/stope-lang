# 自定义指令（Zig 版）

> **只想调宿主函数？本文可以跳过** —— 隐式导出 + `Call` 就够了：源码里写一个未声明的名字
> （如 `println("hi")`），它会自动进 `exports`，宿主把函数值塞进对应槽位即可。见 demo04。

自定义指令的适用情况与语义权威在
[`cpp/docs/custom-opcode.md`](../../cpp/docs/custom-opcode.md)。本文只讲 Zig 侧的动线。

## 登记

```zig
var cfg = stope.opcode.CustomOpcodeConfig.init(alloc);
try cfg.add("myop", 100, 2);   // 编号 100，定长 2 参数
try cfg.add("vop", 101, -1);   // 变长
```

**Lexer / Parser / Compiler 必须共用同一个 `cfg` 指针**（Zig 里显式挂在 `Lexer.custom`
与 `Compiler.init` 的第三参）。关键字优先——注册一个叫 `if` 的指令无效。

编号从 33（`kFirstCustomOpcode`）起。内置指令 33 条（0..32），撞号会在反汇编里报 warning
且内置解码优先。

## 编译 + 反汇编

代码见 `zig/demo/03-custom-opcode.zig`。反汇编：`stope.debug.disasm(alloc, prog, &cfg)`。

## 执行

内置 `basic_vm` **不执行自定义指令**（分派表只有 33 项）。要执行得自己扩表：

```zig
try state.custom_ops.put(100, myHandler);   // *const fn(*State) anyerror!void
```

自定义指令没有 callee 入栈，结果仍占一格。变长指令在产物里多跟一个「参数个数」操作数。
