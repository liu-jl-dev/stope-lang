# Stope 的 Zig 实现

参考实现，语义权威在 [`cpp/`](../cpp/)（语言 / STML / 编译器产物三项标准）。本实现零第三方依赖，模块划分对齐 [`python/`](../python/)。

## 目录结构

```
zig/
├── build.zig / build.zig.zon   # Zig 0.17+，无第三方依赖
├── stope/                      # 库源码（对齐 python/stope/ 的模块划分）
│   ├── root.zig / token.zig / lexer.zig / ast.zig / binarr.zig
│   ├── expr_optim.zig / parser.zig
│   ├── opcode.zig / program.zig / compiler.zig / debug.zig
│   ├── stml.zig / stml_lexer.zig / stml_parser.zig
│   ├── basic_vm.zig / format.zig
├── tests/                      # 测试跑器（读 gdscript/test/data/ 的 golden）
│   ├── golden.zig / dump.zig / main.zig
├── demo/                       # 01 编译运行 / 02 STML / 03 自定义指令 / 04 预导出
└── docs/                       # 用法文档
```

## 跑测试 / demo

在仓库根目录执行（golden 数据真源在 `gdscript/test/data/`，测试依赖它）：

```bash
zig build --build-file zig/build.zig test     # 全部 golden + VM 用例
zig build --build-file zig/build.zig demos    # 四个 demo
```

**3179 条断言全绿**：词法 612、语法 1344、编译 448、反汇编 12、STML 632、VM 78+step/run 等价，均在 `test` 步骤里；四个 demo 可运行。

## 语义对齐要点

见 [`docs/zh-cn/porting-guide.md`](../docs/zh-cn/porting-guide.md) —— 整数 int64 回绕、字符串按 UTF-16 码元、折叠与 VM 共用 helper 等跨语言契约都在那里。

## golden 数据

只读 `gdscript/test/data/`，**绝不复制**：期望值由 C++ 探针 dump，各实现都不手写。

## 文档

[quick-start](docs/quick-start.md) / [stml](docs/stml.md) / [custom-opcode](docs/custom-opcode.md) / [gc](docs/gc.md) / [object-oriented](docs/object-oriented.md)。
