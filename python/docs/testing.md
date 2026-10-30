# Python 实现 · 测试说明

面向**要改这份实现的人**：八组断言怎么跑、期望值从哪来、加一条用例改哪个文件、
以及 Python 在这一层特有的坑。

## 1. 怎么跑

```bash
# 在仓库根目录下（不需要 C++ 工具链，也不需要装任何包）
python python/tests/run_tests.py

# 也可以从 python/ 目录里跑
cd python && python tests/run_tests.py
```

`run_tests.py` 开头会把 `python/` 插进 `sys.path`，所以不用 `pip install`、不用
`python -m`。退出码：全绿 `0`，有失败 `1`。

`dotnet` / `godot` / `npm` 那三条命令的等价物：

```bash
godot --headless --path gdscript --script res://test/run_tests.gd
npm test
dotnet run --project csharp/Stope.Tests
```

四条命令的输出**刻意做成同一副样子**（八组 / 每组「断言 N 条，失败 0 条」/ 末尾总数），
方便横向对照。注意条数口径不同：本实现与 GD / C# 报的是**断言条数**，nodejs 报的是
**用例（`it`）数**。

## 2. 当前结果

```
[1/8] 词法（golden_lex.txt）                        588 条
[2/8] 二进制数组 + 常量折叠（golden_binarr.txt）       87 条
[3/8] 语法（golden.txt）                           1171 条
[4/8] 编译器（golden.txt）                          585 条
[5/8] 嵌套深度上限                                    21 条
[6/8] 反汇编（golden_disasm.txt）                     17 条
[7/8] STML（stml_cases.txt + golden_stml.txt）      604 条
[8/8] 参考执行器                                     142 条
-------------------------------------------------------
全部通过：共 3215 条断言
```

每组断言数怎么算出来的：

| 组 | 条数 | 构成 |
| --- | --- | --- |
| 词法 | 588 | 147 条用例 × 4 个字段（`TOKS` / `LEXEMES` / `ERRN` / `ERRS`） |
| 二进制数组 + 折叠 | 87 | 1 条「行数一致」自检 + 86 行逐行比对 |
| 语法 | 1171 | 195 条用例 × 6 个字段 + 1 条「用例数」自检 |
| 编译器 | 585 | 195 条用例 × 3 个字段（`CMP` / `OUT` / `CERRS`） |
| 嵌套深度 | 21 | 各深度档位 + 默认值 + `max_depth=0` 不检查 |
| 反汇编 | 17 | 12 条逐字节比对 + 5 条单测（见 §6） |
| STML | 604 | 62 条词法 × 4 + 59 条语法 × 6 + 2 条完整性自检 |
| 执行器 | 142 | 值语义 + 实参表 + 两条驱动路径（见 §6） |

## 3. 目录

```
python/
├── stope/                      # 被测对象（库本身）
└── tests/
    ├── run_tests.py            # 入口：八组依次跑 + 汇总
    ├── report.py               # Report：check / check_int / check_true / add_fail / dump
    ├── golden.py               # 数据定位、转义、读取、dump_program（单行产物格式）
    ├── test_lexer.py           # 588
    ├── test_binarr.py          # 87（二进制数组 + 常量折叠矩阵）
    ├── test_parser.py          # 1171 + run_depth()（深度那 21 条）
    ├── test_compiler.py        # 585
    ├── test_disasm.py          # 17
    ├── test_stml.py            # 604
    └── test_vm.py              # 142
```

没有 `conftest.py`、没有 fixture、没有 mock 库 —— 每个 `test_*.py` 只暴露一个
`run(rep)`，`run_tests.py` 依次调用。

## 4. 期望值不是手写的

**唯一的真源是 C++ 侧**。`cpp/tools/` 下的四个探针把 C++ 的真实输出 dump 成文本，
入库在 `gdscript/test/data/`：

