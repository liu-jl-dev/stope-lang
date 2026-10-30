# C# 实现 · 测试说明

> 本文面向**改实现**的人：怎么跑测试、golden 数据怎么读、哪些地方还没覆盖。
> 只想用这个库的话看 [`../README.md`](../README.md)。

## 1. 怎么跑

```bash
dotnet run --project csharp/Stope.Tests
```

退出码：`0` = 全绿，`1` = 有失败。失败时按「用例编号 + 字段」打出来，最多印 40 条：

```
  FAIL CM-42 [OUT]
        期望: code[PushInt(0) ...] vars=1 ...
        实际: code[PushInt(0) ...] vars=2 ...
```

跑之前不用管工作目录：**测试数据目录是从可执行文件所在目录向上找的**
（`Data.LocateDataDir()` 找 `gdscript/test/data`），所以从仓库根、从 `csharp/`、
从 `csharp/Stope.Tests/` 跑都一样。找不到才会抛 `DirectoryNotFoundException`。

只想编译不跑：

```bash
dotnet build csharp/Stope.slnx      # 库 + 测试跑器 + 三个 demo，0 警告
```

三个 demo（`demo/0{1,2,3}`）**不进测试**，要单独跑：

```bash
dotnet run --project csharp/demo/01-quick-start
```

它们的输出与 C++ / Node.js 的对应 demo 逐字节相同，是唯一能看出「跑起来对不对」的地方
（golden 数据只锁中间产物，锁不住 demo 的打印格式）。

三条命令可以横向对照 —— 分组顺序与输出格式刻意做成一致：

```bash
dotnet run --project csharp/Stope.Tests
godot --headless --path gdscript --script res://test/run_tests.gd
npm test --prefix nodejs
```

### 当前结果（2026-10-30）

```
[1/7] 词法（golden_lex.txt）                    588 条
[2/7] 二进制数组 + 常量折叠（golden_binarr.txt）   87 条
[3/7] 语法 + 编译器（golden.txt）               1756 条
[4/7] 嵌套深度上限                                21 条
[5/7] 反汇编（golden_disasm.txt）                 12 条
[6/7] STML（stml_cases.txt + golden_stml.txt）   602 条
[7/7] 参考执行器                                  88 条
====================================================
全部通过：共 3154 条断言
```

## 2. 目录

```
csharp/Stope.Tests/
  Main.cs          测试入口：七组顺序跑，汇总后退出
  Report.cs        Check / CheckInt / CheckTrue / AddFail（**不是测试框架**，见 §3.4）
  Data.cs          golden 读取、反转义、dumpProgram（单行产物格式）
  LexerTests.cs    词法 —— golden_lex.txt
  BinArrTests.cs   二进制数组解析 + 常量折叠矩阵 —— golden_binarr.txt
  ParserTests.cs   语法 + 编译器 —— golden.txt；嵌套深度上限
  DisasmTests.cs   反汇编 —— golden_disasm.txt
  StmlTests.cs     STML 词法 + 语法 —— stml_cases.txt + golden_stml.txt
  VmTests.cs       参考执行器（**没有** golden 数据，见 §5）
```

数据**不在本目录**，在 `gdscript/test/data/`（仓库里只有这一份）：

| 文件 | 条数 | 谁用 |
| --- | --- | --- |
| `golden_lex.txt` | 147 | 词法 |
| `golden.txt` | 195 | 语法 + 编译器共用（各取自己的字段） |
| `golden_binarr.txt` | 86 | 二进制数组 + 折叠矩阵 |
| `stml_cases.txt` | 121 | STML **用例清单**（四方共用） |
| `golden_stml.txt` | 121 | STML 期望值（由清单 dump） |
| `golden_disasm.txt` | 12 | 反汇编完整输出 |

生成这些 `*.txt` 的探针在 `cpp/tools/`，由 CMake 的 `gen-golden` target 编译运行（见 §4）。
它们必须链接 `stope` 库才算出得来期望值，所以留在 C++ 那边；本工程只读它们。

**没有 NuGet 测试包**（不是 xunit / NUnit）。理由有两层：一是保持「零第三方依赖」；
二是要和其他三份实现的汇总格式对齐，自己写 40 行的 `Report` 比配 adapter 省事。

## 3. 期望值不是手写的

**`data/*.txt` 全部由 C++ 侧跑同一批用例 dump 出来**（已入库，跑测试时直接读，不需要
C++ 工具链）。C# 只负责产出同格式文本再逐字段比对。手推期望值一定会错（尤其常量折叠
矩阵、错误恢复、栈容量这些细节），而且会让「C++ 是权威实现」这句话落空。

**唯一例外是执行器组**（§5）：VM 不是标准，错误文案前缀本来就各实现自定，所以那组不读
数据文件，断言只锁「本实现内部自洽 + 与其它三方同答案」。

