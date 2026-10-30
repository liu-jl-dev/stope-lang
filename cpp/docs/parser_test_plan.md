# `cpp/include/stope/parser.hpp` 测试计划

- 被测对象：`cpp/include/stope/parser.hpp` — `Stope::Parser`（含 `cpp/include/stope/ast.hpp`、`cpp/include/stope/parse_binarr.hpp`）
- 计划版本：v1.4（2026-10-16）；**测试已全部落地并全绿**——165 个用例、
  `ctest` 10/10 通过、`test_parser` 700 断言 / 16 KNOWN / 0 失败。
  常量折叠已接入（v1.4 新增）：`Parser::constFolding`（默认开），
  P 组与 L-02 关折叠锁定树形，新增 O 组（O-01…O-37）锁定折叠结果。
  已修/已定夺：PD-1/PD-2/PD-3/PD-4/PD-4b/PD-4c/PD-4d/PD-5/PD-6/PD-16/PD-17；
  PD-7（`^` 结合性）2026-10-16 定夺为左结合，**2026-10-22 又改为右结合**、残留项拆为 PD-18；未修见 §7。
  §6–§10 已按落地实况改写。
- 实测环境：g++ (MinGW-w64 x86_64-win32-seh) 15.2.0，`-std=c++20`，默认 8 MB 线程栈
- 参考实现（语义基准）：`gdscript/addons/stope/parser.gd`
- 上游依赖：`cpp/include/stope/lexer.hpp`（其测试计划与已知缺陷见 `lexer_test_plan.md`）

---

## 1. 目标与非目标

### 1.1 目标

1. 为 `Parser::ParseProgram(AST::Prog&)` 建立可重复执行的回归基线，覆盖
   **10 类语句节点 + 空语句**、**14 个表达式节点类型 + 失败路径的裸 `Expr`（共 26 个可产生的
   `AST::NodeType`）**、**14 个 prefix 注册项 + 17 个 infix 注册项**、**34 处 `error()` 调用点**。
2. 把"当前实际行为"固化成断言，使后续重构（拆 .cpp、改 AST、接入 compiler）能立刻发现行为漂移。
3. 暴露并记录已确认的缺陷（见 §3），用 **已知失败清单（Known-Issue）** 管理，避免缺陷被测试"洗白"。
4. 提供覆盖率与验收口径，作为 parser 可否交付给 `addons/stope/compiler.gd` 的依据。

### 1.2 非目标

- 不测试 lexer（另有 `lexer_test_plan.md`）；不测试语义分析、代码生成（`compiler.gd` 的职责）。
- 不做性能基准；只做"不死循环 / 不崩 / 不泄漏"的健壮性下限（见 §3 PD-12 / PD-13）。
- 不验证"语义正确性"（如 `1 = 2;` 是否应判错），parser 层只记录现状（见 PD-10）。

---

## 2. 被测接口契约

```cpp
struct Parser {
  Lexer* lexer;                              // public，不拥有
  std::vector<std::string> errors;           // public，累加，格式 "line N: msg"
  int lastErrorLine = -1;                    // public，error() 的按行去重状态
 private:
  CustomOpcodeConfig* customOpcodeConfig = 0; // private，由构造函数注入
  BinaryArrayParser binaryArrayParser;       // private，有状态：内含 input string_view
 public:
  Parser(Lexer& lexer, CustomOpcodeConfig* cfg = nullptr); // 构造时即调用 nextToken() 两次
  void ParseProgram(AST::Prog& prog);        // 返回 void，成败只能查 errors
};
```

测试必须遵守的契约约束（均已实测确认）：

| 约束 | 说明 | 测试注意点 |
| --- | --- | --- |
| **只有上述成员是 public** | `curToken()` / `peekToken()` / `nextToken()` / `error()` / `tokens` / `customOpcodeConfig` 全是 private | 断言只能经过 public API；不要为了断言去 friend 或改可见性 |
| **构造即消费 2 个 token** | `Parser` 构造函数体执行 `nextToken(); nextToken();` | 输入至少要有 2 个 token 才有意义；空输入也能安全构造（实测 `Prog(n=0)`） |
| **config 经构造函数注入** | `Parser(Lexer&, CustomOpcodeConfig* = nullptr)`，赋值在两次 `nextToken()` **之前** | PD-3 已修（2026-10-16）：输入最开头的 custom 指令也能识别；`cfg` 传 `nullptr` 即全部走 `Ident`/`Call` 路径（K-10） |
| **`errors` 按行去重** | `error()` 里 `if (line == lastErrorLine) return;`，且 `lastErrorLine` 从不重置 | 同行第二个真实错误会被吞；断言错误**条数**时必须按"去重后"的期望值写（见 PD-5） |
| **`lexer.errors` 不合并** | parser 只往自己的 `errors` 里写 | 调用方必须同时检查 `lexer.errors` 与 `parser.errors`（见 PD-14） |
| **`Token::lexeme` 是 `string_view`** | 指向 `Lexer::input` | 输入 `u16string` 必须在整个断言期间存活（同 lexer 计划 §10.1） |
| **`ParseProgram` 返回 void** | 无返回值可判成败 | 判成败一律用 `parser.errors.empty()`，并**额外**查 `lexer.errors` |
| **AST 节点多态删除** | `Node` 有 `virtual ~Node()`，`Prog::stmts` 是 `vector<unique_ptr<Stmt>>` | 测试持有 `AST::Prog` 时必须让它正常析构（见 §3 PD-12 / PD-13） |

### 2.1 token 环形缓冲

`Parser` 用 `std::array<Token, 2> tokens` + `curTokenIdx` 实现 cur/peek：

- `nextToken()` 先 `curTokenIdx = (curTokenIdx + 1) % 2`，再 `lexer->NextToken(peekToken(), ...)`。
- 即：**`nextToken()` 之后运算符在 `curToken()`，右操作数在 `peekToken()`**。
  2026-10-15 修好的中缀分发 bug（曾用 `peekToken()` 查 `infixParseFns`）就是违反这条约定。
- `tokens` 未零初始化，`Token::type` 在两次 `nextToken()` 填满前是未初始化的（见 PD-15）。
  测试**不应**直接读 `tokens`（private），但可通过"构造后立刻解析"间接覆盖。

### 2.2 已确立的项目约定（测试要保护它）

1. **错误恢复/解析时绝不推进 `Eof` 与 `RBrace`** —— 在 `Eof` 上 `nextToken()` 不前进会死循环；
   前进又会吞掉外层块的 `}`。`parseReturnStmt` / `let` / `export` / `parseCallExpr` / `parseAtExpr`
   均已按此实现，测试必须锁定（否则一次"顺手补 nextToken()"就会回归）。
2. **错误恢复不越过错误点，后续 token 留给下一轮语句解析**（2026-10-16 起确立）——
   分隔符缺失（`;` `{` `[` `)` `]`）时报错即返回，**不再 `nextToken()`**，
   使被错误中断的 token 序列能作为独立语句重新解析。
   已按此实现的：`parseBreakStmt`/`parseContinueStmt`（PD-4）、`parseIfStmt`/`parseWhileStmt`
   的缺 `{` 分支（PD-4b）、`parseArgsExpr` 的缺 `[`（PD-4c）、`parseCustomOpcodeExpr` 的缺 `(`
   与空参数表（PD-17）、`parseExprOrAssignStmt` 的错误分支（PD-4d）。
   - **反例（仍按旧语义，勿改）**：`parseLetStmt`/`parseReturnStmt` 的兜底错误分支仍
     `nextToken()`，由此 `let a, b = 1;` 的 `= 1` 会被丢弃 ——
     该行为在 §3.5 已登记为现有基线（S-06 / S-18）。
3. **`^` 为右结合**（2026-10-22 项目定夺，此前为左结合）：`2^3^2` == `2^(3^2)`。此前 PD-7 曾按"应为右结合"
   登记，现关闭；P-06 已翻为普通断言。残留：一元 `-` 与 `^` 的优先级（PD-18）。
4. **顶层孤立 `}` 是错误，块内 `}` 不是**（PD-6，2026-10-16 确立）——`parseProg` 靠
   `isTopLevel` 区分：顶层报 `unexpected "}" at top level. ` 并跳过继续解析；
   块/if/while 内的 `}` 属于外层语句，仍由外层消费、不得报错。
   - **这是 C++ 侧有意偏离 GDScript 参考实现的语义**（参考实现这几处都会推进，
     其 `prog_end_tokens` 让顶层 `}` 静默结束）；
     回归保护见 S-26/28/29/32、S-36、X-12、F-15/F-16、K-11。
5. **解析错误一律走返回值 / `errors`，不得让异常穿出解析层** ——
   `parse_binarr.hpp` 已按此加 `catch (...)`（对齐 `lexer.hpp:296`）。

---

## 3. 现状基线：已确认的行为与缺陷

> 下列结论**均已用 g++ 15.2 实测**（非静态阅读推测）。测试计划按此基线写断言。
> 标记为 **BUG** 的条目：先写"当前行为"断言并打 `KnownIssue` 标签；修复后把期望值翻转即可。
> 每条缺陷的输入都给出了**可复现的最小样例**。

### 3.1 P0 —— 功能不可用 / 崩溃

