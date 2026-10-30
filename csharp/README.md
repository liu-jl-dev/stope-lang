# Stope —— C# 实现

Stope 语言的 C# 实现：**词法 / 语法 / 编译器 / STML / 参考执行器**五块齐全，与
`cpp/`（权威实现）、`gdscript/`、`nodejs/` 三套实现逐项对齐。

- **零第三方依赖**：只用 BCL。没有 NuGet 包，`dotnet build` 不需要联网。
- **目标框架 `net10.0`**（实测 SDK 10.0.401）。`csharp/Stope.slnx` 是解决方案。
- **命名跟 C++ 走**：`NextToken` / `ParseProgram` / `Compile` / `Disasm` / `Run` / `Step`，
  与 `cpp/include/stope/*.hpp` 逐名对应，方便对照着读。不做成 C# 惯用的 `NextTokenAsync`
  之类 —— 这一层的价值就在于「四份实现能对着看」。

## 快速上手

```bash
# 在仓库根目录下：
dotnet build csharp/Stope.slnx                    # 库 + 测试 + 三个 demo 一起构建
dotnet run --project csharp/Stope.Tests           # 跑测试（3154 条断言）
dotnet run --project csharp/demo/01-quick-start   # 编译 + 运行一段 Stope 代码
```

测试不需要 C++ 工具链：期望值读的是入库的 `gdscript/test/data/*.txt`
（C++ 探针 dump 出来的唯一真源），本实现不复制第二份。

## 目录

```
csharp/
├── Stope.slnx                  # 解决方案（库 / 测试 / 三个 demo）
├── Stope/                      # 库：一个 .csproj，零依赖
│   ├── Common.cs               # Result 返回码（Success == 0）
│   ├── Token.cs / Lexer.cs     # 词法：数字 / 标识符（含 my:add 命名空间）/ 字符串 / 二进制数组
│   ├── Opcode.cs               # 33 条内置指令 + CustomOpcodeConfig
│   ├── Ast.cs / Shape.cs       # 28 种节点 + 测试用的形状串序列化
│   ├── AstVisitor.cs           # 表驱动遍历骨架（子类重写 OnVisitXxx）
│   ├── Parser.cs               # Pratt 语法分析 + 256 层嵌套上限
│   ├── BinArrParser.cs         # '...' 里那段字节的内容解析
│   ├── ExprOptim.cs            # 常量折叠（单节点变换，不递归）
│   ├── Program.cs              # 指令流 + 常量池 + 变量表
│   ├── Compiler.cs             # AST -> Program（作用域 / 变量槽回收 / 跳转回填）
│   ├── Debug.cs                # Disasm：人读的反汇编
│   ├── BasicVm.cs              # 参考执行器（不是标准，见下）
│   ├── Format.cs               # esc / %g / 字节十六进制，跨实现逐字节一致
│   └── Stml/                   # STML：Element + 四态词法 + 语法器
├── Stope.Tests/                # 控制台测试跑器（自己实现断言，不引测试框架）
├── demo/                       # 三个可运行示例，输出与另外三套实现逐字节相同
└── docs/                       # quick-start / usage / stml / custom-opcode / testing
```

**布局用的是 `dotnet new` 的默认形态**（`Stope/` 与 `Stope.Tests/` 平级，解决方案在
`csharp/` 根）—— .NET 没有强制规范，`src/` + `tests/` 也合法（`dotnet/runtime` 就是），
这里选平铺是因为这套实现**只有一个库 + 一个测试工程**，多一层 `src/` 不承载任何信息。
将来若加 `Stope.Tools` / `Stope.Cli`，它们同样平级放在这里。

## 与另外三套实现的关系

C++ 是**权威实现**，四份出现分歧时以 C++ 的实测行为为准。本实现的做法是：

- **期望值不手写**：全部由 `gdscript/test/data/` 的 golden 数据驱动
  （`golden_lex.txt` 147 条、`golden.txt` 195 条、`golden_binarr.txt` 86 条、
  `golden_disasm.txt` 12 条、`golden_stml.txt` 121 条）。改行为时先重生成数据：
  `cmake --build cpp/build --target gen-golden`。
- **类型映射**（C# 有静态类型，这份对照值得记住）：

  | Stope 值 | C++ | C# | 备注 |
  | --- | --- | --- | --- |
  | 整数 | `long long` | `long` | 溢出不检查、按 64 位补码回绕（项目关掉了 `CheckForOverflowUnderflow`） |
  | 浮点 | `double` | `double` | |
  | 字符串 | `std::u16string` | `string` | UTF-16 码元，与 C++ 一致 |
  | 二进制数组 | `std::vector<char>` | `byte[]` | 常量池按**逐字节**去重 |
  | 布尔 | 无（压整数 1/0） | 无（压 `1L`/`0L`） | 宿主函数返回 `bool` 时归一成整数 |
  | 宿主函数 | `HostFunction` 值 | `Func<object?[], object?>` | 参数整包进来，自己拆 |

