# Stope 语法分析通用测试计划

> **跨实现的行为契约** —— 不绑定任何一门语言。C++ 与 GDScript 两套实现都按本文件验证。
>
> | 通用测试计划 | 覆盖范围 | C++ 侧 | GDScript 侧 |
> | --- | --- | --- | --- |
> | [lexer-test-plan.md](lexer-test-plan.md) | 字符流 → Token 流 | `cpp/include/stope/lexer.hpp` | `gdscript/stope/stope_token.gd` |
> | **parser-test-plan.md（本文）** | Token 流 → AST | `cpp/include/stope/parser.hpp` | `gdscript/stope/stope_parser.gd` |
> | [compiler-test-plan.md](compiler-test-plan.md) | AST → Program | `cpp/include/stope/compiler.hpp` | `gdscript/stope/stope_compiler.gd` |
| [stml-test-plan.md](stml-test-plan.md) | STML 文本 → 元素树 | `cpp/include/stope/stml_lexer.hpp` + `cpp/include/stope/stml_parser.hpp` | `gdscript/stope/stml_lexer.gd` + `gdscript/stope/stml_parser.gd` |
>
> **权威实现：C++。** 两侧分歧以 `cpp/include/stope/parser.hpp` 的实测行为为准。
>
> **本文所有期望值都是机器生成的**：由桥接 `cpp/include/stope/parser.hpp` 与
> `cpp/test/test_common.hpp::shapeProg()` 的探针实测导出（2026-10-18），不是手推的。
> 面向语言的规格见 [syntax-reference.md](syntax-reference.md)；C++ 侧实现笔记与缺陷流水见
> `cpp/docs/parser_test_plan.md`。

## 目录