| 文件 | 条数 | 谁生成 | 谁在读 |
| --- | --- | --- | --- |
| `golden_lex.txt` | 147 | `cpp/tools/golden_lex.cpp` | 词法组 |
| `golden.txt` | 195 | `cpp/tools/golden.cpp` | 语法组 + 编译器组 |
| `golden_binarr.txt` | 86 | `cpp/tools/golden_binarr.cpp` | 二进制数组 + 折叠组 |
| `golden_disasm.txt` | 12 | `cpp/tools/golden_disasm.cpp` | 反汇编组 |
| `stml_cases.txt` | 121 | **人写**（用例清单，唯一真源） | STML 组 + `golden_stml.cpp` |
| `golden_stml.txt` | 121 | `cpp/tools/golden_stml.cpp` | STML 组 |

本实现**不复制**第二份数据（`tests/golden.py` 从自身位置向上找 `gdscript/test/data/`）。
理由是：C++ 改行为时只重生成一次，五份实现立刻都知道；复制一份就会出现「哪一份才是真值」。

### 4.1 转义：每个文件都不一样

这是最容易踩的地方，`tests/golden.py` 顶部有同样一张表：

| 文件 | 值要不要解转义 | `SRC` 用什么解 |
| --- | --- | --- |
| `golden.txt` | 解一层 | 解两层（探针写的是 `E_(escUtf8(源码))`） |
| `golden_disasm.txt` | 解一层 | 解两层 |
| `golden_lex.txt` | **不解**（`TOKS`/`LEXEMES`/`ERRS`） | `unescape_lex`（多认 `\v` `\f`） |
| `golden_stml.txt` | **不解**（探针只做了 `escUtf8`） | —（STML 的 SRC 来自 `stml_cases.txt`） |
| `stml_cases.txt` | —（清单本身） | `unescape_lex` |

多解一层会把 `\n` 变成真换行，测试立刻全线飘红。

### 4.2 `dump_program` 不在库里

「单行产物格式」（`code[Assign(2) ...] vars=2 stack=1 ...`）只存在于测试层：
`tests/golden.py` 的 `dump_program`，对应 C++ 的私有 `dumpLine`、GD 的 `test_util.gd`、
nodejs 的 `dumpProgram`、C# 的 `Data.DumpProgram`。**别把它搬进 `stope/`** ——
它不是 `Program` 的公开契约，只是测试的中介物。

库里的 `disasm()` 是另一回事（人读的反汇编），那是要跟 C++ 逐字节对的正式输出。

### 4.3 怎么重新生成数据

改了 C++ 行为之后（**而不是**改了 Python 之后）：

```bash
cd cpp
cmake --build build --target gen-golden      # 四个探针一起重跑，写回 gdscript/test/data/
```

⚠ CMake 的 `file(WRITE)` 在 Windows 上会把 `\n` 转成 `\r\n`。`tests/golden.py` 的
`read_text()` 统一剥掉 `\r`，所以入库 CA 差异交给 git 的 `autocrlf` 处理，不用手工改。

### 4.4 `Report` 不是测试框架

```python
rep.check(cid, "字段名", "期望", "实际")     # 字符串比对，相等记 1 条通过
rep.check_int(cid, "字段名", 1, len(x))      # 整数比对
rep.check_true(cid, "说明", cond)            # 布尔
rep.add_fail(cid, "为什么")                  # 直接记一条失败（编译失败这类）
```

- 失败最多记 40 条（`MAX_SHOWN`），防止一个系统性错误把屏幕刷满。
- 一条失败会让**退出码**变成 1，但不会中断后续组 —— 一组里抛异常也只影响这一组
  （`run_tests.py` 捕获后记一条 `抛异常：…`）。
- 没有「跳过」概念。**「用例没跑」与「用例通过」必须能区分开** —— 所以每组开头都检查
  「数据读到了吗」，STML 组还额外比对「清单条数 == golden 条数」。

## 5. 加一条用例的流程

