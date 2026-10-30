# GDScript 实现 · 测试说明

> 本文面向**改实现**的人：怎么跑测试、golden 数据怎么重生成、哪些地方还没覆盖。
> 只想用这个插件的话看 [`README.md`](README.md)。

## 1. 怎么跑

```bash
godot --headless --path gdscript --script res://test/run_tests.gd
```

这条命令**只需要 Godot**：期望值早就在 `data/*.txt` 里入库了，跑测试不会调用任何 C++
工具。只有重生成期望值时才需要 C++（见 §3.3）。

Windows 上 Godot 没进 PATH 就写全路径（本机是 mono 版，装在 C 盘）：

```bash
"/c/Program Files/Godot/Godot_v4.7.2-stable_mono_win64/godot_console.exe" \
    --headless --path gdscript --script res://test/run_tests.gd
```

跑示例（`demo_0N` 对齐 `cpp/demo/0N-*.cpp`）：

```bash
"/c/Program Files/Godot/Godot_v4.7.2-stable_mono_win64/godot_console.exe" \
    --headless --path gdscript res://demo/demo_01.tscn
```

`demo_02`（STML）、`demo_03`（自定义指令）同样换个文件名即可。改了 demo 或实现之后
三个都该跑一遍：它们不受 golden 数据保护，是唯一能看出"跑起来对不对"的地方。

退出码：`0` = 全绿，`1` = 有失败。失败时按字段打出来：

```
  FAIL GD-P-03  字段 PERRS
    exp= line 2: expected ";". 
    got= line 2: expected "}". 
```

> 新建、删除或**移动**带 `class_name` 的脚本后，请先跑一次
> `godot --headless --path gdscript --import` 让 Godot 刷新
> `.godot/global_script_class_cache.cfg`，否则会出现
> `Identifier "Xxx" not declared in the current scope`。

### 当前结果（2026-10-30）

```
================ Stope GDScript 测试 ================
[1/5] 词法分析
  断言 588 条，失败 0 条
[2/5] 语法分析
  （语法累计）  断言 1855 条，失败 0 条
[3/5] 编译器
  断言 2456 条，失败 0 条
[4/5] STML
  （STML 本组）  断言 3059 条，失败 0 条
[5/5] 执行器
  （执行器本组）  断言 3153 条，失败 0 条
====================================================
全部通过：共 3153 条断言
  （其中词法组 588 条；词法+语法+编译器 2456 条；STML 3059 条；执行器 94 条）
```

> 第 2/3 行打印的是**累计值**，不是本组条数（历史如此）。

## 2. 目录

```
gdscript/test/
  run_tests.gd        入口（SceneTree 脚本），依次跑五组并汇总
  test_util.gd        StopeTestUtil：Report、转义、数据文件读取、共用自定义指令表
  test_lexer.gd       StopeTestLexer    —— 词法
  test_parser.gd      StopeTestParser   —— 语法（含二进制数组 + 常量折叠矩阵）
  test_compiler.gd    StopeTestCompiler —— 编译器
  test_stml.gd        StopeTestSTML     —— STML 词法 + 语法
  test_vm.gd          StopeTestVM       —— 执行器（**没有** golden 数据，见 §3.4）
  data/
    golden_lex.txt      147 条 · 词法
    golden.txt          195 条 · 语法 + 编译器共用
    golden_binarr.txt    86 条 · 二进制数组 + 常量折叠
    stml_cases.txt      121 条 · STML **用例清单**（两侧共用）
    golden_stml.txt     121 条 · STML 期望值（由清单 dump）
    golden_disasm.txt    12 条 · 反汇编器（StopeDebug.disasm）的整段输出
```

本目录**不放 C++ 源码**。生成这些 `*.txt` 的探针在 `cpp/tools/`（`golden.cpp`、
`golden_lex.cpp`、`golden_binarr.cpp`、`golden_stml.cpp`），由 `cpp/CMakeLists.txt`
的 `gen-golden` target 编译并运行（见 §3.3）。它们必须链接 `stope` 库才算出得来期望值，
所以东西留在 C++ 那边；`godot` 不会碰它们，只在「重生成期望值」时才需要。

