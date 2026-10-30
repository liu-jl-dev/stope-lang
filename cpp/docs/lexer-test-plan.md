# `cpp/include/stope/lexer.hpp` 测试计划

- 被测对象：`cpp/include/stope/lexer.hpp` — `Stope::Lexer`
- 计划版本：v1（2026-10-15）
- 实测环境：g++ (MinGW x86_64-win32-seh) 15.2.0，`-std=c++20`，C++20
- 参考实现（语义基准）：`gdscript/addons/stope/lexer.gd`

---

## 1. 目标与非目标

### 1.1 目标

1. 为 `Lexer::NextToken(Token&, const CustomOpcodeConfig*)` 建立可重复执行的回归基线，
   覆盖全部 **47 个 `TokenType`** 的产生路径。
2. 把"当前实际行为"固化成断言，使后续重构（拆 .cpp、换 VM、改数字解析）能立刻发现行为漂移。
3. 暴露并记录已确认的缺陷（见 §3），用 **已知失败清单（Known-Issue）** 管理，避免缺陷被测试"洗白"。
4. 提供覆盖率与验收口径，作为 lexer 可否交付给 parser/compiler 的依据。

### 1.2 非目标

- 不测试 parser、AST、编译器（另有计划）。
- 不测试性能基准（仅做一个"不死循环/不崩"的健壮性下限）。

---

## 2. 被测接口契约

```cpp
struct Lexer {
  std::u16string_view input;         // 输入，随扫描前进（remove_prefix）
  std::vector<std::string> errors;   // 累加，不清空；格式 "line N: msg"
  int line = 1;                      // 1 起算，仅 '\n' 递增
  void NextToken(Token& token, const CustomOpcodeConfig* custom = nullptr);
};

struct Token {
  TokenType type;              // 每次 NextToken 开头 token = Token() 重置
  int line;                    // = 扫描开始时 Lexer::line
  std::u16string_view lexeme;  // 原文切片（指向 input，非拥有）
  std::u16string parsed;       // 规范形式：数字去 '_'、标识符拼 ':'、字符串转义结果
  NumberValue numberValue;     // 仅 Integer/Float 有效
};
```

测试必须遵守的三条契约约束：

| 约束 | 说明 | 测试注意点 |
| --- | --- | --- |
| `lexeme` 是指向 `input` 的 `string_view` | 不拥有内存 | 输入 `u16string` 必须在整个断言期间存活；禁止用临时量 |
| `input` 会被推进 | Lexer 自身状态机 | 一个 Lexer 实例只跑一条输入流；不要复用 |
| `errors` 只累加 | 无 clear 接口 | 断言错误条数要用"增量"或"总数"，不要跨用例复用 Lexer |

---

## 3. 现状基线：已确认的行为与缺陷

> 下列结论**均已用 g++ 15.2 实测**（非静态阅读推测）。测试计划按此基线写断言。
> 标记为 **BUG** 的条目：先写"当前行为"断言并打 `KnownIssue` 标签；修复后把期望值翻转即可。

### 3.1 P0 —— 取值错误

| ID | 输入 | 修复前 | 修复后（`2026-10-15` 已修） | 说明 |
| --- | --- | --- | --- | --- |
| **D-1** ✅已修 | `0x1F` / `0b101` / `0o17` / `0xFF` | `Integer`，`numberValue.integer == 0` | **31 / 5 / 15 / 255** | 原 `getNumberValue()` 用 `std::stoll(s)`（默认 base=10），对 `0x…` 只解析出前导 `0` 就停下 → 静默返回 0。现改为按前缀选基数并跳过前缀后转换 |
| **D-2** ✅已修 | `0xFFFFFFFFFFFFFFFFF` | `Integer`，值 `0`，无报错 | **`Invalid` + `invalid integer.`** | 基数修好后 `stoll` 的 `out_of_range` 正常触发。`0x7FFFFFFFFFFFFFFF` 取最大值正确 |

> 修复要点：新增 `static int numberBase(const std::string&, size_t& prefixLen)`（`0b/B`→2、`0o/O`→8、`0x/X`→16、其余→10），
> `getNumberValue()` 先剥前缀、再 `std::stoll(s.substr(prefixLen), &pos, base)`，
> 并新增**消费完整性校验** `prefixLen + pos == s.size()`。

### 3.2 P1 —— 静默接受非法输入

