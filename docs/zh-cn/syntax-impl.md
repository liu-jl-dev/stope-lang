# Stope 语法实现说明

> **开发人员版** —— 面向要修改 `cpp/include/stope/` 下 Lexer / Parser / AST 的人。
>
> 三份文档的分工：
>
> | 文档 | 面向 | 内容 |
> | --- | --- | --- |
> | [syntax-intro.md](syntax-intro.md) | 第一次写 Stope | 最常用的规则，10 分钟读完 |
> | [syntax-reference.md](syntax-reference.md) | 写 Stope 的人 | 完整规则 + 边界情况 + 错误文案 |
> | **syntax-impl.md（本文）** | 改 Lexer / Parser 的人 | Token 表、优先级数值、AST、错误点清单、已知缺陷 |
>
> 本文只描述 **C++ 实现（`cpp/`）的现状**，含未修复缺陷与其编号（PD-x，与
> `cpp/docs/parser_test_plan.md`、`cpp/docs/lexer_test_plan.md` 中的编号一致）。
> 实测环境：g++ (MinGW-w64 x86_64-win32-seh) 15.2.0，`-std=c++20`，默认 8 MB 栈，2026-10-16。

## 目录

- [1. 源文件与职责](#1-源文件与职责)
- [2. 公共 API 与调用契约](#2-公共-api-与调用契约)
- [3. Token 全集](#3-token-全集)
- [4. 关键字与优先级](#4-关键字与优先级)
- [5. 分发表：prefix / infix](#5-分发表prefix--infix)
- [6. 递归结构与 token 缓冲](#6-递归结构与-token-缓冲)
- [7. AST 节点](#7-ast-节点)
  - [7.1 内存管理（RAII）](#71-内存管理raii)
  - [7.2 遍历骨架 ASTVisitor（继承它做解释器 / 检查器）](#72-遍历骨架-astvisitor继承它做解释器--检查器)
- [8. 错误文案全集](#8-错误文案全集)
- [9. 错误恢复约定](#9-错误恢复约定)
- [10. 已知缺陷清单](#10-已知缺陷清单)
- [11. 测试与验收](#11-测试与验收)
- [12. 改代码时的检查清单](#12-改代码时的检查清单)

---

## 1. 源文件与职责

| 文件 | 职责 | 备注 |
| --- | --- | --- |
| `cpp/include/stope/lexer.hpp` | 源码（`u16string_view`）→ Token 流 | 含关键字表、转义表、扫描数字/字符串/二进制数组 |
| `cpp/include/stope/token.hpp` | `TokenType`（47 个）、`Token`、`NumberValue` | — |
| `cpp/include/stope/common.hpp` | `OpPrecedence` 枚举、`Result` 枚举 | 优先级数值在此 |
| `cpp/include/stope/parser.hpp` | Token 流 → AST（Pratt / 递归下降） | 含全部 prefix/infix 分发表 |
| `cpp/include/stope/ast.hpp` | `NodeType`（28 个）与各节点结构 | header-only，节点不可拷贝 |
| `cpp/include/stope/parse_binarr.hpp` | 二进制数组字面量内容解析 | 被 `parser.hpp` 以 `parseBinaryArray` 挂进 prefix 表 |
| `cpp/include/stope/custom_opcode.hpp` | `CustomOpcodeConfig` / `CustomOpcode` | 宿主注册自定义指令 |
| `cpp/docs/development.md` | 布局 / 构建 / ODR / 行尾 / 文档约定 | 动 `cpp/` 前必读 |
| `cpp/docs/basic_vm.md` | 虚拟机的语义约定（句柄与引用计数、栈、宿主接口） | 动 VM 前必读 |
| `cpp/docs/quick-start.md` | 在 C++ 里嵌入 Stope 的四步（编译 → 装配 → State → 运行） | 配 `cpp/demo/01-quick-start.cpp` 食用 |
| `cpp/docs/custom-opcode.md` | 自定义指令：`CustomOpcodeConfig` → 编译 → `DumpProgram` 反汇编 | 配 `cpp/demo/02-custom-opcode.cpp` 食用 |
| `cpp/docs/stml.md` | STML 上手：回调决定内容怎么切，含 12 条语法注意事项 | 配 `cpp/demo/03-stml.cpp` 食用 |

参考实现（GDScript）：`gdscript/stope/stope_parser.gd`。C++ 侧有两处**有意偏离**，见 §9.3。

---

## 2. 公共 API 与调用契约

### 2.1 接口签名

```cpp
struct Lexer {
  std::u16string_view input;              // 必须指向调用方持有的、解析期间存活的缓冲
  std::vector<std::string> errors;        // 词法错误
  int line = 1;
  void NextToken(Token& token, const CustomOpcodeConfig* custom = nullptr);
};

struct Parser {
  Lexer* lexer;                            // 不拥有
  std::vector<std::string> errors;         // 语法错误
  Parser(Lexer& lexer, CustomOpcodeConfig* customOpcodeConfig = nullptr);
  void ParseProgram(AST::Prog& prog);
};

struct CustomOpcodeConfig {
  std::map<std::u16string, CustomOpcode> opcodes;
  Result addCustomOpcode(std::u16string& name, short opcode, short argNum = -1);
};                                          // argNum < 0 → 变长参数
```

**只有上面这些成员是 public。** `curToken()` / `peekToken()` / `nextToken()` / `error()` /
`tokens` / `customOpcodeConfig` / `binaryArrayParser` 全是 private，测试与调用方不得依赖。

### 2.2 标准调用序列

```cpp
CustomOpcodeConfig cfg;
std::u16string name = u"emit_even";
cfg.addCustomOpcode(name, /*opcode=*/100, /*argNum=*/2);

auto src = std::make_shared<std::u16string>(u"let a = 1; emit_even(a, 2);");
Lexer lx(*src);                 // 注意：view，src 必须活到解析结束
Parser p(lx, &cfg);              // config 必须在这里注入
AST::Prog prog;
p.ParseProgram(prog);

if (!lx.errors.empty() || !p.errors.empty()) { /* 分别检查，见 §10 PD-14 */ }
```

### 2.3 五个必须遵守的契约

| # | 契约 | 违反后果 |
| --- | --- | --- |
| 1 | **输入缓冲必须在整个解析 + AST 存活期内保持有效** | `Token::lexeme` 是 `u16string_view`，悬垂即未定义行为。`BinaryArrayParser` 内部也存 `input` view（`parseBinaryArray` 返回后 `BinArrExpr::value` 已是拷贝，安全） |
| 2 | **`CustomOpcodeConfig` 必须在构造 `Parser` 时注入** | 构造函数体在两次 `nextToken()` **之前**赋值 config；没有"构造后再设置"的入口（旧版有此缺陷，PD-3 已修）。输入最开头的自定义指令也能正确识别 |
| 3 | **`Parser` 构造即消费 2 个 token** | 构造完成后 `curToken()` 是第 1 个、`peekToken()` 是第 2 个。空输入也能安全构造 |
| 4 | **`lexer.errors` 与 `parser.errors` 不合并** | 调用方必须查两处（PD-14，未修） |
| 5 | **`ParseProgram` 返回 `void`** | 成败只能查 `errors`；且解析失败时 AST 可能是残缺但结构合法的树，不能只看 `prog.stmts.empty()` |

---

## 3. Token 全集

`TokenType` 共 **47** 个（`cpp/include/stope/token.hpp`）：

| 分组 | 成员 |
| --- | --- |
| 特殊 | `Invalid` `Eof` |
| 字面量 | `Integer` `Float` `String` `BinArr` |
| 名字 | `Ident` `Custom` |
| 分隔符 | `Comma` `Semi` `LParen` `RParen` `LBrack` `RBrack` `LBrace` `RBrace` |
| 算术 | `Assign` `Add` `Sub` `Mul` `Div` `IDiv` `Mod` `Pow` |
| 比较 | `EQ` `NE` `LT` `LE` `GT` `GE` |
| 逻辑 | `Not` `And` `Or` |
| 控制流 | `If` `Elif` `Else` `While` `Break` `Continue` `Return` |
| 声明 | `Let` `Export` |
| 字面量关键字 | `Null` `False` `True` |
| 参数 | `Args` `Argc` |

```cpp
struct Token {
  TokenType type;
  int line;                       // 1 起；遇 '\n' 递增，块注释与二进制数组内部换行同样计数
  std::u16string_view lexeme;     // 指向 Lexer::input，见契约 1
  std::u16string parsed;          // 字符串/标识符等的已解析值
  NumberValue numberValue;        // union { long long integer; double floating; }
};
```

> `NumberValue` 是 union，**靠 `type` 决定读哪个字段**，读错字段是未定义行为。

---

## 4. 关键字与优先级

### 4.1 关键字（18 个）

全部小写，**关键字优先于自定义指令名**（注册同名无效，返回 `DuplicateWithBuiltinOpcode`）。

| 类别 | 关键字 |
| --- | --- |
| 字面量 | `null` `false` `true` |
| 逻辑/算术 | `not`（= `!`）`and`（= `&&`）`or`（= `\|\|`）`idiv` |
| 控制流 | `if` `elif` `else` `while` `break` `continue` |
| 声明 | `let` `export` |
| 返回 | `return` |
| 参数 | `args` `argc` |

### 4.2 优先级枚举（`common.hpp`）

```cpp
enum class OpPrecedence : int {
  Lowest = 0, Or = 1, And = 2, Equals = 3, LessGreater = 4,
  AddSub = 5, MulDiv = 6, Pow = 7, Prefix = 8, Paren = 9,
};
```

| 级别 | 运算符 | 结合性 | 说明 |
| --- | --- | --- | --- |
| 1 `Or` | `or` `\|\|` | 左 | — |
| 2 `And` | `and` `&&` | 左 | — |
| 3 `Equals` | `==` `!=` | 左 | — |
| 4 `LessGreater` | `<` `<=` `>` `>=` | 左 | — |
| 5 `AddSub` | `+` `-` | 左 | — |
| 6 `MulDiv` | `*` `/` `idiv` `%` | 左 | — |
| 7 `Pow` | `^` | **右**（2026-10-22 项目定夺） | `2^3^2` == `2^(3^2)` |
| 8 `Prefix` | 一元 `-` `!` `not` | 前缀 | 高于 `Pow`，故 `-2^2` == `(-2)^2`（PD-18 待定） |
| 9 `Paren` | `f(...)` `a[...]` | 后缀 | 最高 |

---

## 5. 分发表：prefix / infix

```cpp
using PrefixParseFn = AST::Expr* (*)(Parser&);
using InfixParseFn  = AST::Expr* (*)(Parser&, AST::Expr* left);
```

### 5.1 prefix（14 项）

| Token | 处理函数 |
| --- | --- |
| `Ident` | `parseIdentExpr` |
| `Null` | `parseNullExpr` |
| `False` / `True` | `parseBoolExpr` |
| `Integer` | `parseIntExpr` |
| `Float` | `parseFloatExpr` |
| `String` | `parseStringExpr` |
| `BinArr` | `parseBinaryArray`（在 `parse_binarr.hpp`） |
| `Argc` | `parseArgcExpr` |
| `Sub` / `Not` | `parseUnaryOpExpr` |
| `LParen` | `parseParenExpr` |
| `Custom` | `parseCustomOpcodeExpr` |
| `Args` | `parseArgsExpr` |

### 5.2 infix（17 项）

| Token | 处理函数 |
| --- | --- |
| `Or` `And` `EQ` `NE` `LT` `LE` `GT` `GE` `Add` `Sub` `Mul` `Div` `IDiv` `Mod` `Pow` | `parseBinaryOpExpr`（15 个） |
| `LParen` | `parseCallExpr` |
| `LBrack` | `parseAtExpr` |

> `BinopPrecMap` 与 `infixParseFns` 的**键集合完全一致**，所以 `parseExpr` 里
> `infixParseFns.find(...) == end()` 分支（报 `no infix parse function for token type.`）
> 是**死代码**（`parser.hpp:358`）。同理 `prefixParseFns` 缺项那条（`:350`）**是活的**：
> `();`、`} x;` 等会走到它。

### 5.3 `parseExpr` 主体

```cpp
AST::Expr* parseExpr(OpPrecedence prec) {
  if (prefixParseFns.find(curToken().type) == end) { error(...); return new AST::Expr(); }
  AST::Expr* leftExpr = prefixParseFns.at(curToken().type)(*this);
  while (peekToken().type != TokenType::Semi && prec < peekPrecedence()) {
    if (infixParseFns.find(peekToken().type) == end) { error(...); return leftExpr; }  // 死代码
    nextToken();                                        // 运算符进入 curToken()
    leftExpr = infixParseFns.at(curToken().type)(*this, leftExpr);
  }
  return leftExpr;
}
```

两个易错点：
- 循环条件里的 `peekToken().type != Semi` 让 `;` 天然成为表达式终止符——**不要在 prefix/infix
  回调里手动判断 `;`**。
- `.at()` 用的是 `curToken()`（因为刚 `nextToken()` 过），早期版本误用 `peekToken()` 导致整体错位。

**结合性不在这个 while 里决定**，它取决于 infix 回调往右递归时传入的阈值（`parseBinaryOpExpr`）：

```cpp
expr->op = p.curToken().type;
OpPrecedence prec = p.curPrecedence();
// 右结合：优先级 -1（OpPrecedence 的取值连续，-1 就是低一级）
if (expr->op == TokenType::Pow) {
  prec = OpPrecedence(int(prec) - 1);
}
p.nextToken();
expr->rightExpr.reset(p.parseExpr(prec));
```

同一个阈值解释了两种形状：传 `prec` 时，`2^3^2` 右侧遇同级 `^` 会被
`prec < peekPrecedence()` 挡住，剩给外层 while 迭代 → **左嵌套** `(2^3)^2`；
传低一级时右侧继续吃同级 `^` → **右嵌套** `2^(3^2)`。
所以**改结合性改的是这里，不是 parseExpr 的循环**。
目前只有 `^` 走这条分支（写在 `parseBinaryOpExpr` 里，没有单独的结合性表）。
⚠ `int(prec) - 1` 依赖 `OpPrecedence` 的取值连续，且**结果必须落在合法枚举内**：
`^` 是 `Pow = 7`，减一得 `6`（`AddSub`）没问题；但若将来把某个运算符的优先级降到
`Lowest = 0` 又按右结合处理，就会产生 `-1` —— 枚举外的值，行为未定义。
新增右结合运算符时先确认它的 `OpPrecedence` 不是 `Lowest`。

---

## 6. 递归结构与 token 缓冲

### 6.1 token 环形缓冲

```cpp
std::array<Token, 2> tokens;   // 未零初始化，见 PD-15
int curTokenIdx = 0;
Token& curToken() { return tokens[curTokenIdx]; }
Token& peekToken() { return tokens[(curTokenIdx + 1) % 2]; }
void nextToken() { curTokenIdx = (curTokenIdx + 1) % 2;
                   lexer->NextToken(peekToken(), customOpcodeConfig); }
```

**"进入某 parse 函数时 cur 是什么"是各函数的隐式契约**，改动前先确认：

| 函数 | 进入时 cur |
| --- | --- |
| `parseCallExpr` / `parseAtExpr` | `(` / `[` |
| `parseCustomOpcodeExpr` | `Custom` token |
| `parseArgsExpr` | `args` 关键字 |
| `parseBinaryOpExpr` | 运算符本身 |
| `parseUnaryOpExpr` | `-` / `!` / `not` |

### 6.2 只有两个递归入口

| 入口 | 经由 | 深嵌套形态 |
| --- | --- | --- |
| `parseExpr` | 各 prefix/infix 回调内部再调 `parseExpr` | `((((a))))`、`----a`、`a[a[a[...]]]` |
| `parseProg` | `parseBlockStmt` / `parseIfStmt`（含 elif/else）/ `parseWhileStmt` | `{{{{a;}}}}` |

注意 `1+1+1+…` 这类左结合链**不递归**（`parseExpr` 的 while 是迭代的），所以加深限不会影响它。
但 `^` 自 2026-10-22 改为右结合后，`a^a^a^…` **每级一个 `parseExpr` 递归**（阈值降一级，
同级的 `^` 会进右侧子树），与嵌套括号一样吃栈——PD-13 的风险面多了一种形态。

**当前没有深度上限**（PD-13）。8 MB 栈实测阈值：

| 形态 | 通过 | 崩溃 |
| --- | --- | --- |
| 嵌套括号 | 11000 层 | 12000 层（**解析阶段**栈溢出） |
| 嵌套块 | 4000 层 | 5000 层（**析构阶段**崩） |
| 一元 `-` | 9000 层 | 10000 层（**析构阶段**崩） |
| 索引 `a[a[...]]` | 3000 层 | 5000 层（**析构阶段**崩） |

析构崩溃（PD-13b）容易漏：隐式析构链 `~Prog → ~BlockStmt → ~Prog` 同样递归，且**没有代码可改**。
修 PD-13 的推荐做法是给这两个入口加 RAII 深度守卫（上限建议 1000），AST 深度被限制后析构自然安全。

---

## 7. AST 节点

`NodeType` 共 **28** 个（`cpp/include/stope/ast.hpp`）：

| 分组 | 成员 |
| --- | --- |
| 基类 | `Node` `Prog` `Stmt` `Expr` |
| 语句 | `ExprStmt` `LetStmt` `ReturnStmt` `ExportStmt` `BlockStmt` `IfStmt` `WhileStmt` `AssignStmt` `BreakStmt` `ContinueStmt` |
| 表达式 | `NullExpr` `BoolExpr` `IntExpr` `FloatExpr` `BinArrExpr` `StringExpr` `IdentExpr` `ArgcExpr` `ArgsExpr` `UnaryOpExpr` `BinaryOpExpr` `CallExpr` `AtExpr` `CustomOpcodeExpr` |

约束（写测试或新增节点时必须知道）：

- **节点不可拷贝、不可移动**（`unique_ptr` 子成员 + 多态基类）。`IfStmtElif` 是纯数据块，
  不受此约束。
- 每个节点有 `type` 与 `line`；`line` 默认 `-1`，**解析失败处返回的裸 `AST::Expr` 就是 `-1`**
  （PD-8）。`AssignStmt.line` 取左式行，`LetStmt`/`ExportStmt` 取关键字行。
- `AtExpr` 的下标字段名是 **`keyExprs`**（早期叫 `indices`，已改名）。
- `Prog` **不是** `Stmt` 的子类，遍历节点时要单独分支（测试里 `collectNodeTypes` 踩过）。
  想省掉自己写分派，见 §7.2 的 `ASTVisitor`。
- AST 里所有 `std::` 头文件必须在 `namespace Stope` **之外** include，否则会报
  `expected class-name before '{'`。

### 7.1 内存管理（RAII）

- **`Node` 必须有 `virtual ~Node()`。** 没有它，按基类指针删除派生节点时派生部分
  不析构 → 泄漏。加上后 `sizeof(Node)` 从 8 变 16（vptr），
  8 个正确路径用例 `new == delete` **完全配平**（`parser_test_plan.md` 的 B 组锁住）。
- **成员层面天然 Rule of Zero**：子节点用 `std::vector<std::unique_ptr<...>>` 持有，
  不手写析构/拷贝；拷贝构造已被禁用。
- **使用约定**：用 `unique_ptr` 持有；**不按值传递**（按值会切掉派生部分）；
  `clone` 待补。
- 用全局 `operator new` / `delete` 计数做验证时，**必须同时重载 sized 版**
  `operator delete(void*, size_t)`，否则全部释放都走编译器默认的 sized delete，
  计数会被误判成「没释放」。`stringstream` 让计量不配平的那个坑见 §8.3。

### 7.2 遍历骨架 `ASTVisitor`（继承它做解释器 / 检查器）

`cpp/include/stope/ast_visitor.hpp` 把「按 `NodeType` 分派 + 默认递归子节点」抽成了一副
可复用的骨架，`Compiler` 就是它的第一个子类（`compiler.hpp`）。所以**想直接解释 AST
（`vm-guide.md` §2 的 B 路线），继承 `ASTVisitor` 比自己写 `switch(node->type)` 省事**：
分发表已经写全 26 个具体节点 + `Prog`，你只管填语义。

```cpp
struct Interp : ASTVisitor {              // 只需 public 继承 + override 钩子
  std::map<std::u16string, Value> vars;

 protected:                               // 钩子是 protected，override 保持 protected
  void onVisitLetStmt(AST::LetStmt* s) override {
    if (!s->hasAssign) {                  // let a; —— 只声明
      for (auto& n : s->idents) vars[n] = Value();
      return;
    }
    Visit(s->expr.get());                 // 要子表达式的值，就自己再下钻一次
    vars[s->idents[0]] = takeValue();
  }
  void onVisitIntExpr(AST::IntExpr* e) override { push(Value(e->value)); }
  void onVisitIdentExpr(AST::IdentExpr* e) override { push(lookup(e->ident)); }
  void onVisitBinaryOpExpr(AST::BinaryOpExpr* e) override {
    if (e->op == TokenType::Or || e->op == TokenType::And) {
      ASTVisitor::onVisitBinaryOpExpr(e);  // 短路交给基类 → 走 onVisitOrExpr/AndExpr
      return;
    }
    Visit(e->leftExpr.get());
    Value l = takeValue();
    Visit(e->rightExpr.get());
    Value r = takeValue();
    push(arithmetic(e->op, l, r));
  }
};
// 入口：传 AST::Prog& —— Visit 收的是 AST::Node*
AST::Prog tree;
parser.ParseProgram(tree);
Interp interp;
interp.Visit(&tree);
```

（上面是节选，`push` / `takeValue` / `Value` 是占位；完整可编译版本见本节末。）

四条必须知道的规矩：

| 规矩 | 说明 |
| --- | --- |
| **`Visit(AST::Node*)` 是唯一入口** | 没有 `visitProg(Prog&)` 这种便利重载了（`compiler.hpp` 开头记过这个坑）。`Prog` 不是 `Stmt`，它走 `visitMap` 里自己的表项 `onVisitProg` |
| **重写里不调基类版 = 不再下钻** | 基类 `onVisitXxx` 全部是「按源码顺序递归子节点」。要子节点的值就得自己 `Visit`（或先调基类），要语句的语义就别调 —— 于是**同一个钩子既能当遍历、又能当求值**，不需要两套代码 |
| **`onVisitOrExpr` / `onVisitAndExpr` 是为后端留的** | 基类 `onVisitBinaryOpExpr` 先分流 `or` / `and` 到这两个钩子，**默认实现会老老实实遍历两侧**（没有短路）。解释器想短路就只重写这两个；编译器不需要特判（它出 `If` / `GoTo`），所以没重写 |
| **`curLine` 在基类** | `visit()` 顺带更新，供没有专属行号的诊断用。子类**不要**再声明一个同名字段 —— 名字隐藏会让实际被更新的那个读不到（`Compiler` 踩过，见 `compiler_test_plan.md` §4.5） |

三个「骨架不管」的地方，实现时得自己记住：

- **`let a, b = 1;` 的语义。** `LetStmt` 是 `{hasAssign, idents, expr}`：`hasAssign == true` 时
  只有 `idents[0]` 拿到 `expr`，`idents` 里剩下的名字**没有初值**。骨架只提供字段，怎么定语义由你
  （`Compiler` 的做法也一样：只绑第一个名字）。
- **`Prog` 不是 `Stmt`。** `BlockStmt::prog` / `IfStmt::firstProg` / `WhileStmt::prog` 都是裸
  `Prog`，直接 `Visit(&block->prog)` 即可；`elseProg` 是 `std::optional<Prog>`，取 `&*s->elseProg`。
- **表达式结果的落点由你定。** 骨架没有任何「求值结果」的概念 —— 参考实现（`Compiler`）是往
  虚拟栈里写，解释器可以像上面的例子一样用一个 `std::vector<Value>` 当值栈。

**完整可编译的版本**（`Interp`：支持 `let` / 赋值 / 算术 / 变量 / 表达式语句，
变量用 `map<u16string, Value>`，求值结果压一个 `vector<Value>` 当值栈）：

```cpp
#include <iostream>
#include <map>
#include <string>
#include <variant>
#include <vector>

#include <stope/ast.hpp>
#include <stope/ast_visitor.hpp>
#include <stope/lexer.hpp>
#include <stope/parser.hpp>

using namespace Stope;

struct Value {
  std::variant<std::monostate, std::int64_t, double> v;  // monostate = null
  Value() = default;
  Value(std::int64_t i) : v(i) {}
  Value(double d) : v(d) {}
};

struct Interp : ASTVisitor {
  std::map<std::u16string, Value> vars;
  std::vector<Value> stack;

  void run(AST::Prog& p) { Visit(&p); }

 protected:
  void onVisitLetStmt(AST::LetStmt* s) override {
    if (!s->hasAssign) {
      for (auto& n : s->idents) vars[n] = Value();
      return;
    }
    Visit(s->expr.get());
    vars[s->idents[0]] = pop();
  }
  void onVisitAssignStmt(AST::AssignStmt* s) override {
    // 只有 Ident 左值；AtExpr 左值等你按需扩展
    auto* id = dynamic_cast<AST::IdentExpr*>(s->leftExpr.get());
    Visit(s->rightExpr.get());
    Value v = pop();
    if (id != nullptr) vars[id->ident] = v;
  }
  void onVisitExprStmt(AST::ExprStmt* s) override {
    Visit(s->expr.get());
    if (!stack.empty()) stack.pop_back();
  }
  void onVisitIntExpr(AST::IntExpr* e) override { stack.push_back(Value(e->value)); }
  void onVisitFloatExpr(AST::FloatExpr* e) override { stack.push_back(Value(e->value)); }
  void onVisitIdentExpr(AST::IdentExpr* e) override {
    auto it = vars.find(e->ident);
    stack.push_back(it == vars.end() ? Value() : it->second);
  }
  void onVisitBinaryOpExpr(AST::BinaryOpExpr* e) override {
    if (e->op == TokenType::Or || e->op == TokenType::And) {
      ASTVisitor::onVisitBinaryOpExpr(e);  // 交给基类走短路钩子
      return;
    }
    Visit(e->leftExpr.get());
    Value l = pop();
    Visit(e->rightExpr.get());
    stack.push_back(binary(e->op, l, pop()));
  }

 private:
  Value pop() {
    Value v = stack.back();
    stack.pop_back();
    return v;
  }
  static double num(const Value& v) {
    if (auto* i = std::get_if<std::int64_t>(&v.v)) return double(*i);
    if (auto* d = std::get_if<double>(&v.v)) return *d;
    return 0.0;  // null 参与算术：真实现要报错，见 vm-guide §8
  }
  Value binary(TokenType op, const Value& l, const Value& r) {
    switch (op) {
      case TokenType::Add: return Value(num(l) + num(r));
      case TokenType::Sub: return Value(num(l) - num(r));
      case TokenType::Mul: return Value(num(l) * num(r));
      case TokenType::Div: return Value(num(l) / num(r));
      default: return Value();  // 其余运算符留给读者
    }
  }
};

int main() {
  std::u16string src = u"let x = 1;\nlet y = x + 2.5;\ny = y * 2;\ny;";
  Lexer lexer(src);
  Parser parser(lexer);
  AST::Prog tree;
  parser.ParseProgram(tree);

  Interp interp;
  interp.run(tree);
  for (auto& kv : interp.vars) {
    if (auto* d = std::get_if<double>(&kv.second.v)) std::cout << "y = " << *d << "\n";
  }
}
```

实测输出：

```
y = 7
```

顺带一个**语义**提醒：上面这段故意把类型规则简化成了「都按 double 算」，只为演示骨架怎么用。
真正的实现要满足 `vm-guide.md` §8 的全部规则（整数 `/` 除不尽才转浮点、`null` 不参与算术、
整数溢出回绕、整数除零报错而浮点除零得 `inf` 等）—— 继承骨架省掉的只是遍历代码，不是语义功课。

---

## 8. 错误文案全集

错误文本统一形如 `line 3: expected ";". `（**结尾带一个空格**）。同一行的多个错误**全部上报，不去重**。

### 8.1 Parser（34 处调用点）

| 行 | 文案 | 触发示例 |
| --- | --- | --- |
| 40 | `unexpected "}" at top level. ` | `a; } b;`（PD-6 已修） |
| 78 | `expected identifier after "let". ` | `let 1;` |
| 100 | `expected ";" in let statement. ` | `let a, b` |
| 103 | `failed to parse let statement with multiple identifiers. ` | `let a, b = 1;` |
| 114 | `unexpected token in let statement. ` | `let a 1;` |
| 124 | `expected identifier after "export". ` | `export 1;` |
| 146 | `expected ";" in export statement. ` | `export a, b` |
| 149 | `failed to parse export statement with multiple identifiers. ` | `export a, b = 1;` |
| 155 | `unexpected token in export statement. ` | `export a = 1;` |
| 170 | `expected ";" in return statement. ` | `return 1 2;` |
| 186 | `expected ";" or "," in return statement. ` | `return 1 2 3;` |
| 199 | `expected "}" at end of block statement. ` | `{ a;` |
| 212 | `expected "{" in if statement. ` | `if a b;` |
| 218 | `expected "}" in if statement. ` | `if a { b;` |
| 230 | `expected "{" of elif. ` | `if a { } elif c d;` |
| 236 | `expected "}" of elif. ` | `elif c { d;` |
| 245 | `expected "{" after else. ` | `if a { } else c;` |
| 251 | `expected "}" in if statement. ` | else 分支缺 `}` |
| 267 | `expected "{" in while statement. ` | `while a b;` |
| 273 | `expected "}" at end of while statement. ` | `while a { b;` |
| 284 | `expected ";" in break statement. ` | `break x;` |
| 295 | `expected ";" in continue statement. ` | `continue x;` |
| 322 | `expected ";" at end of assign statement. ` | `a = b = 1;` |
| 326 | `expected ";" or "=". ` | `a b;` |
| 350 | `no prefix parse function for token type. ` | `();` |
| 358 | `no infix parse function for token type. ` | **死代码**，见 §5.2 |
| 428 | `invalid binary array. ` | `'x zz'` |
| 450 | `expected ")". ` | `(1;` |
| 460 | `expected "(" after custom opcode. ` | `x; myop 1;` |
| 474 | `expected ")". ` | `x; myop(1;` |
| 485 | `expected "[" after "args". ` | `args 0;` |
| 493 | `expected "]". ` | `args[1;` |
| 525 | `expected ")". ` | `f(1, 2 x;` |
| 545 | `expected "]". ` | `a[1, 2 x;` |

### 8.2 Lexer（9 处调用点 / 8 种文案）

| 行 | 文案 | 触发示例 |
| --- | --- | --- |
| 120 | `unknown token. ` | `&`、`|` 单独出现、`@` |
| 297 | `invalid integer. ` | `0b2`（`0b` 部分）、超大整数 |
| 309 | `invalid float. ` | `1e`、`1e+`、单独的 `.` |
| 326 | `unclosed binary array. ` | `'x 41` |
| 341 / 347 | `unclosed string literal. ` | `"abc`、字符串内换行 |
| 377 / 383 | `invalid escape character. ` | `"\q"`（并**停止处理余下内容**，字面量被截断） |
| 411 | `unclosed identifier. ` | `a:` |

### 8.3 `error()` 实现的一个坑

```cpp
void error(int line, const char* msg) {
  std::stringstream ss;              // ← PD-12：换成 std::to_string 拼接可配平
  ss << "line " << line << ": " << msg;
  errors.emplace_back(ss.str());
}
```

在 MinGW 该工具链上，`stringstream` 的内部分配**不经过**可替换的全局 `operator new`，
释放却走 sized `operator delete`，导致「重载 new/delete 计数」时 `delete == new + error 条数`
恒成立——看起来像泄漏，实际不是。测内存计量时要知道这一点（详见 `cpp/docs/parser_test_plan.md` §10 风险 5）。

---

## 9. 错误恢复约定

### 9.1 四条约定（`cpp/docs/parser_test_plan.md` §2.2 有同步记录）

1. **绝不推进 `Eof` 与块内的 `}`** —— 在 `Eof` 上 `nextToken()` 不前进会死循环；
   前进又会吞掉外层块的 `}`。
2. **分隔符（`;` `{` `[` `)` `]`）缺失时只报错、不推进 token**，让后续 token 作为独立语句
   重新解析。已按此实现：`parseBreakStmt`/`parseContinueStmt`、`parseIfStmt`/`parseWhileStmt`
   的缺 `{` 分支、`parseArgsExpr` 的缺 `[`、`parseCustomOpcodeExpr`、`parseExprOrAssignStmt`
   的错误分支。
3. **解析错误一律走返回值 / `errors`，不得让异常穿出解析层** ——
   `parse_binarr.hpp` 已按此加 `catch (...)`（对齐 `lexer.hpp:296`）。
4. **顶层孤立 `}` 是错误** —— `parseProg(prog, isTopLevel)`：只有 `ParseProgram` 传 `true`，
   块/if/elif/else/while 内部一律 `false`。顶层遇 `}` 报 `unexpected "}" at top level.` 并
   `nextToken(); continue;`（**必须推进**，否则死循环；只 `break` 会丢语句）。

### 9.2 有意保留的旧语义（不要顺手改）

- `parseLetStmt` / `parseReturnStmt` 的兜底分支**仍** `nextToken()` → `let a, b = 1;` 丢 `= 1`、
  `return 1 2;` 丢 `2`。这是已登记的行为基线（S-06 / S-18）。
- **不变量**：`parseExpr()` 之后必有一次 `nextToken()`。它是防死循环的关键，删错误分支的
  `nextToken()` 时不能连带删掉它。

### 9.3 与 GDScript 参考实现的差异（有意）

| 场景 | 参考实现 `stope_parser.gd` | C++ 实现 |
| --- | --- | --- |
| 出错后是否推进 token | `parse_break_stmt` / `parse_args_expr` / `parse_call_expr` / `parse_custom_inst` 等出错后都 `next_token()`（吞掉后续内容） | 只报错、不推进（约定 2） |
| 顶层孤立 `}` | `prog_end_tokens` 让解析静默结束，后续语句被丢弃 | 报错并跳过继续解析（约定 4） |

改动这两处会同时影响：本文档、`cpp/docs/parser_test_plan.md`、
`cpp/docs/parser_test_plan.md`、以及 S-26/28/29/32、S-36、X-12、F-15/16、K-11 这组断言。

---

## 10. 已知缺陷清单

编号与 `cpp/docs/parser_test_plan.md` §3 一致，测试里以 `KNOWN("PD-x", ...)` 挂起。

### 10.1 已修（回归保护，勿回退）

| 编号 | 内容 | 日期 |
| --- | --- | --- |
| PD-1 | 含 `Custom` token 的输入 SIGILL | 2026-10-16 |
| PD-2 | custom 参数表解析 | 2026-10-16 |
| PD-3 | config 只能在构造后设置 → 输入开头两个 token 拿不到 config | 2026-10-16 |
| PD-4 / 4b / 4c / 4d | 错误路径吞 token（`break x;`、`if a b;`、`args 0;`、`f(1, 2 x; y;`） | 2026-10-16 |
| PD-5 | `error()` 按 `lastErrorLine` 去重吞错（去重已停用） | 2026-10-16 |
| PD-6 | 顶层孤立 `}` 静默结束并丢弃后续语句 | 2026-10-16 |
| PD-16 | `ArgsExpr::line` 恒为 -1 | 2026-10-16 |
| PD-17 | `x; myop();` 空参数表误报缺 `;` | 2026-10-16 |
| PD-7 | `^` 结合性 —— 2026-10-16 定夺为左结合，**2026-10-22 改为右结合**（`2^3^2` ≡ `2^(3^2)`），机制见 §5.3 | 2026-10-22 |
### 10.2 未修 / 待定

| 编号 | 现象 | 建议 |
| --- | --- | --- |
| **PD-8** | 解析失败处返回裸 `AST::Expr`（`line == -1`），无 panic-mode | 引入错误节点或跳到下一个 `;` / `}`；与 §2.3 契约 5 一起设计 |
| **PD-13 / PD-13b** | 递归无深度上限，会**真崩**（解析阶段 / 析构阶段） | 给 `parseExpr` 与 `parseProg` 加 RAII 深度守卫（建议上限 1000），并在 `error()` 开头加 `if (depthAborted) return;` 防错误洪水 |
| **PD-12** | `error()` 里 `stringstream` 使内存计量不配平 | 换成 `std::to_string` 拼接 |
| **PD-14** | `lexer.errors` 与 `parser.errors` 不合并 | 调用方查两处，或提供合并接口 |
| **PD-15** | `std::array<Token,2> tokens` 未零初始化 | 加 `{}` 初始化 |
| **PD-9** | `a = b = 1;` 无法表达（赋值非表达式） | 与参考实现一致，记录为现状 |
| **PD-10** | `1 = 2;` **0 errors**，parser 不校验左值 | 明确交给语义分析，或 parser 报错 |
| **PD-11** ✅已修 | 失败节点 `line` 恒为 -1 并传染外层 `ExprStmt.line` | 已改为取 `curToken().line`（2026-10-16） |
| **PD-11b** | `();` → 裸 `Expr` + 3 errors；空括号不支持 | 明确报错或明确支持 |
| **PD-18** | `-2 ^ 2` == `(-2)^2`（一元 `-` 优先级高于 `^`） | 项目定夺：Python 是 `-(2^2)`，Excel 是 `(-2)^2`，参考实现与本实现一致 |

---

## 11. 测试与验收

### 11.1 怎么跑

```bash
cd cpp
cmake -B build && cmake --build build
ctest --test-dir build                 # 10/10
./build/test_parser.exe                # 主用例
./build/test_lexer.exe
```

产物直接落在 `cpp/build/`（不是 `build/test/`）。

**深嵌套用例必须独立进程跑**（PD-13 会真崩）：

```bash
./build/test_parser_depth.exe <paren|block|unary|at> <depth>
```

ctest 经 `cpp/test/run_depth.cmake` 包装，用 `EXPECT=crash|ok` 登记（`WILL_FAIL` 不反转
段错误判定；MinGW 下崩溃进程的 `RESULT_VARIABLE` 是字符串 `"Stack overflow"`，包装器用正则
`^-?[0-9]+$` 判别是否为数字退出码）。

### 11.2 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 全部通过 |
| 1 | 有 `OK` 用例失败 |
| 2 | 有 `FIXED-PENDING-FLIP`（缺陷已修，需把 `KNOWN` 翻成普通断言） |

### 11.3 当前规模（2026-10-16）

| 项 | 值 |
| --- | --- |
| `test_parser` | 626 断言 / 0 失败 / 16 KNOWN / 0 待翻转 / PASSED |
| `test_lexer` | 292 断言 / 0 失败 / PASSED |
| `ctest` | 10/10 |
| NodeType 覆盖 | 26/26（parser 用例实际产生的类型） |
| 编译告警 | `parser.hpp` 在 `-Wall -Wextra` 下零告警；现存告警来自 `lexer.hpp` 的 `-Wsign-compare` |

### 11.4 测试文件布局

| 文件 | 内容 |
| --- | --- |
| `test/test_common.hpp` | `ParseResult` / `parseAll` / AST shape DSL 序列化 / `EXPECT_P*` 宏（前缀 P 避免与 lexer 的 `EXPECT_*` 冲突） |
| `test/test_parser.cpp` | 入口 + NodeType 覆盖自检 + 已知问题清单打印 |
| `test/test_parser_stmt.cpp` | `S-01…S-45` 语句 |
| `test/test_parser_expr.cpp` | `X-01…X-13` 字面量 / 一元 / args |
| `test/test_parser_prec.cpp` | `P-01…P-20` 优先级 |
| `test/test_parser_postfix.cpp` | `F-01…F-18` 调用 / 索引 / 错误恢复 |
| `test/test_parser_custom.cpp` | `K-01…K-12` 自定义指令 |
| `test/test_parser_flow.cpp` | `L/R/B` 行号 / 错误恢复 / 健壮性与内存 |
| `test/test_parser_depth.cpp` | 独立进程深度探针（打印 `PARSE-OK` / `DESTROY-OK` 两段） |
| `test/run_depth.cmake` | ctest 包装器 |

---

## 12. 改代码时的检查清单

1. **改了 `parser.hpp` 的公共 API 就先 `cmake --build build` 一次** —— 测试 harness 直接引用它，
   否则整个测试目标编译不过（踩过：`AtExpr::indices` → `keyExprs`、构造函数加 config 参数）。
2. **动了错误路径的 `nextToken()`** → 先确认没破坏 §9.1 约定 1 与 §9.2 的不变量，再跑
   B-01（全前缀截断，166 例）验证不挂死。
3. **加了/改了 `error()` 调用点** → 同步更新 §8 的表、`cpp/docs/parser_test_plan.md` 的 R-01 与 §6 覆盖统计。
4. **修好某个 PD** → 框架会报 `FIXED-PENDING-FLIP`（退出码 2）；把 `KNOWN` 翻成普通断言，
   并在 `cpp/docs/parser_test_plan.md` §3 标 `[已修 YYYY-MM-DD]`、§7.1 补一行记录。
5. **改了语义** → 三份文档一起更新：`syntax-intro.md`、`syntax-reference.md`、本文，
   外加 `cpp/docs/parser_test_plan.md` §2.2。
6. **新增 AST 节点** → 同步 `test_common.hpp` 的 `nodeName()` 与 shape 序列化，否则
   NodeType 覆盖自检会失败。
7. **header-only ODR** → `test_common.hpp` 里所有自由函数/命名空间变量必须 `inline` 或
   `constexpr`，否则多 TU 链接报 `multiple definition`。