五组测试各占一个 `class_name`，都只有静态 `run(rep)`。`run_tests.gd` 持有唯一的
`StopeTestUtil.Report`，五组往同一个报表里累加。前四组的期望值来自 `data/*.txt`，
执行器那组自己算（见 §3.4）。

## 3. 期望值不是手写的

**`data/*.txt` 全部由 C++ 侧跑同一批用例 dump 出来**（已入库，跑测试时直接读，不需要
C++），GDScript 只负责产出同格式文本，再逐字段比对。手推期望值一定会错（尤其常量折叠
矩阵、错误恢复、栈容量这些细节），而且会让「C++ 是权威实现」这句话落空。

**唯一例外是执行器组**（§3.4）：VM 不是标准，文字面本来就和 C++ 不同，所以那组不读
数据文件，断言只锁「本实现内部自洽」。

词法 / 语法 / 编译器三个探针都注册同一张自定义指令表（与 `StopeTestUtil.custom_config()`
一致）：

- `myop` —— 定长 2 个参数 → opcode `100`
- `vop` —— 变长参数 → opcode `101`

### 3.1 比对字段

| 组 | 数据文件 | 比对字段 | 条数 × 字段 |
| --- | --- | --- | --- |
| 词法 | `golden_lex.txt` | `TOKS` `LEXEMES` `ERRN` `ERRS` | 147 × 4 = 588 |
| 语法 | `golden.txt` | `SHAPE` `LINES` `PERR` `LEXERR` `PERRS` `LEXERRS` | 195 × 6 = 1170 |
| 语法（附加） | `golden_binarr.txt` | 整行（`BA` / `FB` / `FU` 三种记录） | 86 |
| 编译器 | `golden.txt` | `CMP` `OUT` `CERRS` | 195 × 3 = 585 |
| STML 词法 | `golden_stml.txt` | `TOKS` `LEXS` `ERRN` `ERRS` | 62 × 4 = 248 |
| STML 语法 | `golden_stml.txt` | `SHAPE` `RESULT` `ERRN` `ERRS` `LEXERRN` `LEXERRS` | 59 × 6 = 354 |
| 反汇编 | `golden_disasm.txt` | `DIS`（整段，逐字节） | 12 |
| 编译器（附加） | — | 指令表重名注册 4 条（`C-DUP`，见 §3.4） | 4 |
| 语法（深度） | — | 嵌套深度上限 6 条（`PD-DEPTH`，见 §3.4） | 11 |
| 执行器 | — | step / run 两条路径逐项比对（`V-01…V-04`）+ 自定义指令报错（`V-05`，见 §3.4） | 31 |

合计 **3153**。`golden.txt` 被语法组和编译器组共用，两组各取自己那几个字段；
`golden_stml.txt` 同理被 STML 的词法与语法两半共用。

### 3.2 记录格式

`golden.txt` / `golden_lex.txt` 一行一条，`\t` 分字段，`key=value`，值里做了一层转义
（`\\` `\n` `\r` `\t`，词法那份还多转 `\v` `\f`）。`SRC=` 是**输入源码**，测试先反转义
再喂给 `Lexer`；其余字段是 C++ 的产出，测试把自产出的转义结果按字符串比。
转义 / 反转义在 `test_util.gd` 的 `esc_` / `esc_lex` / `unesc` 里，与 C++ 探针的 `E_()` 对齐。

`golden.txt` 每行还带 `FOLD=0|1`，用来控制 `parser.const_folding`；**同一个用例要能在
两种模式下都成立**，这是折叠加持是否等价的最直接证据。

`golden_binarr.txt` 没有 `key=`，按位置分列：

```
BA\t输入\tok|err\t[字节]        二进制数组解析
FB\t运算符\t是否折叠\t结果       二元常量折叠
FU\t运算符\t是否折叠\t结果       一元常量折叠
```

