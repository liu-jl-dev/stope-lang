# Node.js 实现 · 测试说明

> 本文面向**改实现**的人：怎么跑测试、三种驱动方式的区别、哪些地方还没覆盖。
> 只想用这个包的话看 [`../README.md`](../README.md) 与 [`quick-start.md`](quick-start.md)。
> 词法那一组的**用例清单与覆盖矩阵**单独在 [`lexer-test-plan.md`](lexer-test-plan.md)。

## 1. 怎么跑

```bash
cd nodejs
npm test          # 全跑
npm run test:watch
npm run test:cov  # 带覆盖率，并卡门禁（行 80% / 分支 70%）
npm run check     # 只做语法检查（node --check src/index.js）
```

用的是 Node 自带的 `node:test`（`node --test "test/**/*.test.js"`），**零第三方依赖** ——
和测试框架无关，包本身也不引入任何依赖，所以选了内置跑器。输出是 TAP：

```
# tests 780
# suites 29
# pass 780
# fail 0
# duration_ms 364
```

退出码 `0` = 全绿，`1` = 有失败（失败时 TAP 会把期望值/实际值都打出来）。

> ⚠ **780 是「用例（it）数」，不是断言条数**。一个 `test()` 里可以有好几条 `assert`。
> GDScript（3153）与 C#（3154）报的是断言条数 —— 三个数字口径不同，不能横向比大小。

跑 demo（三个；输出给人看，不必与其它实现逐字节相同）：

```bash
node demo/01-quick-start/main.js
node demo/02-stml/main.js
node demo/03-custom-opcode/main.js
```

demo **不进测试**，是唯一能看出「跑起来对不对」的地方（golden 只锁中间产物，
锁不住 demo 的打印格式）。

### 当前结果（2026-10-30）

| 文件 | 用例数 | 驱动方式 |
| --- | --- | --- |
| `lexer.test.js` | 87 | **自写期望值**（见 §3.2） |
| `parser.test.js` | 204 | golden.txt 195 + 条数自检 1 + 深度 8 |
| `compiler.test.js` | 200 | golden.txt 195 + 补测 5 |
| `binary.test.js` | 87 | golden_binarr.txt 86 + 行数自检 1 |
| `disasm.test.js` | 17 | golden_disasm.txt 12 + 单测 5 |
| `stml.test.js` | 122 | stml_cases.txt 121 + 条数自检 1 |
| `vm.test.js` | 58 | 自写（执行器，见 §4） |
| `smoke.test.js` | 5 | 包自洽（见 §3.3） |
| **合计** | **780** | |

覆盖率（`npm run test:cov`）：**行 89.43% / 分支 90.88%**，门禁 80 / 70。
函数列 78% 不在门禁里（`program.js`、`stml.js` 里几个 getter 没被跑到）。

## 2. 目录

```
nodejs/test/
  golden.js        golden 读取、反转义、dumpProgram（单行产物格式）
  helpers.js       词法断言族：expectType / expectLex / expectParsed / expectInt / …
  run_case.js      跑一条 golden.txt 用例（词法 → 语法 → 编译），摊平成同名字段
  lexer.test.js    词法（自写用例，编号沿用 C++）
  parser.test.js   语法（golden）+ 嵌套深度上限
  compiler.test.js 编译器（golden）+ 作用域 / 清空输出补测
  binary.test.js   二进制数组解析 + 常量折叠矩阵（golden）
  disasm.test.js   反汇编（golden）+ 排序等单测
  stml.test.js     STML 词法 + 语法（清单 + golden）
  vm.test.js       参考执行器（自写，无 golden）
  smoke.test.js    包本身的自洽检查（无 golden）
```

数据**不在本目录**，在 `../../gdscript/test/data/`（`test/golden.js` 的 `dataDir`），
仓库里只有这一份，五份实现都读它。