七组里有五组读数据，比对字段如下：

| 组 | 数据文件 | 比对字段 | 条数 |
| --- | --- | --- | --- |
| 词法 | `golden_lex.txt` | `TOKS` `LEXEMES` `ERRN` `ERRS` | 147 × 4 = **588** |
| 二进制数组 + 折叠 | `golden_binarr.txt` | 整行（`BA` / `FB` / `FU`） | 86 + 1 = **87** |
| 语法 + 编译器 | `golden.txt` | `SHAPE` `LINES` `PERR` `PERRS` `LEXERR` `LEXERRS` `CMP` `OUT` `CERRS` | 195 × 9 + 1 = **1756** |
| 反汇编 | `golden_disasm.txt` | `DIS`（整段，逐字节） | **12** |
| STML 词法 | `golden_stml.txt` | `TOKS` `LEXS` `ERRN` `ERRS` | 62 × 4 = 248 |
| STML 语法 | `golden_stml.txt` | `SHAPE` `RESULT` `ERRN` `ERRS` `LEXERRN` `LEXERRS` | 59 × 6 = 354 |

STML 两组合计 **602**。余下两组（深度 21、执行器 88）不读数据文件，见 §5。

### 3.1 转义：每个文件都不一样

这是最容易踩的坑 —— **四个 golden 文件的转义约定各不相同**，照抄一份到另一份会大批红：

| 文件 | 值是否解转义 | `SRC` 用什么解 | 备注 |
| --- | --- | --- | --- |
| `golden.txt` | 解一层（`Unescape`） | `Unescape`（**两层**，见下） | `FOLD=0\|1` 控制是否折叠 |
| `golden_disasm.txt` | 解一层 | `Unescape`（两层） | `MODE=src\|raw` |
| `golden_lex.txt` | **不解** | `UnescapeLex`（多认 `\v` `\f`） | TOKS/LEXEMES/ERRS 直接就是 esc-lex 形态 |
| `golden_stml.txt` | **不解** | `UnescapeLex` | 只做了 escUtf8；ERRS 里的引号要以 `\"` 形态比 |
| `stml_cases.txt` | — | `UnescapeLex` | 清单本身，不是期望值 |

`golden.txt` 的 `SRC` 要解**两层**：探针写的是 `E_(escUtf8(源码))`，源码本身不是转义文本，
所以多解一层才能还原；而 `SHAPE` / `OUT` 这些字段存的就是「转义后的形态」，只解一层。

三套转义函数在 `Data.cs` 里，与 C++ 探针逐个对应：

- `Unescape` ↔ 探针的 `E_()`（`\n` `\r` `\t` `\\`）
- `UnescapeLex` ↔ 词法那套（多 `\v` `\f`）
- `Esc`（= `Format.Esc`）↔ C++ 的 `escUtf8`（`\` `"` `\n` `\r` `\t`，非 ASCII 一律变 `?`）

### 3.2 `dumpProgram` 不在库里

「单行产物格式」（`docs/zh-cn/compiler-test-plan.md` §2.3）是**只为测试比对**存在的：

```
code[PushInt(0) Assign(2) ...] vars=3 stack=2 maxRet=1 ints=[1,2] floats=[1.5] strs=[a] binarrs=[[01,02]] exports=[f:0]
```

四份实现各写一份、都不进库：C++ 是 `cpp/tools/golden.cpp` 的私有 `dumpLine`，
GD 是 `test/test_util.gd` 的 `dump_program`，nodejs 是 `test/golden.js` 的 `dumpProgram`，
C# 是 `Data.DumpProgram`。三处细节要一致，否则比对毫无意义：

- **浮点用 `%g`**（C# 的 `Format.FmtG` 忠实实现 `printf("%g")`：`nan` / `inf` / 6 位有效数字去尾零）；
- **`exports` 按名字字典序**（C++ 是 `std::map`，C# 的 `Dictionary` 是插入序 → 必须排序再打印）；
- **自定义指令**印成 `Opcode(N)`，带不带操作数看 `isVarArg`。

### 3.3 怎么重新生成数据

跑测试**不需要 C++**（数据已入库）。只有两种情况才需要重跑探针：改了 C++ 侧行为，
或给某组加了新用例。

```bash
cd cpp && cmake --build build --target gen-golden
```

成功时打印四行 `-- gen: <路径>（<字节数> 字节）`。前提是按
[`../../cpp/docs/development.md`](../../cpp/docs/development.md) 配好并能构建。

- 探针不在默认构建里（`EXCLUDE_FROM_ALL`），日常 `cmake --build build` 不会编它们；
- **行尾不用管**：`ReadText` 统一剥 `\r`，Windows / Linux 都能跑；
- 生成完 `git diff` 看一眼，只有无关内容变了就 `git checkout` 回去。