| ID | 输入 | 当前实际 | 期望（参考实现 / 文法） |
| --- | --- | --- | --- |
| **PD-1** ✅已修 | `x; myop(1, 2);`（已注册 `myop`） | 曾 **SIGILL（exit 132）**。根因：`parseCustomOpcodeExpr`（`parser.hpp:443-468`）是非 void 函数却**没有 `return`**，MinGW 插 `ud2`。**2026-10-16 已修**：函数补齐 `return expr;`，`-Wreturn-type` 告警随之消失 | 正常解析（现已达成，K-01 为回归保护） |
| **PD-2** ✅已修 | `let x = myop(1, 2);` | 曾 `Call(callee = Custom(name=myop, args=0), args=[1,2])`，`CustomOpcodeExpr::args` 恒空。**2026-10-16 已修**：空参数分支与 `expr ("," expr)*` 参数表均已实现 | `Custom(name=myop, args=[1,2])`（现已达成，K-01/K-02） |
| **PD-3** ✅已修 | `myop(1, 2);`（`myop` 位于输入**最开头**） | 曾识别为 `Ident myop` + `Call`，**不是** `Custom`（根因：`Parser(Lexer*)` 构造体的两次 `nextToken()` 执行时 `customOpcodeConfig` 仍是 `nullptr`）。**2026-10-16 已修**：构造函数改签名 `Parser(Lexer*, CustomOpcodeConfig*)`，config 在两次 `nextToken()` **之前**赋值 | `Custom(myop; Int(1); Int(2))`（现已达成，K-04/K-05/K-09） |

> PD-1/PD-2/PD-3/PD-4 家族/PD-17 均已于 2026-10-16 修复或由用户修复，见 §7.1；
> K 组与 S/F/X 组的相关断言已从 `KNOWN` 翻转为普通断言。

### 3.2 P1 —— 静默丢 token / 吞错误

| ID | 输入 | 当前实际 | 期望 |
| --- | --- | --- | --- |
| **PD-4** ✅已修 | `break x;` | 曾 `BreakStmt` + 1 error，**`x;` 被静默丢弃**（`parseBreakStmt` 错误路径无条件 `nextToken()`）。**2026-10-16 已修**：错误路径不推进，`x;` 保留为下一条语句。`continue x;` 同理 | `stmts == 2`（`Break` + `ExprStmt(Ident x)`，1 error）（现已达成，S-36） |
| **PD-4b** ✅已修 | `if a b;` / `if a { b; } elif c d;` / `if a { b; } else c;` / `while a b;` | 曾各 1 error，`b;`/`d;`/`c;` 被静默丢弃（缺 `{` 分支也 `nextToken()`）。**2026-10-16 已修**：`parseIfStmt`/`parseWhileStmt` 的"缺 `{`"分支只报错、不推进 | 保留后续语句为独立 stmt（现已达成，S-26/28/29/32） |
| **PD-4c** ✅已修 | `args 0;` | 曾 `Args(null)` + 1 error，`0;` 被丢弃（`parseArgsExpr` 先 `nextToken()` 再判 `[`，等于把 `0` 当成表达式的尾 token）。**2026-10-16 已修**：改为先看 `peekToken()`，不是 `[` 就报错且不推进 | `stmts == 2`（`Args(null)` + `ExprStmt(Int 0)`，1 error）（现已达成，X-12） |
| **PD-4d** ✅已修 | `f(1, 2 x; y;` / `a[1, 2 x; y;` | 曾 1 error，**`x;` 被丢弃**，只剩 `y;`。根因不在 `parseCallExpr`/`parseAtExpr`（它们已"缺 `)`/`]` 不推进"），而在 `parseExprOrAssignStmt` 的错误分支仍无条件 `nextToken()`，越过了 `x` | `stmts == 3`（Call/At + `x` + `y`，1 error）（现已达成，F-15/F-16） |
| **PD-5** ✅已修（2026-10-16） | `'x zz'; 'b _';`（同行两个非法 BinArr） | 曾 **errors = 1**（第二个被 `lastErrorLine` 吞）。**已修**：`error()` 的按行去重与 `lastErrorLine` 成员一并停用（源码里保留注释形式），同行每个错误都上报。连带影响：一批按旧基线写的条数断言整体上调（`S-06` 1→2、`F-12` 1→2、`F-17` 1→3、`F-18b…e` 1→3、`F-18f` 1→2、`R-06` 1→2） | errors = 2（现已达成，R-02/R-04/R-05 已翻为普通断言） |
| **PD-6** ✅已修（2026-10-16） | `} x;` / `a; } b;` | 曾 `Prog(n=0)` / `Prog(n=1)`，**errors = 0**，`b;` 静默丢失。根因：`parseProg` 循环条件 `cur == RBrace` 直接退出，而顶层没有外层块来消费这个 `}`。**已修**：`parseProg(prog, isTopLevel)` 增加上下文参数（`ParseProgram` 传 `true`，块/if/while 内传 `false`）；顶层遇到 `}` 报 `unexpected "}" at top level. ` 并**跳过继续解析**（只报错不推进会死循环，只 break 又会丢语句） | `} x;` → 1 error + `ExprStmt(Ident x)`；`a; } b;` → 1 error + 2 stmts；块内 `}` 行为不变（`{ a; } b;` 仍 0 errors，S-21 对照组锁定） |
| **PD-7** ✅已改（2026-10-22） | `2 ^ 3 ^ 2;` | `2 ^ (3 ^ 2)`（**右结合**） | 2026-10-16 曾定夺为左结合；**2026-10-22 项目改为右结合**，机制见 `parseBinaryOpExpr` 里对 `Pow` 的 `prec = OpPrecedence(int(prec) - 1)`（右结合 → 递归阈值降一级）。P-06 已按右结合翻为普通断言（`2^3^2^4` 三级锁定）。残留的一元优先级问题另立 **PD-18** |
| **PD-8** ❌未修 | `let a = 1 +` / `f(1,` / `a[1,` / `(1 +` / `args[` / `a = ;` / `();` | 失败处返回裸 `new AST::Expr()`（`type = NodeType::Expr`、**`line = -1`**）。若它是 `ExprStmt` 的左式（如 `();`），外层语句 `line` 也被带成 -1；`AssignStmt`/`LetStmt` 的 `line` 取自左式/关键字，不受传染 | 要么给一个可识别的"错误节点"，要么做 panic-mode（跳到下一个 `;` / `}`）。当前下游只能靠 `line == -1` 识别 |
| **PD-17** ✅已修（2026-10-16 新发现并修复） | `x; myop();`（空参数表，非输入开头） | 曾 **1 条误报**：`expected ";" or "=". `（`parseCustomOpcodeExpr` 空参数分支之后仍执行收尾 `nextToken()`，越过 `)`）。**2026-10-16 已修**：收尾 `nextToken()` 移入 `else` 分支，空参数表停在 `)` | `0 errors`（现已达成，K-11） |

### 3.3 P2 —— 正确性与资源

| ID | 现象（实测） | 影响 | 期望 |
| --- | --- | --- | --- |
| **PD-9** | `a = b = 1;` → `AssignStmt(a, b)` + `ExprStmt(1)` + 1 error | 赋值不是表达式，链式赋值无法表达（参考实现同样） | 记录为现状；若要支持需改文法 |
| **PD-10** | `1 = 2;` / `f() = 1;` → **0 errors** | parser 不校验左值 | 若由语义分析负责，则在计划里标注"有意" |
| **PD-11** ✅已修（2026-10-16） | `();` → 裸 `AST::Expr`（**line 由当前 token 决定，不再恒为 -1**）+ 3 errors | 曾 line 恒为 -1 并传染外层 `ExprStmt.line`。**已修**：失败节点的 `line` 改为取 `curToken().line`。连带：`S-42`/`F-17` 的 `Err(L-1)` → `Err(L1)`，`L-05` 的 `line == -1` → `== 1`，F-17 的 `KNOWN(PD-11)` 翻成普通断言 | 剩下的是 PD-8：失败处不该返回裸 `Expr` |
| **PD-11b** ❌未修 | `();` | 空括号不支持；`parseParenExpr` 留着 `// 不必 nextToken() ？` 自问注释 | 明确支持或明确报错 |
| **PD-12** | 正确路径 `new == delete`（配平）；**但每发出 1 条 error，`delete` 就比 `new` 多 1**。实测：`a;` → 4/4；`break x;` → 5/6；`break x; break y;`（同行去重成 1 条）→ 7/8；分两行 2 条 → 8/10 | 不配平，方向是 delete > new（不是 AST 节点泄漏） | **根因已定位（2026-10-16 实测隔离）**：不在 parser，而在 `error()` 的 `std::stringstream` + `vector::emplace_back` 惯用法 —— 该工具链上 stringstream 的内部分配不经过可替换的全局 `operator new`（重载 `new`/`new[]` 都看不到），释放却走 `operator delete(void*, size_t)`，于是每次 error 多计一次 delete。**不是双重释放**（指针唯一、进程干净退出、AST 侧完全配平）。改用 `std::to_string` 拼接实测可配平。测量方法本身的坑见 §10 第 5 条 |
| **PD-18** ❌待定（2026-10-16 从 PD-7 拆出） | `-2 ^ 2;` → `Pow(Unary(-, 2), 2)`，即一元 `-` 优先级**高于** `^` | 不是结合性问题（`^` 结合性已定，见 PD-7），而是"一元 `-` 与 `^` 谁先结合"。多数语言（Python）是 `-(2^2)`，但也有语言（Excel）是 `(-2)^2`。参考实现与本实现一致 | 项目定夺后：若改为 `-(2^2)`，则 `parseUnaryExpr` 的操作数要用低于 `Pow` 的优先级解析；若维持现状则把 P-07 的 `KNOWN` 删掉、记为有意行为 |
| **PD-13** | 递归无深度上限，默认 8 MB 栈实测阈值：`((((a))))` 11000 OK / 12000 **解析阶段**崩；`{{{{a;}}}}` 4000 OK / 5000 **析构阶段**崩；`a[a[a[0]]]` 3000 OK / 5000 **析构阶段**崩。256 MB 栈下 10 万层正常 | 恶意/病态输入可致栈溢出崩溃 | ✅ **2026-10-30 已修**：加 `Parser::maxDepth`（默认 256），超限报 `nesting too deep (max 256). ` 并停止递归。上面这些阈值是加限额前的实测，留作历史 |
| **PD-13b** | **析构同样递归**：`----a` 9000 层解析成功且析构成功；10000 层解析成功、但 `AST::Prog` 析构时崩。块 5000 / 索引 5000 同样是"解析 OK、析构崩" | 即使解析通过，销毁 AST 也会崩 | ✅ **2026-10-30 随 PD-13 一并解决**：AST 深度不会超过 `maxDepth`，析构链自然有界。教训仍然成立 —— 判"解析安全"必须包含析构（`test_parser_depth` 的 `DESTROY-OK` 那一段就是为此保留的） |

