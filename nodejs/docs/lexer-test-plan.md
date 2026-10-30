# `src/lexer.js` 测试计划

- 被测对象：`src/lexer.js` — `Lexer`
- 计划版本：v1（2026-10-26）
- 实测环境：Node v24.18.0，`node:test` + `node:assert/strict`，零第三方依赖
- 语义基准：`../../cpp/src/lexer.cpp` 与其测试 `../../cpp/test/test_lexer_*.cpp`

---

## 1. 目标与非目标

### 1.1 目标

1. 给 `Lexer.NextToken(custom)` 建立可重复执行的回归基线，覆盖 **47 个 `TokenType`** 的产生路径
   （见 §3 覆盖矩阵）。
2. **用例编号与 C++ 侧逐条对齐**，两边可以对照着读；C++ 改行为时，这边应当一起改。
3. 记录 nodejs 侧与 C++ 的**有意差异**与**同源缺陷**，避免差异被时间抹平（见 §4）。
4. 提供覆盖率现状与不可达分支说明（见 §7）。

### 1.2 非目标

- 本文件只管 lexer。parser / compiler / 反汇编 / 执行器 / STML 各自有测试文件
  （`test/parser.test.js`、`compiler.test.js`、`disasm.test.js`、`vm.test.js`、`stml.test.js`），
  它们由 golden 数据驱动，见 `../README.md` §测试。
- 不做性能基准，只有"不死循环、不崩"的健壮性下限（R 组）。
- **不做与 C++ 的运行时交叉比对**：那需要编译 C++，是一次性动作，做法见 §6。

---

## 2. 被测接口契约

```js
class Lexer {
  constructor(input)          // = Reset(input)
  Reset(input)                // line 归 1、errors 清空
  NextToken(custom)           // custom 是 CustomOpcodeConfig，可省略；返回一个新 Token
  // 状态
  input                       // 剩余输入，随扫描前进
  line                        // 1 起算，仅 '\n' 递增
  errors                      // 累加，格式 "line N: msg"
}

// src/token.js
class Token { line, type }    // 构造时只有这两个字段，其余由 Lexer 填
// Lexer 额外写入：lexeme（原文）、parsed（规范形式）、value（数值）
```

与 C++ 的契约差异（测试必须知道）：

| 项 | C++ | nodejs |
| --- | --- | --- |
| Token 复用 | `NextToken(Token&)` 复用同一个对象 | **每次返回新对象**，旧 token 不受影响 |
| `lexeme` 类型 | `u16string_view`，指向输入，非拥有 | 普通字符串，独立副本 |
| 输入推进 | `input.remove_prefix()` | `this.input = this.input.slice(n)`（`O(n²)`，R-04 用例验证了不会爆） |
| 整数取值 | `long long` | **BigInt**（JS 的 Number 装不下 int64） |

`errors` 只累加、无清空接口 → 每条用例都用新的 `Lexer`（`lexAll()` 保证）。

---

## 3. 用例编号与覆盖矩阵

`suite` 按 C++ 的分组编号（T1–T14），case 编号沿用 C++ 的用例号，一眼可对照。
**87 条用例**，分布如下（行末标了 C++ 侧对应的测试文件）：