STML 那份多一层：`data/stml_cases.txt` 是**用例清单本身**（`ID` `KIND` `ST` `SF` `SRC`
`TIMES`），C++ 探针和 `test_stml.gd` 都读它，保证两侧跑的是同一批输入。转义用 `esc_` /
`unesc` 那套；形状串与 lexeme 另外用 `esc_shape`（与 C++ 的 `escUtf8` 一致：多一个 `\"`，
非 ASCII 一律变 `?`）。

### 3.3 怎么重新生成数据

先明确一件事：**跑测试不需要 C++**。`data/*.txt` 全部已入库，`run_tests.gd` 只读它们，
装了 Godot 就能跑。只有两种情况才需要重跑探针：

- 改了 C++ 侧行为（权威实现变了，期望值必须跟着变）；
- 给某组加了新用例。

探针源码在 `cpp/tools/`，但它们**必须链接 `stope` 库**才算出得来期望值 ——
期望值只能由权威实现产出，让被测实现自证的话测试永远是绿的，等于没测。所以四个探针
注册成了 CMake target，一条命令重生成四份：

```bash
cd cpp
cmake --build build --target gen-golden
```

成功时打印四行 `-- gen: <路径>（<字节数> 字节）`，数据落回 `gdscript/test/data/`。
前提是 `cpp/` 已按 [development.md](../../cpp/docs/development.md) 配好并能构建 ——
本来也只有改 C++ 行为的人才需要这一步。

几个要点：

- **不用记编译参数**。探针和 `stope` 静态库一起编（全局 C++20），`-I`、`include/stope`
  都写在 `cpp/CMakeLists.txt` 的 `gen_*` target 里。
- **改了 C++ 接口会编译期报错**，不会静默沿用旧数据 —— 比手敲 `g++` 安全。
- **探针不在默认构建里**（`EXCLUDE_FROM_ALL`），日常 `cmake --build build` 不会编它们。
- **行尾不用管**。Windows 上探针输出 CRLF、Linux 上输出 LF，`.gitattributes` 的
  `* text=auto` 会把入库内容统一成 LF，`read_golden` 也兜底剥 `\r`。手加 `tr -d '\r'`
  反而会和 git 打架（CMake 的 `file(WRITE)` 在 Windows 上会把 `\n` 再转回 `\r\n`）。
- 生成完 `git diff` 看一眼：如果只有时间戳之类无关内容变了，说明 C++ 行为没动，
  `git checkout` 回去即可。
- 可执行文件落在 `cpp/build/`（已被 `.gitignore` 挡），不再有 `gen.exe` 需要手工删。

**数据文件和用例清单一一对应**：探针里的用例数组就是执行顺序，改探针就改数据文件，两边
永远同源。别手工编辑 `data/*.txt` —— STML 那一组则是别手工编辑 `data/golden_stml.txt`，
要加删用例去改 `data/stml_cases.txt`。

### 3.4 不读数据文件的三组

**`C-DUP`（指令表查重）** —— C++ 的 `addCustomOpcode` 遇到同名返回
`DuplicateWithBuiltinOpcode` 且**不插入**。这条靠 `test/test_compiler.gd` 的 `_check_dup`
锁：注册两次同名，断言返回值、保留的是第一次那个、数量没变。

**嵌套深度 `PD-DEPTH`** —— 限额 256 与错误文案是**两侧约定**（C++ `Parser::maxDepth` =
GD `max_depth` = 256，文案 `line N: nesting too deep (max 256). ` 逐字相同），没法 dump，
所以两边各按约定写死：`test/test_parser.gd` 断言 6 条深度（`paren` 200 通过 / 300 报错、
`block` / `unary` / `at` 各 300 报错、`paren` 12000 报错），C++ 侧由
`cpp/test/test_parser_depth.cpp` 跑同一组深度。任一侧改了计数口径或文案，两边都会红。

