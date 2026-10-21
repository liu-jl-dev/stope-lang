# GDScript 实现 · 测试说明

## 怎么跑

```bash
godot --headless --path gdscript --script res://test/run_tests.gd
```

Windows 上 Godot 没进 PATH 就写全路径（本机是 mono 版）：

```bash
"/d/Program Files/Godot/Godot_v4.7.2-stable_mono_win64/Godot_v4.7.2-stable_mono_win64.exe" \
    --headless --path gdscript --script res://test/run_tests.gd
```

退出码：`0` = 全绿，`1` = 有失败。失败时会把每条不符合的字段按
`ID / 字段 / exp= / got=` 打出来。

> 新建或删除带 `class_name` 的脚本后，请**先**跑一次
> `godot --headless --path gdscript --import` 让 Godot 刷新
> `.godot/global_script_class_cache.cfg`，否则会出现
> `Identifier "Xxx" not declared in the current scope`。

### 当前结果（2026-10-18）

```
================ Stope GDScript 测试 ================
[1/3] 词法分析
  断言 588 条，失败 0 条
[2/3] 语法分析
  （语法累计）  断言 1844 条，失败 0 条
[3/3] 编译器
  断言 2429 条，失败 0 条
====================================================
全部通过：共 2429 条断言
```

## 目录

```
gdscript/test/
  run_tests.gd        入口，依次跑三组并汇总
  test_util.gd        StopeTestUtil：Report、转义、数据文件读取、共用自定义指令表
  test_lexer.gd       StopeTestLexer    —— 词法
  test_parser.gd      StopeTestParser   —— 语法（含二进制数组 + 常量折叠）
  test_compiler.gd    StopeTestCompiler —— 编译器
  data/
    golden_lex.txt      147 条 · 词法
    golden.txt          195 条 · 语法 + 编译器
    golden_binarr.txt    86 条 · 二进制数组 + 常量折叠
  tools/
    golden.cpp          生成 data/golden.txt
    golden_lex.cpp      生成 data/golden_lex.txt
    golden_binarr.cpp   生成 data/golden_binarr.txt
```

## 期望值不是手写的

**`data/*.txt` 全部由 C++ 侧跑同一批用例 dump 出来**。测试这边只负责让 GDScript 侧产出
同格式文本，再逐字段比对。理由：手推期望值一定会出错（尤其常量折叠矩阵、错误恢复、栈容量
这些细节），而且会让「C++ 是权威实现」这句话落空。

三组 Probe 都注册同一张自定义指令表（与 C++ 探针一致）：

- `myop` —— 定长 2 个参数 → opcode `100`
- `vop`  —— 变长参数 → opcode `101`

### 三组测试的比对字段

| 组 | 数据文件 | 比对字段 | 条数 × 字段 |
| --- | --- | --- | --- |
| 词法 | `golden_lex.txt` | `TOKS` `LEXEMES` `ERRN` `ERRS` | 147 × 4 |
| 语法 | `golden.txt` | `SHAPE` `LINES` `PERR` `LEXERR` `PERRS` `LEXERRS` | 195 × 6 |
| 编译器 | `golden.txt` | `CMP` `OUT` `CERRS` | 195 × 3 |
| 语法（附加） | `golden_binarr.txt` | 整行（`BA` / `FB` / `FU` 三种记录） | 86 |

`golden.txt` 被语法组和编译器组共用，两组各取自己那几个字段。

### 记录格式

`golden.txt` / `golden_lex.txt` 一行一条，`\t` 分字段，`key=value`，值里做了一层转义
（`\\` `\n` `\r` `\t`，词法那份还多转 `\v` `\f`）。`SRC=` 是**输入源码**，测试要先反转义
再喂给 Lexer；其余字段是 C++ 的产出，测试要把自己的产出做同样的转义再比字符串。
转义 / 反转义在 `test_util.gd` 的 `esc_ / esc_lex / unesc` 里，与 C++ 探针的 `E_()` 对齐。

`golden_binarr.txt` 没有 `key=`，按位置分列：

```
BA\t输入\tok|err\t[字节]        二进制数组解析
FB\t运算符\t是否折叠\t结果       二元常量折叠
FU\t运算符\t是否折叠\t结果       一元常量折叠
```

### 怎么重新生成数据

**改了 C++ 侧的行为，或要加用例**时才需要重跑。在 `gdscript/test/tools/` 下：

```bash
cd gdscript/test/tools
INC="-I<仓库根>/cpp -I<仓库根>/cpp/stope -I<仓库根>/cpp/test"
g++ -std=c++17 $INC -o gen.exe golden.cpp        && ./gen.exe      > ../data/golden.txt
g++ -std=c++17 $INC -o gen.exe golden_lex.cpp    && ./gen.exe      > ../data/golden_lex.txt
g++ -std=c++17 $INC -o gen.exe golden_binarr.cpp && ./gen.exe      > ../data/golden_binarr.txt
```

本机实测过这三条命令能复现出与 `data/` 完全一致的文件（含
`--strip-trailing-cr`，因为 Windows 上重定向出来是 CRLF，而 `FileAccess` 写出是 LF ——
比对前统一按 LF 看）。

**数据文件和用例清单一一对应**：probe 里的用例数组就是执行顺序，改 probe 就改 Add 数据文件，
两边永远同源。别手工编辑 `data/*.txt`。

## 覆盖到哪了

三组跑的就是 `docs/zh-cn/` 三份通用测试计划的全部用例：

- **词法**：空白与注释 `LEX-W`、行号 `LEX-L`、整数 `LEX-N-I`、浮点 `LEX-N-F`、
  标识符 `LEX-I`、关键字与自定义指令 `LEX-K`、字符串 `LEX-S`、二进制数组 `LEX-B`、
  标点 `LEX-P`、混合 `LEX-MIX`。
- **语法**：语句 `S`、表达式与字面量 `X`、优先级 `P`、调用/索引/括号 `F`、自定义指令 `K`、
  行号 `L`、错误恢复 `R`、折叠 `O`；外加二进制数组 + 折叠矩阵 86 条。
- **编译器**：`CM-01…CM-72`，覆盖字面量、变量与作用域、一元/二元运算、调用索引、return、
  控制流、自定义指令、错误场景、折叠与编译的配合。

用例的分节、每条的意图、作者的意图都在三份计划文档的 §4，改用例前先看那里。

## 加一条用例的流程

1. 在对应的 `tools/golden*.cpp` 的用例数组里加一项（**只有 C++ 侧加**，保持同源）；
2. 重跑上面的 `g++` 命令刷新 `data/*.txt`；
3. 必要时同步更新 `docs/zh-cn/*.md` 的 §4 用例清单表；
4. `godot ... --script res://test/run_tests.gd` —— 新用例会自动被比对上，不用改测试代码。

`golden_binarr.txt` 例外：它的用例列表写死在 `test/test_parser.gd` 的 `_dump_binarr()` 里，
加删必须在**两边同步**（`tools/golden_binarr.cpp` 与 `test_parser.gd`）。