| ID | 输入 | 当前实际 | 期望（参考 GDScript 实现） |
| --- | --- | --- | --- |
| **D-3** ✅已修 | `1e` / `1e+` / `.5e` | ~~`Float`，值 1.0 / 1.0 / 0.5，无 error~~ → **`Invalid` + `invalid float.`** | `Invalid` + `invalid float.`（指数后必须有数字）。随 D-1 一起由"消费完整性校验"修好 |
| **D-4** 🟡部分已修 | `0b` / `0x` / `0o` / `0b_` / `0x_` / `0o_` / `0b2` | ~~`Integer` 值 0~~ → **`Invalid` + `invalid integer.`** | `Invalid`（前缀后至少一个数字）。**已达成**：去前缀后为空串 → `stoll` 抛 `invalid_argument`。<br>`0x_1` / `0o_7` 仍判 `Integer`（parsed 去下划线后是 `0x1`/`0o7`，有真数字）—— **这是有意的**，符合本文档 §3.5 的取舍："扫描阶段不检查空数字，延后到转换阶段再检查" |
| **D-5** ✅已修（用户侧，2026-10-15） | `"a\qb"` | ~~无 error~~ → **`invalid escape character.`** | 已达成：`escapeString()` 已在 `scanString()` 末尾被调用，不再是死代码 |
| **D-6** | `/* 未闭合` | 静默跳到 EOF，token = `Eof`，**无 error** | 报 `unclosed comment.` |
| **D-7** | `1._` / `._` | `Float` 1.0 / `Invalid` | `._` 已是 Invalid；`1._` 小数部分以 `_` 结尾应同样 `Invalid` |

### 3.3 P2 —— 字段缺失 / 一致性问题

| ID | 现象 | 影响 | 期望 |
| --- | --- | --- | --- |
| **D-8** | `scanIdent()` 从不写 `token.lexeme` → **标识符、关键字、Custom 的 `lexeme` 恒为空** | 报错信息、AST 源码位置、反查原文全部拿不到 | 至少填原文切片 |
| **D-9** | 所有标点类 token（`= + - * / % ^ == != < <= > >= ! && \|\| , ; ( ) [ ] { }`）`lexeme` 与 `parsed` **均为空** | 同上 | 填 1~2 字符原文 |
| **D-10** ✅已修（用户侧，2026-10-15） | ~~未闭合字符串仍判 `String`~~ → 现在改判 `Invalid` | 两种引号行为现已一致 | — |
| **D-11** ✅已修（用户侧，2026-10-15） | `parsed` 对 String 恒空 | `escapeString()` 已接线 → `"a\nb"` 的 `parsed` 正确解码为换行 | — |
| **D-14** 🆕 | 非法转义时 `escapeString()` `break` 后：`parsed` 被**截断**（`"a\qb"` → `parsed` = `a`），且 `type` 仍是 `String`、**未置 `Invalid`** | 与"报错即 Invalid"的其它路径不一致；下游拿到半截字符串 | 出错时置 `Invalid` |
| **D-12** | `length`(int) 与 `input.size()`(size_t) 比较 | `-Wall -Wextra` 下 6+ 处 `-Wsign-compare` 警告 | 统一 `size_t` |
| **D-13** | 跨行**字符串**不累加 `line`（`"a\nb"` 之后 token 仍 line=1），而跨行 **BinArr** 会累加 | 两者行为不一致，多行字符串的后续报错行号偏小 | 统一累加 |

### 3.4 已确认**正确**的行为（回归基线，重点保护）

- 十进制：`0`→0、`00`→0、`0009`→9、`1_000`→1000、`1_`→1（parsed `1`）、`0_1`→1、`123abc`→`Integer 123` + `Ident abc`。
- **各进制（D-1 修复后）**：`0x1F`→31、`0X1f`→31、`0xFF`→255、`0b101`/`0B101`→5、`0o17`/`0O17`→15、`0b1_01`→5、`0x_1`→1、`0o_7`→7。
- 溢出：`9223372036854775807` 正确；`9223372036854775808` → `Invalid` + `invalid integer.`；
  **`0x7FFFFFFFFFFFFFFF`→最大值、`0xFFFFFFFFFFFFFFFF` 与 `0xFFFFFFFFFFFFFFFFF` → `Invalid`**（D-2 修复后）。