| 文件 | 条数 | 谁用 |
| --- | --- | --- |
| `golden.txt` | 195 | 语法 + 编译器共用（各取自己的字段） |
| `golden_binarr.txt` | 86 | 二进制数组 + 折叠矩阵 |
| `stml_cases.txt` | 121 | STML **用例清单**（四方共用） |
| `golden_stml.txt` | 121 | STML 期望值（由清单 dump） |
| `golden_disasm.txt` | 12 | 反汇编完整输出 |
| `golden_lex.txt` | 147 | ⚠ **本实现不读**，见 §3.2 |

生成这些 `*.txt` 的探针在 `cpp/tools/`（`golden.cpp`、`golden_binarr.cpp`、
`golden_stml.cpp`、`golden_disasm.cpp`），由 CMake 的 `gen-golden` target 编译运行（§3.4）。
它们必须链接 `stope` 库才算出得来期望值，所以留在 C++ 那边。

## 3. 三种驱动方式

### 3.1 golden 驱动（parser / compiler / binary / disasm / stml）

**期望值不手写**：`data/*.txt` 由 C++ 侧跑同一批用例 dump 出来（已入库，跑测试不需要
C++）。nodejs 只负责产出同格式文本再逐字段比对。手推期望值一定会错（尤其折叠矩阵、
错误恢复、栈容量），而且会让「C++ 是权威实现」这句话落空。

| 组 | 数据 | 比对字段 |
| --- | --- | --- |
| 语法 | `golden.txt` | `SHAPE` `LINES` `PERR` `PERRS` `LEXERR` `LEXERRS` |
| 编译器 | `golden.txt` | `CMP` `OUT` `CERRS` |
| 二进制数组 + 折叠 | `golden_binarr.txt` | 整行（`BA` / `FB` / `FU`） |
| 反汇编 | `golden_disasm.txt` | `DIS`（整段，逐字节） |
| STML 词法 | `golden_stml.txt` | `TOKS` `LEXS` `ERRN` `ERRS` |
| STML 语法 | `golden_stml.txt` | `SHAPE` `RESULT` `ERRN` `ERRS` `LEXERRN` `LEXERRS` |

`golden.txt` 被语法与编译器两组共用：`run_case.js` 一次跑完词法→语法→编译，把结果摊平成
同名字段，两边各取自己那几个。同一条用例要在 `FOLD=0|1` 两种模式下都成立。

**转义每个文件都不一样**，照抄一份到另一份会大批红：

| 文件 | `readGolden` 的 `unescapeValues` | 说明 |
| --- | --- | --- |
| `golden.txt` / `golden_disasm.txt` | `true`（解一层） | `SRC` 要**再解一层**（探针写的是 `E_(escUtf8(源码))`） |
| `golden_stml.txt` | **`false`** | 只做了 escUtf8，多解一层会把 `\n` 变成真换行 |
| `golden_lex.txt` | — | 本实现不读 |

**`dumpProgram` 不在库里**：「单行产物格式」（`docs/zh-cn/compiler-test-plan.md` §2.3）
只为比对存在，五份实现各写一份、都不进库（C++ 是 `tools/golden.cpp` 的私有 `dumpLine`，
GD 是 `test_util.gd` 的 `dump_program`，C# 是 `Data.DumpProgram`，本实现是
`test/golden.js` 的 `dumpProgram`）。三处细节要一致：

- 浮点用 `%g` 的忠实实现（`fmtGBytes`：`nan` / `inf` / 6 位有效数字去尾零）；
- `exports` **按名字字典序**（C++ 是 `std::map`，JS 的 `Map` 是插入序 → 要排序）；
- 自定义指令印成 `Opcode(N)`，带不带操作数看 `isVarArg`。

### 3.2 自写期望值（lexer，87 条）

**只有词法这一组不用 golden**：`lexer.test.js` 的期望值写在测试里，编号沿用 C++ 侧
（`I-xx` 整数 / `F-xx` 浮点 / `D-xx` 标识符 / `K-xx` 关键字 / `S-xx` 字符串 /
`B-xx` 二进制串 / `P-xx` 标点 / `W-xx` 空白注释 / `L-xx` 行号 / `E-xx` 错误 /
`R-xx` 健壮性 / `C-xx` 自定义指令 / `G-xx` 端到端），用例清单与覆盖矩阵在
[`lexer-test-plan.md`](lexer-test-plan.md) §3。