- [1. 目标与非目标](#1-目标与非目标)
- [2. 通用契约：AST 形状串](#2-通用契约ast-形状串)
- [3. 行为基线](#3-行为基线)
- [4. 用例清单](#4-用例清单)
- [5. 验收标准](#5-验收标准)
- [6. 执行方式](#6-执行方式)
- [7. 已知差异登记](#7-已知差异登记)

---

## 1. 目标与非目标

**目标**

1. 定义一套**与实现语言无关**的 AST 序列化格式（§2），让两套实现能产出逐字符可比较的输出。
2. 逐条钉住：语句形状、运算符优先级与结合性、错误文案、**错误恢复的确切停位**。
3. 常量折叠的开关与效果。

**非目标**

- 不测试 Token 怎么来（见词法计划）。脏 Token（`Invalid`）进入表达式时只承诺「报一条错、不停机」。
- 不测试 AST → 指令（见编译器计划）。
- 不做性能基准，只做嵌套深度下限（§4 B 组）。

---

## 2. 通用契约：AST 形状串

两侧测试都必须能把一棵 AST 序列化成下面的文本。**同一份输入必须产出同一串字符。**
这套格式就是 C++ 侧 `cpp/test/test_common.hpp` 里 `shapeProg()` 的输出。

### 2.1 顶层

一条 Prog 的语句按 `" ; "` 连接，**没有外层包装**。空 Prog 输出空串。

### 2.2 各节点的写法

| 节点 | 形状串 | 备注 |
| --- | --- | --- |
| 表达式语句 | `ExprStmt( e )` | |
| 赋值 | `Assign( lhs , rhs )` | |
| 变量声明 | `Let[a]` / `Let[a,b]` / `Let[a]= e` | 无标识符时是 `Let[]` |
| 返回 | `Return()` / `Return( e1 , e2 )` | 多个用 `, ` 分隔 |
| 导出 | `Export[a,b]` / `Export[]` | |
| 块 | `Block{ ... }` | 花括号是形状串的一部分 |
| 条件 | `If( c ){ ... }Elif( c ){ ... }Else{ ... }` | 没有的分支整段省略 |
| 循环 | `While( c ){ ... }` | 省略条件写作 `While(null){ ... }` |
| 跳转 | `Break` / `Continue` | |
| 标识符 | `Ident( name )` | 取词法 §parsed（含 `:`，因此可能是 `Ident(a:b)`） |
| 整数 / 浮点 | `Int( 31 )` / `Float( 1.5 )` | 浮点按 `%g` |
| 字符串 | `Str("a\nb")` | **带引号**，控制字符用 `\n` `\r` `\t` `\\` `\"` 转义 |
| 二进制数组 | `BinArr[ab]` / `BinArr[04,01]` / `BinArr[]` | 小写十六进制，逗号分隔，无空格 |
| 空 / 布尔 | `Null` / `Bool(true)` / `Bool(false)` | |
| `argc` / `args` | `Argc` / `Args( k )` / `Args(null)` | 缺 key 时写作 `Args(null)` |
| 一元 | `Unary(Sub, e )` / `Unary(Not, e )` | 用 TokenType 名，不是符号 |
| 二元 | `Bin(Add, lhs , rhs )` | op ∈ `Or And EQ NE LT LE GT GE Add Sub Mul Div IDiv Mod Pow` |
| 调用 | `Call( callee ; a1 ; a2 )` | 每个实参前都带 `"; "` |
| 索引 | `At( container ; k1 ; k2 )` | 同上 |
| 自定义指令 | `Custom( name ; a1 ; a2 )` | 同上 |
| 错误占位 | `Err(L1)` | 失败路径返回的裸 Expr，`L1` 是该节点的行号 |

### 2.3 三条硬规则

| 约束 | 说明 |
| --- | --- |
| 行号 | 形状串里**不带行号**，`Err(Lx)` 是唯一例外；行号另用 §4.6 的 L 组单独锁 |
| 折叠 | 除 §4.9 的 O 组外，全部用例在 **`constFolding = false`** 下生成形状串 |
| 比较 | 字符串全等比较；不做任何空白归一化 |

---

## 3. 行为基线

**B-1 语句集合。** `prog := stmt*`；`stmt := ";" | let | export | return | block | if | while | break | continue | 表达式语句 | 赋值语句`。

**B-2 顶层 `}`。** 顶层的孤立 `}` 报 `unexpected "}" at top level.`、**跳过它并继续**解析后面的语句；
块内的 `}` 是正常终结符，**不消费**，交给外层。

**B-3 错误恢复总则：缺分隔符时「只报错、不推进」。**
理由：推进会吞掉下一个 token（`f(1, 2 x;` 里的 `x;` 会被吞），使后面的语句被误解。
适用位置：`break/continue` 缺 `;`、if/elif/else/while 缺 `{`、Call 缺 `)`、At 缺 `]`、
`args` 缺 `[`、表达式语句结尾既不是 `;` 也不是 `=`。

**B-4 Eof 与 `}` 上绝不推进。** 这两处推进要么死循环（Eof），要么吃掉外层块的终结符。

> **B-3 的例外（有意保留）**：`let` 与 `return` 的兜底分支仍然推进。
> 后果：`let a, b = 1;` 会丢掉 `= 1`，`return 1 2;` 会丢掉 `2`，`let a b;` 会丢掉 `b`。
> 这是**已登记基线**，不要顺手改。

**B-5 `let` 的两种形态互斥。** 多标识符时禁止赋值；赋值时只允许一个标识符。

**B-6 优先级（低 → 高）。**
`||(1) < &&(2) < == !=(3) < < <= > >=(4) < + -(5) < * / idiv %(6) < ^(7) < 前缀 -(8) < () 调用/索引(9)`。

**B-7 `^` 规定为左结合**：`2^3^2` ≡ `(2^3)^2`。

**B-8 一元 `-` 与 `^`。** `-2^2` ≡ `(-2)^2`（一元优先级高于 `^`）。这是**待定项 PD-18**。

**B-9 `ExprStmt.line` 与 `AssignStmt.line` 取左侧表达式的行**，不是分号的行。

**B-10 常量折叠默认开启**，可关闭。折叠规则见 `cpp/docs/expr_optim.md` §4。

**B-11 错误不去重。** 同一行的多个错误全部上报，级联错误的条数会成倍上升。

**B-12 词法错误不合并。** lexer 的错误与 parser 的错误在两个列表里，调用方要查两处。

---

## 4. 用例清单

> 表中「形状」列即 §2 的序列化结果；「err」列是 **parser.errors 的条数**。
> 未标注 inputs 的自定义指令一律用：已注册 `myop`（定长 2 参）、`vop`（变长）。

### 4.1 S 语句层

| ID | 输入 | 形状 | err | 关键错误子串 |
| --- | --- | --- | --- | --- |
| S-01 | （空） | （空串） | 0 | |
| S-02 | `;` | （空串） | 0 | |
| S-03 | `;;;` | （空串） | 0 | |
| S-04 | `let a;` | `Let[a]` | 0 | |
| S-05 | `let a, b, c;` | `Let[a,b,c]` | 0 | |
| S-06 | `let a = 1;` | `Let[a]=Int(1)` | 0 | |
| S-07 | `let a = 1` | `Let[a]=Int(1)` | **0** | 赋值分支不检查结尾 `;` |
| S-08 | `let;` | `Let[]` | 1 | `expected identifier after "let".` |
| S-09 | `let 1;` | `Let[]` | 1 | 同上 |
| S-10 | `let a, b = 1;` | `Let[a,b]` | 2 | `failed to parse let statement with multiple identifiers.`（×2） |
| S-11 | `let a b;` | `Let[a]` | 1 | `unexpected token in let statement.`（`b` 被丢，见 B-3 例外） |
| S-12 | `let a,` | `Let[a]` | 2 | `failed to parse...` + `expected ";" in let statement.` |
| S-13 | `export a;` | `Export[a]` | 0 | |
| S-14 | `export a, b;` | `Export[a,b]` | 0 | |
| S-15 | `export;` | `Export[]` | 1 | `expected identifier after "export".` |
| S-16 | `return;` | `Return()` | 0 | |
| S-17 | `return 1;` | `Return(Int(1))` | 0 | |
| S-18 | `return 1, 2;` | `Return(Int(1), Int(2))` | 0 | |
| S-19 | `return 1 2;` | `Return(Int(1))` | 1 | `expected ";" or "," in return statement.`（`2` 被丢） |
| S-20 | `return` | `Return()` | 1 | `expected ";" in return statement.` |
| S-21 | `{ }` | `Block{}` | 0 | |
| S-22 | `{ let a; }` | `Block{Let[a]}` | 0 | |
| S-23 | `{ let a;` | `Block{Let[a]}` | 1 | `expected "}" at end of block statement.` |
| S-24 | `}` | （空串） | 1 | `unexpected "}" at top level.` |
| S-25 | `} let a;` | `Let[a]` | 1 | 同上；后面的语句照常解析 |
| S-26 | `break;` | `Break` | 0 | |
| S-27 | `continue;` | `Continue` | 0 | |
| S-28 | `break` | `Break` | 1 | `expected ";" in break statement.` |
| S-29 | `break x;` | `Break ; ExprStmt(Ident(x))` | 1 | 同上（不推进，`x` 留给下一条） |
| S-30 | `continue x;` | `Continue ; ExprStmt(Ident(x))` | 1 | `expected ";" in continue statement.` |
| S-31 | `a;` | `ExprStmt(Ident(a))` | 0 | |
| S-32 | `a = 1;` | `Assign(Ident(a), Int(1))` | 0 | |
| S-33 | `a = 1` | `Assign(Ident(a), Int(1))` | 1 | `expected ";" at end of assign statement.` |
| S-34 | `a b;` | `ExprStmt(Ident(a)) ; ExprStmt(Ident(b))` | 1 | `expected ";" or "=". ` |
| S-35 | `a[0] = 1;` | `Assign(At(Ident(a); Int(0)), Int(1))` | 0 | |

### 4.2 X 表达式与字面量

| ID | 输入 | 形状 | err |
| --- | --- | --- | --- |
| X-01 | `null;` | `ExprStmt(Null)` | 0 |
| X-02 | `true;` | `ExprStmt(Bool(true))` | 0 |
| X-03 | `false;` | `ExprStmt(Bool(false))` | 0 |
| X-04 | `1;` | `ExprStmt(Int(1))` | 0 |
| X-05 | `0x1F;` | `ExprStmt(Int(31))` | 0 |
| X-06 | `1.5;` | `ExprStmt(Float(1.5))` | 0 |
| X-07 | `"a\nb";` | `ExprStmt(Str("a\nb"))` | 0 |
| X-08 | `'b 0100 0001';` | `ExprStmt(BinArr[04,01])` | 0 |
| X-09 | `'';` | `ExprStmt(BinArr[])` | 0 |
| X-10 | `argc;` | `ExprStmt(Argc)` | 0 |
| X-11 | `args[0];` | `ExprStmt(Args(Int(0)))` | 0 |
| X-12 | `args 0;` | `ExprStmt(Args(null)) ; ExprStmt(Int(0))` | 2：`expected "[" after "args". ` + `expected ";" or "=". ` |
| X-13 | `a:b;` | `ExprStmt(Ident(a:b))` | 0 |
| X-14 | `-1;` | `ExprStmt(Unary(Sub, Int(1)))` | 0 |
| X-15 | `!a;` | `ExprStmt(Unary(Not, Ident(a)))` | 0 |
| X-16 | `--a;` | `ExprStmt(Unary(Sub, Unary(Sub, Ident(a))))` | 0 |
| X-17 | `'ab';` | `ExprStmt(BinArr[ab])` | 0（无前缀按十六进制） |
| X-18 | `'d 01 02';` | `ExprStmt(BinArr[01,02])` | 0 |

### 4.3 P 优先级与结合性

| ID | 输入 | 形状（ExprStmt 内的部分） |
| --- | --- | --- |
| P-01 | `1 + 2 * 3;` | `Bin(Add, Int(1), Bin(Mul, Int(2), Int(3)))` |
| P-02 | `1 * 2 + 3;` | `Bin(Add, Bin(Mul, Int(1), Int(2)), Int(3))` |
| P-03 | `1 - 2 - 3;` | `Bin(Sub, Bin(Sub, Int(1), Int(2)), Int(3))` |
| P-04 | `2 ^ 3 ^ 2;` | `Bin(Pow, Bin(Pow, Int(2), Int(3)), Int(2))` |
| P-05 | `-2 ^ 2;` | `Bin(Pow, Unary(Sub, Int(2)), Int(2))` |
| P-06 | `1 < 2 == true;` | `Bin(EQ, Bin(LT, Int(1), Int(2)), Bool(true))` |
| P-07 | `a \|\| b && c;` | `Bin(Or, Ident(a), Bin(And, Ident(b), Ident(c)))` |
| P-08 | `a && b \|\| c;` | `Bin(Or, Bin(And, Ident(a), Ident(b)), Ident(c))` |
| P-09 | `1 + 2 < 3;` | `Bin(LT, Bin(Add, Int(1), Int(2)), Int(3))` |
| P-10 | `a idiv b % c;` | `Bin(Mod, Bin(IDiv, Ident(a), Ident(b)), Ident(c))` |
| P-11 | `(1 + 2) * 3;` | `Bin(Mul, Bin(Add, Int(1), Int(2)), Int(3))` |
| P-12 | `-a * b;` | `Bin(Mul, Unary(Sub, Ident(a)), Ident(b))` |
| P-13 | `!a == b;` | `Bin(EQ, Unary(Not, Ident(a)), Ident(b))` |
| P-14 | `1 - -2;` | `Bin(Sub, Int(1), Unary(Sub, Int(2)))` |
| P-15 | `a / b / c;` | `Bin(Div, Bin(Div, Ident(a), Ident(b)), Ident(c))` |

### 4.4 F 调用 / 索引 / 括号（多数 0 错误，列 er 的除外）

| ID | 输入 | 形状 | err |
| --- | --- | --- | --- |
| F-01 | `f();` | `ExprStmt(Call(Ident(f)))` | 0 |
| F-02 | `f(1);` | `ExprStmt(Call(Ident(f); Int(1)))` | 0 |
| F-03 | `f(1, 2);` | `ExprStmt(Call(Ident(f); Int(1); Int(2)))` | 0 |
| F-04 | `f(1, 2, 3);` | `ExprStmt(Call(Ident(f); Int(1); Int(2); Int(3)))` | 0 |
| F-05 | `f()();` | `ExprStmt(Call(Call(Ident(f))))` | 0 |
| F-06 | `f(a)(b);` | `ExprStmt(Call(Call(Ident(f); Ident(a)); Ident(b)))` | 0 |
| F-07 | `f(1, 2 x;` | `ExprStmt(Call(Ident(f); Int(1); Int(2))) ; ExprStmt(Ident(x))` | 2：`expected ")". ` + `expected ";" or "=". ` |
| F-08 | `a[0];` | `ExprStmt(At(Ident(a); Int(0)))` | 0 |
| F-09 | `a[0, 1];` | `ExprStmt(At(Ident(a); Int(0); Int(1)))` | 0 |
| F-10 | `a[0][1];` | `ExprStmt(At(At(Ident(a); Int(0)); Int(1)))` | 0 |
| F-11 | `a[b[c]];` | `ExprStmt(At(Ident(a); At(Ident(b); Ident(c))))` | 0 |
| F-12 | `a[;` | `ExprStmt(At(Ident(a); Err(L1)))` | **3**：`no prefix parse function...` + `expected "]". ` + `expected ";" or "=". ` |
| F-13 | `(1);` | `ExprStmt(Int(1))` | 0 |
| F-14 | `(1 + 2) * 3;` | 同 P-11 | 0 |
| F-15 | `(1;` | `ExprStmt(Int(1))` | 2：`expected ")". ` + `expected ";" or "=". ` |
| F-16 | `((((1))));` | `ExprStmt(Int(1))` | 0 |
| F-17 | `f(a[0]);` | `ExprStmt(Call(Ident(f); At(Ident(a); Int(0))))` | 0 |
| F-18 | `f() + 1;` | `ExprStmt(Bin(Add, Call(Ident(f)), Int(1)))` | 0 |

### 4.5 K 自定义指令

| ID | 输入 | 形状 | err |
| --- | --- | --- | --- |
| K-01 | `myop(1, 2);` | `ExprStmt(Custom(myop; Int(1); Int(2)))` | 0 |
| K-02 | `vop();` | `ExprStmt(Custom(vop))` | 0 |
| K-03 | `vop(1, 2, 3);` | `ExprStmt(Custom(vop; Int(1); Int(2); Int(3)))` | 0 |
| K-04 | `myop(1);` | `ExprStmt(Custom(myop; Int(1)))` | **0**（参数个数在编译阶段查） |
| K-05 | `myop 1;` | `ExprStmt(Custom(myop)) ; ExprStmt(Int(1))` | 2：`expected "(" after custom opcode. ` + `expected ";" or "=". ` |
| K-06 | `myop(1, 2;` | `ExprStmt(Custom(myop; Int(1); Int(2)))` | 2：`expected ")". ` + `expected ";" or "=". ` |
| K-07 | `myop() + 1;` | `ExprStmt(Bin(Add, Custom(myop), Int(1)))` | 0 |
| K-08 | `f(myop(1, 2));` | `ExprStmt(Call(Ident(f); Custom(myop; Int(1); Int(2))))` | 0 |
| K-09 | `undefined_op(1);` | `ExprStmt(Call(Ident(undefined_op); Int(1)))` | 0（未注册 → 普通 Ident） |
| K-10 | `myop[0];` | `ExprStmt(Custom(myop)) ; ExprStmt(Err(L1))` | 3：`expected "(" after custom opcode. ` + `expected ";" or "=". ` + `no prefix parse function...` |

### 4.6 L 行号

| ID | 输入 | 期望 |
| --- | --- | --- |
| L-01 | `let a;\nlet b;` | 两条 `Let` 的 line 分别为 1、2 |
| L-02 | `1 +\n2;` | `BinaryOpExpr.line == 1`（== 左侧操作数的行） |
| L-03 | `{\nlet a;\n}` | `BlockStmt.line == 1`，内部 `Let.line == 2` |
| L-04 | `if x {\na;\n}` | `IfStmt.line` 取 `if` 行；块内 `ExprStmt.line` 取 `a` 行 |
| L-05 | `a\nb;` | `ExprStmt(Ident(a)).line == 1`；`ExprStmt(Ident(b)).line == 2`；报错落在**第 2 行**（报错用当前 token 的行） |

### 4.7 R 错误恢复

| ID | 输入 | 形状 | err |
| --- | --- | --- | --- |
| R-01 | `a; } b;` | `ExprStmt(Ident(a)) ; ExprStmt(Ident(b))` | 1：`unexpected "}" at top level.` |
| R-02 | `{ a; } b;` | `Block{ExprStmt(Ident(a))} ; ExprStmt(Ident(b))` | 0 |
| R-03 | `if a { b; } c;` | `If(Ident(a)){ExprStmt(Ident(b))} ; ExprStmt(Ident(c))` | 0 |
| R-04 | `if a b;` | `If(Ident(a)){} ; ExprStmt(Ident(b))` | 1：`expected "{" in if statement.` |
| R-05 | `while a b;` | `While(Ident(a)){} ; ExprStmt(Ident(b))` | 1：`expected "{" in while statement.` |
| R-06 | `f(1, 2 x; y;` | `ExprStmt(Call(Ident(f); Int(1); Int(2))) ; ExprStmt(Ident(x)) ; ExprStmt(Ident(y))` | 2 —— **`x;` 与 `y;` 必须还在**（B-3 的硬证明） |
| R-07 | `let a, b = 1; c;` | `Let[a,b] ; ExprStmt(Ident(c))` | 2（`= 1` 被丢，`c;` 还在） |

### 4.8 B 健壮性

| ID | 输入 | 期望 |
| --- | --- | --- |
| B-01 | 1 万条 `let x;` | 解析成功，不崩 |
| B-02 | 1 万层嵌套 `(`（`"("*10000 + "1" + ")"*10000`） | 解析成功。**这是曾踩过的栈溢出**：折叠不能把 `parseExpr` 再包一层 |
| B-03 | 1 万层嵌套 `{` | 同上 |
| B-04 | 1 万个连续 `-`（前缀） | 同上 |
| B-05 | 缺尾 `)` 的 1000 层括号 | 报错但不停机、不死循环 |
| B-06 | `args args args` | 报错不死循环 |

### 4.9 O 常量折叠（`constFolding = true` 下重跑同一批源码）

| ID | 输入 | 折叠后形状 | 说明 |
| --- | --- | --- | --- |
| O-01 | `1 + 2;` | `ExprStmt(Int(3))` | |
| O-02 | `2 * 3 + 4;` | `ExprStmt(Int(10))` | |
| O-03 | `1 + 2 * 3;` | `ExprStmt(Int(7))` | |
| O-04 | `"ab" + "cd";` | `ExprStmt(Str("abcd"))` | 串相加为连接 |
| O-05 | `1 / 0;` | `ExprStmt(Bin(Div, Int(1), Int(0)))` | **不折叠**（除零） |
| O-06 | `9223372036854775807 + 1;` | `ExprStmt(Int(-9223372036854775808))` | 整数溢出不检查，按补码回绕 |
| O-07 | `f(1) + 2;` | 原树形 | **不折叠**（Call 有副作用） |
| O-08 | `a + 2;` | 原树形 | **不折叠**（含变量） |
| O-09 | `null + 5;` | `ExprStmt(Bin(Add, Null, Int(5)))` | **不折叠**：null 不参与算术 |
| O-10 | `-true;` | `ExprStmt(Int(-1))` | Bool 当 0/1 参与数值运算 |
| O-11 | `2 ^ 3 ^ 2;` | `ExprStmt(Int(64))` | 左结合 → `(2^3)^2` |
| O-12 | `f(1 + 2);` | `ExprStmt(Call(Ident(f); Int(3)))` | 实参折叠，Call 本身不折 |
| O-13 | `1 + "a";` | 原树形 | **不折叠**（跨类型） |
| O-14 | `"ab" * 3;` | `ExprStmt(Str("ababab"))` | 串 × 整数 = 重复 |
| O-15 | `'01 ' + '02 ';` | `ExprStmt(BinArr[01,02])` | 二进制数组相加为连接 |

> 完整行为矩阵见 `cpp/docs/expr_optim.md` §4（行为矩阵总表）。
> O 组只锁「有代表性的格子 + 禁止折叠的边界」。

---

## 5. 验收标准

| 维度 | 门槛 |
| --- | --- |
| 形状串一致 | 两侧对 §4 全部输入产出**逐字符相同**的形状串 |
| error 条数 | 逐条命中；文案至少命中 §4 里给出的英文子串 |
| 不停机 | B 组全过；任一畸形输入不得死循环 |
| 错误恢复 | R-06 是硬门槛：`x;` 与 `y;` 必须还在 AST 里 |
| 折叠一致性 | O 组两侧都要一致 |

---

## 6. 执行方式

### C++

```bash
cd E:/lib/stope-lang/cpp
cmake -B build && cmake --build build
ctest --test-dir build
```

parser 相关：`test_parser_stmt` / `test_parser_expr` / `test_parser_prec` /
`test_parser_postfix` / `test_parser_custom` / `test_parser_flow` / `test_parser_fold`。
深嵌套用例（B 组）必须独立进程跑，见 `cpp/docs/parser_test_plan.md` §8。

### GDScript

```bash
"/d/Program Files/Godot/Godot_v4.7.2-stable_mono_win64/Godot_v4.7.2-stable_mono_win64.exe" \
    --headless --path gdscript --script res://test/run_tests.gd
```

---

## 7. 已知差异登记

> 新差异按顺序编号，修一条划一条（保留记录，标 `[已修 日期]`）。

| ID | 现象（GDScript 侧） | C++ 基准 | 状态 |
| --- | --- | --- | --- |
| **GD-P-01** | `AtExpr.args` 承载索引表达式，语义不清 | C++ 侧叫 `keyExprs` | [已修 2026-10-18] |
| **GD-P-02** | 没有常量折叠 | `constFolding` 默认开启，见 §4.9 | [已修 2026-10-18] |
| **GD-P-03** | 缺分隔符的分支几乎都 `next_token()`（吞 token），违反 B-3 | 见 B-3 | [已修 2026-10-18] |
| **GD-P-04** | 缺 `}` / `)` / `]` 时在 `Eof` 上继续推进，可能死循环 | B-4 | [已修 2026-10-18] |
| **GD-P-05** | `parse_prog()` 没有「顶层 / 块内」之别，块的 `}` 结算会错位 | `parseProg(prog, isTopLevel)` | [已修 2026-10-18] |
| **GD-P-06** | 没有 AST 形状串序列化（§2） | 已实现并跑本文全部用例 | [已修 2026-10-18] |
| **GD-P-07** | 错误是否合并不明确 | B-12：不合并 | [已修 2026-10-18] |
| **GD-P-08** | `return` 的多值解析用 `for i in range(50)` 硬限 50 个 | 无上限 | [已修 2026-10-18] |
| **GD-P-09** | 顶层孤立 `}` 会被 `prog_end_tokens` 直接结束解析，后续语句被丢弃 | B-2：报错、跳过、继续 | [已修 2026-10-18] |
| **GD-P-10** | 二进制数组字面量没有内容解析（只存原文） | `parse_binarr.hpp` 在语法阶段解析成字节 | [已修 2026-10-18] |