- 空前缀（D-4 修复后）：`0b` / `0x` / `0o` / `0b_` / `0x_` / `0o_` → `Invalid` + `invalid integer.`；`0b2` → `Invalid` + `Integer 2`。
- 浮点：`1e5`→100000、`1E-3`→0.001、`.5`→0.5、`1_.5`→1.5（parsed `1.5`）、`1e+3`→1000、`1..2`→`1.`+`.2`、`1.5.5`→`1.5`+`.5`。
- 非法浮点：`.`、`.e5`、`._` → `Invalid` + `invalid float.`；**`1e` / `1e+` / `.5e` / `1ex` 修复后也 → `Invalid`**（D-3）；`1e999` / `1e-999` → `Invalid`（上下溢）。
- 标识符：`[A-Za-z_][A-Za-z0-9_]*`，`_` / `__9` / `_9a` 合法；`9a`→`9`+`a`；关键字大小写敏感（`IF`/`If`/`iff`/`if2` 均为 `Ident`）。
- `:` 命名空间：`a:b` → parsed `a:b`；**跨行、跨 `//`、`/* */` 都合并成一个 Ident**（`a\n:b`、`a // c\n:b`、`a :/*x*/ b` 均成立）。
- `:` 错误恢复：`a::b` → `Invalid`(parsed `a:`) + `Invalid`(unknown token) + `Ident b`；`a:1` → `Invalid`(`a:`) + `Integer 1`；均有 `unclosed identifier.`。
- 17 个关键字与 `Custom` 优先级：关键字 > 自定义指令 > 标识符（自定义指令名含 `:` 也能匹配）。
- 字符串：`"a\"b"` 扫描层正确跳过转义；`""`→空 String；`"abc\` 正确报未闭合。
- BinArr：`''`→空 BinArr，`'a' 'b'`→两个；跨行累加 `line`。
- 运算符：两字符优先（`==`≠`=+`、`<=`、`>=`、`!=`）；单 `&` / 单 `|` → `Invalid` + `unknown token.`。
- 注释：`//`、`/* */`，**不支持嵌套**（`/* a /* b */ c` → 只认 `c`）。
- 未知字符只消费 1 个码元并报错 → **不会死循环**（这一条是硬保障，必须有用例）。
- 行号：`1\n2\n\n3\r\n4` → 1,2,4,5（`\r` 不计数）。
- 空输入 → `Eof`，`lexeme` 空，`line`=1。
- 浮点上溢/下溢 `1e999` / `1e-999` → `Invalid` + `invalid float.`。
- 复用同一个 `Token` 变量连续扫描（`alpha beta gamma`）→ `parsed` 每轮清空，**无串味**（`NextToken` 开头 `token = Token()` 已生效）。
- 4000 层嵌套 `(` → 4001 个 token，无栈溢出、无 error（lexer 无递归）。
- `Token{}` 值初始化：`type==Invalid(0)`、`line==0`、`lexeme` 空。

### 3.5 实现侧的既定约定（改行为前先看）

- **数字扫描分两阶段：扫描阶段不检查空数字，延后到转换阶段。**
  扫描只负责把符合形态的字符吃掉（`_` 分隔、`0x`/`0o`/`0b` 前缀），
  **不检查前缀后有没有真数字**；前缀后为空串时，由 `std::stoll` / `std::stod`
  抛 `invalid_argument` 再报错。因此 `0x_1` / `0o_7` 是**合法**的
  （去下划线后有真数字），`0x` / `0b_` 才是 `Invalid`。
  这是 D-4 的取舍，`0x_1` 保留为合法**是有意的**，不要当 bug 修。
- **带 `e` / `E` 指数的一律是 `Float`**，`1e5` 不可能是整数。
- **错误一律进 `errors`，不让异常穿出词法层**（`parse_binarr.hpp` 的 `catch (...)`
  与此对齐）。
- **中途换输入用 `lx.input = ...`。** `T12-2` 与 `test_parser_flow.cpp` 的 `B-09`
  专门锁这个行为。但 `errors` 只累加、无 clear 接口，
  所以**测试里不要跨用例复用同一个实例**（见 §2 的契约约束表）。

---

## 4. 测试基础设施

### 4.1 目录布局

```
cpp/
├─ CMakeLists.txt              # 新增 test 目标（见 4.3）
├─ docs/
│  ├─ lexer-test-plan.md       # 本文档（计划文档统一放 docs/）
│  ├─ parser-test-plan.md
│  └─ compiler-test-plan.md
└─ test/
   ├─ test_common.hpp          # 断言宏 + u16 辅助 + Token 转字符串 + 已知失败标记
   ├─ test_lexer_number.cpp    # T3/T4 数字
   ├─ test_lexer_ident.cpp     # T5/T6 标识符与关键字
   ├─ test_lexer_string.cpp    # T7/T8 字符串与 BinArr
   ├─ test_lexer_punct.cpp     # T9 标点与运算符
   ├─ test_lexer_flow.cpp      # T1/T2/T11/T12 空白、行号、错误恢复、状态重置
   ├─ test_lexer_misc.cpp      # T10 自定义指令 / T13 端到端 / T14 健壮性
   └─ test_main.cpp            # 统一 main，注册并跑全部
```

> `cpp/` 自 2026-10-19 起是 **Pitchfork Layout（编译型）**，仍是零第三方依赖
> （选型结论见 `development.md` §1），
> 因此**不引入 GoogleTest / Catch2**：自写 ~80 行断言头即可，保持 `cmake -B build && cmake --build build` 一条命令跑通。
> 若将来引入包管理，再整体迁移到 GTest，用例断言只需替换宏名。

### 4.2 `test_common.hpp` 骨架（待实现）