| 分组 | 编号 | 条数 | 覆盖点 | C++ 出处 |
| --- | --- | --- | --- | --- |
| T3 整数 | `I-01`…`I-10` | 10 | 十进制/前导零/下划线、各进制取值、**int64 边界与溢出**、空前缀、非法字符的分词边界 | `test_lexer_number.cpp` |
| T4 浮点 | `F-01`…`F-09` | 9 | 小数、指数、`1..2` / `1.5.5` 切分、指数缺数字、**上溢与下溢** | 同上 |
| T5 标识符 | `D-01`…`D-09` | 9 | 合法字符集、`:` 命名空间、冒号两侧的空白/换行/注释、`a::b` 与 `a:1` 错误恢复 | `test_lexer_ident.cpp` |
| T6 关键字 | `K-01`…`K-03` | 3 | 18 个关键字全映射、大小写敏感、关键字与符号写法同类型 | 同上 |
| T7 字符串 | `S-01`…`S-10` | 7 | 空串、转义引号、未闭合、反斜杠结尾、9 种转义序列、非法转义的截断行为 | `test_lexer_string.cpp` |
| T8 二进制串 | `B-01`…`B-06` | 5 | 相邻不合并、未闭合、跨行累加 `line`、串内无转义 | 同上 |
| T9 标点 | `P-01`…`P-10` | 10 | 全部分隔符/运算符、两字符优先、`&`/`|` 单字符非法、非语言字符逐码元报错 | `test_lexer_punct.cpp` |
| T1 空白注释 | `W-01`…`W-10` | 7 | 六种空白、单行/多行注释、不嵌套、未闭合静默、退化 `//` 与 `/*/` | `test_lexer_flow.cpp` |
| T2 行号 | `L-01`…`L-06` | 6 | 仅 `\n` 计数、跨行 BinArr / 字符串 / 标识符、错误行号 | 同上 |
| T11 错误 | `E-01`…`E-04` | 4 | **七条 error 文案全覆盖**、累加与行号前缀、出错后继续推进、代理对按码元计数 | 同上 |
| T12 生命周期 | `T12-1`/`2`/`4` | 3 | 连续取词不串味、`Reset()` 复用、Eof 的字段 | 同上（`T12-3` 是 string_view 特有，不适用） |
| T14 健壮性 | `R-01`…`R-05` | 5 | 空输入、10000 字符标识符、1000 层括号、交替引号不死循环、孤立 `:` | 同上 |
| T10 自定义指令 | `C-01`…`C-06` | 5 | 不传配置、命中/未命中、含 `:` 的名字、**关键字优先**、重复注册的返回值 | `test_lexer_misc.cpp` |
| T13 端到端 | `G-01`…`G-05` | 5 | 真实代码片段的完整 token 流 | 同上 |

`E-01` 锁定的七条文案：`unknown token.` / `unclosed string literal.` /
`unclosed binary array.` / `invalid integer.` / `invalid float.` /
`unclosed identifier.` / `invalid escape character.` —— 与 C++ 逐字一致（含尾部空格）。

---

## 4. 与 C++ 的差异

### 4.1 有意差异（nodejs 侧的主动选择）

| 项 | C++ | nodejs | 理由 |
| --- | --- | --- | --- |
| 标识符/标点的 `lexeme` | **恒为空**（缺陷 D-8 / D-9，未修） | 填源文本（含标识符里被跳过的空白） | 报错定位、反查原文都依赖它；覆盖面更广，与 C++ 差异仅限"多填了字段" |
| 整数 `value` 的类型 | `long long` | **BigInt** | 9223372036854775807 这类值用 Number 存会丢精度。断言用 `BigInt` 字面量（`I-04` / `I-07`） |
| 浮点溢出判定 | `stod` 抛 `out_of_range` | 手动判：`!Number.isFinite(v)`（上溢）或 `v == 0` 但字面量含非零数字（下溢） | JS 不抛异常，只能自己判；`F-09` 锁定行为一致 |

### 4.2 同源缺陷（C++ 未修，nodejs 保持一致）

这几条在 C++ 里是 `KNOWN` 标记的待修项，nodejs **照当前行为断言**，用例名后缀 `-current`：

| C++ 编号 | 输入 | 当前行为 |
| --- | --- | --- |
| D-6 | `/* abc` | 未闭合块注释静默跳到 EOF，无 error（`W-08-current`） |
| D-7 | `1._` | 小数部分以 `_` 结尾仍判 Float 1.0（`F-08-current`） |
| D-13 | `"a\nb" c` | 跨行字符串不累加 `line`（`L-04-current`） |
| D-14 | `"a\qb"` | 非法转义后 `parsed` 截断为 `a`，`type` 仍是 `String`（`S-09-current`） |

C++ 哪天修了，这些用例的后缀和期望值一起翻。

### 4.3 语言层差异（不是缺陷）

- **非 ASCII 按 UTF-16 码元切**：`中文`、`😀` 各产生 2 个 `Invalid`（`P-08`、`E-04`），与 C++ 的 `char16_t` 行为一致。
- **C-xx 用例的编号取 100**（照 `test_lexer_misc.cpp`），不依赖 `kFirstCustomOpcode` —— 后者目前在 `src/opcode.js` 里定义但未导出。