### 3.4 P3 —— 接口与一致性

| ID | 现象 | 说明 |
| --- | --- | --- |
| **PD-14** | `@ a;` → `lexer.errors=1` + `parser.errors=1`（两条独立） | `lexer.errors` 不合并进 `parser.errors`；调用方必须同时查两个 vector。且 lexer 的 `Invalid` token 会触发 parser 的 `no prefix parse function`，一条错误报两遍 |
| **PD-15** | `std::array<Token,2> tokens` 未零初始化 | 依赖构造函数两次 `nextToken()` 填满；`Token::type` 在填充前是未初始化的。若 `NextToken` 某条路径不写 `type`，会读到垃圾 |
| **PD-16** ✅已修 | `parseDecicalInteger` 拼写错误 | 2026-10-16 方案 A 重构已把 4 个 `parseXxxInteger` 合并为 `parseInteger(o, base, isDigit)`，拼写问题随之消解 |

### 3.5 已确认**正确**的行为（回归基线，重点保护）

**语句层**

- 空程序 / `;;;` → `Prog(n=0)`，0 errors。
- `let a;` / `let a = 1;` / `let a, b, c;` → `idents=[a]` / `hasAssign=1` / `idents=[a,b,c]`。
- `let a, b = 1;` → 1 error，`= 1` 被丢弃（`parseLetStmt` 的兜底错误分支仍 `nextToken()`；
  2026-10-16 修复 PD-4 家族时**有意未动**，见 §2.2 约定 2 的"反例"，`hasAssign=0`）。
- `export a;` / `export a, b;` → `idents=[a]` / `[a,b]`；`export a = 1;` → `ExportStmt[a]` + `ExprStmt[1]` + 1 error。
- `return;` → `exprs=0`；`return 1, 2, 3;` → `exprs=3`（**`return` 无值是合法的**，`ast.hpp:82` 文法 `( expr ("," expr)* )?`）。
- `{ a; b; }` / `{}` / `{ { a; } b; }` → 嵌套 `BlockStmt` 正确。
- `if a { b; }` → `hasElse=0`；`if a { b; } elif c { d; } else { e; }` → `elifs=1, hasElse=1`；多 `elif` 正确。
- `while a { b; }` → 有 `cond`；**`while { b; }` → `cond` 为空且 0 errors**（文法 `expr?`，可选）。
- `break;` / `continue;` → 0 errors。**顶层** `return; break; continue;` 也被接受（无语境检查，3 stmts 0 errors）。
- 表达式语句 / 赋值语句：`a;` → `ExprStmt`；`a = 1;` → `AssignStmt(left=Ident a, right=Int 1)`；`a[0] = 1;` 左值是 `AtExpr`。
- `1 + 2 * 3;` → `1 + (2*3)`；`(1 + 2) * 3;` → 括号改优先级；`1 - 2 - 3;` → 左结合。
- `a and b or c;` → `(a and b) or c`；`a or b and c;` → `a or (b and c)`（**and 高于 or，正确**）。
- `7 idiv 2 % 3;` → `(7 idiv 2) % 3`（同级左结合）。
- `1 < 2 < 3;` / `1 == 2 != 3;` → 左结合（正常）。
- `-a * b;` → `(-a) * b`；`-(a * b);` → 括号生效；`not a and b;` → `(not a) and b`。
- `- - a;` / `not not a;` → 一元可叠层。
- `f();` → `Call args=0`；`a[];` → `At idx=0`；**两者都合法且 0 errors**。
- `f(1, 2, 3);` → args=3；`f(a + 1, b * 2);` → 参数是完整表达式；`f(g(1), h(2));` → 嵌套 Call。
- `f(a)(b)[c];` → `At(Call(Call(f,a),b),c)`（链式后缀，左结合）。
- `a[b[1]];` / `a[1][2];` / `f(1)[2];` → 嵌套/链式 At 正确。
- `args[0];` → `Args` 包 `Int`；`args[a + 1];` → 包 `BinOp`。
- `argc;` → `Argc`；`null;` `true;` `false;` → `Null` / `Bool(true)` / `Bool(false)`。
- `'x ff 0a';` → `BinArr n=2 [255,10]`；`'b 1010 1111';` → `[10,15]`；`'';` → 0 字节 0 errors。
- `"a\nb";` → `StringExpr` 的 `value` 含真实换行（转义在 lexer 层解码）。
- 行号：多行输入 `1 +\n2;\na;` → `Int(L1)`、`Int(L2)`、`ExprStmt(L3)`，**表达式跨行时左右操作数行号各自正确**。
- `a = ;` → `AssignStmt.line = 1`（取自左式）；`();` → `ExprStmt.line = -1`（左式是裸 `Expr`，PD-8 只在这一路传染）。
- 自定义指令（2026-10-16 PD-1/PD-2 修复后）：`x; myop(1, 2);` → `Custom(myop; Int(1); Int(2))` 0 errors；
  可作 `let` 初值、调用参数、`if` 条件、索引键，结果还能再 `( )` 调用；`myop(1)(2);` 正常。
  未注册标识符 `other(1)` 走普通 `Call`；`customOpcodeConfig == nullptr` 时全部走 `Ident` 路径。
- 全前缀截断：11 组合法程序 × 全部前缀 = **166 个截断用例，0 挂起、0 崩溃、0 异常**（`test_parser_flow.cpp` B-01）。
- 内存：8 个正确路径用例 `new == delete` **完全配平**（`virtual ~Node()` 生效，见 `../../docs/zh-cn/syntax-impl.md` §7.1）。
- 深嵌套：`Parser::maxDepth` 默认 **256 层**，超限报 `nesting too deep (max 256). ` 并停止
  解析 —— 不再有栈溢出。限额前 8 MB 栈的崩溃阈值（括号 12000 / 块 5000 / 一元 10000 /
  索引 5000）见 PD-13/PD-13b，留作历史。

---

## 4. 测试基础设施

### 4.1 目录布局（增量，不动 lexer 现有文件）

```
cpp/
├─ CMakeLists.txt                  # 新增 test_parser / test_parser_depth 目标（见 4.3）
├─ docs/
│  ├─ README.md                    # 本目录总览（面向所有人）
│  ├─ lexer_test_plan.md           # lexer 的计划文档（计划文档统一放 docs/）
│  ├─ parser_test_plan.md          # 本文档
│  ├─ compiler_test_plan.md        # compiler 的计划文档（CD-1…CD-5 的对照表在 §3）
│  ├─ stml_test_plan.md            # STML 的计划文档
│  ├─ expr_optim.md                # 常量折叠的规则总表
│  ├─ development.md               # 布局 / 构建 / ODR / 行尾 / 代码风格 / API 约定 / 文档约定
│  ├─ basic_vm.md                  # 虚拟机的语义约定（句柄 / 栈 / 宿主接口）
│  └─ quick-start.md               # 嵌入 Stope 的四步，讲 demo/01-quick-start.cpp
└─ test/
   ├─ test_common.hpp              # 已有，已增量扩展（见 4.2）
   ├─ test_compiler.cpp            # C 编译器（C-01…C-52 + C-37b）
   ├─ test_ast_visitor.cpp         # V 遍历骨架（V-01…V-07，ASTVisitor 基类）
   ├─ test_parser.cpp              # parser 测试入口（命名对齐 test_lexer.cpp）
   ├─ test_parser_stmt.cpp         # S 语句层（S-01…S-45）
   ├─ test_parser_expr.cpp         # X 表达式与字面量（X-01…X-13）
   ├─ test_parser_prec.cpp         # P 优先级与结合性（P-01…P-20）
   ├─ test_parser_postfix.cpp      # F 调用 / 索引 / args / 括号（F-01…F-18）
   ├─ test_parser_custom.cpp       # K 自定义指令（K-01…K-11）
   ├─ test_parser_flow.cpp         # L 行号 / R 错误恢复 / B 健壮性与内存
   ├─ test_parser_fold.cpp         # O 常量折叠（O-01…O-37，parser 已接入折叠后新增）
   └─ test_parser_depth.cpp        # 嵌套深度上限（独立进程，B-02…B-04）
```

> **为什么不并进 `test_lexer`**：深嵌套用例要构造上万 token 的输入，一个二进制里跑崩了会连带
> lexer 的结论全部看不到；独立 `test_parser` / `test_parser_depth` 能让 `ctest` 分别报告成败。
> 加 `maxDepth` 之前这几条是真的栈溢出崩溃点（PD-13/PD-13b），现在不崩了，但「超限后是否
> 干净地停」仍值得独立验证。

### 4.2 `test_common.hpp` 增量扩展

复用现有 `g_total / g_failed / g_known / g_flip`、`check()`、`knownCheck()`、`section()`，
新增（全部 `inline`，遵守 header-only ODR 约束，见 `development.md` §3 与 lexer 计划 §10.3）：

> **`check()` 的第三参已放宽成 `const std::string&`**（2026-10-16）：原来是 `const char*`，
> `check(ok, id, "stack size == " + to_string(n), detail)` 这类拼接传不进去。`test_compiler.cpp`
> 依赖它；对既有的字符串字面量调用点完全兼容。