```cpp
#pragma once
#include <cstdio>
#include <string>
#include <string_view>
#include <vector>
#include "lexer.hpp"

namespace Stope::Test {
inline int g_failed = 0, g_total = 0, g_known = 0;

inline std::string toUtf8(std::u16string_view v) {          // 仅 ASCII 断言用
  std::string s; for (char16_t c : v) s += (c < 128 ? char(c) : '?'); return s;
}
inline std::u16string toU16(std::string_view u8) { ... }     // ASCII 源码 → u16，够用

inline const char* tokenName(TokenType);                     // 47 个枚举全覆盖的 switch

// 一次扫描到底，返回 token 序列（输入保证存活）
inline std::vector<Token> lexAll(std::u16string src,
                                 const CustomOpcodeConfig* cfg = nullptr,
                                 std::vector<std::string>* errs = nullptr) {
  Lexer lx; lx.input = src;
  std::vector<Token> out;
  for (int i = 0; i < 10000; ++i) {          // 上限：死循环保险丝
    Token t; lx.NextToken(t, cfg);
    out.push_back(t);
    if (t.type == TokenType::Eof) break;
  }
  if (errs) *errs = lx.errors;
  return out;
}

#define EXPECT_TOK(ts, i, TYPE, LEX, PARSED) ...   // 逐字段断言，失败打印实际值
#define EXPECT_ERR(errs, n, SUBSTR) ...            // 断言行号 + 文案子串
#define KNOWN_ISSUE(id, ...) ...                   // 期望失败：失败→计入 g_known，通过→报"已修复待翻转"
}
```

`KNOWN_ISSUE` 的规则（关键）：标记用例**失败时不算构建失败，但必须在报告中列出**；
若它**通过**了（说明缺陷被修好），则报 `FIXED-PENDING-FLIP` 提醒把断言翻转成普通用例。
这样缺陷既不会阻塞 CI，也不会被遗忘。

### 4.3 CMake 接入

根 `CMakeLists.txt` 现状：只有 `demo01` ← `demo/demo01.cpp`，而 `demo/` **是空目录**，当前无法配置成功。
测试落地时需要：

```cmake
enable_testing()
add_executable(test_lexer
    test/test_main.cpp test/test_lexer_number.cpp test/test_lexer_ident.cpp
    test/test_lexer_string.cpp  test/test_lexer_punct.cpp
    test/test_lexer_flow.cpp    test/test_lexer_misc.cpp)
target_include_directories(test_lexer PRIVATE stope)
add_test(NAME lexer COMMAND test_lexer)
```

- 同时把 `demo01` 目标改为 `if(EXISTS ...)` 守卫，避免空目录导致配置失败。
- MSVC 保留 `/utf-8`；GCC/Clang 加 `-Wall -Wextra`（当前 lexer 有 6+ 处 `-Wsign-compare`，
  先不 `-Werror`，待 D-12 修复后再开）。

---

## 5. 用例清单

约定：`L`=lexeme、`P`=parsed、`V`=numberValue、`E`=errors。
每组给关键用例，实现时按同一规格铺满。**"性质"列：`OK`=当前行为正确（必须永远通过）；`KNOWN`=按 D-x 标记为已知失败。**

> **2026-10-15 更新**：D-1 / D-2 / D-3 / D-4（数值解析，本次 `getNumberValue()` 修复）与
> D-5 / D-11（字符串转义，用户侧接线）已修，对应用例已从 `KNOWN` 翻转为 `OK`，
> 新增 D-14。仍未修：D-6、D-7、D-8、D-9、D-10、D-12、D-13、D-14。

### T1 空白字符与注释（LEX-W）

| ID | 输入 | 预期 | 性质 |
| --- | --- | --- | --- |
| W-01 | `""` | 单个 `Eof`，`E` 为空 | OK |
| W-02 | `"   \t\v\f\r\n  "` | 单个 `Eof` | OK |
| W-03 | `"a // 注释\nb"` | `Ident a`(line1) + `Ident b`(line2) | OK |
| W-04 | `"a // 注释"`（行尾无换行） | `Ident a` + `Eof` | OK |
| W-05 | `"a /* x */ b"` | 两个 Ident，注释不产生 token | OK |
| W-06 | `"a /*\n多\n行 */ b"` | 两个 Ident，`b` 的 line=3 | OK |
| W-07 | `"/* a /* b */ c"` | 不嵌套 → `Ident c` | OK |
| W-08 | `"/* 未闭合"` | `Eof`，**当前无 error** | KNOWN(D-6) 期望 `unclosed comment.` |
| W-09 | `"//"` 单独 | `Eof` | OK |
| W-10 | `"/*/"` | `*/` 不闭合 → 吃到 EOF | OK |

### T2 行号（LEX-L）