### 3.4 `Report` 不是测试框架

没有测试发现、没有 fixture、没有并行 —— 只有四个方法：

| 方法 | 用途 |
| --- | --- |
| `Check(id, field, want, got)` | 比字符串（绝大多数断言） |
| `CheckInt(id, field, want, got)` | 比 `long`（错误条数、槽位号、步数） |
| `CheckTrue(id, what, ok)` | 布尔条件 |
| `AddFail(id, why)` | 直接记一笔失败（编译意外失败时用） |

每组一个 `Report`，`Main` 累加到总的。这样做只有一个理由：让输出与 GDScript / nodejs
两侧同形，三条命令可以横着看。代价是失败不会自动指到行号 —— 靠 `id` 定位（用例编号 +
字段名），所以**断言时必须填有意义的 `id`**，别写 `Check("", ...)`。

## 4. 加一条用例的流程

1. 在对应的 `cpp/tools/golden*.cpp` 用例数组里加一项（**只在 C++ 侧加**，保持同源）；
2. 重跑 §3.3 的 `gen-golden` 刷新 `data/*.txt`；
3. 必要时同步更新 `docs/zh-cn/*.md` 的 §4 用例清单表；
4. `dotnet run --project csharp/Stope.Tests` —— 新用例会被自动比对，不用改测试代码。
   **另外三份实现同样不用改**，只是要各自跑一遍。

两种例外：

- **`golden_binarr.txt`**：用例列表写死在 `BinArrTests.cs` 的 `BaCases` 数组里（照抄 GD 的
  `_dump_binarr` 与 nodejs 的 `binary.test.js`），加删必须**两边同步**，并且顺序即行序 ——
  缺一条就整体错位。
- **STML**（最省事）：只在 `data/stml_cases.txt` 里加一行（`KIND` / `ST` 或 `SF` / `SRC`），
  重跑 `gen-golden`，更新 `docs/zh-cn/stml-test-plan.md` §4。清单四方共用，探针和测试都不用改。
  新增 `SF=` / `ST=` 取值才需要动 `golden_stml.cpp` 与 `StmlTests.cs` 的 `_state()`。

**深度组和执行器组不在这条流程里** —— 它们没有 golden 数据，见 §5。

## 5. 不读数据文件的两组

### 5.1 嵌套深度上限（`PD-DEPTH`，21 条）

限额与错误文案是**四方约定**（C++ `Parser::maxDepth` = GD `max_depth` = nodejs `maxDepth`
= C# `MaxDepth` = **256**，文案 `line N: nesting too deep (max 256). ` 逐字相同），
没法 dump，所以各实现按约定写死。四条递归路径各测一遍（`paren` / `block` / `unary` / `at`）：

| 用例 | 内容 |
| --- | --- |
| `PD-DEPTH-1…5` | `paren` 200 通过；`paren` / `block` / `unary` / `at` 各 300 报错 |
| `PD-DEPTH-6` | `paren` 12000（曾真的栈溢出） |
| `PD-DEPTH-7…9` | `block` / `unary` / `at` 各 200 通过 |
| `PD-DEFAULT` | 默认 `MaxDepth` = 256 |
| `PD-NOLIMIT` | `MaxDepth = 0` 时不检查（600 层仍能解析） |

⚠ `PD-NOLIMIT` 用的是 **600 层**，不是 nodejs 侧的 2000 层：C# 每层递归的栈帧更大，
默认 1 MB 线程栈会在 2000 层**先在运行时层**溢出，测不到「不检查」这件事本身。

### 5.2 参考执行器（`V-06…V-21`，88 条）

VM 不是标准，没有可 dump 的权威期望值（错误串前缀各实现自定：C# 是 `4: "Div" msg`，
GD 是 `3 Add: msg`）。所以比两类东西：

**① 与其它三方同答案**（`V-06…V-15e`）—— 判 `returns` 与错误消息，错误消息
**只比 `: ` 之后**（`MsgOnly`），前缀归实现自定。覆盖的都是容易写错的地方：