```cpp
struct ParseResult {
  std::shared_ptr<const std::u16string> src;  // 持有输入，保证 lexeme 有效
  AST::Prog prog;
  std::vector<std::string> errors;            // parser.errors
  std::vector<std::string> lexErrors;         // lexer.errors（PD-14：两者不合并）
  CustomOpcodeConfig* cfg = nullptr;
  size_t stmts() const { return prog.stmts.size(); }
};

// 一次解析到底。输入按值传入，由 shared_ptr 持有（Token::lexeme 是 string_view）。
// fold=false 关掉常量折叠（Parser::constFolding），用于锁定未折叠的树形（P 组、L-02）。
inline ParseResult parseAll(std::u16string src,
                            CustomOpcodeConfig* cfg = nullptr,
                            bool fold = true) {
  auto holder = std::make_shared<std::u16string>(std::move(src));
  ParseResult r; r.src = holder; r.cfg = cfg;
  Lexer lx(*holder);
  Parser p(lx, cfg);   // config 经构造函数传入（PD-3 已修：构造体内两次 nextToken() 已拿到）
  p.constFolding = fold;
  p.ParseProgram(r.prog);
  r.errors = p.errors;
  r.lexErrors = lx.errors;
  return r;
}

inline bool pHasErr(const ParseResult& r, const std::string& sub);   // 查 parser.errors
inline bool pHasErrAny(const ParseResult& r, const std::string& sub); // parser + lexer 都查

// ---- AST 断言（实际实现：形状序列化，一条断言锁定整棵子树） ----
// shapeExpr/shapeStmt/shapeProg 把树序列化成紧凑字符串，如
//   Bin(Add, Int(1), Bin(Mul, Int(2), Int(3))) / Call(Ident(f); Int(1); Int(2))
//   Custom(myop; Int(1)) / At(Ident(a); Int(1)) / Args(null) / Err(L-1)
//   Let[a]=Int(1) / If(c){...}Elif(c){...}Else{...} / While(c?){...}
// 断言失败时打印实际形状（比"期望 X 实际 Y"好定位）。
inline std::string shapeExpr(const AST::Expr* e);
inline std::string shapeStmt(const AST::Stmt* s);
inline std::string shapeProg(const AST::Prog& p);
#define EXPECT_PSTMTS(r, N, id) ...        // prog.stmts.size()
#define EXPECT_PSTMT(r, I, TYPE, id) ...   // 第 I 条语句的 NodeType
#define EXPECT_PEXPR(r, I, TYPE, id) ...   // 第 I 条是 ExprStmt 且 expr 类型匹配
#define EXPECT_PLINE(r, I, N, id) ...      // 第 I 条语句的 line
#define EXPECT_PSTMT_SHAPE(r, I, SH, id) ...
#define EXPECT_PROG_SHAPE(r, SH, id) ...
#define EXPECT_PERR_COUNT(r, N, id) ...    // 注意 PD-5：按去重后期望值写
#define EXPECT_PERR_HAS(r, SUB, id) ...    // parser.errors
#define EXPECT_PERR_ANY(r, SUB, id) ...    // parser + lexer.errors
```

> parser 断言宏一律 `EXPECT_P` 前缀：与 lexer 的 `EXPECT_*` 宏区分（两者共用
> `test_common.hpp`，重名会冲突）。`KNOWN(defect, cond, id)` 宏共用。

### 4.3 CMake 接入（已落地）

```cmake
add_executable(test_parser
    test/test_parser.cpp
    test/test_parser_stmt.cpp   test/test_parser_expr.cpp
    test/test_parser_prec.cpp   test/test_parser_postfix.cpp
    test/test_parser_custom.cpp test/test_parser_flow.cpp)
target_include_directories(test_parser PRIVATE stope)
add_test(NAME parser COMMAND test_parser)
set_tests_properties(parser PROPERTIES TIMEOUT 120)   # 死循环兜底，见 §10 第 3 条

add_executable(test_parser_depth test/test_parser_depth.cpp)
# 9 组深度用例：目标名就是判据（ok / deep 由二进制自己断言），见 §5.8
```

- `test_lexer` 目标保持不动。
- MSVC 保留 `/utf-8`；GCC/Clang 加 `-Wall -Wextra`。
  **PD-1 修复后 `parser.hpp` 已无 `-Wreturn-type` 告警**；现存告警全部来自 `lexer.hpp`
  的 `-Wsign-compare`（`int length` 与 `string_view::size()` 比较，属 lexer 计划已知项）。

---

## 5. 用例清单

约定：`OK`=当前行为正确（必须永远通过）；`KNOWN`=按 PD-x 标记为已知失败。
ID 前缀：`S` 语句 / `X` 表达式 / `P` 优先级 / `F` 后缀与前缀 / `K` 自定义指令 / `L` 行号 /
`R` 错误恢复 / `B` 健壮性与内存。共 129 个用例（S45 + X13 + P20 + F18 + K12 + L5 + R7 + B10；
其中 K-12 是 PD-3 的绕坑对照，故 K 组计 12 个）。
测试代码全部落地于 `cpp/test/`，计划文档统一收在 `cpp/docs/`；`ctest` 全绿
（当前 15 项：lexer + parser + compiler + stml + ast_visitor + vm + 9 组深度用例）。

### 5.1 语句层（test_parser_stmt.cpp，S-01…S-45）

| ID | 输入 | 预期 | 性质 |
| --- | --- | --- | --- |
| S-01 | `""` | `Prog(n=0)`，errors=0 | OK |
| S-02 | `;;;` | `Prog(n=0)`，errors=0 | OK |
| S-03 | `let a;` | `LetStmt idents=[a] hasAssign=0` | OK |
| S-04 | `let a = 1;` | `hasAssign=1`，`expr=Int(1)` | OK |
| S-05 | `let a, b, c;` | `idents=[a,b,c]` | OK |
| S-06 | `let a, b = 1;` | `idents=[a,b]`，`hasAssign=0`，errors=**2**（PD-5 除去重后 `=` 与 `1` 各报一次） | OK（固化 PD-4 同族） |
| S-07 | `let 1;` | `LetStmt idents=[]` + `expected identifier after "let".` | OK |
| S-08 | `let`（EOF） | 同上，**不挂死** | OK |
| S-09 | `let a, b`（缺 `;`） | `expected ";" in let statement.`，不挂死、不吃 `}` | OK（约定 1） |
| S-10 | `{ let a, b } x;` | 报缺 `;`，块闭合，`x;` 保留为第 2 条 | OK（约定 1） |
| S-11 | `export a;` / `export a, b;` | `idents=[a]` / `[a,b]` | OK |
| S-12 | `export a = 1;` | `ExportStmt[a]` + `ExprStmt[1]` + 1 error | OK |
| S-13 | `export ;` / `export` | `expected identifier after "export".`，不挂死 | OK |
| S-14 | `return;` | `exprs=0`，errors=0 | OK |
| S-15 | `return 1;` / `return 1, 2, 3;` | `exprs=1` / `3` | OK |
| S-16 | `return`（EOF） | `expected ";" in return statement.`，exprs=0 | OK |
| S-17 | `return x; y;` | **2 条语句，0 errors**（`return x;` 合法） | OK |
| S-18 | `return 1 2;` | 1 error，`2` 被吞（`parseReturnStmt` 兜底分支仍 `nextToken()`，属 §2.2 约定 2 的"反例"） | OK |
| S-19 | `{ a; b; }` / `{}` / `{ { a; } b; }` | 嵌套 BlockStmt 正确 | OK |
| S-20 | `{ a;` / `{ a; x;` | `expected "}" at end of block statement.`，不挂死 | OK |
| S-21 | `} x;` / `a; } b;` / `} } x;` | 顶层 `}` 报 `unexpected "}" at top level. ` 并**跳过继续解析**：`} x;` → 1 error + `x;`；`a; } b;` → 1 error + 2 stmts；`} } x;` → 2 errors。对照组 `{ a; } b;` 仍 0 errors（块内 `}` 由块自己消费） | OK（PD-6 已修 2026-10-16） |
| S-22 | `if a { b; }` | `elifs=0 hasElse=0` | OK |
| S-23 | `if a { b; } elif c { d; } else { e; }` | `elifs=1 hasElse=1`，三段内容正确 | OK |
| S-24 | `if a { b; } elif c { d; } elif e { f; }` | `elifs=2` | OK |
| S-25 | `if a { } else { }` | 两个空 `Prog(n=0)`，errors=0 | OK |
| S-26 | `if a b;` | 1 error，`If(a){}` + `b;` 独立成语句（stmts=2） | OK（PD-4b 已修） |
| S-27 | `if a { b; c;` | `expected "}" in if statement.`，块内 2 条 | OK |
| S-28 | `if a { b; } elif c d;` | `expected "{" of elif.`，`d;` 独立成语句（stmts=2） | OK（PD-4b 已修） |
| S-29 | `if a { b; } else c;` | `expected "{" after else.`，`c;` 独立成语句（stmts=2） | OK（PD-4b 已修） |
| S-30 | `while a { b; }` | `cond=Ident a` | OK |
| S-31 | `while { b; }` | **`cond` 为空**，errors=0 | OK（文法 `expr?`） |
| S-32 | `while a b;` | `expected "{" in while statement.`，`b;` 独立成语句（stmts=2） | OK（PD-4b 已修） |
| S-33 | `while a { b;` | `expected "}" at end of while statement.` | OK |
| S-34 | `while {} x;` | 2 条语句（`x;` 不被吞） | OK（2026-10-15 修复的回归保护） |
| S-35 | `break;` / `continue;` | 0 errors | OK |
| S-36 | `break x;` / `continue x;` | 1 error，`x;` 独立成语句（stmts=2：`Break`/`Continue` + `ExprStmt(Ident x)`） | OK（PD-4 已修） |
| S-37 | `break`（EOF） | 1 error，不挂死 | OK |
| S-38 | `a;` | `ExprStmt(Ident a)` | OK |
| S-39 | `a = 1;` | `AssignStmt(Ident a, Int 1)` | OK |
| S-40 | `a[0] = 1;` | 左值 `AtExpr` | OK |
| S-41 | `a = 1 b;` | `expected ";" at end of assign statement.` | OK |
| S-42 | `a = ;` | `rightExpr` 是裸 `Expr`（**line=-1**）；`AssignStmt.line` 取自左式 = 1 | KNOWN(PD-8)（只针对裸节点） |
| S-43 | `a = b = 1;` | `AssignStmt(a,b)` + `ExprStmt(1)` + 1 error | KNOWN(PD-9) |
| S-44 | `1 = 2;` / `f() = 1;` | **0 errors** | KNOWN(PD-10) 或标注"有意" |
| S-45 | `return; break; continue;`（顶层） | 3 条语句，0 errors | OK（记录：无语境检查） |