---

## 5. 运行

```sh
cd nodejs
npm test                                       # 全部（当前 780 条，其中 lexer 87 条）
node --test test/lexer.test.js                 # 只跑 lexer
node --test --test-name-pattern="I-0" test/lexer.test.js   # 按编号过滤
npm run test:watch
npm run test:cov                               # 覆盖率 + 阈值门禁
```

glob 必须带双引号，否则 shell 先展开、`node --test` 收不到 glob。

八份测试文件各自的驱动方式与条数见 [`testing.md`](testing.md) §1 —— 本计划只覆盖
`lexer.test.js` 那 87 条。

### 断言族（`test/helpers.js`）

对应 C++ 的 `EXPECT_*` 宏，失败时打印 token 全貌与整份 errors：

| 函数 | 对应 C++ 宏 | 说明 |
| --- | --- | --- |
| `lexAll(src, custom)` | `lexAll()` | 扫到底，返回 `{ tokens, errors }`；内置 10000 次上限兜底死循环 |
| `expectType` / `expectLex` / `expectParsed` | `EXPECT_TYPE` / `EXPECT_LEX` / `EXPECT_PARSED` | 单字段断言 |
| `expectInt` / `expectDbl` | `EXPECT_INT` / `EXPECT_DBL` | 整数按 BigInt 比较；浮点容差 1e-9 |
| `expectLine` / `expectCount` | `EXPECT_LINE` / `EXPECT_COUNT` | 行号、token 总数 |
| `expectSeq` | `EXPECT_SEQ` | 类型序列整体比对，如 `'Let Ident Eof'` |
| `expectErrCount` / `expectErrHas` / `expectNoErrors` | `EXPECT_ERR_COUNT` / `EXPECT_ERR_HAS` | 错误条数与文案（子串匹配） |

每个 `expect*` 的最后一个参数都是 C++ 侧的用例编号，失败信息里能直接看到是哪一条。

---

## 6. 与 C++ 的交叉验证（一次性，不进测试）

本仓库的规矩是 **golden 不手写**：拿 C++ 当基准，两边 dump 同一批输入再逐行 diff。
2026-10-26 用 76 个输入 / 316 行输出做到 **0 差异**，做法记在 `.workbuddy/memory/2026-10-26.md`。

步骤（临时目录里做，不落进仓库）：

1. 准备一批输入，行内把 `\n` `\t` `\r` `\\` 转义，写成一行一个用例；
2. C++ 侧：`g++ -std=c++17 -I ../../cpp/include dump.cpp ../../cpp/src/lexer.cpp -o dump.exe`，
   逐条调 `NextToken` 打印 `type|lexeme|parsed|line|value` 与 errors；
3. nodejs 侧用同一套格式打印；
4. 逐行 diff。

四个只在做工具时才踩到的坑：

- C++ 的 `printf` 重定向出来是 **CRLF**，比对前先剥 `\r`；
- `lexeme` 可能含 `|`，别用 `split('|')`，用正则定位字段；
- 控制字符（`\v` `\f` `\b`）要在 dump 的转义函数里处理，且**先转义再转 ASCII**；
- 标识符与标点的 `lexeme` 要跳过比较（§4.1）。

---

## 7. 覆盖率现状

`npm run test:cov`（阈值：行 80% / 分支 70%）：

| 文件 | 行 | 分支 | 函数 |
| --- | --- | --- | --- |
| `src/lexer.js` | 98.23% | 97.48% | 100% |
| 其余（`token.js` / `opcode.js` / `common.js`） | 100% | 100% | 100% |
| **all files** | **98.73%** | **97.63%** | 100% |

`lexer.js` 未覆盖的两处都是**防御性分支，实际不可达**（与 C++ 同源，保留不动）：

- `getNumberValue()` 里 `BigInt()` 的 `catch`：进入前已有正则校验 `digits`，转换不会抛；
- `escapeString()` 里"孤立反斜杠结尾"：能被 `reStringBody` 接受的 body 不可能以单个 `\` 结尾。