**执行器组 `V-01…V-14`** —— VM 不是标准，两侧连错误文案都不同（GD 是 `3 Add: msg`，
C++ 是 `3: msg`），没有可 dump 的权威期望值。`V-01…V-05` 比的是**同一程序走两条驱动路径**：

| 路径 | 调用 |
| --- | --- |
| 一次跑完 | `state.run()` |
| 逐条单步 | `while state.step(): pass` |

两条路径的 `returns`、`errors`（条数与全文）、停机时的 `i` 必须逐项相同，停机后再
`step()` 不得执行任何指令。`run()` 与 `step()` 是两份独立实现（为了热循环不套函数调用），
这组就是防止它们漂开的那道锁 —— 改步进规则忘了同步另一处，这里会立刻红。

其中 `V-05` 单独锁一件事：**自定义指令（编号 ≥ 33）里报错时，错误串拼指令名不能越界**。
`Opcode.keys()` 只有 33 项，早期 `_error` 直接下标取，自定义指令一报错就变成引擎级
`Out of bounds` —— 错误一句都没记下来，而 `errors` 为空，`run()` 还会返回 `true`（假装成功）。
现在印成 `0 Custom33: boom. `，断言逐字比对（把 `_inst_name` 的越界保护去掉，这条立刻红）。

C++ 侧有对应用例：`cpp/test/test_vm.cpp` 的 `V-31…V-34`，同样把 `Run()` 与 `Step()` 钉在
一起。但那边 `Run()` **就是**拿 `Step()` 循环（header-only + inline，展开后没有额外开销），
不存在「两份实现要同步」的问题 —— 这是两种语言的取舍差别，不是不一致。

**值语义 `V-06…V-14`** —— 这一组比的是「与 C++ / Node.js 给出同一种答案」，判的是
`returns` 与错误消息（错误串的「下标 + 指令名」前缀由实现定，所以只比 `: ` 之后的部分）。
覆盖的都是在 GDScript 里**容易写错**的地方：

| 组 | 锁什么 |
| --- | --- |
| `V-06` | 布尔就是整数 1 / 0；比较结果也是整数 |
| `V-07` | 整数幂按 64 位回绕（`2 ^ 64` = 0，不是 GDScript 的 `**` 会给出的 INT64_MIN）；负指数得浮点 |
| `V-08` | 序列重复 `"ab" * 2` / `2 * "ab"` / 二进制数组重复；负次数报错；`String + String` 与 `BinArr + BinArr` |
| `V-09` | 真值：空串 / 空二进制数组为假（照 C++ `truely`，不是 Godot 的隐式转换） |
| `V-10` | 整数除零进 `errors`（`Div` / `IDiv` / `Mod`），不让 GDScript 把脚本打崩；浮点除零得 `inf` |
| `V-11` | `!` 只接受 null / 整数 / 浮点，字符串报错 |
| `V-12` | `INT64_MIN` 的取负 / `idiv -1` / `% -1` 都回绕，不能中止脚本 |
| `V-13` | `idiv` 两侧整数得整数、含浮点**保持浮点** |
| `V-14` | 宿主函数返回 `bool` 时归一成整数 |

改这几条之前先跑一遍三方差分（同一批源码分别喂给 C++ / GDScript / Node.js 的执行器，
比对 `returns` 与错误消息）—— 2026-10-30 用 47 组做过一次，三方零差异。

## 4. 覆盖到哪了

前四组跑的就是 `docs/zh-cn/` 四份通用测试计划的用例：