### 5.2 表达式与字面量（test_parser_expr.cpp，X-01…X-13）

| ID | 输入 | 预期 | 性质 |
| --- | --- | --- | --- |
| X-01 | `1; 1.5; "s"; 'x ff'; null; true; false; argc; a;` | 9 条 `ExprStmt`，类型依次 `Int/Float/Str/BinArr/Null/Bool/Bool/Argc/Ident` | OK |
| X-02 | `'x ff 0a';` | `BinArr n=2 [255,10]` | OK |
| X-03 | `'b 1010 1111';` | `[10,15]`（**每段一字节**） | OK |
| X-04 | `'';` | 0 字节，0 errors | OK |
| X-05 | `'x zz';` / `'b _';` | `BinArr n=0` + `invalid binary array.` | OK（`parse_binarr.hpp` 的回归） |
| X-06 | `"a\nb";` | `StringExpr.value` 含真实换行 | OK |
| X-07 | `let x = -a;` | `Unary(op=Sub, Ident a)` | OK |
| X-08 | `not a; !a;` | 两个 `Unary(op=Not)` | OK |
| X-09 | `- - a;` / `not not a;` | 一元可叠层 | OK |
| X-10 | `argc;` / `args[0];` | `Argc` / `Args(Int 0)` | OK |
| X-11 | `args[a + 1];` | `Args(BinOp Add)` | OK |
| X-12 | `args 0;` | `Args` 的 `keyExpr` 为 **null** + 1 error，`0;` 独立成语句（stmts=2） | OK（PD-4c 已修） |
| X-13 | `args[0;` | 1 error（缺 `]`） | OK |

### 5.3 优先级与结合性（test_parser_prec.cpp，P-01…P-20）

用 `dump()` 比对整棵树的形状，不看打印值。优先级期望来自 `ast.hpp` 的 `BinopPrecMap`。

> **本文件整体关闭常量折叠**：`parseAll(src, nullptr, false)`。
> P 组靠整数字面量验证树形，一旦折叠 `1 + 2 * 3` 会直接变成 `Int(7)`，
> 断言既失败也失去验优先级的意义。折叠后的期望见 §5.9 的 O 组。

| ID | 输入 | 预期树形状 | 性质 |
| --- | --- | --- | --- |
| P-01 | `1 + 2 * 3;` | `Add(1, Mul(2,3))` | OK |
| P-02 | `(1 + 2) * 3;` | `Mul(Add(1,2), 3)` | OK |
| P-03 | `1 * 2 + 3;` | `Add(Mul(1,2), 3)` | OK |
| P-04 | `1 - 2 - 3;` | `Sub(Sub(1,2),3)` 左结合 | OK |
| P-05 | `8 / 4 / 2;` | `Div(Div(8,4),2)` 左结合 | OK |
| P-06 | `2 ^ 3 ^ 2;` / `2 ^ 3 ^ 2 ^ 4;` | `Pow(2,Pow(3,2))` / `Pow(2,Pow(3,Pow(2,4)))` —— **项目规定 `^` 右结合**（2026-10-22 改），即规范行为 | OK |
| P-07 | `-2 ^ 2;` | `Pow(Unary(-,2),2)` | KNOWN(PD-18) 一元 `-` 优先级待项目定夺 |
| P-08 | `2 * 3 ^ 2;` | `Mul(2, Pow(3,2))` | OK |
| P-09 | `3 ^ 2 * 2;` | `Mul(Pow(3,2), 2)` | OK |
| P-10 | `a and b or c;` | `Or(And(a,b),c)` | OK |
| P-11 | `a or b and c;` | `Or(a, And(b,c))` | OK |
| P-12 | `a or b or c and d and e;` | `Or(Or(a,b), And(And(c,d),e))` | OK |
| P-13 | `1 == 2 != 3;` | `NE(EQ(1,2),3)` 左结合 | OK |
| P-14 | `1 < 2 < 3;` | `LT(LT(1,2),3)` 左结合 | OK |
| P-15 | `7 idiv 2 % 3;` | `Mod(IDiv(7,2),3)` 同级左结合 | OK |
| P-16 | `-a * b;` / `-(a * b);` | `Mul(Unary(-,a),b)` / `Unary(-,Mul(a,b))` | OK |
| P-17 | `not a and b;` | `And(Unary(not,a), b)` | OK |
| P-18 | `if a + 1 > 2 { b; }` | `cond = GT(Add(a,1),2)` | OK |
| P-19 | 15 个二元运算符逐个：`or and == != < <= > >= + - * / idiv % ^` | 每个都产生 `BinaryOpExpr` 且 `op` 字段正确 | OK |
| P-20 | 一元运算符逐个：`-` `!` `not` | 产生 `UnaryOpExpr`，`op` 为 `Sub`/`Not` | OK |

### 5.4 后缀与前缀：调用 / 索引 / 括号（test_parser_postfix.cpp，F-01…F-18）

| ID | 输入 | 预期 | 性质 |
| --- | --- | --- | --- |
| F-01 | `f();` | `Call args=0`，0 errors | OK |
| F-02 | `f(1);` / `f(1, 2, 3);` | args=1 / 3 | OK |
| F-03 | `f(a + 1, b * 2);` | 参数是完整表达式 | OK |
| F-04 | `f(g(1), h(2));` | 嵌套 `Call` | OK |
| F-05 | `f()();` | `Call(callee=Call(f))` | OK |
| F-06 | `f(a)(b)[c];` | `At(Call(Call(f,a),b),c)` | OK |
| F-07 | `a[];` | `At idx=0`，0 errors | OK |
| F-08 | `a[1];` / `a[1, 2];` | idx=1 / 2 | OK |
| F-09 | `a[b[1]];` / `a[1][2];` / `f(1)[2];` | 嵌套/链式 `At` | OK |
| F-10 | `-f(1);` / `- a[1];` | `Unary` 包 `Call` / `At`（后缀优先级高于一元） | OK |
| F-11 | `(1);` / `((2));` | 括号不产生节点 | OK |
| F-12 | `(1;` | **2 errors**（缺 `)` + 缺 `;`），**不吞 `;`** | OK（约定 1） |
| F-13 | `f(1;` | 1 error，不吞后续 token | OK（约定 1） |
| F-14 | `a[1;` | 1 error，不吞后续 token | OK（约定 1） |
| F-15 | `f(1, 2 x; y;` | 1 error（`expected ")".`）；`Call(f;1;2)` + `x;` + `y;` 三条语句 | OK（PD-4d 已修） |
| F-16 | `a[1, 2 x; y;` | 同上（`expected "]".`）；`At(a;1;2)` + `x;` + `y;` 三条语句 | OK（PD-4d 已修） |
| F-17 | `();` | 裸 `Expr`(line=1，PD-11 已修) + **3 errors**（无前缀解析函数 + 缺 `)` + 缺 `;`） | OK；残留 PD-8/PD-11b |
| F-18 | `let a = 1 +` / `f(1,` / `a[1,` / `(1 +` / `args[` / `a = ;` | 右操作数是裸 `Expr`，line=-1；errors 依次为 **1/3/3/3/3/2**（PD-5 除去重后级联错误全上报） | KNOWN(PD-8) |

### 5.5 自定义指令（test_parser_custom.cpp，K-01…K-10）

> **整组阻塞在 PD-1（SIGILL）**：任何含 `Custom` token 的输入都会让进程崩。
> 实现时先把每个用例包成独立子进程跑（或用 `KNOWN` 标记"当前崩溃"），
> 修好 PD-1 后再逐条放开。下面的"修复后预期"来自给 `parseCustomOpcodeExpr` 补 `return expr;` 后的实测。

| ID | 输入（注册 `myop`、`a:b`） | 当前 | 修复后预期 | 性质 |
| --- | --- | --- | --- | --- |
| K-01 | `x; myop(1, 2);` | `Custom(myop; Int(1); Int(2))`，0 errors | **OK**（PD-1/PD-2 已修，回归保护） |
| K-02 | `let x = myop(1, 2);` | `Let[x]=Custom(myop; Int(1); Int(2))`，0 errors | **OK**（回归保护） |
| K-03 | `f(myop(1,2));` | 外层 `Call` 的参数是 `Custom`，0 errors | **OK**（回归保护） |
| K-04 | `myop(1, 2);`（在输入最开头） | 识别为 `Custom(myop; Int(1); Int(2))`，0 errors | 同上 | OK（PD-3 已修） |
| K-05 | `;myop(1);` | 同上（第 2 个 token 也能识别，`Custom(myop; Int(1))`） | 同上 | OK（PD-3 已修） |
| K-06 | `myop(1;` / `x; myop(1;` | 两者都走 `Custom` 路径，均报 `expected ")".`，形状 `Custom(myop; Int(1))` | 同上 | OK（PD-3 已修） |
| K-07 | `myop 1;` / `x; myop 1;` | 两者都报 `expected "(" after custom opcode. `，形状 `Custom(myop)` | 同上 | OK（PD-3 已修） |
| K-08 | `other(1);`（未注册） | `Call(Ident other, [1])` | 同上 | OK |
| K-09 | `a:b(1);`（命名空间名） | 开头与 `x; a:b(1);` 都识别为 `Custom(a:b; Int(1))`，0 errors | 同上 | OK（PD-3 已修） |
| K-10 | `customOpcodeConfig = nullptr` | `myop(1,2)` → 普通 `Call` | 同上 | OK |
| K-11 | `x; myop();`（空参数表） | `Custom(myop)`，**0 errors**（对照组 `x; f();` 0 errors） | 同左 | OK（PD-17 已修） |
| K-12 | `x; myop(1, 2, 3);` / `a; if myop(1) { b; }` / `x; myop(1)(2);` / `x; a[myop(1)];` | 参数个数不校验；可作条件、可链式调用 | 同上 | OK |