| 想加什么 | 改哪里 | 然后 |
| --- | --- | --- |
| 词法 / 语法 / 编译 / 反汇编 / 折叠 | **改 C++ 侧的探针**（`cpp/tools/golden*.cpp` 里的用例表） | `cmake --build build --target gen-golden`，Python 侧一行都不用改 |
| STML | 只改 `gdscript/test/data/stml_cases.txt`（一行一条，`ID` / `KIND` / `SRC` …） | 重跑探针；本实现的 `test_stml.py` 自己会遍历清单 |
| 执行器语义 | 改 `tests/test_vm.py`（没有 golden，见 §6） | 直接跑 |
| 嵌套深度 | 改 `tests/test_parser.py` 的 `run_depth()` | 直接跑 |

⚠ 加用例时**别动已有的 `ID`**：跨实现对照靠 `ID`（`I-xx` / `S-xx` / `PARSE-PA-01` …），
改名等于让另外四份实现的报告里出现「多了一条没人认领的失败」。

## 6. 不读数据文件的两组

### 6.1 嵌套深度上限（21 条）

深度上限是**实现定义**的（不是语言标准），C++ 的探针 dump 不出「其他实现该报几层」，
所以这一组是手写期望值：`PD-DEFAULT` / `PD-DEPTH` / `PD-NOLIMIT` 三条编号 + 各档位。

⚠ Python 特有：600 层嵌套要 1800 个栈帧，默认 `sys.setrecursionlimit(1000)` 会在 300 层
就先撞穿。`run_tests.py` 开头 `sys.setrecursionlimit(30000)`；`PD-NOLIMIT` 用的是 600 层
而不是 nodejs 侧的 2000 层，同样是因为栈帧大小。

### 6.2 参考执行器（142 条）

`stope/basic_vm.py` **不是标准**（见仓库根 README「标准范围」），C++ 侧也没有可 dump 的
期望值。所以这一组锁两件事：

1. **`run()` 与 `step()` 一致** —— 两份独立实现（热循环不套函数调用），
   `V-21` 把同一批程序跑两遍，比 `returns` / `errors` / 停机时的 `i` / 走的条数；
2. **与另外四份实现同一种答案** —— 值语义那一族（`V-06` … `V-15`）锁的是
   「顺手用宿主原生运算符就会错」的地方：布尔就是整数、整数回绕、序列重复、
   除零、`INT64_MIN` 三个角落、相等不跨类型。

外加 Python 专属的几条（这是别的实现没有的）：

| 编号 | 锁什么 |
| --- | --- |
| `V-07c` | `(-8.0) ^ 0.5` 得 `nan`（Python 的 `**` 会返回**复数**） |
| `V-10e` | `0.0 / 0` 得 `nan`（Python 抛 `ZeroDivisionError`） |
| `V-10f` | `1.5 % 0` 得 `nan`（Python 抛 `ZeroDivisionError`） |
| `V-10g` | `-7.0 % 2.0` 得 `-1.0`（Python 的 `%` 符号跟除数，C++ 跟被除数） |
| `V-13c` | `1.0 idiv 0` 得 `inf`（`math.trunc(inf)` 抛 `OverflowError`） |
| `V-08g` | `b'\x01' * -2` 报错（Python 静默给 `b''`） |
| `V-15g` | `"😀"[0]` 得 `55357`（UTF-16 码元，不是码点） |
| `V-15h` | 下标越界 |

改执行器语义时按 `csharp/README.md` 的老规矩来：**先跑一次五方差分**（同一批源码分别
喂五条实现，只比 `returns` 与错误消息正文 —— 错误串前缀各实现不同），再动这里。

## 7. 覆盖到哪了