| 计划 | 覆盖 |
| --- | --- |
| [lexer-test-plan.md](../../docs/zh-cn/lexer-test-plan.md) | 空白与注释 `LEX-W`、行号 `LEX-L`、整数 `LEX-N-I`、浮点 `LEX-N-F`、标识符 `LEX-I`、关键字与自定义指令 `LEX-K`、字符串 `LEX-S`、二进制数组 `LEX-B`、标点 `LEX-P`、混合 `LEX-MIX` |
| [parser-test-plan.md](../../docs/zh-cn/parser-test-plan.md) | 语句 `S`、表达式与字面量 `X`、优先级 `P`、调用 / 索引 / 括号 `F`、自定义指令 `K`、行号 `L`、错误恢复 `R`、折叠 `O`；外加二进制数组 + 折叠矩阵 86 条 |
| [compiler-test-plan.md](../../docs/zh-cn/compiler-test-plan.md) | `CM-01…CM-72`：字面量、变量与作用域、一元 / 二元运算、调用索引、`return`、控制流、自定义指令、错误场景、折叠与编译的配合 |
| [stml-test-plan.md](../../docs/zh-cn/stml-test-plan.md) | §4 全部 121 条：词法 `LEX-SX/SW/SS/ST/SN/SP/SL/SE/SR`（62 条）与语法 `PARSE-PA/PB/PC/PL/PE/PF/PH`（59 条） |

用例的分节与每条的意图都在四份计划的 §4，改用例前先看那里。第五组（执行器）不对应任何
计划 —— VM 不是标准，它测什么见 §3.4。

**没有覆盖的**：

- **执行器的全指令覆盖**。§3.4 的 `V-06…V-14` 只覆盖了容易出错的那些语义（算术、序列、
  真值、除零、回绕），不是每条 opcode 都有对拍用例（`At` 的 key 数、容器类型等差异见
  `usage.md` §9）。
- **非 BMP 字符**（emoji 等）。GDScript 按码点、C++ 按 UTF-16 码元，这类输入的行为
  尚未定夺，见 [gdscript-notes.md](gdscript-notes.md) §1.3 与
  [stml-test-plan.md](../../docs/zh-cn/stml-test-plan.md) 的 GD-S-18。

## 5. 加一条用例的流程

1. 在对应的 `cpp/tools/golden*.cpp` 用例数组里加一项（**只在 C++ 侧加**，保持同源）；
2. 重跑 §3.3 的 `gen-golden` 刷新 `data/*.txt`；
3. 必要时同步更新 `docs/zh-cn/*.md` 的 §4 用例清单表；
4. `godot ... --script res://test/run_tests.gd` —— 新用例会被自动比对上，不用改测试代码。

`golden_binarr.txt` 例外：它的用例列表写死在 `test/test_parser.gd` 的 `_dump_binarr()` 里，
加删必须在**两边同步**（`cpp/tools/golden_binarr.cpp` 与 `test_parser.gd`），并保证两边行数
一致 —— 行数不等会直接报「期望 N 行，实际 M 行」。

**STML 又是另一种**（最省事的一种）：

1. 在 `data/stml_cases.txt` 里加一行（`KIND` / `ST` 或 `SF` / `SRC`）；
2. 重跑 §3.3 的 `gen-golden`（读清单的那个探针带参数跑）；
3. 更新 `docs/zh-cn/stml-test-plan.md` §4 的用例表；
4. 跑测试。

因为清单两侧共用，探针和测试**都不用改代码**。新增的 `SF=` / `ST=` 取值才需要动
`golden_stml.cpp` 的 `parseState()` / `textStateFunc` 与 `test_stml.gd` 的 `_state()` /
`_state_func()`。

## 6. 排错

| 现象 | 原因 / 处理 |
| --- | --- |
| `Identifier "StopeLexer" not declared in the current scope` | 全局类缓存过期 → `--import` |
| `FAIL 词法：读不到 res://test/data/...` | 数据文件缺失或被 .gitignore 挡住 → 按 §3.3 重新生成 |
| 整组只有 `ERRN` 对、`TOKS` 全错 | 大概率是行号或 `type_name` 变了，先看第一条差异 |
| `FAIL ... 字段 LEXEMES` | 标点 / 标识符的 lexeme 本来就「实现自定」，只有数字 / 字符串 / 二进制数组参与比对；别把断言扩到标点 |