### 5.6 行号与位置（test_parser_flow.cpp，L-01…L-05）

| ID | 输入 | 预期 | 性质 |
| --- | --- | --- | --- |
| L-01 | `let a = 1;` | 所有节点 `line=1` | OK |
| L-02 | `1 +\n2;\na;` | `Int(L1)`、`Int(L2)`、`ExprStmt(L3)` | OK |
| L-03 | `if a\n{ b; }` | `IfStmt.line=1`，`cond.line=1` | OK |
| L-04 | 错误行号：`a\n@` | parser 报错行号与 token 行号一致 | OK |
| L-05 | 失败表达式的 `line` | 裸 `Expr` 的 `line = -1`，且外层 `ExprStmt.line` 也被带成 -1 | KNOWN(PD-8) |

### 5.7 错误恢复（test_parser_flow.cpp，R-01…R-07）

| ID | 场景 | 预期 | 性质 |
| --- | --- | --- | --- |
| R-01 | 34 处 `error()` 调用点，可达的 33 处每个至少触发一次 | 文案逐条与 §3/§5 表格一致 | OK |
| R-02 | `'x zz'; 'b _';`（同行两错） | errors=**2** | OK（PD-5 已修） |
| R-03 | `'x zz';\n'b _';`（分两行） | errors=2 | OK |
| R-04 | `(1;`（同行两处错误） | errors=**2** | OK（PD-5 已修） |
| R-05 | `let 1; let 2;` | errors=**2** | OK（PD-5 已修） |
| R-06 | `@ a;` | `lexer.errors=1` + `parser.errors=`**2**，**两者不合并** | KNOWN(PD-14) |
| R-07 | 每条错误后都必须能继续走到 `Eof` | 不得死循环（`parseAll` 加迭代/递归上限兜底） | OK（硬性） |

### 5.8 健壮性与内存（test_parser_flow.cpp，B-01…B-10）

| ID | 场景 | 预期 | 性质 |
| --- | --- | --- | --- |
| B-01 | 11 组合法程序 × 全部前缀（实测 166 个） | 0 挂起、0 崩溃、0 异常；语句数 ≤ 前缀长度 | OK（硬性） |
| B-02 | `((((a))))` 10000 层 | 报 1 条 `nesting too deep (max 256). `，解析+析构都不崩 | OK（2026-10-30 限额后） |
| B-02b | `((((a))))` 200 层 | 限额内照常解析：1 条 `ExprStmt(Ident(a))`、0 错误 | OK |
| B-03 | `((((a))))` 11000 / 12000 层 | 同 B-02（限额前 12000 崩在解析阶段） | OK |
| B-04 | `{{{{a;}}}}` 4000 / 5000 层 | 同 B-02（限额前 5000 崩在析构阶段） | OK |
| B-05 | `----a` 9000 / 10000 层 | 同 B-02（无限额时这类递归**没有括号**，只数括号挡不住） | OK |
| B-06 | `a[a[a[0]]]` 3000 / 5000 层 | 同 B-02 | OK |
| B-07 | 正确路径 8 例（`return 1,2;`、`f(g(1),2)[3];`、if/elif/else、`while{let x,y;}`、`a[0]=f(1,2);`、`'x ff 0a';` 等） | `new == delete` 配平 | OK |
| B-08 | 有 error 的输入（`break x;`、`a = ;`、`'x zz';`） | `delete = new + error条数` | KNOWN(PD-12) |
| B-09 | 同一个 `Lexer` / `Parser` 复用跑第二条输入 | 明确不支持，只断言"不崩" | OK（记录） |
| B-10 | 空输入 / 只有空白 / 只有注释 | `Prog(n=0)`，0 errors | OK |

### 5.9 常量折叠（test_parser_fold.cpp，O-01…O-36）

parser 侧只锁定「哪些 AST 会被折、折成什么」；**每一格的语义见
`cpp/docs/expr_optim.md` §4 行为矩阵**（那里是唯一的可调总表，§4.7 有格子→代码位置对照）。

| ID | 输入 | 折叠后 | 覆盖的规则 |
| --- | --- | --- | --- |
| O-01/02/03 | `1+2*3;` / `(1+2)*3;` / `2^3^2;` | `Int(7)` / `Int(9)` / `Int(512)` | 自底向上；`^` 右结合 |
| O-04/05/06/07 | `7/2;` / `8/4/2;` / `7 idiv 2 % 3;` / `7 % 2.5;` | `Float(3.5)` / `Int(1)` / `Int(0)` / `Float(2)` | 整除保 `Int`、`idiv` 向零、`%` 含浮点走 `fmod` |
| O-08 | `-2 ^ 2;` | `Int(4)` | 一元先折 |
| O-09/10 | `1==2!=3;` / `1<2<3;` | `Bin(NE, Bool(false), Int(3))` / `Bin(LT, Bool(true), Int(3))` | 内层折、外层跨类型停住（仍可见结合性） |
| O-11…13 | `"ab"+"cd";` / `"ab"*3;` / `3*"ab";` | `Str(abcd)` / `Str(ababab)` ×2 | 拼接、双向重复 |
| O-14/15/16 | `'x 41'+'x 42';` / `'x 41'*3;` / `"ab"*0;` | `BinArr[41,42]` / `BinArr[41,41,41]` / `Str()` | 字节连接、字节重复、0 次 |
| O-17…21 | `true+1;` / `true*2.5;` / `-true;` / `not true;` / `true==1;` | `Int(2)` / `Float(2.5)` / `Int(-1)` / `Bool(false)` / **不折** | Bool 当 0/1；`==` 仍按类型区分 |
| O-22…24c | `null+5;` / `null==null;` / `null*5;` / `null-5;` / `null!=5;` | **不折** / `Bool(true)` / **不折** / **不折** / `Bool(true)` | null 不参与算术（交给运行期报错）；`==` `!=` 只与 null 相等 |
| O-26 | `INT64_MAX+1;` | `Int(-9223372036854775808)` | 整数溢出不检查，按补码回绕 |
| O-25/27/28/29/29b/29c | `1/0;` / `1 idiv 2.0;` / `"ab"*-1;` / `0^-1;` / `"ab"*2.5;` / `2^(0-1);` | 前五个**不折**；`2^(0-1)` → `Float(0.5)` | 除零、含浮点 `idiv`、负次重复、非有限幂、非整数次；负指数走浮点 |
| O-30…33 | `x+1;` / `false and f();` / `a[1+2];` / `args[1+2];` | 前两条**不折**；后两条折成 `At(Ident(a); Int(3))` / `Args(Int(3))` | 副作用保护、子表达式照折 |
| O-34 | `1 +\n2;` | `Int(3)`，语句行号仍为 1 | 折叠节点的 `line` 沿用运算符节点 |
| O-35 | `1 + 2 * 3;` 开/关折叠 | `Int(7)` / `Bin(Add, Int(1), Bin(Mul, Int(2), Int(3)))` | 开关两种形态都成立 |
| O-36 | `1 + ;` 开/关折叠 | `errors.size()` 相同 | 折叠不影响错误计数 |

> 接入时踩到的两个坑（已处理，勿回退）：
> ① 把 `parseExpr` 包一层会让每层递归多一个常驻栈帧，实测打崩 B-02 的 10000 层括号；
>    折叠挂在 `parseUnaryOpExpr` / `parseBinaryOpExpr` 的构造末尾则不影响栈深度。
> ② L-02 里 `static_cast<const AST::BinaryOpExpr*>(es->expr.get())` 在折叠开启时是
>    未定义行为（那时是 `IntExpr`），已改为先判 `expr->type`。

---

## 6. 覆盖率与验收标准

| 指标 | 目标 | 度量方式 |
| --- | --- | --- |
| `AST::NodeType` 覆盖 | **26/26** 每个节点类型至少被 1 个用例产生（实测 `test_parser` 末尾自检通过） | 用例内统计"已产生类型集合"，`main` 末尾打印缺失项并判失败 |
| prefix 注册项覆盖 | **14/14**（Ident/Null/False/True/Integer/Float/String/BinArr/Argc/Sub/Not/LParen/Custom/Args） | 除 K-10（config 为 null 的对照例外）外，每个字面量/一元/括号/args 各 1 例；Custom 自 PD-1 修复后不再阻塞 |
| infix 注册项覆盖 | **17/17**（15 个二元运算符 + LParen + LBrack） | P-01…P-20 + F-01…F-18 |
| `error()` 调用点覆盖 | **34 处**：其中 33 处可达并各至少触发一次（PD-6 修复新增 `unexpected "}" at top level.`）；`parseExpr` 里的 `no infix parse function` 是死代码（while 条件保证 `peekPrecedence() > Lowest`，而 `BinopPrecMap` 与 `infixParseFns` 键完全一致，`.at()` 永不抛）——建议删除或改断言 | R-01 实测统计 |
| 语句类型覆盖 | **11/11**（Let/Export/Return/Block/If/While/Break/Continue/ExprStmt/AssignStmt + 空语句） | S 组 S-01…S-45 |
| 行覆盖率 | ≥ 90% | `gcov`（可选，本轮未跑） |
| 已知失败 | 全部挂 `KNOWN(PD-x)`，报告中单列 | 实测 16 个 KNOWN（PD-11 已翻转），见 §7 |
| 编译告警 | `-Wall -Wextra` 下 `parser.hpp` **零告警**（PD-1 修复后 `-Wreturn-type` 消失）；现存告警全部来自 `lexer.hpp` 的 `-Wsign-compare` | 构建日志 |
| 断言规模 | 实测 700 条断言 / 0 失败 / 16 KNOWN / 0 FIXED-PENDING-FLIP（v1.4 新增 O 组 74 条） | `test_parser.exe` 汇总行 |

