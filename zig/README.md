# Stope 的 Zig 实现

参考实现，语义权威在 [`cpp/`](../cpp/)（语言 / STML / 编译器产物三项标准）。本实现零第三方依赖，模块划分对齐 [`python/`](../python/)。

## 目录结构

```
zig/
├── build.zig / build.zig.zon   # Zig 0.17+，无第三方依赖
├── stope/                      # 库源码（对齐 python/stope/ 的模块划分）
│   ├── root.zig
│   ├── token.zig
│   └── lexer.zig
├── tests/                      # 测试跑器（读 gdscript/test/data/ 的 golden）
│   ├── golden.zig              # golden 读取与转义（照抄 python/tests/golden.py）
│   └── main.zig
└── docs/                       # 用法文档
```

## 跑测试

在仓库根目录执行（golden 数据真源在 `gdscript/test/data/`，测试依赖它）：

```bash
zig build --build-file zig/build.zig test
```

当前进度：词法（`golden_lex.txt`，153 条 × 4 字段 = 612 断言）已全绿；parser / 编译器 / STML / BasicVM / 反汇编等模块待移植。

## 语义对齐要点

见 [`docs/zh-cn/porting-guide.md`](../docs/zh-cn/porting-guide.md) —— 整数 int64 回绕、字符串按 UTF-16 码元、折叠与 VM 共用 helper 等跨语言契约都在那里。

## golden 数据

只读 `gdscript/test/data/`，**绝不复制**：期望值由 C++ 探针 dump，各实现都不手写。
