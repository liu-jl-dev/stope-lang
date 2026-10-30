# Stope 词法分析通用测试计划

> **跨实现的行为契约** —— 不绑定任何一门语言。C++ 与 GDScript 两套实现都按本文件验证。
>
> | 通用测试计划 | 覆盖范围 | C++ 侧 | GDScript 侧 |
> | --- | --- | --- | --- |
> | **lexer-test-plan.md（本文）** | 字符流 → Token 流 | `cpp/include/stope/lexer.hpp` | `gdscript/addons/stope/lexer.gd` |
> | [parser-test-plan.md](parser-test-plan.md) | Token 流 → AST | `cpp/include/stope/parser.hpp` | `gdscript/addons/stope/parser.gd` |
> | [compiler-test-plan.md](compiler-test-plan.md) | AST → Program | `cpp/include/stope/compiler.hpp` | `gdscript/addons/stope/compiler.gd` |
| [stml-test-plan.md](stml-test-plan.md) | STML 文本 → 元素树 | `cpp/include/stope/stml_lexer.hpp` + `cpp/include/stope/stml_parser.hpp` | `gdscript/addons/stope/stml_lexer.gd` + `gdscript/addons/stope/stml_parser.gd` |
>
> **权威实现：C++。** 两侧出现分歧时以 `cpp/include/stope/lexer.hpp` 的实测行为为准，
> GDScript 侧按 §7 的差异清单整改；反向的分歧（C++ 落后于 GDScript 且确认是好的）
> 必须先在这里登记再动 C++。
>
> 面向语言的规格文档另见 [syntax-reference.md](syntax-reference.md)；C++ 侧更细的实现笔记见
> `cpp/docs/lexer-test-plan.md`（那一份含 C++ 特有的 API 与已修缺陷流水）。

## 目录