| ID | 输入 | 预期 | 性质 |
| --- | --- | --- | --- |
| L-01 | `"1\n2\n\n3\r\n4"` | line = 1,2,4,5 | OK |
| L-02 | `"a\nb\n"` | 尾部换行后 `Eof` 的 line=3 | OK |
| L-03 | `'a\nb'`（跨行 BinArr）后接 `c` | `c` 的 line=2 | OK |
| L-04 | `"\"a\nb\""`（跨行字符串）后接 `c` | 字符串**不**累加行 → `String` line=1、`c` line=1 | KNOWN(D-13) 期望 `c` line=2 |
| L-05 | 跨行标识符 `"a\n:b"` 后接 `c` | `Ident a:b` line=1；`c` line=2 | OK |
| L-06 | 错误 token 的行号 | `1\n@` → `unknown token.` 行号=2 | OK |

### T3 整数（LEX-N-I）

| ID | 输入 | 预期（当前） | 性质 |
| --- | --- | --- | --- |
| I-01 | `0` `00` `0009` | 0 / 0 / 9，`L` 原文，`P` 同 | OK |
| I-02 | `1_000` `1_` `0_1` | 1000 / 1 / 1；`P` = `1000`/`1`/`01` | OK |
| I-03 | `123abc` | `Integer 123` + `Ident abc` | OK |
| I-04 | `9223372036854775807` | 值正确 | OK |
| I-05 | `9223372036854775808` | `Invalid` + `invalid integer.` | OK |
| I-06 | `0x1F` `0X1f` `0b101` `0B101` `0o17` `0O17` `0xFF` | `Integer`，`L`/`P` 含前缀，V = **31/31/5/5/15/15/255** | OK（D-1 已修） |
| I-07 | `0x7FFFFFFFFFFFFFFF` / `0xFFFFFFFFFFFFFFFF` / `0xFFFFFFFFFFFFFFFFF` | 最大值 / `Invalid` / `Invalid` | OK（D-2 已修） |
| I-08 | `0b` `0x` `0o` `0b_` `0x_` `0o_` | `Invalid` + `invalid integer.` | OK（D-4 已修） |
| I-09 | `0b_1` `0x_1` `0o_7` | `Integer`，V = 1 / 1 / 7（下划线不计，属有意保留） | OK |
| I-10 | `0xG` `0b2` `0o8` | 前缀后停 → `Invalid`+`Ident G` / `Invalid`+`Integer 2` / `Invalid`+`Integer 8` | OK（记录分词边界） |

### T4 浮点（LEX-N-F）

| ID | 输入 | 预期（当前） | 性质 |
| --- | --- | --- | --- |
| F-01 | `1.0` `1.5` `.5` `0.0` | 1.0 / 1.5 / 0.5 / 0.0 | OK |
| F-02 | `1e5` `1E5` `1e+3` `1E-3` `.5e3` | 100000 / 100000 / 1000 / 0.001 / 500，**均为 Float** | OK |
| F-03 | `1_.5` | Float 1.5，`P`=`1.5` | OK |
| F-04 | `1..2` | `1.`(1.0) + `.2`(0.2) | OK |
| F-05 | `1.5.5` | `1.5` + `.5` | OK |
| F-06 | `1e` `1e+` `.5e` `1ex` | **`Invalid` + `invalid float.`**（`1ex` 后接 `Ident x`） | OK（D-3 已修） |
| F-07 | `.` `.e5` `._` | `Invalid` + `invalid float.` | OK |
| F-08 | `1._` | Float 1.0 | KNOWN(D-7) 期望 `Invalid` |
| F-09 | `1e999` `1e-999`（上溢/下溢） | `Invalid` + `invalid float.`（已实测：`stod` 抛 `out_of_range` 被 catch） | OK |

### T5 标识符与 `:` 命名空间（LEX-I）

| ID | 输入 | 预期 | 性质 |
| --- | --- | --- | --- |
| D-01 | `abc` `_x` `A9` `_` `__9` | `Ident`，`P`=原文 | OK |
| D-02 | `9a` | `Integer 9` + `Ident a` | OK |
| D-03 | `a:b` | 单个 `Ident`，`P`=`a:b` | OK |
| D-04 | `a:b:c` | 单个 `Ident`，`P`=`a:b:c` | OK |
| D-05 | `a : b` / `a\n:b` / `a // c\n:b` / `a :/*x*/ b` | 均合并成 `a:b` | OK |
| D-06 | `a::b` | `Invalid`(`P`=`a:`) + `Invalid` + `Ident b`；`E` 含 `unclosed identifier.` 与 `unknown token.` | OK |
| D-07 | `a:1` | `Invalid`(`a:`) + `Integer 1` + `unclosed identifier.` | OK |
| D-08 | `a:`（EOF 结尾） | `Invalid` + `unclosed identifier.` | OK |
| D-09 | 所有 Ident/关键字/Custom 的 `L` | **恒为空** | KNOWN(D-8) 期望原文 |