| 块 | 覆盖情况 |
| --- | --- |
| 词法 | `golden_lex.txt` 全覆盖（147 条 × 4 字段）。`TokenType` 47 个成员中，`Invalid` / `Eof` / 各类字面量 / 全部标点 / 关键字都有用例 |
| 常量折叠 | `golden_binarr.txt` 的 `FB` / `FU` 矩阵：每个运算符 × 每个常量类型的「折 / 不折」预期都在数据里 |
| 语法 | `golden.txt` 195 条，含形状串、语句行号序列、错误文案与条数 |
| 编译器 | 同一批 195 条的产物（`OUT`）+ 编译状态（`CMP`）+ 编译错误（`CERRS`） |
| 反汇编 | 12 条（`MODE=src` 走「源码→编译→反汇编」，`MODE=raw` 直接给指令流）+ 5 条单测 |
| STML | 121 条用例（62 词法 + 59 语法），12 个 `TokenType` 全部覆盖 |
| 执行器 | 33 条内置指令都有用例（`V-06` … `V-15` + `V-21` 的六个程序）。**几处防御性分支没有**：`stack underflow. ` / `no implement for value type. ` / `no implement for key num != 1. ` / `no implement for container type. ` —— 正常编译产物走不到它们（编译器保证 `PushId` 只出现在赋值左端、`At` 的 key 恒为 1） |

已知缺口（与另外几份实现一致，不是本实现独有的）：

- **`add_custom_opcode` 的重名查重**只有 GD 侧有专门用例（本实现的 `V-05b` 只查了
  `Api.set_opcode` 的补齐行为）；
- **词法错误恢复**只比 `ERRN` / `ERRS`，没逐 token 比对「恢复后接着扫出什么」。

## 8. Python 侧写测试要小心的地方

| 坑 | 说明 |
| --- | --- |
| 递归深度 | 600 层嵌套 = 1800 帧。`run_tests.py` 里 `sys.setrecursionlimit(30000)` |
| `bool` 是 `int` 子类 | 断言「类型是 int」要写 `type(x) is int` 或 `not isinstance(x, bool)`，别用 `isinstance(x, int)` |
| 浮点格式化 | 期望 `3.0` 这类值要自己补 `.0`（`fmt_g` 给的是 `3`），见 `test_vm._fmt` |
| 非 ASCII | 比 golden 时用 `golden.esc`（非 ASCII → `?`）；STML 那组用 `test_stml._esc16`（按 **UTF-16 码元**，与 C++ 完全一致，顺带修掉了 GD-S-18） |
| 行尾 | golden 读入统一剥 `\r`；自己造期望值时别拼 `\r\n` |
| `grep -c $'\r'` 判行尾 | **别用**（Git Bash 会吞换行，全报成 CRLF）。用 Python 分别数 `\r\n` 与裸 `\n` |
| 打印 | 断言里带换行的实际值会被 `Report.show()` 转义成 `\n`，最多 300 字符 —— 看失败信息时别以为数据坏了 |

## 9. 排错

| 症状 | 原因 / 做法 |
| --- | --- |
| `FileNotFoundError: 找不到 gdscript/test/data` | 从别的目录跑、或把 `python/` 单独拷出去了。数据不入包，测试必须在仓库里跑 |
| 一改实现就全线飘红、失败信息里的「期望」看着像没解转义 | §4.1 的转义表；`read_golden(..., unescape_values=False)` 只对 `golden_lex.txt` / `golden_stml.txt` 用 |
| `KEY=VALUE` 里出现多解一层后的真换行 | 同上 |
| `RecursionError` | §6.1 |
| 某组报「一条都没读到」 | 数据文件被清空 / 路径变了；`golden.locate_data_dir()` 从 `tests/` 向上找 |
| STML 组报 `golden_stml.txt 里没有这条` | 加了 `stml_cases.txt` 却没重跑 `gen-golden` |
| 反汇编组单条失败但 demo 输出一样 | 单行产物格式（`dump_program`）与 `disasm` 是两个东西，先确认比的是哪个 |
| 执行器组报「停机后 step 返回 Success」失败 | `step()` 在 `errors` 非空时必须返回 `Error`；`run()` 与 `step()` 改了一处忘了另一处 |
