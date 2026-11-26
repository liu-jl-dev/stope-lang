# Stope 的 Java 实现

参考实现，语义权威在 [`cpp/`](../cpp/)（语言 / STML / 编译器产物三项标准）。本实现零第三方依赖，纯 `javac` 构建，模块划分对齐 [`python/`](../python/)。

## 目录结构

```
java/
├── build.sh / run-tests.sh     # 纯 javac（零第三方依赖），JDK 17+
├── stope/                      # 库源码（对齐 python/stope/ 的模块划分）
│   ├── Token.java / TokenType.java / Lexer.java / Ast.java / BinArrParser.java
│   ├── ExprOptim.java / Parser.java
│   ├── Opcode.java / Program.java / Compiler.java / Debug.java / Format.java
│   ├── Stml.java / StmlLexer.java / StmlParser.java
│   └── BasicVM.java
├── tests/                      # 测试跑器（读 gdscript/test/data/ 的 golden）
│   ├── Golden.java / Dump.java / TestMain.java
├── demo/                       # 01 编译运行 / 02 STML / 03 自定义指令 / 04 预导出
└── docs/                       # 用法文档
```

## 跑测试 / demo

在仓库根目录执行（golden 数据真源在 `gdscript/test/data/`，测试依赖它）：

```bash
bash java/run-tests.sh          # 编译 + 全部 golden 与 VM 用例
bash java/build.sh              # 只编译
java -cp java/out demo.Demo01   # 四个 demo（01..04）
```

**3156 条断言全绿**：词法 612、语法 1344、编译 448、反汇编 12、STML 632、VM 96 + step/run 等价与宿主函数；四个 demo 可运行。

## 语义对齐要点

见 [`docs/zh-cn/porting-guide.md`](../docs/zh-cn/porting-guide.md) —— 整数 int64 回绕、字符串按 UTF-16 码元（Java `String` 天然是 UTF-16）、折叠与 VM 共用 helper 等跨语言契约都在那里。

## golden 数据

只读 `gdscript/test/data/`，**绝不复制**：期望值由 C++ 探针 dump，各实现都不手写。

## 文档

[quick-start](docs/quick-start.md) / [stml](docs/stml.md) / [custom-opcode](docs/custom-opcode.md) / [gc](docs/gc.md) / [object-oriented](docs/object-oriented.md)。