- [1. 目标与非目标](#1-目标与非目标)
- [2. 通用契约](#2-通用契约)
- [3. 行为基线](#3-行为基线)
- [4. 用例清单](#4-用例清单)
- [5. 验收标准](#5-验收标准)
- [6. 执行方式](#6-执行方式)
- [7. 已知差异登记](#7-已知差异登记)

---

## 1. 目标与非目标

**目标**

1. 把「什么是正确的词法分析结果」从实现里抽出来，写成一份所有实现共用、
   可不依赖读源码就审计的规格。
2. 新实现（解释器、WASM 移植、第三语言重写）拿本文当验收卷；老实现重构时当回归网。
3. 每一条负面用例（非法输入）都要有**确定的**输出：错误与否、错误文案、
   Token 类型，不能留「实现自选」。

**非目标**

- 不测试 AST / 指令生成（那是另两份计划的事）。
- 不测试宿主如何提供自定义指令表，只测试拿到表之后词法怎么判。
- 不做性能基准，只做「不得死循环、不得栈溢出」这类健壮性下限（§4 LEX-R）。
- 不规定内部数据结构（`string_view` 还是 `String`、`char16_t` 还是 `String`）。
  但 **bool 归类必须可观测**（见 §2.2）。

---

## 2. 通用契约

### 2.1 驱动方式

所有实现都必须提供等价的这两个入口：

```
lexer = create(input, customOpcodes)     # 自定义指令表可为缺省
loop:
    t = lexer.nextToken()
    if t.kind == Eof: break
    ... 断言 t ...
errors = lexer.errors                    # 累加，不清空
```

契约要点：

| 约束 | 内容 |
| --- | --- |
| 推进方式 | 每次 `nextToken()` 消费**恰好一个** token，**至少**推进一个字符的天花板由风格决定；但「未知字符」必须消费（否则死循环，见 LEX-P-07） |
| 结束 | 输入耗尽后**永远**返回 `Eof`，`line` 保持当时值，不报错 |
| `errors` | 只累加、不自动清空；格式 `"line N: message"`；跨 token 累计到流结束仍是关键停工点 |
| 复用 | 一个 lexer 实例只跑一条输入流；换新输入要重新构造或显式 reset |

### 2.2 Token 的四要素

| 字段 | 含义 | 必须满足 |
| --- | --- | --- |
| `kind` | Token 种类 | 见 §2.3 的 47 项 |
| `line` | 从 1 起算的行号，只有 `\n` 让它 +1 | token 的第一个字符所在行 |
| `lexeme` | 原始文本切片 | 数字/标识符/字符串/二进制数组要有原文；标点可有可无（由实现自定，本文不断言） |
| `parsed` | 规范形式 | 数字去掉 `_`；标识符把 `a : b` 拼成 `a:b`；双引号字符串是转义**之后**的内容 |
| `numberValue` | 仅整数字面量 / 浮点字面量有效 | 溢出、非法都要走到 `kind = Invalid` 并报错 |

**归类必须可观测。** 允许实现内部合并（例如只用一个 `Number` 枚举项），
但对外必须能回答下面 4 个判定，测试只通过这 4 个判定写断言：

```
isIntegerLiteral(t)   isFloatLiteral(t)
isStringLiteral(t)    isBinArrLiteral(t)
```

C++ 侧直接用 `TokenType::Integer/Float/String/BinArr`；
GDScript 侧由 `StopeLexer.Token.Type.Integer/Float/String/BinArr` 提供（2026-10-18 整改新增，见 §7 GD-L-01）。

### 2.3 Token 种类清单（47 项，顺序不重要，集合必须一致）

```
Invalid  Eof  Ident  Integer  Float  String  BinArr
Comma ,  Semi ;  LParen (  RParen )  LBrack [  RBrack ]  LBrace {  RBrace }
Assign =  Add +  Sub -  Mul *  Div /  IDiv idiv  Mod %  Pow ^
EQ ==  NE !=  LT <  LE <=  GT >  GE >=  Not ! not
And && and  Or || or
If  Elif  Else  Let  Return  While  Break  Continue
Null  False  True  Args  Argc  Export  Custom
```

关键字：`idiv if not and or elif else let return while break continue
null false true args argc export`。大小写敏感，且**关键字 > 自定义指令 > 标识符**。
（`idiv` 在语法上写作运算符，词法上仍是关键字；旧文档按「17 个关键字 + `idiv`」计数，
实际词法表是这 18 项。）

### 2.4 两侧 API 对照

| 抽象 | C++ | GDScript |
| --- | --- | --- |
| 取下一个 token | `Lexer::NextToken(Token&, const CustomOpcodeConfig*)` | `StopeLexer.Lexer.next_token(custom) -> StopeLexer.Token` |
| 错误列表 | `Lexer::errors : vector<string>` | `StopeLexer.Lexer.errors : Array[String]` |
| 当前行号 | `Lexer::line : int` | `StopeLexer.Lexer.line : int` |
| Token 字段 | `type / line / lexeme / parsed / numberValue` | `type / line / literal / parsed / int_value / float_value`（`literal` 对应 `lexeme`，数值按整 / 浮分两个字段） |

---

## 3. 行为基线

> 以下每一条都是**规范**，两侧实现都必须成立。取值举例均已在 C++ 侧实测过。

**B-1 空白与换行。** `' '` `\t` `\v` `\f` `\r` 只跳过，不加行；只有 `\n` 让 `line` +1。

**B-2 注释。** `//` 到行尾（含结尾的 `\n`，所以 `//x\n1` 的 `1` 在第 2 行）；
`/* */` 跨行且**不嵌套**（`/* a /* b */ c` 之后第一个非空白 token 是 `c`）；
注释不算 token。

**B-3 数字分为整数字面量与浮点字面量。** 只要扫到了 `.` 小数部分或指数部分
就是浮点；否则是整数。`0x/0b/0o` 前缀的一定是整数。

**B-4 整数写法。** `dec`、`0b[01]`、`0o[0-7]`、`0x[0-9a-fA-F]`，各处允许 `_`
作分隔符，`_` 只在回填 `parsed` 时剥离。

**B-5 数值必须用标准库/标准接口真正转换。**
转换失败或超出范围 → `Invalid` + `invalid integer.` / `invalid float.`。
**必须做「消费完整性」检查**：`0b2` 不能被当成合法前缀加默认值。

**B-6 浮点。**
`^[._0-9]*\.[_0-9]*([eE][+-]?[0-9]+)?$` 一类的写法，`1e5`=100000、`1E-3`=0.001、
`.5`=0.5、`1_.5`=1.5、`1e+3`=1000。指数后没有数字（`1e`、`1e+`、`.5e`）→ `Invalid`。

**B-7 上溢下溢。** `1e999` / `1e-999` / `9223372036854775808` → `Invalid`，不静默截断。

**B-8 标识符。** `^[a-zA-Z_][a-zA-Z0-9_]*$`；数字开头会被切成数字+标识符（`9a` → `9` + `a`）。

**B-9 `:` 命名空间。** `a:b:c` 是一个 Ident（`parsed`=`a:b:c`），`:` 两侧可跨行、
跨 `//`、`/* */` 注释。`a::b`、`a:1`、`a:`（`EOF` 前）都要报 `unclosed identifier.` 并产出 `Invalid`。

**B-10 双引号字符串。** 支持 9 种转义：`\\ \' \" \b \f \n \r \t \v`；
其它转义序列 → `invalid escape character.`。

**B-11 单引号二进制数组。** `'...'` 里的内容**不做转义**，原样交给上层解析；
`''` 是合法的空数组。

**B-12 两字符运算符优先。** `==` 优先于 `=`；`<= >= !=` 同理；
单 `&`、单 `|` 是 `Invalid` 不是 `And/Or`。

**B-13 自定义指令。** 名字语法与普通标识符一致（允许含 `:`），匹配优先级低于关键字。

**B-14 未知字符必须消费并报错。** 这是唯一防死循环的硬保障。

---

## 4. 用例清单

> 记法：`输入` → `期望的 token 序列`，`kind` 简写取 §2.3 的名字。
> `ε` 表示不产 token。`✗ "`msg"` 表示追加一条 error 且 error 文案含 msg。

### LEX-W 空白字符与注释

| ID | 输入 | 期望 |
| --- | --- | --- |
| LEX-W-01 | ``（空串） | `Eof`，line=1，无 error |
| LEX-W-02 | `" \t\v\f\r"` | `Eof`，line=1 |
| LEX-W-03 | `"\n\n"` | `Eof`，line=3 |
| LEX-W-04 | `"// c\n1"` | `Integer 1` line=2 |
| LEX-W-05 | `"// c"`（无换行） | `Eof` |
| LEX-W-06 | `"/* a\nb */1"` | `Integer 1` line=2 |
| LEX-W-07 | `"/* a /* b */ c"` | `Ident c`（不嵌套） |
| LEX-W-08 | `"1/* 未闭合"` | `Integer 1`，`Eof` |
| LEX-W-09 | `"a // x\n :b"` | `Ident a:b`（注释被跨过） |

### LEX-L 行号

| ID | 输入 | 期望各行号 |
| --- | --- | --- |
| LEX-L-01 | `"1\n2\n\n3\r\n4"` | 1,2,4,5（`\r` 不计数） |
| LEX-L-02 | `"'a\nb' 1"` | BinArr=1，Integer=2（二进制数组跨行累加） |
| LEX-L-03 | `"1\n  \t 2"` | 1,2 |
| LEX-L-04 | `"a\n:\nb"` | `Ident`，parsed=`a:b`，三者合并成一个 token，line 取第一个字符所在行 |

> **LEX-L-05（双引号字符串跨行）当前 C++ 侧不累加行号**，属于已登记待定项 D-13，
> 两侧都先不要求；一文里要有注释说明不要顺手改。

### LEX-N-I 整数字面量

| ID | 输入 | parsed | numberValue | 备注 |
| --- | --- | --- | --- | --- |
| LEX-N-I-01 | `0` | `0` | 0 | |
| LEX-N-I-02 | `00` | `00` | 0 | 前导零允许 |
| LEX-N-I-03 | `0009` | `0009` | 9 | |
| LEX-N-I-04 | `1_000` | `1000` | 1000 | |
| LEX-N-I-05 | `1_` | `1` | 1 | 尾随下划线允许 |
| LEX-N-I-06 | `0_1` | `01` | 1 | |
| LEX-N-I-07 | `0x1F` | `0x1F` | 31 | |
| LEX-N-I-08 | `0X1f` | `0X1f` | 31 | 大小写不敏感 |
| LEX-N-I-09 | `0xFF` | `0xFF` | 255 | |
| LEX-N-I-10 | `0b101` / `0B101` | 原文 | 5 | |
| LEX-N-I-11 | `0o17` / `0O17` | 原文 | 15 | |
| LEX-N-I-12 | `0b1_01` | `0b101` | 5 | |
| LEX-N-I-13 | `0x_1` | `0x1` | 1 | 前缀后紧跟下划线仍合法 |
| LEX-N-I-14 | `0o_7` | `0o7` | 7 | |
| LEX-N-I-15 | `9223372036854775807` | 原文 | INT64_MAX | |
| LEX-N-I-16 | `0x7FFFFFFFFFFFFFFF` | 原文 | INT64_MAX | |
| LEX-N-I-17 | `9223372036854775808` | — | — | `Invalid` ✗ `invalid integer.` |
| LEX-N-I-18 | `0xFFFFFFFFFFFFFFFFF` | — | — | `Invalid` ✗ `invalid integer.` |
| LEX-N-I-19 | `0b` / `0x` / `0o` | — | — | `Invalid` ✗ `invalid integer.` |
| LEX-N-I-20 | `0b_` / `0x_` / `0o_` | — | — | `Invalid` ✗ `invalid integer.` |
| LEX-N-I-21 | `0b2` | — | — | `Invalid` ✗ `invalid integer.` **+** `Integer 2`（消费完整性） |
| LEX-N-I-22 | `123abc` | — | — | `Integer 123` + `Ident abc`，无 error |

### LEX-N-F 浮点字面量

| ID | 输入 | parsed | value |
| --- | --- | --- | --- |
| LEX-N-F-01 | `1e5` | `1e5` | 100000.0 |
| LEX-N-F-02 | `1E-3` | `1E-3` | 0.001 |
| LEX-N-F-03 | `.5` | `.5` | 0.5 |
| LEX-N-F-04 | `1_.5` | `1.5` | 1.5 |
| LEX-N-F-05 | `1e+3` | `1e+3` | 1000.0 |
| LEX-N-F-06 | `1.` | `1.` | 1.0（`.` 后无数字仍合法） |
| LEX-N-F-07 | `1..2` | — | `Float 1.` + `Float .2` |
| LEX-N-F-08 | `1.5.5` | — | `Float 1.5` + `Float .5` |
| LEX-N-F-09 | `.` | — | `Invalid` ✗ `invalid float.` |
| LEX-N-F-10 | `.e5` / `._` | — | `Invalid` ✗ `invalid float.` |
| LEX-N-F-11 | `1e` / `1e+` / `.5e` | — | `Invalid` ✗ `invalid float.` |
| LEX-N-F-12 | `1e999` / `1e-999` | — | `Invalid` ✗ `invalid float.` |

### LEX-I 标识符与 `:` 命名空间

| ID | 输入 | 期望 |
| --- | --- | --- |
| LEX-I-01 | `_` / `__9` / `_9a` | `Ident`，合法 |
| LEX-I-02 | `9a` | `Integer 9` + `Ident a` |
| LEX-I-03 | `a:b` | 一个 `Ident`，parsed=`a:b` |
| LEX-I-04 | `a:b:c` | parsed=`a:b:c` |
| LEX-I-05 | `a\n:b` | parsed=`a:b`（跨行） |
| LEX-I-06 | `a // c\n:b` | parsed=`a:b`（跨行注释） |
| LEX-I-07 | `a :/*x*/ b` | parsed=`a:b`（跨块注释） |
| LEX-I-08 | `a::b` | `Invalid`(parsed `a:`) ✗ `unclosed identifier.` + `Invalid` + `Ident b` |
| LEX-I-09 | `a:1` | `Invalid`(parsed `a:`) ✗ `unclosed identifier.` + `Integer 1` |
| LEX-I-10 | `a:`（到 EOF） | `Invalid`(parsed `a:`) ✗ `unclosed identifier.` + `Eof` |

### LEX-K 关键字

| ID | 输入 | 期望 |
| --- | --- | --- |
| LEX-K-01 | 17 个关键字逐个 | 各自的关键字 kind，非 `Ident` |
| LEX-K-02 | `IF` / `If` / `iff` / `if2` | 全部 `Ident`（大小写敏感、须整词匹配） |
| LEX-K-03 | 注册名为 `if` 的自定义指令 | 被关键字压住，仍是 `If` |

### LEX-S 双引号字符串

| ID | 输入 | 期望 |
| --- | --- | --- |
| LEX-S-01 | `""` | `String`，parsed=空 |
| LEX-S-02 | `"abc"` | parsed=`abc` |
| LEX-S-03 | `"a\"b"` | parsed=`a"b`（转义引号不结束串） |
| LEX-S-04 | `"a\nb"` | parsed 含真换行 |
| LEX-S-05 | `"a\\b"` | parsed=`a\b` |
| LEX-S-06 | 其余 6 种转义 `\b \f \r \t \v \'` | 各自的控制字符 |
| LEX-S-07 | `"a\qb"` | ✗ `invalid escape character.` |
| LEX-S-08 | `"abc` | `Invalid` ✗ `unclosed string literal.` |
| LEX-S-09 | `"abc\` | `Invalid` ✗ `unclosed string literal.` |

> **待定项 D-14**：非法转义时 C++ 侧 `parsed` 会被截断到出错位置且 `kind` 仍是
> `String`。本文不对此做出要求，两侧保持现状，**自动化测试不要锁这一条**，
> 只锁「必须有 `invalid escape character.` 错误」。

### LEX-B 单引号二进制数组

| ID | 输入 | 期望 |
| --- | --- | --- |
| LEX-B-01 | `''` | `BinArr`，内容为空 |
| LEX-B-02 | `'a'` | `BinArr`，lexeme=`a` |
| LEX-B-03 | `'a' 'b'` | 两个 `BinArr` |
| LEX-B-04 | `'a\nb'` | **不转义**：内容是 `a\nb` 六个字符（反斜杠+n），不是换行 |
| LEX-B-05 | `'a` | `Invalid` ✗ `unclosed binary array.` |
| LEX-B-06 | `'a\nb'`（真换行） | `BinArr`，后续 token 行号 +1 |

### LEX-P 标点与运算符

| ID | 输入 | 期望 |
| --- | --- | --- |
| LEX-P-01 | `,` `;` `(` `)` `[` `]` `{` `}` | 各自 kind |
| LEX-P-02 | `=` `+` `-` `*` `/` `%` `^` | 各自 kind |
| LEX-P-03 | `==` | `EQ`（不是两个 `Assign`） |
| LEX-P-04 | `<=` `>=` | `LE` / `GE` |
| LEX-P-05 | `!=` | `NE`（不是 `Not`+`Assign`） |
| LEX-P-06 | `&&` / `||` | `And` / `Or` |
| LEX-P-07 | `&` / `|` | `Invalid` ✗ `unknown token.`，**且消费该字符**（防死循环） |
| LEX-P-08 | `@` `#` `$` `~` `?` `\` 等非法字符 | `Invalid` ✗ `unknown token.`，各消费一个字符 |

### LEX-C 自定义指令

| ID | 输入（已注册 `foo`（定长 2）/ `bar`（变长）） | 期望 |
| --- | --- | --- |
| LEX-C-01 | `foo` | `Custom`，parsed=`foo` |
| LEX-C-02 | `bar` | `Custom`，parsed=`bar` |
| LEX-C-03 | `baz` | `Ident`（未注册） |
| LEX-C-04 | 注册名为 `a:b` 的指令后输入 `a:b` | `Custom` |
| LEX-C-05 | 同名重复注册 | 登记失败，返回「重复」语义，不覆盖旧项 |

### LEX-E 错误累计

| ID | 输入 | 期望 |
| --- | --- | --- |
| LEX-E-01 | `& & &` | 3 条 error，各带自己的行号前缀 |
| LEX-E-02 | `&\n&` | 2 条，行号分别为 1、2 |
| LEX-E-03 | 一条输入里多处错误 | **不去重**：同行的多个错误全部上报 |

### LEX-T Token 状态与生命周期

| ID | 场景 | 期望 |
| --- | --- | --- |
| LEX-T-01 | 复用同一个 token 变量连扫 `alpha beta gamma` | `parsed` 每次都重建，无串味 |
| LEX-T-02 | 取到 `Eof` 后继续取 | 仍是 `Eof`，不越界、不报错 |
| LEX-T-03 | 每轮开始前 reset token | `parsed` 为空、`numberValue` 归零 |

### LEX-E2E 端到端 token 流

| ID | 输入 | 期望序列 |
| --- | --- | --- |
| LEX-E2E-01 | `let a = 1;` | `Let Ident(a) Assign Integer(1) Semi Eof` |
| LEX-E2E-02 | `if a < 2 { return a; }` | `If Ident(a) LT Integer(2) LBrace Return Ident(a) Semi RBrace Eof` |
| LEX-E2E-03 | `"s" + 'b' + 1.5 idiv 2` | `String Add BinArr Add Float IDiv Integer Eof` |
| LEX-E2E-04 | `export x, y; let z;` | `Export Ident(x) Comma Ident(y) Semi Let Ident(z) Semi Eof` |

### LEX-R 健壮性下限

| ID | 输入 | 期望 |
| --- | --- | --- |
| LEX-R-01 | 10 万个连续 `( ` | 产出等量 token，无栈溢出（词法无递归） |
| LEX-R-02 | 1 MB 全空白 | 一次扫完到 `Eof`，不崩溃、不栈溢出（词法为纯循环，不得递归） |
| LEX-R-03 | 单个未闭合 `'` / `"` 到 EOF | `Invalid` + 一次 error，输入耗尽 |

---

## 5. 验收标准

| 维度 | 门槛 |
| --- | --- |
| 功能通过率 | §4 全部用例通过（待定项 D-13/D-14 除外）。**任一实现有 1 条不过就要在 §7 登记** |
| 两实现一致性 | C++ 与 GDScript 用**同一份**用例数据；用例表由本文 + 各自的驱动脚本体现，不允许出现「GDScript 版少测几条」 |
| 错误文案 | 「库内中药材」式的自由文案不算不合格，但 §3/§4 里明写的英文子串必须逐字命中（`invalid integer.`、`invalid float.`、`unknown token.`、`unclosed string literal.`、`unclosed binary array.`、`unclosed identifier.`、`invalid escape character.`） |
| 行号 | 每条 error 的 `line N` 必须能对上 token 起始行 |
| 不停机 | 任何非法输入都不得死循环（LEX-P-07 是硬门槛） |

**跨实现一致性怎么验。** 两侧各自跑一遍本文全部用例，
把 `kind + line + parsed + errors.size()` 导成可比对的文本，
一份输入都不能差。C++ 侧由 `ctest` 承担，GDScript 侧由
`gdscript/test/` 的 runner 承担（见 §6）。

---

## 6. 执行方式

### C++

```bash
cd E:/lib/stope-lang/cpp
cmake -B build && cmake --build build
ctest --test-dir build
```

lexer 相关：`test_lexer_number` / `test_lexer_ident` / `test_lexer_string` /
`test_lexer_punct` / `test_lexer_flow` / `test_lexer_misc`。
细化的 C++ 侧记录见 `cpp/docs/lexer-test-plan.md`。

### GDScript

```bash
"/c/Program Files/Godot/Godot_v4.7.2-stable_mono_win64/godot_console.exe" \
    --headless --path gdscript --script res://test/run_tests.gd
```

详见 `gdscript/docs/testing.md`。

---

## 7. 已知差异登记

> 新差异按顺序编号，修一条划一条（保留记录，标 `[已修 日期]`）。

| ID | 现象（GDScript 侧） | C++ 基准 | 状态 |
| --- | --- | --- | --- |
| **GD-L-01** | `Type.Number` 一个枚举项同时承载整数与浮点，`Type.Str` 同时承载字符串与二进制数组，无法回答 §2.2 的四个判定 | 分成 `Integer/Float/String/BinArr` 四项 | [已修 2026-10-18] |
| **GD-L-02** | `Lexer.errors` 被注释掉，错误只是静默丢弃 | 有 `errors`，格式 `line N: msg` | [已修 2026-10-18] |
| **GD-L-03** | 未知字符时 `token.type` 留在 `Invalid` 且**不推进输入** → 上层循环没有终止条件 | 消费 1 个字符并报错 | [已修 2026-10-18] |
| **GD-L-04** | `scan_exp()` 的正则是 `^([eE]\|[pP])-?[0-9]+`：既额外接受 `p/P`，又漏了 `+` 号 | 只允许 `[eE][+-]?[0-9]+` | [已修 2026-10-18] |
| **GD-L-05** | `scan_dec_number()` 里 `input == 'E'` 是把整个剩余输入和单字符比，恒假 | 应写 `input[0] == 'E'` | [已修 2026-10-18] |
| **GD-L-06** | 数字只靠 `is_valid_int()/is_valid_float()` 在**编译期**判合法性，词法期不校验 `0b2`、溢出、超范围 | 词法期就用「消费完整性 + 溢出」校验，不合格直接 `Invalid` | [已修 2026-10-18] |
| **GD-L-07** | 单引号内容也走 `defalt_escape()` | 单引号不做任何转义 | [已修 2026-10-18] |
| **GD-L-08** | 未闭合字符串时 `res.err` 置了但仍会给 `val`，上层看不出区别 | `Invalid` + `unclosed string literal.` | [已修 2026-10-18] |
| **GD-L-09** | `skip_multiline_comment()` 走到 EOF 时不报错 | 走到 EOF 不报错（与 C++ 一致，`D-6` 是 C++ 侧待定项） | 一致，无需改 |
| **GD-L-10** | `Type` 注释写「共 43 个」，实际枚举 45 项 | — | [已修 2026-10-18] |