**验收门槛**：所有 `OK` 用例 100% 通过；`KNOWN` 用例全部如实失败并在报告中列出；
无死循环、无崩溃（PD-1/PD-13 除外，它们本身就是崩溃项）、无 ASan/UBSan 报告。

---

## 7. 缺陷处理流程

1. 用例按**当前实际行为**写断言，缺陷项用 `KNOWN("PD-x", ...)` 包裹并写入期望值注释。
2. 报告末尾固定输出一段"已知问题"小节：`PD-1 … PD-18` 各自 PASS/FAIL/FIXED 状态。
3. 修好某个缺陷后：框架报 `FIXED-PENDING-FLIP`，把该断言翻成普通 `EXPECT_*`，
   并在本文档 §3 标记 `[已修 YYYY-MM-DD]`。
4. **剩余优先级建议**（2026-10-16 更新；PD-1/PD-2/PD-3/PD-4/PD-4b/PD-4c/PD-4d/PD-5/PD-6/
   PD-16/PD-17 已修，`^` 结合性已定为右结合）：
   PD-13/PD-13b（递归深度上限，会真崩）→ PD-12（`error()` 换掉 `stringstream` 即配平）
   → PD-8（panic-mode / 错误节点）→ PD-14（lexer/parser 错误不合并）
   → PD-9/PD-10/PD-11b/PD-18（需与参考实现对齐或项目定夺）→ PD-15（接口与资源）。

### 7.1 已修复记录（parser）

| 日期 | 缺陷 | 修复内容 |
| --- | --- | --- |
| 2026-10-15 | 中缀分发取错 token | `parseExpr` 的 `infixParseFns.at(peekToken().type)` → `nextToken()` 后用 `curToken()`；`1+2*3`、`f(1)`、`a[1]`、`(1+2)*3` 不再抛 `map::at` |
| 2026-10-15 | `parseWhileStmt` 漏跳 `}` | 结尾补 `nextToken()`；`while {} x;` 不再吞掉 `x;` |
| 2026-10-15 | `let`/`export` 多标识符循环 EOF 死循环 | 加 `Eof`/`RBrace` 出口分支，报 `expected ";"` 且不推进（确立约定 1） |
| 2026-10-15 | `return;` 不支持 | `parseReturnStmt` 支持空 `exprs`；缺 `;` 时报错且不吞 `}`/`Eof` |
| 2026-10-15 | 14 个 parse 函数返回类型不协变 | 统一改为 `AST::Expr*`，`prefixParseFns`/`infixParseFns` 可编译 |
| 2026-10-15 | `parseCallExpr`/`parseAtExpr` 整体错位一个 token | 重写为"进入时 cur 是 `(`/`[`"；空 `f()`/`a[]` 合法；缺 `)`/`]` 时不推进 |
| 2026-10-16 | `ArgsExpr::line` 恒为 -1 | `parseArgsExpr` 补 `expr->line = p.curToken().line` |
| 2026-10-16 | `parseBinaryArray` 空函数体 SIGILL + 结果全丢 + `stoi` 未捕获异常 | 重写 `parse_binarr.hpp`；4 个进制解析合并为 `parseByBase`/`parseInteger` + 4 个谓词；加 `try/catch` 与空串守卫；`'D 1 2'` 笔误修复 |
| 2026-10-16 | PD-1：custom 解析未初始读即 `jmp` → SIGILL | `parseCustomOpcodeExpr` 重写为"先 `nextToken()` 到 `(`，再逐个 `parseExpr(Lowest)` 填 args，缺 `)` 不推进"；K-01…K-12 转普通断言回归 |
| 2026-10-16 | PD-2：custom 参数表缺失 | 同一函数内补完整参数表解析（`expr` `,` `expr` 循环 + `RParen` 校验），副作用：`-Wreturn-type` 告警随之消失 |
| 2026-10-16 | PD-16：`parseDecicalInteger` 拼写错误 | 2026-10-16 方案 A 重构把 4 个 `parseXxxInteger` 合并为 `parseInteger(o, base, isDigit)`，拼写问题随之消解 |
| 2026-10-16 | PD-8 表述收窄（测试侧发现） | `AssignStmt.line` 实际取左式行（`a = ;` 时 line==1 而非 -1）；`-1` 只在 ExprStmt 失败路径传染。S-42/L-05 断言按实测改写，KNOWN 点移到"失败处不该返回裸 Expr" |
| 2026-10-16 | PD-3：输入开头两个 token 拿不到 config | `Parser(Lexer*)` → `Parser(Lexer*, CustomOpcodeConfig*)`；config 在两次 `nextToken()` **之前**赋值。K-04/K-05/K-06/K-07/K-09 的开头用例转为普通断言（由用户修复） |
| 2026-10-16 | PD-4：`break`/`continue` 错误路径吞 `x;` | `parseBreakStmt`/`parseContinueStmt` 的错误分支不再 `nextToken()`（`else` 才推进）；S-36 翻转为 stmts==2（由用户修复） |
| 2026-10-16 | PD-4b：`if`/`elif`/`else`/`while` 缺 `{` 吞语句 | 缺 `{` 分支只报错、直接 `return`，不推进；S-26/28/29/32 翻转为 stmts==2（由用户修复） |
| 2026-10-16 | PD-4c：`args 0;` 吞掉 `0;` | `parseArgsExpr` 改为**先看 `peekToken()`**：不是 `[` 就报错且不推进（等价于删掉那句可疑的 `nextToken()`）；X-12 翻转为 stmts==2 |
| 2026-10-16 | PD-4d：`f(1, 2 x; y;` 吞掉 `x;` | `parseExprOrAssignStmt` 的 `expected ";" or "="` 分支删掉 `nextToken()`，把越界的 token 留给下一轮语句解析；F-15/F-16 翻转为 stmts==3。配套：探针扫描 35 个对抗性输入确认无死循环/无崩溃 |
| 2026-10-16 | PD-17：`x; myop();` 空参数表误报缺 `;` | `parseCustomOpcodeExpr` 的收尾 `nextToken()` 移入 `else` 分支（空参数表停在 `)`）；K-11 翻转为 0 errors（由用户修复） |
| 2026-10-16 | 测试 harness 与 `parser.hpp` 新 API 脱节 | `test_common.hpp`：`AtExpr::indices` → `keyExprs`（2 处）、`Parser p(&lx); if (cfg) p.customOpcodeConfig = cfg;` → `Parser p(&lx, cfg);`；`test_parser_flow.cpp`、`test_parser_depth.cpp` 同步（否则整个目标编译不过） |
| 2026-10-16 | PD-5：`error()` 按行去重吞错 | `lastErrorLine` 成员与 `error()` 里的去重分支一并停用（保留注释形式）；同行每个错误都上报。连带把按旧基线写的条数断言整体上调：S-06 1→2、F-12 1→2、F-17 1→3、F-18b…e 1→3、F-18f 1→2、R-06 1→2；R-02/R-04/R-05 的 `KNOWN(PD-5)` 翻成普通断言（由用户修复） |
| 2026-10-16 | PD-6：顶层孤立 `}` 静默结束并丢弃后续语句 | `parseProg(prog)` → `parseProg(prog, isTopLevel)`：`ParseProgram` 传 `true`，块/if/elif/else/while 内的 6 处调用传 `false`。顶层遇 `}` 报 `unexpected "}" at top level. ` 并跳过继续解析（只 break 会丢语句、不推进会死循环）；块内 `}` 行为不变。S-21 翻转并加对照组 `{ a; } b;`；探针扫描 1024 组 `{ } a ;` 组合确认终止 |
| 2026-10-16 | PD-7：`^` 结合性 | **项目定夺为左结合**，当前实现即规范，缺陷关闭；P-06 翻为普通断言并加 `2^3^2^4` 三级锁定。残留的"一元 `-` vs `^`"拆出为 PD-18 继续挂 `KNOWN` |
| 2026-10-22 | PD-7 反转：`^` 改右结合 | 项目决定把 `^` 由左结合改为右结合（`2^3^2` ≡ `2^(3^2)`，与 Python/数学惯例一致，**偏离**参考实现）。实现：`parseBinaryOpExpr` 里 `if (expr->op == TokenType::Pow) prec = OpPrecedence(int(prec) - 1);` —— 右结合时把递归阈值由 `prec` 降为 `prec - 1`，**没有动 `parseExpr` 的 while**（`^` 是 `Pow = 7`，减一得 `AddSub = 6`，仍在合法枚举内）。连带翻转：P-06 两条形状、O-03 `Int(64)`→`Int(512)`。文档同步 8 处（`syntax-reference` / `syntax-intro` / `syntax-impl` §4.2/§5.3/§6.2/§10.1 / 两侧 parser 测试计划 / `expr_optim` / `compiler-test-plan` CM-27 栈深 2→3） |