### T6 关键字（LEX-K）

| ID | 输入 | 预期 | 性质 |
| --- | --- | --- | --- |
| K-01 | 17 个关键字逐个：`idiv not and or if elif else let return while break continue null false true args argc export` | 对应 `IDiv/Not/And/Or/If/Elif/Else/Let/Return/While/Break/Continue/Null/False/True/Args/Argc/Export`（18 项） | OK |
| K-02 | `IF` `If` `iff` `if2` `IF2` | 全部 `Ident`（大小写敏感、全字匹配） | OK |
| K-03 | `not` 与 `!`、`and` 与 `&&`、`or` 与 `\|\|` | 两两产生**同一** `TokenType`（Not / And / Or） | OK |

### T7 字符串（LEX-S）

| ID | 输入 | 预期（当前） | 性质 |
| --- | --- | --- | --- |
| S-01 | `"abc"` | `String`，`L`=`abc`（不含引号） | OK |
| S-02 | `""` | `String`，`L` 空 | OK |
| S-03 | `"a\"b"` | 转义引号不终止 → 单个 `String`，`L`=`a\"b` | OK |
| S-04 | `"a\\b"` | `L`=`a\\b` | OK |
| S-05 | `"abc`（未闭合） | **`Invalid`** + `unclosed string literal.`（与 BinArr 一致） | OK（D-10 已修） |
| S-06 | `"abc\`（反斜杠结尾） | `String`，`E` 恰好 1 条 `unclosed string literal.`（不重复报） | OK |
| S-07 | `"a\qb"`（非法转义） | **报错 `invalid escape character.`** | OK（D-5 已修） |
| S-08 | `"a\nb"` 的 `P` | `P` = 解码后的 `a`+换行+`b`（`escapeString()` 已接线） | OK（D-11 已修） |
| S-09 | `"a\qb"` 出错后的 `P` 与 `type` | `P` 被截断为 `a`，`type` 仍 `String` | KNOWN(D-14) 期望 `Invalid` |

### T8 二进制数组 `'...'`（LEX-B）

| ID | 输入 | 预期 | 性质 |
| --- | --- | --- | --- |
| B-01 | `'abc'` | `BinArr`，`L`=`abc` | OK |
| B-02 | `''` | 空 `BinArr` | OK |
| B-03 | `'a' 'b'` | 两个 BinArr（不合并） | OK |
| B-04 | `'abc`（未闭合） | `Invalid` + `unclosed binary array.`；输入被吃到末尾 | OK |
| B-05 | `'a\nb'` | `L` 含换行，`line` 累加 | OK |
| B-06 | `'\'' x` | 单引号内**无转义**：`BinArr`(`L`=`\`) + `Invalid`(`L`=` x`) + `unclosed binary array.`（已实测） | OK（固化） |

### T9 标点与运算符（LEX-P）

| ID | 输入 | 预期 | 性质 |
| --- | --- | --- | --- |
| P-01 | `, ; ( ) [ ] { }` | `Comma Semi LParen RParen LBrack RBrack LBrace RBrace` | OK |
| P-02 | `+ - * / % ^` | `Add Sub Mul Div Mod Pow` | OK |
| P-03 | `= == ===` | `Assign` / `EQ` / `EQ`+`Assign` | OK |
| P-04 | `! != !==` | `Not` / `NE` / `NE`+`Assign` | OK |
| P-05 | `< <= > >=` | `LT LE GT GE` | OK |
| P-06 | `&& and` / `\|\| or` | `And` / `Or`（两种写法同类型） | OK |
| P-07 | `&` / `\|`（单个） | `Invalid` + `unknown token.` | OK |
| P-08 | `@ $ # ~ ? :` 等非语言字符 | 每个 → `Invalid` + 1 条 `unknown token.`，**各消费 1 码元** | OK |
| P-09 | 全部标点 token 的 `L`/`P` | **均空** | KNOWN(D-9) 期望原文 |
| P-10 | `(`后紧跟`)`无空白 | 两个 token，无粘连 | OK |

### T10 自定义指令（LEX-C）

| ID | 输入 | 预期 | 性质 |
| --- | --- | --- | --- |
| C-01 | `custom=nullptr` 时传普通标识符 | `Ident`，不查表不崩 | OK |
| C-02 | 注册 `myop` → 输入 `myop` | `Custom`，`P`=`myop` | OK |
| C-03 | 注册 `a:b` → 输入 `a:b` / `a : b` | `Custom`，`P`=`a:b` | OK |
| C-04 | 未注册的 `other` | `Ident` | OK |
| C-05 | 自定义名与关键字同名（如注册 `if`） | **关键字优先** → `If` | OK |
| C-06 | 重复注册同名 | `addCustomOpcode` 返回 `DuplicateWithBuiltinOpcode`（顺带覆盖 `custom_opcode.hpp`） | OK |

### T11 错误处理与恢复（LEX-E）

| ID | 场景 | 预期 | 性质 |
| --- | --- | --- | --- |
| E-01 | 每个 error 分支至少一次：`unknown token.` / `unclosed string literal.` / `unclosed binary array.` / `invalid integer.` / `invalid float.` / `unclosed identifier.` | 文案含 `"line N: "` 前缀 | OK |
| E-02 | 多个错误 | 顺序累加，`errors.size()` 精确匹配 | OK |
| E-03 | 错误后继续扫描 | 必须推进到 `Eof`，**不得死循环**（`lexAll` 的 10000 上限兜底） | OK（硬性） |
| E-04 | `中文`（非 ASCII） | 每个 UTF-16 码元 1 个 `Invalid`；emoji（代理对）→ 2 个 | OK |
| E-05 | 错误行号 | 与 `T2` 一致 | OK |
| E-06 | 未闭合块注释 | 见 W-08 | KNOWN(D-6) |

### T12 Token 状态与生命周期（LEX-T）

| ID | 场景 | 预期 | 性质 |
| --- | --- | --- | --- |
| T12-1 | 复用同一个 `Token` 变量连续调 `NextToken`（parser 的环形缓冲用法） | 每轮 `parsed` 必须清空，不得出现 `alphagamma` 式串味 | OK（硬性，防回归） |
| T12-2 | 复用同一个 `Lexer` 连续跑两条输入 | 明确不支持（`input`/`line`/`errors` 不重置）→ 用例只断言"不崩" | OK（记录） |
| T12-3 | `lexeme` 生命周期 | 输入 `u16string` 存活期内 `lexeme` 可读；输入销毁后访问属 UB → 测试不得依赖 | OK（约束） |
| T12-4 | `Token()` 值初始化 | `type==Invalid`、`line==0`、`lexeme` 空 | OK |

### T13 端到端 token 流（LEX-E2E）

用完整程序片段断言**整条 token 序列**（类型序列即可，不逐字段），至少 5 段：

| ID | 片段要点 |
| --- | --- |
| G-01 | `let a = 1 + 2 * 3;` 含关键字、标点、数字 |
| G-02 | `if a >= 1 and b != 2 { return; } elif c { } else { }` |
| G-03 | `while true { break; continue; }` |
| G-04 | `export foo:bar = "s" , 'x' , null , false , argc , args;` |
| G-05 | 含 `//`、`/* */`、空行、跨行标识符的混合片段，并断言每条 token 的 `line` |

预期写法：把类型序列写成字符串（如 `"Let Ident Assign Integer Add Integer Mul Integer Semi"`），一次比对。

### T14 健壮性下限（LEX-R）

| ID | 场景 | 预期 |
| --- | --- | --- |
| R-01 | 空输入 / 只有空白 / 只有注释 | 立即 `Eof`，无 error |
| R-02 | 10000 个 `a`（超长标识符） | 不崩、不死循环（仅断言 token 数与 `Eof`） |
| R-03 | 1000 层嵌套 `((((…))))` | 不栈溢出（lexer 无递归，应安全） |
| R-04 | 1000 个未闭合 `"` 与 `'` 交替 | 不死循环，error 数有限 |
| R-05 | 单个孤立 `:` | `Invalid` + `unknown token.` |

---

## 6. 覆盖率与验收标准

| 指标 | 目标 | 度量方式 |
| --- | --- | --- |
| `TokenType` 覆盖 | **47/47** 每个类型至少被 1 个用例产生 | 用例内统计"已产生类型集合"，`main` 末尾打印缺失项并判失败 |
| `NextToken` 分支覆盖 | 每个 `else if` 分支 ≥1 次 | 手工核对 + `gcov`（GCC）可选 |
| `error()` 文案覆盖 | **7 条**文案全覆盖（含已接线的 `invalid escape character.`） | E-01 |
| 行覆盖率 | ≥ 90% | `gcov` |
| 已知失败 | 全部挂 `KNOWN_ISSUE(id)`，报告中单列 | 见 §7 |
| 编译告警 | `-Wall -Wextra` 下除已知的 `-Wsign-compare` 外无新增告警 | 构建日志 |

**验收门槛**：所有 `OK` 用例 100% 通过；`KNOWN` 用例全部如实失败并在报告中列出；无死循环、无崩溃、无 ASan/UBSan 报告（建议本地加跑一次 `-fsanitize=address,undefined`）。

---

## 7. 缺陷处理流程

1. 用例按**当前实际行为**写断言，缺陷项用 `KNOWN_ISSUE("D-1", ...)` 包裹并写入期望值注释。
2. 报告末尾固定输出一段"已知问题"小节：`D-1 … D-14` 各自 PASS/FAIL/FIXED 状态。
3. 修好某个缺陷后：框架报 `FIXED-PENDING-FLIP`，把该断言翻成普通 `EXPECT_*`，并在本文档 §3 标记 `[已修 YYYY-MM-DD]`。
4. **剩余优先级建议**：D-8/D-9（lexeme 缺失，parser 报错要用）→ D-14/D-10（出错未置 `Invalid`）→ D-6/D-7/D-13（一致性与静默接受）→ D-12（清理警告后开 `-Werror`）。

### 7.1 已修复记录

| 日期 | 缺陷 | 修复内容 |
| --- | --- | --- |
| 2026-10-15 | D-1 / D-2 | `getNumberValue()` 新增 `numberBase()` 按前缀（`0b/0B/0o/0O/0x/0X`）选基数并剥前缀后 `stoll(s, &pos, base)`；溢出检测随之对非十进制生效 |
| 2026-10-15 | D-3 | 同上函数内新增浮点消费完整性校验 `pos == s.size()`，`1e`/`1e+`/`.5e` 不再静默通过 |
| 2026-10-15 | D-4（部分） | 去前缀后为空串 → `stoll` 抛 `invalid_argument` → `Invalid`。`0x_1`/`0o_7` 按笔记取舍保留为合法 |
| 2026-10-15（用户侧） | D-5 / D-11 | `scanString()` 末尾调用 `escapeString()`，非法转义报错、`parsed` 正确解码 |
| 2026-10-15（用户侧） | D-10 | 未闭合字符串改判 `Invalid`，与 BinArr 行为一致 |

---

## 8. 执行方式

```bash
```bash
cd cpp
cmake -B build
cmake --build build
ctest --test-dir build --output-on-failure   # 或直接 ./build/test_lexer.exe
```

MinGW 环境下若 make 报错（源码路径含非 ASCII 字符时 `mingw32-make` 无法处理），
改用 g++ 直接编译，产物同样落在 `build/`：

```bash
g++ -std=c++20 -Wall -Wextra -I stope -o build/test_lexer.exe \
    test/test_main.cpp test/test_lexer_number.cpp test/test_lexer_ident.cpp \
    test/test_lexer_string.cpp test/test_lexer_punct.cpp \
    test/test_lexer_flow.cpp test/test_lexer_misc.cpp
./build/test_lexer.exe
```

退出码约定：`0`=全部通过；`1`=有 `OK` 用例失败；`2`=有 `FIXED-PENDING-FLIP`（提醒翻转）。

---

## 9. 里程碑

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| M1 | `test_common.hpp` + `test_main.cpp` + 根 CMake 接入（`demo01` 加 `EXISTS` 守卫） | ✅ 2026-10-15 完成 |
| M2 | T3/T4 数字 + T5/T6 标识符关键字 | ✅ 完成 |
| M3 | T7/T8 字符串与 BinArr + T9 标点 | ✅ 完成 |
| M4 | T1/T2/T11/T12/T14 流程与健壮性 | ✅ 完成 |
| M5 | T10 自定义指令 + T13 端到端 | ✅ 完成（292 断言、47/47 类型覆盖） |
| M6 | 修复 D-6/D-7/D-8/D-9/D-13/D-14 并翻转断言 | ⏳ 未开始 |

---

## 10. 风险与注意事项

1. **`lexeme` 是 `string_view`**：`lexAll()` 必须在栈上持有 `u16string` 且断言期间不销毁；否则读到悬垂内存，测试会偶发通过偶发崩。
2. **死循环风险**：历史上 `NextToken` 兜底分支不消费字符导致过死循环。`lexAll` 必须有迭代上限（建议 10000）并断言最终一定到 `Eof`。
3. **header-only ODR**：`test_common.hpp` 里任何非模板自由函数/命名空间变量必须 `inline`/`constexpr`，否则多 TU 链接报 `multiple definition`（`development.md` §3 已记录该坑）。
4. **编码**：源码统一 UTF-8；MSVC 已在根 CMake 加 `/utf-8`；测试输入若含中文，建议用 `u"..."` 字面量而非运行时转换。
5. **`std::stoll`/`std::stod` 依赖 locale 与实现**：断言浮点用相对误差（`fabs(a-b) < 1e-9`）而非 `==`；整数断言精确值。
6. **与 GDScript 参考实现的语义差异**：本计划以"参考实现为准"标注期望（如指数缺数字应报错）；若项目决定采用 C++ 侧的宽松语义，需回来把对应 `KNOWN` 改成 `OK` 并记录在本文档 §3.5。
7. **测试不得依赖 `escapeString()`**：它目前从未被调用，若后续接线，S-07/S-08 的期望值需要一并更新。
