# STML 测试计划（C++ 侧）

> 本文是 **C++ 侧的实现笔记与缺陷流水**。
> 面向用户 / 跨实现的通用契约在 `docs/zh-cn/stml-test-plan.md`，
> 两份文件一起读：那边写"应该是什么"，这边写"代码现在是什么、为什么"。
>
> 想**直接用 STML 解析文档**的话，先读 `stml.md`（本目录）—— 那份是逐段讲
> `demo/02-stml.cpp` 的上手教程；它 §6 的「语法注意事项」一大半都是从本文的
> 实测行为里抽出来的。

## 目录

- [1. 目标与非目标](#1-目标与非目标)
- [2. 被测接口契约](#2-被测接口契约)
- [3. 现状基线：已确认的行为与缺陷](#3-现状基线已确认的行为与缺陷)
- [4. 测试基础设施](#4-测试基础设施)
- [5. 用例清单](#5-用例清单)
- [6. 覆盖率与验收标准](#6-覆盖率与验收标准)
- [7. 缺陷处理流程](#7-缺陷处理流程)
- [8. 执行方式](#8-执行方式)
- [9. 里程碑](#9-里程碑)
- [10. 风险与注意事项](#10-风险与注意事项)

---

## 1. 目标与非目标

**目标**

1. 给 `stml_lexer.hpp` / `stml_parser.hpp` 建一张回归网：状态机、代码段边界、
   属性解析、错误停位全部有断言。
2. 钉住**易用错的三处**：状态交还、无值属性的向前看、文本只有一段。
3. 让 GDScript 侧有可对照的基线（当前差异见 `docs/zh-cn/stml-test-plan.md` §7）。

**非目标**

- 不测 Nevext / Stope 语言本身（那是另两份计划的事）。
  Nevext 项目地址：<https://github.com/liu-jl-dev/nevext>。
- 不规定 `attrs` 的内部结构，只规定**可观测的输出顺序**（键字典序，TD-2）。
- 不做性能基准，只做"不得死循环"这类下限（§5 的 SR / PF 组）。

**与另两份计划的关系**：STML 与 Stope 主语言**只共用** `Stope::Result` 与
测试断言框架，Lexer / Parser 完全是两套。因此它自成二进制 `test_stml`。

---

## 2. 被测接口契约

### 2.1 `stml_lexer.hpp`

```cpp
namespace Stope::STML {
enum class TokenType { Invalid, EndOfFile, LAngle, RAngle, CLAngle,
                       CRAngle, EQ, Word, String, Text, NevextSrc, StopeSrc };  // 12 项
struct Token { TokenType type; int line; std::u16string_view lexeme; };
enum class LexerState { Xml, Text, Nevext, Stope };                              // 4 态
struct Lexer {
  std::u16string_view input;
  int line = 1;
  std::vector<std::string> errors;
  LexerState state = LexerState::Xml;
  explicit Lexer(const std::u16string_view& input);
  void NextToken(Token& token);
};
}
```

| 不变量 | 内容 |
| --- | --- |
| lexeme 生命周期 | `lexeme` 是 `string_view`，**指向 `input`，不拥有内存** → 测试必须用 `shared_ptr` 持有输入副本（§4.2） |
| 一次一个 | 每次 `NextToken` 产出恰好一个 token；未知字符**必须消费 1 个码元** |
| 状态交还 | `Text` / `Nevext` / `Stope` 在 `NextToken` 里扫完一段后 `state = Xml`。删掉这句会产出无限个空 token |
| 行号 | 只有 `\n` 让 `line + 1`；`\r` 不计数；跨行的字符串/注释内部也累加 |
| 尾部空白 | `Text` / `NevextSrc` / `StopeSrc` 的 lexeme **不含尾部空白**（`trimTrailingWs`） |
| 错误 | 格式 `line N: msg`，只累加；跨行字面量报**起始行**（`error2`） |

**子扫描函数的契约**（2026-10-18 补全时确立，改动前务必看）：
`scanNevextString` / `scanStopeString` / `scanNevextSinglelineComment` /
`scanStopeSinglelineComment` / `scanNevextMultilineComment` / `scanStopeMultilineComment`
一律 **从 `input` 开头工作 → 自己推进 `input` → 返回消费的字符数**。
未闭合的引号串报错后**吃掉剩余全部输入**并返回，调用方（`scanNevextSrc` / `scanStopeSrc`）
才能靠 `!input.empty()` 正常结束。

### 2.2 `stml_parser.hpp`

```cpp
struct Element {
  int line = -1;
  std::u16string_view tagName;
  std::map<std::u16string_view, std::u16string_view> attrs;
  bool selfClosing = false;
  std::vector<Element> children;   // 值语义，不用 unique_ptr
  std::u16string_view text;
};
using LexerStateFunc = LexerState (*)(std::u16string_view tag,
                                      std::map<std::u16string_view, std::u16string_view> attrs);
struct Parser {
  Lexer* lexer;
  LexerStateFunc stateFunc = nullptr;
  std::vector<std::string> errors;
  Token token;
  Parser(Lexer& lexer);
  Result Parse(Element& root, LexerStateFunc stateFunc);
};
```

| 不变量 | 内容 |
| --- | --- |
| 入口 | `Parse` **自己先 `nextToken()` 一次**，调用方不要再调；返回 `Success` iff `errors` 为空 |
| 状态重置 | `parseElement` 开头无条件 `lexer->state = LexerState::Xml`。自闭合分支与出错提前 return 的路径都走不到 `stateFunc`，不重置会污染后续 token |
| 属性循环 | **每个分支自己推进**，循环开头**不能**无条件 `nextToken()` —— 无值属性需要"向前看一个 token 但不消费" |
| 无值属性 | `<a flag>` ≡ `attrs["flag"] = ""` |
| 文本 | 只有一段，`e.text = token.lexeme`，**不拼接** |
| 子元素 / 文本互斥 | 由 `stateFunc` 的返回值决定走哪个分支 |
| 错误 | 每个错误分支都 `return`（级联例外见 TD-7）；文案见通用计划 §3 |
| 顶层 | 只解析**一个**元素，根之后的输入忽略（TD-5） |

### 2.3 两侧的"坑"对照

| 坑 | C++ | GDScript |
| --- | --- | --- |
| 内容状态决策 | `LexerStateFunc` 回调（宿主决定） | 硬编码 `nev` / `sto`（`asm` 属性走 Nevext） |
| `Text` 状态 | 独立状态，只认 `</` | 没有该状态；`Xml` 下 `scan_text()` 遇到任意 `<` 就停 |
| 属性顺序 | `std::map` → 字典序 | `Dictionary` → 插入序 |
| 转义 | Xml 属性串**不**转义；Nevext 两种引号都转义；Stope `'` 不转义 | 代码段两种引号都转义 |

---

## 3. 现状基线：已确认的行为与缺陷

> 全部由 `test_stml` 实测（2026-10-18，215 条断言全绿）。
> `TD-n` 是 STML 专属编号（区别于主语言的 `PD-n` / `CD-n`）。

| ID | 现象 | 影响 | 状态 | 锁定用例 |
| --- | --- | --- | --- | --- |
| **TD-1** | `TokenType::Word` 与 `scanWord` 的注释写 `^[a-zA-Z_:][a-zA-Z0-9_.:-]*$`（含 `.`），但 `isWordChar()` 不含 `.` | 注释与实现矛盾，`a.b` 实际被切成 `Word Invalid Word` | [已修 2026-10-18] 改注释对齐实现 | SW-04 / SW-08 |
| **TD-2** | `attrs` 是 `std::map`，顺序不保证 | 测试若按源码顺序写期望必然翻车 | **定夺**：形状串按**键字典序**输出 | PB-05 / PB-06 |
| **TD-3** | 元素内文本只有一段，不做多段拼接 | 与 GD 侧 `str(text,'\n',lexeme)` 不一致 | **定夺**：以 C++ 为准，GD 侧待改（GD-S-09） | PC-01 / PC-09 |
| **TD-4** | `Text` 状态只认 `</`，`<b/>` 会被整段当文本 | 普通文本元素里写不了子元素 | 未修（需要时用 `Xml` 状态） | ST-05 / PC-09 |
| **TD-5** | 顶层只解析一个元素，`<a/><b/>` 的 `<b/>` 被忽略 | 不是"文档"解析 | 未修 | PA-09 |
| **TD-6** | `lexer.errors` **不合并**进 `parser.errors` | 调用方要查两处 | 未修（与主语言 PD-14 同源） | PE-06 / PE-11 |
| **TD-7** | `parseElement` 返回 `void`，父元素不知道子元素失败 → 继续解析并**级联报错** | `<a><b id=></b></a>` 报 2 条错 | 未修。建议：改成返回 `bool`，父元素 `if (!parseElement(child)) return;` | PE-12 |
| **TD-8** | Xml 侧未闭合串文案 `unclosed string literal`，代码段侧是 `unclosed string literal. `（差一个句号） | 文案不一致 | 未修 | SS-06 / PE-11 |
| **TD-9** | Xml 属性字符串**不做转义**：`"a\"b"` 里的 `\"` 就是结束引号 | 属性值里写不了引号 | 未修 | SS-08 |

### 3.1 已确认**正确**的行为（回归基线，重点保护）

| 行为 | 为什么值得单列 |
| --- | --- |
| `Text`/`Nevext`/`Stope` 扫完一段后交还 `Xml` | 删掉这句 = 无限空 token，历史上真的死循环过 |
| `skipWs()` 的 `else break` | 缺这句同样是死循环（2026-10-18 修） |
| `<!-- -->` 只在 `Xml` 状态跳过 | `Stope` 里的 `<!--` 是小于号，误跳会吃掉代码 |
| 未闭合的 `/*` 不是错误 | 与 Nevext 规范一致，别"顺手"改成报错 |
| 未闭合引号串吃掉剩余输入 | 保证调用方的 `for(; !input.empty();)` 能退出 |
| `scanStopeString` 对 `'` 不转义 | 与 `Stope::Lexer::scanBinArr` 对齐 |
| 进入元素时重置 `state = Xml` | 不重置会让上一次的 `Stope` 状态污染后续标签 |

---

## 4. 测试基础设施

### 4.1 文件

| 文件 | 作用 |
| --- | --- |
| `cpp/test/test_stml.cpp` | 入口：`main()` → 词法组 + 语法组 → 覆盖统计 → 已知问题清单 → 退出码 |
| `cpp/test/test_stml_common.hpp` | 断言宏（**S 前缀**）、`slexAll` / `sparseAll` 驱动、`shapeElem` 形状串、`defaultStateFunc`、覆盖统计 |
| `cpp/test/test_stml_lexer.cpp` | 词法用例（SX / SW / SS / ST / SN / SP / SL / SE / SR） |
| `cpp/test/test_stml_parser.cpp` | 语法用例（PA / PB / PC / PL / PE / PF / PH） |

**为什么要 S 前缀**：`test_common.hpp` 里已经有 `EXPECT_TYPE` / `EXPECT_LEX` / `EXPECT_COUNT`
（lexer 用）和 `EXPECT_PSTMTS` / `EXPECT_PSTMT_SHAPE`（parser 用）。STML 的宏一律
`EXPECT_STOK_*` / `EXPECT_SP_*`，避免在同一编译单元里撞名。

### 4.2 驱动

```cpp
struct SLexResult {
  std::shared_ptr<const std::u16string> src;   // 持有输入，保证 lexeme 有效
  std::vector<Token>       tokens;
  std::vector<std::string> errors;
  std::vector<LexerState>  states;   // 产出该 token **之后** 的 state（状态回退断言用）
};
SLexResult slexAll(std::u16string src, LexerState state = LexerState::Xml);

struct SParseResult {
  std::shared_ptr<const std::u16string> src;
  Element root;
  std::vector<std::string> errors;     // Parser::errors
  std::vector<std::string> lexErrors;  // Lexer::errors（不合并，TD-6）
  Stope::Result result;
  std::string shape() const;
};
SParseResult sparseAll(std::u16string src, LexerStateFunc sf = defaultStateFunc);
```

两个"保险丝"，**不要删**：

- `shared_ptr` 持有输入副本 —— `Token::lexeme` / `Element::tagName` / `Element::text`
  都是 `string_view`，函数返回后局部变量就悬空了。
- `slexAll` 里的 `for (int i = 0; i < 10000; ++i)` —— `NextToken` 一旦不消费字符就会
  无限产出空 token；这个上限把"挂死"变成"失败"。

### 4.3 `defaultStateFunc`

```cpp
<sto> → LexerState::Stope
<nev> → LexerState::Nevext
<p>   → LexerState::Text
其余   → LexerState::Xml
```

用例里凡是写 `<p>…</p>` / `<sto>…</sto>` / `<nev>…</nev>` 的，都依赖这个默认回调。
要测"不是这三种"的标签，用 `<a>`（走 Xml / 子元素模式）。

### 4.4 形状串

`shapeElem()` 的输出格式（完整定义见通用计划 §2.8）：

```
Elem( <tag>, L<line>[, /][, @<k>[="<v>"]]...[, T="<text>"][, C=[<child> ...]] )
```

两个**必须记住**的性质：

1. 属性按 `std::map` 的键字典序输出，**不是源码顺序**。
2. `id=""` 与 `id`（无值）在形状串里长得一样（map 的值都是空 view）。
   想区分只能另加断言，目前 PB-08 只锁"能解析成功 + 属性条数"。

### 4.5 断言宏

| 宏 | 用途 |
| --- | --- |
| `EXPECT_STOK_TYPE(r, i, T, id)` | 第 i 个 token 的类型 |
| `EXPECT_STOK_LEX(r, i, U16, id)` | lexeme（传 `u16` 字面量） |
| `EXPECT_STOK_LINE(r, i, N, id)` | 行号 |
| `EXPECT_STOK_STATE(r, i, S, id)` | **产出该 token 之后**的 lexer 状态 |
| `EXPECT_SCOUNT(r, N, id)` | token 条数（含 `Eof`） |
| `EXPECT_SSEQ(r, "LAngle Word Eof", id)` | 整条类型序列 |
| `EXPECT_SERR_COUNT` / `EXPECT_SERR_HAS` | 词法错误条数 / 子串 |
| `EXPECT_SP_SHAPE(r, "Elem(a, L1, /)", id)` | 元素形状串 |
| `EXPECT_SP_RESULT(r, Stope::Result::Success, id)` | `Parse` 的返回值 |
| `EXPECT_SP_LINE` / `EXPECT_SP_TAG` / `EXPECT_SP_TEXT` | 根元素的三个标量 |
| `EXPECT_SP_SELFCLOSING` / `EXPECT_SP_CHILD_COUNT` / `EXPECT_SP_ATTR_COUNT` | 根元素的结构 |
| `EXPECT_SP_DEPTH(r, N, id)` | 树深度（根算 1） |
| `EXPECT_SPERR_COUNT` / `EXPECT_SPERR_HAS` | 语法错误条数 / 子串 |
| `EXPECT_SPLEX_COUNT(r, N, id)` | **词法**错误条数（TD-6，与语法分开计） |
| `SKNOWN(defect, cond, id)` | 已知缺陷登记（`knownCheck`） |

覆盖统计 `stmlTypeCoverage()`：12 种 `TokenType` 全部要被至少 1 个用例产出，缺了会打印。

---

## 5. 用例清单

### 5.1 词法（62 用例 / 119 断言）

| 组 | 主题 | 用例 | 断言 |
| --- | --- | --- | --- |
| **SX** | Xml 状态：标签骨架、标点、注释、意外字符 | 10 | 19 |
| **SW** | Word 边界（首字符 / 续字符集 / 截断） | 8 | 10 |
| **SS** | Xml 属性字符串（引号、跨行、未闭合、不转义） | 8 | 18 |
| **ST** | Text 状态（只认 `</`、尾部裁剪、空文本、吃 `<b/>`） | 6 | 13 |
| **SN** | Nevext 段（引号 / `//` / `/* */` / 未闭合 / 跨行） | 8 | 19 |
| **SP** | Stope 段（同上 + BinArr 单引号不转义 + `<!--` 不是注释） | 10 | 17 |
| **SL** | 行号（`\n` 计数、`\r` 不计数、`Eof` 行） | 3 | 8 |
| **SE** | 错误（条数累加、`line N` 跟随、文案格式） | 3 | 4 |
| **SR** | 健壮性下限（空输入、未闭合注释、5000 字符、200 个引号） | 6 | 11 |

### 5.2 语法（59 用例 / 96 断言）

| 组 | 主题 | 用例 | 断言 |
| --- | --- | --- | --- |
| **PA** | 元素骨架：自闭合 / 空元素对 / 嵌套 / 兄弟 / 顶层只吃一个 | 9 | 16 |
| **PB** | 属性：有值 / 无值 / 顺序无关 / 值里含 `>` / 名字含 `:` `-` | 11 | 15 |
| **PC** | 内容：Text / Nevext / Stope / 跨行 / 子元素与文本互斥 | 12 | 15 |
| **PL** | 行号：根取 `<` 所在行 | 4 | 6 |
| **PE** | 错误恢复：12 条分支各一条，PE-12 单独锁 2 条（TD-7） | 12 | 28 |
| **PF** | `stateFunc`（nullptr / 自定义）与健壮性（50 层、2000 字符） | 7 | 11 |
| **PH** | 混合：真实片段 + Stope/Nevext 代码段原样保留 | 4 | 5 |

（逐条输入与期望见 `docs/zh-cn/stml-test-plan.md` §4，两边 ID 一一对应。）

---

## 6. 覆盖率与验收标准

| 维度 | 门槛 | 当前 |
| --- | --- | --- |
| 断言通过率 | 100% | **215 / 215** |
| `TokenType` 覆盖 | 12 / 12 | **12 / 12** |
| `LexerState` 覆盖 | 4 / 4（每种都要有用例从该状态起扫） | **4 / 4** |
| 语法错误分支 | 8 条文案全部命中 | **8 / 8** |
| 不停机 | SR / PF 组不挂死 | 通过（ctest 另加 120s 超时兜底） |
| 编译告警 | `-Wall -Wextra` 下 STML 相关文件零告警 | 通过 |

---

## 7. 缺陷处理流程

1. 发现新缺陷 → 在 §3 表里按 `TD-n` 顺序登记，写清"现象 / 影响 / 状态 / 锁定用例"。
2. 若**暂不修**：在用例里用 `EXPECT_*` 锁住**当前**行为，并在注释里写 `（TD-n，未修）`。
   不要用 `SKNOWN` 把当前正确行为包起来 —— `SKNOWN` 只在"修复后应成立"时用。
3. 修复后：把期望值翻成修复后的值，重跑，确认全绿，然后在 §3 标 `[已修 日期]`
   **并保留原记录行**。
4. 若修的是**行为**而不是缺陷，先改 `docs/zh-cn/stml-test-plan.md` 的契约，再动代码。

### 已修复记录

| 日期 | 内容 | 用例 |
| --- | --- | --- |
| 2026-10-18 | `skipWs()` 缺 `else break` → 死循环 | SR-01…SR-06（兜底） |
| 2026-10-18 | `scanNevextSrc` 用 `test()` / `input[0]` 永远检查同一位置 | SN-01…SN-08 |
| 2026-10-18 | `</` 被判成 `CRAngle` | SX-02 / ST-01 |
| 2026-10-18 | `scanWord()` 不推进 `input` | SW-01…SW-08 |
| 2026-10-18 | `scanString()` 用 `input[0]` 而非 `input[len]` | SS-01…SS-08 |
| 2026-10-18 | `scanStopeString` 声明 `int` 却无 `return`（UB） | SP-01…SP-10 |
| 2026-10-18 | Parser 缺首次 `nextToken()`、属性循环多读一次、Text 分支少推进一次 | PA / PB / PC 全组 |
| 2026-10-18 | 无值属性 `<a flag>` | PB-03 / PB-04 / PB-05 |
| 2026-10-18 | 进入元素不重置 `lexer->state` | PF-01…PF-07 |
| 2026-10-18 | 删除 `Parser::line` 成员，改用 `e.line = token.line` | PL-01…PL-04 |
| 2026-10-18 | TD-1：`Word` 字符集注释含 `.` 但实现不支持 | SW-04 / SW-08 |

---

## 8. 执行方式

```bash
cd E:/lib/stope-lang/cpp
cmake -B build && cmake --build build
ctest --test-dir build                 # 13 项全绿
./build/test_stml.exe                  # 单独跑 STML
```

只想快速迭代（不跑全套）：

```bash
g++ -std=c++20 -Wall -Wextra -Wno-sign-compare -I stope \
    -o /tmp/test_stml.exe \
    test/test_stml.cpp test/test_stml_lexer.cpp test/test_stml_parser.cpp
/tmp/test_stml.exe
```

（`-Wno-sign-compare` 只是为了屏蔽 `stope/lexer.hpp` 里**既有**的告警，
STML 自己的代码在 `-Wall -Wextra` 下是零告警。）

退出码：`0` 全过；`1` 有断言失败；`2` 全过但有 `FIXED-PENDING-FLIP`。

---

## 9. 里程碑

| 状态 | 内容 |
| --- | --- |
| ✅ | `stml_lexer.hpp` 的 5 个子扫描函数补全 + 10 处阻塞缺陷修复（2026-10-18） |
| ✅ | `stml_parser.hpp` 审查与修复（自闭合 / 属性 / 文本 / 无值属性）（2026-10-18） |
| ✅ | 测试框架 `test_stml_common.hpp` + 词法 61 用例 + 语法 59 用例（2026-10-18） |
| ✅ | 接入 `CMakeLists.txt`，`ctest` 收录（`test_stml`，13 项全绿） |
| ⬜ | TD-7：让 `parseElement` 返回 `bool`，消掉级联报错 |
| ⬜ | TD-9：Xml 属性字符串支持转义（需先定夺，影响 TD-8 文案统一） |
| ✅ | GDScript 侧整改（GD-S-01…16 里的 14 条）+ `gdscript/test/` 的 STML 用例 121 条（2026-10-28）；残留 GD-S-17/18 |

---

## 10. 风险与注意事项

1. **深嵌套没有保护**：`parseElement` 递归无深度上限。PF-04 只测到 50 层，
   真要防栈溢出得照 `test_parser_depth` 的做法单独探测阈值。
2. **属性顺序是"不保证"而不是"字典序"**：现在恰好是字典序（`std::map`），
   但语义上不要依赖它。换 `unordered_map` 那天，PB-06 / PB-07 会红。
3. **`lexeme` 是 view**：任何把 `Element` 或 `Token` 存下来跨函数用的写法都会悬空。
   要长期持有就自己拷贝成 `std::u16string`。
4. **不要在 `Parser` 里加 `line` 成员**：项目定夺过（2026-10-18），
   元素行号写 `e.line = token.line`。
5. **改动 `stml_lexer.hpp` 的子扫描函数前**，先读 §2.1 的"子扫描函数契约"
   （"从 `input` 开头工作 → 自己推进 → 返回消费长度"），以及"未闭合要吃掉剩余输入"。
6. **ctest 的构建类型会影响深度用例**：另 8 组 `parser-depth-*` 的崩溃阈值是
   **默认**（无 `CMAKE_BUILD_TYPE`）构建下实测的；加 `-DCMAKE_BUILD_TYPE=Release`
   会让栈用量变小、该崩的不崩，那 4 项会报失败。
7. **行尾**：`cpp/include/stope/stml_*.hpp` 是 **CRLF**，`cpp/test/test_stml_*.cpp/hpp` 是 **LF**。
   用 Python 改写时用 `newline=''` 保持。