| 组 | 锁什么 |
| --- | --- |
| `V-06` | 布尔就是整数 1 / 0；比较结果也是整数 |
| `V-07` | 整数幂按 64 位回绕（`2 ^ 64` = 0，不是 `INT64_MIN`）；负指数得浮点 |
| `V-08` | 序列重复 / 拼接；负次数报错 |
| `V-09` | 真值：空串 / 空二进制数组为假（照 C++ `truely`，不是 C# 的隐式转换） |
| `V-10` | 整数除零进 `errors`（`Div` / `IDiv` / `Mod`）；浮点除零得 `inf` |
| `V-11` | `!` 只接受 null / 整数 / 浮点 |
| `V-12` | `INT64_MIN` 的取负 / `idiv -1` / `% -1` 都回绕（C# 里不兜就是 `OverflowException`） |
| `V-13` | `idiv` 两侧整数得整数、含浮点**保持浮点** |
| `V-14` | 宿主函数是一个值，直接放变量槽；返回 `bool` 归一成整数 |
| `V-15` | 相等：类型不同一律不等（`"1" != 1`、`null != 0`） |
| `V-16` | 错误串带指令下标（`4: "Div" division by zero. `） |
| `V-17` | `Call` 到非函数报错 |
| `V-18…V-20` | `argc` / `args[i]`、没给实参表、宿主实参表越界 |

**② 本实现内部自洽**（`V-21`）—— `State.Run()` 与 `State.Step()` 是两份独立实现
（热循环不套函数调用），六个程序各跑两遍：`returns`、`errors` 必须一致，
`Step` 必须把指令流走完；顺序执行的（无跳转）还断言「步数 == 指令条数」。
改步进规则忘了同步另一处，这里会立刻红。

> `V-01…V-05` 在本实现里不存在：那是 GDScript 侧 `run()` / `step()` 的编号。
> 编号不追求跨实现对齐，只要求**同一批语义在四方都测到**。

改这几条之前先跑一遍四方差分（同一批源码分别喂给四份执行器，比对 `returns` 与
错误消息 `: ` 之后的部分）—— 2026-10-30 用 47 组做过一次，零差异。

## 6. 覆盖到哪了

前六组跑的就是 `docs/zh-cn/` 四份通用测试计划的用例：

| 计划 | 覆盖 |
| --- | --- |
| [lexer-test-plan.md](../../docs/zh-cn/lexer-test-plan.md) | 空白与注释、行号、整数、浮点、标识符、关键字与自定义指令、字符串、二进制数组、标点、混合 |
| [parser-test-plan.md](../../docs/zh-cn/parser-test-plan.md) | 语句、表达式与字面量、优先级、调用 / 索引 / 括号、自定义指令、行号、错误恢复、折叠；外加二进制数组 + 折叠矩阵 |
| [compiler-test-plan.md](../../docs/zh-cn/compiler-test-plan.md) | `CM-01…CM-72`：字面量、变量与作用域、一元 / 二元运算、调用索引、`return`、控制流、自定义指令、错误场景、折叠与编译的配合 |
| [stml-test-plan.md](../../docs/zh-cn/stml-test-plan.md) | §4 全部 121 条：词法 62 条 + 语法 59 条 |

用例的分节与每条的意图都在四份计划的 §4，改用例前先看那里。执行器组不对应任何计划
（VM 不是标准），它测什么见 §5.2。

**没有覆盖的**：

- **指令表查重（`C-DUP`）**。GDScript 侧 `test_compiler.gd` 的 `_check_dup` 锁了
  「`addCustomOpcode` 遇同名返回 `DuplicateWithBuiltinOpcode` 且不插入」，C# 侧**没有对应
  用例**（`AddCustomOpcode` 的返回值在 `DisasmTests` 的撞号配置里间接用到，但没断言）。
- **执行器的全指令覆盖**。§5.2 只覆盖容易出错的语义，不是每条 opcode 都有对拍用例
  （`At` 的 key 数、容器类型等差异见 [`usage.md`](usage.md)）。
- **非 BMP 字符**（emoji 等）。C# 的 `string` 是 UTF-16，与 C++ 一致；但 GDScript 按码点，
  这类输入的行为尚未定夺，见 [../../docs/zh-cn/stml-test-plan.md](../../docs/zh-cn/stml-test-plan.md) 的 GD-S-18。

## 7. 排错

| 现象 | 原因 / 处理 |
| --- | --- |
| `找不到 gdscript/test/data` | 从非仓库位置跑了（`bin/` 下向上找不到）→ 在仓库里跑，或检查目录是否被误删 |
| 整组只有 `ERRN` 对、`TOKS` 全错 | 行号或 `type_name` 变了，先看第一条差异 |
| 词法组字符串用例大批红 | 转义解错层：`golden_lex.txt` 是**不解**的，见 §3.1 |
| STML 组的 `ERRS` 全是引号差异 | 那个字段要用 `EscQuote`（`\"` 形态）比对，不是 `Unescape` |
| 控制台里中文/符号是乱码 | `Main` 里设了 `Console.OutputEncoding = UTF8`；管道重定向到 PowerShell 时按 UTF-8 解 |
| 单组抛异常（其它组照跑） | 每组外面套了 `try`，异常会变成一条 `FAIL`，看那条的堆栈 |
| 只有 `PD-NOLIMIT` 栈溢出 | 别把 600 层改成 2000，见 §5.1 |