这是历史形成的：那时还没有 `golden_lex.txt`，而 GD（588 条）与 C#（588 条）后来都改成了
读那份数据。**所以 `golden_lex.txt` 的 147 条在本实现里没被跑** —— 想接上去的话，
照 `parser.test.js` 的写法加一个 `describe` 即可，但要留意三件事：

1. `golden_lex.txt` 的 `TOKS` / `LEXEMES` / `ERRS` **不做二次转义**（`unescapeValues: false`）；
2. `SRC` 用 `unescapeLex`（多认 `\v` `\f`）；
3. 标识符与标点的 lexeme 在 nodejs 侧**有值**（C++ 的 D-8 / D-9 未修，恒为空）——
   这是 `lexer-test-plan.md` §4.1 登记的**有意差异**，接 golden 时要保留这条差异，别顺手"修"掉。

⚠ 整数 token 的 `value` 是 **BigInt**，断言要写 `1n` 而不是 `1`。

### 3.3 自洽检查（`smoke.test.js`，5 条）

不测语言，测包本身：`package.json` 声明 ESM、**零依赖**、`exports` 指向的文件真实存在；
`src/index.js` 能被 import；`src/` 只 import `node:` 内置与相对路径。
这几条是「零依赖」这个卖点的护栏 —— 谁不小心引入一个包，这里立刻红。

### 3.4 怎么重新生成数据

跑测试**不需要 C++**（数据已入库）。只有两种情况才需要重跑探针：改了 C++ 侧行为，
或给某组加了新用例。

```bash
cd cpp && cmake --build build --target gen-golden
```

成功时打印四行 `-- gen: <路径>（<字节数> 字节）`。探针不在默认构建里
（`EXCLUDE_FROM_ALL`）；行尾不用管，`readText` 统一剥 `\r`。

## 4. 没有 golden 的两组

### 4.1 嵌套深度上限（8 条，`parser.test.js`）

限额与错误文案是**四方约定**（`maxDepth` = **256**，文案
`line N: nesting too deep (max 256). ` 逐字相同），没法 dump，所以按约定写死：
`paren` 200 通过、`paren` / `block` / `unary` / `at` 各 300 报错、`paren` 12000 报错
（曾真的栈溢出）、默认值 256、`maxDepth = 0` 时不检查（2000 层仍能解析）。

### 4.2 参考执行器（58 条，`vm.test.js`）

VM 不是标准，错误串前缀各实现自定（nodejs 是 `<i>: msg`，GD 是 `3 Add: msg`），
没有可 dump 的权威期望值。所以比两类东西：

- **算术与类型规则**：布尔是整数 1n / 0n；整数幂按 64 位回绕（`2n ^ 64n` = 0n）；
  BinArr 连接与重复；字符串 / 字节串取下标；除零；`INT64_MIN` 的角落。
  ⚠ 整数全是 **BigInt**，断言写 `1n`。
- **宿主接口**：`argc` / `args[i]`、宿主函数放 exports 槽位、`Call` 到非函数报错、
  没给实参表报 `no args. `、宿主实参表自己报错时停在那条指令。
- **运行期错误**：错误串带指令下标 `"<i>: msg"`；出错后 `Step` 不再重复执行同一条指令。
- **`Run` 与 `Step` 等价**：`Run()` 与 `Step()` 是两份独立实现（热循环不套函数调用），
  同一批程序跑两遍，`returns` / `errors` / 停机时的 `i` 必须逐项相同。
- **State 装配自检**：`Reset` 开好变量槽位；`Identifier` 只由 `PushId` 产生、
  `Assign` 靠它取槽位；空程序 `Run` 成功且 `returns` 为空；多次 `return` 取最上面那次。

改这几条之前先跑一遍四方差分（同一批源码喂四份执行器，比对 `returns` 与错误消息
`: ` 之后的部分）—— 2026-10-30 用 47 组做过一次，零差异。

## 5. 覆盖到哪了

