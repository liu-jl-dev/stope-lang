# Stope Quick Start（Zig 版）

## 安装

需要 Zig 0.17 或更高版本（本仓库在 0.17.1 上验证）。零第三方依赖，`build.zig.zon` 的依赖清单为空。

```bash
git clone <仓库地址>
cd stope-lang
zig build --build-file zig/build.zig test     # 跑全部 golden 测试（在仓库根执行）
```

> golden 数据真源在 `gdscript/test/data/`，测试直接读它（不复制）。所以测试要在仓库根目录跑。

## 模块一览

| 模块 | 内容 |
| --- | --- |
| `stope/token.zig` / `lexer.zig` | 词法（编号与 C++ 对齐） |
| `stope/ast.zig` | AST 节点 + shape 测试序列化 |
| `stope/parser.zig` | Pratt 语法分析（深度上限 256） |
| `stope/expr_optim.zig` | 常量折叠 + 数值 helper |
| `stope/opcode.zig` / `program.zig` / `compiler.zig` | 指令集、产物、编译器 |
| `stope/debug.zig` | 反汇编 |
| `stope/stml.zig` / `stml_lexer.zig` / `stml_parser.zig` | STML 四态词法 + 解析 |
| `stope/basic_vm.zig` | 参考执行器（**不属于标准**） |
| `stope/format.zig` / `binarr.zig` | `%g` 格式、字节数组字面量 |

## 最小示例：编译并执行一段 Stope 源码

代码见 `zig/demo/01-quick-start.zig`，运行：

```bash
zig build --build-file zig/build.zig 01-quick-start
./zig/zig-out/bin/01-quick-start
```

核心四步：

```zig
var lx = stope.Lexer.init(alloc, src);
var ps = try stope.Parser.init(alloc, &lx);       // 预读两个 token
var tree = stope.ast.Prog.init(alloc);
try ps.parseProgram(&tree);

const prog = try alloc.create(stope.program.Program);
prog.* = stope.program.Program.init(alloc);
var comp = try stope.Compiler.init(alloc, prog, null);
_ = try comp.compile(&tree, &.{});               // 第三参 = preExports

const state = try alloc.create(stope.basic_vm.State);
state.* = try stope.basic_vm.State.init(alloc, prog);
_ = try state.run();
```

## 内存管理

库 API 普遍接收 `std.mem.Allocator`，测试与 demo 用 `ArenaAllocator` 一次性释放。
`Program` 的字符串/字节数组常量是 arena 里的切片，arena 必须活得比 `Program` 与 `State` 长。
自定义指令表通过 `Lexer.custom` 与 `Compiler` 的第三参共用同一个 `CustomOpcodeConfig` 指针。

## 与其它实现的关系

本实现是**参考实现**，语义权威在 `cpp/`。词法 / 语法 / 编译器 / STML / 反汇编的期望值
全部由 C++ 探针 dump 到 `gdscript/test/data/`，本实现直接读、不手写。BasicVM 是内置
参考执行器，**不属于标准**——换一台执行器完全不用它。详见
[../../docs/zh-cn/vm-guide.md](../../docs/zh-cn/vm-guide.md)。

## 更多

- [stml.md](stml.md)：STML 用法
- [custom-opcode.md](custom-opcode.md)：自定义指令（多数使用者可跳过）
- [gc.md](gc.md) / [object-oriented.md](object-oriented.md)：宿主 OOP 示例的约定（本实现暂无对应 demo，见其它实现）
- [../../docs/zh-cn/syntax-reference.md](../../docs/zh-cn/syntax-reference.md)：语言权威