---

## 8. 执行方式

```bash
cd cpp
cmake -B build
cmake --build build
ctest --test-dir build --output-on-failure     # 15 个用例全过（6 个模块 + 9 个深度用例）
./build/test_parser.exe                           # 708 断言 / 16 KNOWN / PASSED
```

MinGW 环境下若 make 报错（源码路径含非 ASCII 字符时 `mingw32-make` 无法处理），
改用 g++ 直接编译，产物同样落在 `build/`：

```bash
g++ -std=c++20 -Wall -Wextra -I stope -o build/test_parser.exe \
    test/test_parser.cpp test/test_parser_stmt.cpp \
    test/test_parser_expr.cpp test/test_parser_prec.cpp \
    test/test_parser_postfix.cpp test/test_parser_custom.cpp \
    test/test_parser_flow.cpp
./build/test_parser.exe
```

退出码约定（与 lexer 一致）：`0`=全部通过；`1`=有 `OK` 用例失败；
`2`=有 `FIXED-PENDING-FLIP`（提醒翻转）。

**深嵌套用例单独编译/单独跑**：`test/test_parser_depth.cpp` 是独立 main，
`test_parser_depth <paren|block|unary|at> <depth> <ok|deep>`，分两段打印
`PARSE-OK` / `DESTROY-OK`（历史上这两段用来区分崩在解析还是崩在析构，PD-13/PD-13b）。

判据在二进制里，不在 CMake 里：`ok` 要求 **0 条**错误，`deep` 要求**恰好 1 条**且含
`nesting too deep`。`CMakeLists.txt` 直接注册 9 组 `add_test`，不需要包装器（不再有崩溃要
"翻译"）。主二进制只跑 B-01/B-07…B-10。

---

## 9. 里程碑

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| M1 | 实测基线（AST 转储探针，覆盖语句/表达式/优先级/自定义/健壮性/内存） | ✅ 2026-10-16 完成 |
| M2 | `test_common.hpp` 扩展（`ParseResult`/`parseAll`/AST 断言宏）+ `test_parser` CMake 接入 | ✅ 2026-10-16 完成 |
| M3 | S 语句层用例（S-01…S-45） | ✅ 2026-10-16 完成 |
| M4 | P + F 优先级与后缀用例（P-01…P-20 / F-01…F-18） | ✅ 2026-10-16 完成 |
| M5 | L + R 行号与错误恢复用例（L-01…L-05 / R-01…R-07） | ✅ 2026-10-16 完成 |
| M6 | K 自定义指令用例（K-01…K-12） | ✅ 2026-10-16 完成（PD-1/PD-2 修复后解除阻塞） |
| M7 | B 健壮性与内存用例（B-01…B-10，含独立进程的深度探测） | ✅ 2026-10-16 完成 |
| M8 | 修复剩余 PD 并翻转断言 | ⏳ 进行中（PD-1/PD-2/PD-3/PD-4/PD-4b/PD-4c/PD-4d/PD-5/PD-6/PD-11/PD-16/PD-17 已修并翻转，PD-7 已定夺、PD-18 拆出待定；PD-8/PD-9/PD-10/PD-11b/PD-12/PD-13/PD-13b/PD-14/PD-15/PD-18 待修或待定） |

**本轮总验收**：`ctest --test-dir build` **15/15 通过**；`test_parser.exe`
708 断言 / 0 失败 / 16 KNOWN / 0 待翻转，`RESULT: PASSED`；lexer 未回归
（292 断言 / 0 失败）。

---

## 10. 风险与注意事项

1. **PD-1/PD-3 均已修**（2026-10-16）：含 `Custom` token 的输入不再 SIGILL；
   `customOpcodeConfig` 由构造函数注入，输入最开头的 custom 也能识别（K-04/K-05/K-09）。
2. **"错误恢复不吞 token"是 C++ 侧有意偏离参考实现**（见 §2.2 约定 2）：
   参考实现 `parse_break_stmt`/`parse_args_expr`/`parse_call_expr`/`parse_custom_inst`
   在出错后都会推进（吞掉后续 token）；C++ 侧改为不推进。改动 PD-4 家族时务必保持
   这一族的**一致性**，并同步更新 §5 的用例期望。若将来决定回归参考实现语义，
   需把 S-26/28/29/32、S-36、X-12、F-15/F-16、K-11 一起改回，并在本文档 §2.2 记录。
3. **`Token::lexeme` 是 `string_view`**：`parseAll()` 用 `shared_ptr` 持有输入副本，
   保证断言期间不悬垂（同 lexer 计划 §10.1）。`BinaryArrayParser` 内部也存 `input` string_view，
   `parseBinaryArray` 返回后 `BinArrExpr::value` 已是拷贝，安全。
4. **死循环风险**：历史上 `let`/`export` 在 EOF 上死循环过。`parseAll()` 需要递归/迭代上限兜底，
   并断言"一定能走到 `Eof`"。全前缀截断（B-01，166 例）是最有效的防回归手段。
   改 `parseExprOrAssignStmt`/`parseArgsExpr` 的错误分支时，"`parseExpr` 后必有一次 `nextToken()`"
   是防死循环的关键不变量，不要一并删掉。
4. **header-only ODR**：`test_common.hpp` 里任何非模板自由函数/命名空间变量必须 `inline`/`constexpr`，
   否则多 TU 链接报 `multiple definition`（`development.md` §3 与 lexer 计划 §10.3 已记录该坑）。
   另：`ast.hpp`/`parser.hpp` 与一切 std 头必须在 namespace **外**被 include，
   `namespace Stope::Test { #include <optional> }` 会直接编译失败。
5. **内存计量的坑（PD-12）**：重载全局 `operator new/delete` 时必须**同时重载 sized delete**
   （`delete(void*, size_t)`，C++14 起析构路径优先选它），否则计数永远不配平、得出假泄漏结论。
   还要：先跑一次预热排除 stdio/locale 的一次性分配；用**增量法**（窗口内 new/delete 之差）；
   输入 `u16string` 要在窗口外构造和析构，否则它的缓冲会被算进下一个窗口。
   PD-12 根因已定位（非双重释放）：`error()` 内 `std::stringstream` + `vector::emplace_back` 惯用法
   在该 MinGW 工具链上，stringstream 内部分配不经过可替换的全局 `operator new`（重载 new/new[] 均无记录），
   释放却走 `operator delete(void*, size_t)` → 每条 error 多计一次 delete。裸 string 增长与
   `std::to_string` 拼接实测配平，改用后者即可消除（B-08 恒等式 `delete == new + error条数`）。
6. **栈溢出阈值依赖栈大小**：PD-13/PD-13b 的数值（paren 12000 解析崩；block 5000 / unary 10000 /
   at 5000 析构崩）是 8 MB 栈下的实测值，换编译器/平台/链接选项（`-Wl,--stack`）会变。
   ctest 断言写"深度不超过 N 时成功 / 超过 M 时 crash"（`EXPECT=ok/crash`），不依赖具体退出数字——
   MinGW 下崩溃进程的 `RESULT_VARIABLE` 是字符串 `"Stack overflow"` 而非负数。
7. **错误条数基线已随 PD-5 变化**（2026-10-16）：`lastErrorLine` 去重停用后，同一行里的级联错误
   全部上报，条数整体上升（`F-17` 1→3、`F-18b…e` 1→3 …）。写 `EXPECT_PERR_COUNT` 时必须按**当前**
   实测值写；看到一批条数断言同时失败，先确认是不是这个基线变化，不要逐个"修"解析器。
   反向风险：若将来恢复按行去重，这批期望值要整体下调。
7b. **`parseProg` 带 `isTopLevel` 上下文**：顶层（`ParseProgram`）与块内（block/if/elif/else/while）
   对 `}` 的处理不同——前者报错并跳过，后者直接结束并交给外层消费。新增任何 prog 解析入口时
   必须显式传这个参数，默认值容易埋雷。
8. **深度用例不再依赖栈容量**（2026-10-30）：B-02…B-04 改由 `Parser::maxDepth`（默认 256）
   兜住 —— 超限报错、不崩，所以 `run_depth.cmake` 那套「把崩溃翻译成预期」的包装器已删除，
   `CMAKE_BUILD_TYPE` 也不再影响这几条用例。**改计数口径必须两侧同步**：`depth` 只在
   `parseExpr` / `parseProg` 两个递归入口 +1，线性下降（`parseProg → parseLetStmt → parseExpr`）
   原值传递，否则 `let a = 1;` 这类平铺代码会凭空吃掉好几层额度。
9. **与 GDScript 参考实现的语义差异**：本计划以"参考实现为准"标注期望（如 custom 参数表、
   错误不去重）。若项目决定采用 C++ 侧的宽松语义，需回来把对应 `KNOWN` 改成 `OK`
   并记录在本文档 §2.2。**项目已定夺的两条**：① `^` 为**右结合**（PD-7，
   2026-10-22 由左结合改；参考实现为左结合，属**有意偏离**）；
   ② 顶层孤立 `}` 要报错（PD-6 已修）——这一条**偏离**参考实现的
   `prog_end_tokens`（它静默结束），属有意偏离。
10. **测试不得依赖私有成员**：`curToken`/`peekToken`/`nextToken`/`error`/`tokens` 全是 private。
    若某条断言确实需要观察内部状态，应改为通过 public API 间接验证，或提请项目开放接口。
11. **`parseExpr` 里的 `no infix parse function` 是死代码**：永不可达（`while` 条件保证
    `peekPrecedence() > Lowest`，而 `BinopPrecMap` 与 `infixParseFns` 键完全一致，`.at()` 永不抛），
    所以 34 处 `error()` 调用点中只有 33 处可达；R-01 的"每处至少触发一次"目标对它不适用，
    建议删除（或改成不可达断言）。