| 计划 | 覆盖 |
| --- | --- |
| [lexer-test-plan.md](lexer-test-plan.md) | 本实现词法的用例清单（87 条）；`golden_lex.txt` 未接，见 §3.2 |
| [../../docs/zh-cn/parser-test-plan.md](../../docs/zh-cn/parser-test-plan.md) | 语句、表达式与字面量、优先级、调用 / 索引 / 括号、自定义指令、行号、错误恢复、折叠（`golden.txt` 195 条）+ 深度 8 条 |
| [../../docs/zh-cn/compiler-test-plan.md](../../docs/zh-cn/compiler-test-plan.md) | `CM-01…CM-72`（`golden.txt` 195 条）+ 作用域 / 清空输出补测 |
| [../../docs/zh-cn/stml-test-plan.md](../../docs/zh-cn/stml-test-plan.md) | §4 全部 121 条：词法 62 条 + 语法 59 条 |

外加两组不在任何计划里的：`disasm.test.js` 的 5 条单测（其中一条专门锁
「`custom opcodes:` 段按**编号**排序」—— golden 那 12 条两种排序恰好一致，看不出来）、
`vm.test.js` 的 58 条。

**没有覆盖的**：

- **`golden_lex.txt` 的 147 条**（§3.2）；
- **指令表查重**（GD 侧 `test_compiler.gd` 的 `_check_dup` 锁了 `addCustomOpcode`
  遇同名返回 `DuplicateWithBuiltinOpcode` 且不插入，本实现没有对应用例）；
- **执行器的全指令覆盖**（只覆盖了容易出错的语义，不是每条 opcode 都有对拍用例）；
- **非 BMP 字符**（emoji 等）：GDScript 按码点、其它按 UTF-16 码元，行为尚未定夺。

## 6. 加一条用例的流程

**golden 驱动的四组**（parser / compiler / binary / disasm）：

1. 在对应的 `cpp/tools/golden*.cpp` 用例数组里加一项（**只在 C++ 侧加**，保持同源）；
2. 重跑 §3.4 的 `gen-golden` 刷新 `data/*.txt`；
3. 必要时同步更新 `docs/zh-cn/*.md` 的 §4 用例清单表；
4. `npm test` —— 新用例会被自动比对，不用改测试代码。

例外：

- **`golden_binarr.txt`**：用例表**写死在测试里**（`binary.test.js` 的 `dumpAll`，
  照抄 GD 的 `_dump_binarr`），加删必须在**两边同步**，顺序即行序 —— 缺一条就整体错位。
- **STML**（最省事）：只在 `data/stml_cases.txt` 里加一行（`KIND` / `ST` 或 `SF` / `SRC`），
  重跑 `gen-golden`，更新 `docs/zh-cn/stml-test-plan.md` §4。清单四方共用，探针和测试都不用改。

**自写的两组**（lexer / vm）直接在测试文件里加一条 `test()` 即可 —— 但改 lexer 用例时要
同步 [`lexer-test-plan.md`](lexer-test-plan.md) §3 的清单，改 vm 用例时想清楚这条语义在
另外四份实现里是不是也要测（那里没有共用清单，靠人工对齐）。

## 7. 排错

| 现象 | 原因 / 处理 |
| --- | --- |
| `ENOENT ... gdscript/test/data` | 数据目录被误删，或测试文件被挪出 `nodejs/test/` → `golden.js` 的 `dataDir` 是相对 `../..` 拼的 |
| 词法用例报 `expected 1n, got 1` | 整数 token 的 `value` 是 BigInt，断言写 `1n` |
| STML 组 `ERRS` 全是转义差异 | `golden_stml.txt` 要 `readGolden(name, false)`，见 §3.1 |
| `dumpProgram` 的 `exports` 段顺序不对 | 要按名字排序（C++ 是 `std::map`），见 §3.1 |
| 只红「用例数」那一条 | golden 条数变了 → 重跑 `gen-golden`，或检查生成器与用例表是否一起改了 |
| 覆盖率门禁红 | 行 < 80% 或分支 < 70%；`npm run test:cov` 会列出未覆盖行号 |
| `SyntaxError: Cannot use import statement outside a module` | 忘了 `"type": "module"`，或用 CommonJS 方式跑了测试 |