- **`long` 的两个陷阱**：`long.MinValue / -1` 在 C# 里会抛 `OverflowException`（不是回绕），
  `% -1` 也有未定义风险 —— `Runtime.IntDiv` / `IntMod` 各加了一个 `b == -1` 的分支，
  与 C++ 的「先取绝对值走 unsigned」等价。写新指令时别直接用 `/` 和 `%`。
- **`bool` 不是值类型**：宿主要是返回 `true`，必须走 `Runtime.Normalize` 折成 `1L`，
  否则后续算术会拿到一个「既不是整数也不是浮点」的值。这条与 GDScript 侧的 V-14 对齐。

## 测试

```
[1/7] 词法（golden_lex.txt）                        588 条
[2/7] 二进制数组 + 常量折叠（golden_binarr.txt）      87 条
[3/7] 语法 + 编译器（golden.txt）                   1756 条
[4/7] 嵌套深度上限                                   21 条
[5/7] 反汇编（golden_disasm.txt）                    12 条
[6/7] STML（stml_cases.txt + golden_stml.txt）      602 条
[7/7] 参考执行器                                     88 条
------------------------------------------------------
全部通过：共 3154 条断言
```

测试跑器是**控制台程序**，不是 xUnit/NUnit：自己实现 `Check(id, 字段, 期望, 实际)` 与
分组汇总。输出格式与 GDScript 的 `run_tests.gd`、nodejs 的 `npm test` 刻意做成同一副样子，
方便三条命令横向对照。

七组怎么来的、golden 数据的转义约定、加一条用例的流程，见
[`docs/testing.md`](docs/testing.md)。

## 标准范围与内置执行器

Stope 只规定三件事：**语言**、**STML**、**编译器的产物 `Program`**。

**不规定虚拟机的标准** —— `BasicVm.cs` 只是**内置的基础虚拟机**（会维护，但不承诺接口
稳定），拿到 `Program` 之后怎么执行、值怎么表示、栈怎么布局、宿主函数怎么调，全由实现者
决定。它**不支持**：

| 内置执行器支持 | 不支持 |
| --- | --- |
| 33 条内置指令、变量槽与栈、`Exports`、宿主函数、`argc`/`args[i]`、单步 `Step()` | **自定义指令**：`Api.OpMap` 只有内置 33 项；产物里 ≥ 33 的编号没有实现（会抛 `ArgumentOutOfRangeException`） |
| 空、整数、浮点、字符串、二进制数组、宿主函数（布尔 = 整数 1/0） | **自定义数据类型**：不能注册新值类型，没有对象 / 结构体 / 类 |

自己写执行器见 [`docs/zh-cn/vm-guide.md`](../docs/zh-cn/vm-guide.md)。

## 文档导览

| 想看 | 去哪 |
| --- | --- |
| 四步上手 + 可复制骨架 + 常见错误 | [`docs/quick-start.md`](docs/quick-start.md) |
| 每个类 / 方法 / 字段 / 返回码 | [`docs/usage.md`](docs/usage.md) |
| STML 怎么用（逐段讲 `demo/02`） | [`docs/stml.md`](docs/stml.md) |
| 自定义指令（逐段讲 `demo/03`） | [`docs/custom-opcode.md`](docs/custom-opcode.md) |
| **改实现**：测试怎么跑、数据怎么来 | [`docs/testing.md`](docs/testing.md) |
| STML / 自定义指令的**语义权威** | [`cpp/docs/stml.md`](../cpp/docs/stml.md)、[`cpp/docs/custom-opcode.md`](../cpp/docs/custom-opcode.md) |
| 语言本身 | [`docs/zh-cn/syntax-intro.md`](../docs/zh-cn/syntax-intro.md)、[`syntax-reference.md`](../docs/zh-cn/syntax-reference.md) |
| 产物格式（指令编号 / 操作数 / 跳转） | [`cpp/docs/development.md`](../cpp/docs/development.md) |
| 虚拟机怎么写（指南，不是规范） | [`docs/zh-cn/vm-guide.md`](../docs/zh-cn/vm-guide.md) |

> 文档语言：本目录的中文文档面向「要改这份实现的人」；`docs/zh-cn/` 是四份实现共用的
> 跨实现契约。文件名一律 ASCII kebab-case。
