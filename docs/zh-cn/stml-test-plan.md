# STML 通用测试计划

> **跨实现的行为契约** —— 不绑定任何一门语言。C++ 与 GDScript 两套实现都按本文件验证。
>
> | 通用测试计划 | 覆盖范围 | C++ 侧 | GDScript 侧 |
> | --- | --- | --- | --- |
> | [lexer-test-plan.md](lexer-test-plan.md) | 字符流 → Token 流 | `cpp/include/stope/lexer.hpp` | `gdscript/addons/stope/lexer.gd` |
> | [parser-test-plan.md](parser-test-plan.md) | Token 流 → AST | `cpp/include/stope/parser.hpp` | `gdscript/addons/stope/parser.gd` |
> | [compiler-test-plan.md](compiler-test-plan.md) | AST → Program | `cpp/include/stope/compiler.hpp` | `gdscript/addons/stope/compiler.gd` |
> | **stml-test-plan.md（本文）** | STML 文本 → 元素树 | `cpp/include/stope/stml_lexer.hpp` + `cpp/include/stope/stml_parser.hpp` | `gdscript/addons/stope/stml_lexer.gd` + `gdscript/addons/stope/stml_parser.gd` |
>
> **权威实现：C++。** 两侧出现分歧时以 `cpp/include/stope/stml_*.hpp` 的实测行为为准，
> GDScript 侧按 §7 的差异清单整改；反向的分歧（C++ 落后于 GDScript 且确认是好的）
> 必须先在这里登记再动 C++。
>
> **本文所有期望值都是机器生成的**：由 `cpp/test/test_stml_lexer.cpp` 与
> `cpp/test/test_stml_parser.cpp` 实测导出（2026-10-18，215 条断言全绿），不是手推的。
> C++ 侧更细的实现笔记与缺陷流水见 `cpp/docs/stml_test_plan.md`。

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

STML 是 Stope 项目内嵌的**标记语言**：一份 STML 文档是一棵树，树上挂着三类"代码段"
（普通文本 / Nevext 脚本 / Stope 脚本）。本文同时覆盖它的词法与语法两段，因为它们
**共享同一个状态机**（§2.4），拆开测会漏掉状态切换这一类缺陷。

**目标**

1. 把「什么是正确的 STML 解析结果」从实现里抽出来，写成一份所有实现共用、
   可不依赖读源码就审计的规格。
2. 逐条钉住：状态切换时机、代码段的边界判定、属性的有值/无值、**错误的确切文案与停位**。
3. 每条负面用例都要有**确定的**输出：错误与否、错误文案、产出的元素形状。

**非目标**

- **不测试 Nevext / Stope 语言本身**（那是另两份计划的事）。本文只保证"整段代码被
  原样、完整地交出来"，不保证代码内部写对了。
  Nevext 是另一门汇编风格的数据描述语言，项目地址
  <https://github.com/liu-jl-dev/nevext>；STML 只按 §2.5 的引号 / 注释规则切分它，
  不解释其内容。
- 不测试字符实体（`&amp;`）：STML 没有，文本一律原样。
- 不做性能基准，只做「不得死循环、不得栈溢出」这类健壮性下限（§4 LEX-SR / PARSE-PF）。
- 不规定内部数据结构（`string_view` 还是 `String`、`std::map` 还是 `Dictionary`）。
  但 **属性顺序必须可观测** —— 因为两侧都"不保证源码顺序"（见 TD-2），
  测试必须用**键的字典序**输出，否则没法比对。

---

## 2. 通用契约

### 2.1 驱动方式（词法）

```
lexer = create(input)          # 初始 state = Xml
lexer.state = <初始状态>        # 可覆盖，用于单独测 Text / Nevext / Stope
loop:
    t = lexer.nextToken()
    if t.kind == Eof: break
    ... 断言 t.kind / t.line / t.lexeme / lexer.state ...
errors = lexer.errors          # 累加，不清空
```

| 约束 | 内容 |
| --- | --- |
| 推进 | 每次 `nextToken()` 产出**恰好一个** token；未知字符必须消费（否则死循环，见 LEX-SX-09） |
| 结束 | 输入耗尽后**永远**返回 `Eof`，`line` 保持当时值，不报错 |
| `errors` | 只累加、不自动清空；格式 `"line N: message"` |
| 状态交还 | `Text` / `Nevext` / `Stope` 扫完一段（遇到 `</` 或输入耗尽）后**必须把 state 交还 Xml**，否则后续 `nextToken()` 会产出无限个空 token |
| 复用 | 一个 lexer 实例只跑一条输入流 |

### 2.2 Token 的三要素

| 字段 | 含义 | 必须满足 |
| --- | --- | --- |
| `kind` | Token 种类 | 见 §2.3 的 12 项 |
| `line` | 从 1 起算，只有 `\n` 让它 +1 | token **第一个字符**所在行；跨行的字面量/注释内部也要跟着走 |
| `lexeme` | 原始文本切片 | **字符串不含两侧引号**；`Text` / `NevextSrc` / `StopeSrc` **不含尾部空白**；标点、结束标签名的 lexeme 由实现自定，不断言 |

### 2.3 Token 种类清单（12 项）

| # | C++ 名 | GDScript 名 | 含义 | lexeme |
| --- | --- | --- | --- | --- |
| 0 | `Invalid` | `Invalid` | 意外字符 / 未闭合字面量 | — |
| 1 | `EndOfFile` | `Eof` | 输入耗尽 | — |
| 2 | `LAngle` | `LAngle` | `<` | — |
| 3 | `RAngle` | `RAngle` | `>` | — |
| 4 | `CLAngle` | `CLAngle` | `</` | — |
| 5 | `CRAngle` | `CRAngle` | `/>` | — |
| 6 | `EQ` | `EQ` | `=` | — |
| 7 | `Word` | `Word` | 标签名 / 属性名 | 有 |
| 8 | `String` | `Str` | Xml 属性字符串 | 有（不含引号） |
| 9 | `Text` | `Text` | 元素内普通文本 | 有 |
| 10 | `NevextSrc` | `NevSrc` | Nevext 代码段 | 有 |
| 11 | `StopeSrc` | `StoSrc` | Stope 代码段 | 有 |

**集合必须完全一致**（12 项，不多不少），名字也已对齐（见 §7 GD-S-03），
但**种类划分**必须能对上：例如不能把 `Text` 合并进 `Word`。

### 2.4 词法状态机（4 态）

```
                  nextToken() 开头
   Xml ─────────────────────────────────────────► 标签骨架 / 属性 / 注释
    │  state := Text|Nevext|Stope（由 Parser 的 stateFunc 决定）
    ▼
 Text / Nevext / Stope ─── 扫一整段 ───► 产出 1 个 token，state := Xml
```

| 状态 | 扫描规则 | 终止条件 |
| --- | --- | --- |
| `Xml` | 空白与 `<!-- -->` 注释跳过；认 `<` `>` `</` `/>` `=`、引号串、Word | 每次一个 token |
| `Text` | 一路吃到 `</`，**只认 `</` 不认 `<`** | `</` 或输入耗尽 |
| `Nevext` | 同 `Text`，但跳过引号串与 `//` `/* */` 注释，其中的 `</` 不算终止 | 同上 |
| `Stope` | 同 `Nevext`，引号规则不同（见 §2.5） | 同上 |

`<!-- -->` **只在 `Xml` 状态是注释**：Nevext / Stope 里出现的 `<!--` 里的 `<` 是小于号。

### 2.5 引号与注释（两侧差异最大的地方）

| 场合 | 双引号 `"` | 单引号 `'` |
| --- | --- | --- |
| Xml 属性值 | 字符串；**不转义**（`\"` 里的引号就是结束引号，TD-9） | 同左 |
| Nevext 段 | 字符串；`\` 转义下一个字符 | 字符串；同样转义 |
| Stope 段 | 字符串；`\` 转义下一个字符 | **BinArr 字面量，不转义**（与 `Stope::Lexer::scanBinArr` 一致） |

注释：`//` 到行尾、`/* */` 可跨行。**未闭合的 `/*` 不是错误**，吃到输入末尾即可。
未闭合的引号串**是错误**，报错后**消费掉剩余全部输入**（保证调用方不死循环），
行号报的是**字面量起始行**。

### 2.6 驱动方式（语法）

```
parser = create(lexer)
result = parser.parse(root, stateFunc)   # stateFunc 可以为 null
errors = parser.errors
```

`stateFunc(tagName, attrs) -> state` 由**宿主**决定某个标签的内容该按哪种状态扫：

| 返回 | 后果 |
| --- | --- |
| `Text` | 元素内容按普通文本扫 |
| `Nevext` / `Stope` | 元素内容按代码段扫 |
| `Xml` | 元素内容按**子元素列表**解析（此时出现裸文本是错误，见 PARSE-PC-11） |
| `null`（回调本身缺省） | 一律 `Xml` |

进入每个元素时**强制把 lexer.state 重置为 `Xml`**：自闭合分支与出错提前返回的路径
都走不到 stateFunc，留着上一次的状态会污染后续 token。

### 2.7 元素模型

```
Element {
    line        : int              # '<' 所在行，从 1 起算
    tagName     : string
    attrs       : map<string,string>   # 无值属性的值是空串
    selfClosing : bool
    children    : Element[]        # 与 text 互斥
    text        : string           # 只有一段，不拼接
}
```

### 2.8 元素形状串

两侧测试都必须能把一棵元素树序列化成下面的文本。**同一份输入必须产出同一串字符。**
这套格式就是 C++ 侧 `cpp/test/test_stml_common.hpp::shapeElem()` 的输出。

```
Elem( <tag>, L<line>[, /][, @<k>[="<v>"]]...[, T="<text>"][, C=[<child> <child> ...]] )
```

| 片段 | 含义 | 出现条件 |
| --- | --- | --- |
| `Elem(` `)` | 元素外壳 | 总是 |
| `<tag>` | 标签名 | 总是（失败时可能是空串） |
| `L<line>` | 行号 | 总是 |
| `/` | 自闭合 | `selfClosing == true` |
| `@<k>` | 无值属性 | 值等于空串 |
| `@<k>="<v>"` | 有值属性 | 值非空 |
| `T="<text>"` | 元素内文本 | 文本非空 |
| `C=[...]` | 子元素，用空格分隔、按源码顺序 | 非空 |

**字段顺序固定**：tag → line → `/` → 属性 → 文本 → 子元素。
**属性按"键的字典序"输出，不是源码顺序**（TD-2）。字符串里的 `"` `\` 与
控制字符按 `\n` `\r` `\t` `\\` `\"` 转义。

示例：

| 输入 | 形状串 |
| --- | --- |
| `<a/>` | `Elem(a, L1, /)` |
| `<a></a>` | `Elem(a, L1)` |
| `<a id="x" flag/>` | `Elem(a, L1, /, @flag, @id="x")` |
| `<p>hello</p>`（stateFunc → Text） | `Elem(p, L1, T="hello")` |
| `<a><b/><c/></a>` | `Elem(a, L1, C=[Elem(b, L1, /) Elem(c, L1, /)])` |

### 2.9 两侧 API 对照

| 环节 | C++ | GDScript |
| --- | --- | --- |
| 词法器构造 | `STML::Lexer lx(u16string_view)` | `STMLLexer.Lexer.new(String)` |
| 取一个 token | `lx.NextToken(Token&)` | `lx.next_token() -> STML.Token` |
| 状态字段 | `lx.state : LexerState`（4 态） | `lx.state : int`（4 态，枚举值相同） |
| 语法器构造 | `STML::Parser p(lx)` | `STMLParser.Parser.new(lex)` |
| 解析入口 | `p.Parse(Element& root, LexerStateFunc) -> Result` | `p.parse(root, state_func) -> int` |
| 内容状态决策 | `LexerStateFunc(tag, attrs)` 回调 | 宿主 `Callable(tag, attrs) -> int`；传 `Callable()` 等价于 `nullptr` |
| 错误 | `lx.errors` / `p.errors`，**两者不合并** | `lx.errors` / `p.errors`，同样不合并 |
| 结果枚举 | `Stope::Result::Success / Error` | `StopeResult.Success / Error`（与编译器共用同一份，见 gdscript/docs/usage.md 开头） |

---

## 3. 行为基线

> 编号 `B-n` 是**契约**，`TD-n` 是**已登记的缺陷/偏离**（同步登记在 `cpp/docs/stml_test_plan.md` §3）。

| ID | 基线 | 锁定用例 |
| --- | --- | --- |
| **B-1** | 初始状态是 `Xml`；`Text`/`Nevext`/`Stope` 扫完一段后交还 `Xml` | LEX-ST-01、LEX-SN-01、LEX-SP-01 |
| **B-2** | `Text` 只认 `</`，`<b/>` 会被整段当文本吃掉 | LEX-ST-05、PARSE-PC-09 |
| **B-3** | `Nevext`/`Stope` 跳过引号串与注释，其中的 `</` 不是结束标签 | LEX-SN-05、LEX-SP-03、PARSE-PC-06 |
| **B-4** | `<!-- -->` 只在 `Xml` 状态是注释，且**跳过它不产生 token** | LEX-SX-06、LEX-SX-07、LEX-SP-09 |
| **B-5** | 未闭合的 `/*` **不是**错误；未闭合的引号串**是**错误且报起始行 | LEX-SN-04、LEX-SP-07、LEX-SN-07 |
| **B-6** | 未闭合引号串报错后吃掉剩余输入，调用方不会死循环 | LEX-SN-07、PARSE-PE-11 |
| **B-7** | `Word` 首字符 `[a-zA-Z_:]`，续字符 `[a-zA-Z0-9_:-]` —— 不含 `.` | LEX-SW-01…04、LEX-SW-08（**TD-1**） |
| **B-8** | 字符串 lexeme 不含引号；`Text`/代码段 lexeme 不含尾部空白 | LEX-SS-01、LEX-ST-02 |
| **B-9** | 属性**可以没有值**：`<a flag>` ≡ `flag = ""` | PARSE-PB-03 |
| **B-10** | 属性集合是**无序**的：测试输出必须按键字典序（**TD-2**） | PARSE-PB-05、PARSE-PB-06 |
| **B-11** | 元素内文本**只有一段**，不做多段拼接（**TD-3**） | PARSE-PC-01、PARSE-PC-09 |
| **B-12** | 子元素与文本**互斥**；`Xml` 模式的元素里出现裸文本是错误 | PARSE-PC-11 |
| **B-13** | 结束标签名必须与开始标签逐字符相等，且后面必须是 `>` | PARSE-PE-04、PARSE-PE-09 |
| **B-14** | 每个错误分支都**提前 return**，不在同一处级联（**例外见 TD-7**） | PARSE-PE-01…PE-11 |
| **B-15** | 顶层只解析**一个**元素；根之后的剩余输入被忽略（**TD-5**） | PARSE-PA-09 |
| **B-16** | `lexer.errors` 与 `parser.errors` **不合并**，调用方要查两处（**TD-6**） | PARSE-PE-06、PARSE-PE-11 |

**错误文案（必须逐字命中；英文，末尾带一个空格和句号）**

| 触发 | 文案 |
| --- | --- |
| 未知字符（词法） | `unexpected character. ` |
| 属性字符串未闭合（词法） | `unclosed string literal`（**无句号**，TD-8） |
| 代码段引号串未闭合（词法） | `unclosed string literal. ` |
| 元素开头不是 `<` | `expected "<". ` |
| `<` 后不是 Word | `expected tag name. ` |
| `=` 后不是 String | `expected string. ` |
| 属性位置上出现别的 token | `expected ">" or "/>" or attribute. ` |
| 元素内容位置上出现别的 token | `expected "<" or "</". ` |
| 内容状态不是 Xml 却没拿到内容 token | `expected element content. ` |
| 结束标签名不匹配 | `tag name mismatch. ` |
| 结束标签后不是 `>` | `expected ">". ` |

---

## 4. 用例清单

> 共 **121 个用例 / 215 条断言**，C++ 侧落地在
> `cpp/test/test_stml_lexer.cpp` 与 `cpp/test/test_stml_parser.cpp`。
> 用例 ID 就是源码里的 ID 字符串，便于反查。

### 4.1 词法（62 用例 / 119 断言）

#### LEX-SX Xml 状态（10）

| 用例 | 输入 | 期望 |
| --- | --- | --- |
| SX-01 | `<a>` | `LAngle Word RAngle Eof` |
| SX-02 | `</a>` | `CLAngle Word RAngle Eof` |
| SX-03 | `<a/>` | `LAngle Word CRAngle Eof` |
| SX-04 | `<a id="x">` | `LAngle Word Word EQ String RAngle Eof`，`tok[4].lexeme == x` |
| SX-05 | `<a id='x'>` | 同 SX-04（单引号同价） |
| SX-06 | `<!-- 注释 --><a>` | 注释不产 token：`LAngle Word RAngle Eof`，0 错 |
| SX-07 | `<!--\n跨行\n--><a>` | 同上，且 `tok[0].line == 3` |
| SX-08 | `hello` | `Word Eof`（Xml 状态下的裸文本被切成 Word） |
| SX-09 | `@` | `Invalid Eof`，1 错，含 `unexpected character.` |
| SX-10 | `<1>` | `LAngle Invalid RAngle Eof`，1 错 |

#### LEX-SW Word 边界（8）

| 用例 | 输入 | 期望 |
| --- | --- | --- |
| SW-01/02/03 | `abc` / `_x` / `:ns` | 一个 `Word`，lexeme 同上 |
| SW-04 | `a-b:c_9` | 一个 `Word`（续字符集含 `-` `:` `_`） |
| SW-05 | `9a` | `Invalid`（数字不能开头） |
| SW-06/07 | `a>b` / `a=b` | `Word RAngle Word` / `Word EQ Word` |
| SW-08 | `a.b` | `Word Invalid Word`，1 错（`.` 不是 Word 字符，TD-1） |

#### LEX-SS 属性字符串（8）

| 用例 | 输入 | 期望 |
| --- | --- | --- |
| SS-01 | `"abc"` | `String`，lexeme `abc` |
| SS-02 | `''` | `String`，lexeme 空 |
| SS-03 | `"a b"` | 空格不截断 |
| SS-04 | `"a>b"` | `>` 在串内不截断 |
| SS-05 | `"a\nb"` | 跨行，后续 token `line == 2` |
| SS-06 | `"abc` | `Invalid`，1 错，含 `unclosed string literal` |
| SS-07 | `'abc` | 同 SS-06 |
| SS-08 | `"a\"b"` | `String Word Invalid`，**Xml 属性串不转义**（TD-9） |

#### LEX-ST Text 状态（6）

| 用例 | 输入（state=Text） | 期望 |
| --- | --- | --- |
| ST-01 | `hello world</a>` | `Text CLAngle Word RAngle`，`tok[0].state == Xml` |
| ST-02 | `hello world  \n  </a>` | 尾部空白被裁掉 |
| ST-03 | `a\nb</a>` | `CLAngle` 在第 2 行 |
| ST-04 | `</a>` | 空 Text（不是错误） |
| ST-05 | `text<b/>more</a>` | 只认 `</`：Text 是 `text<b/>more` |
| ST-06 | `没有结束标签` | `Text Eof`，吃到 EOF 不是错误 |

#### LEX-SN Nevext 状态（8）

| 用例 | 输入（state=Nevext） | 期望 |
| --- | --- | --- |
| SN-01 | `windowSize 1280, 720;</nev>` | 整段一个 `NevextSrc`，尾部无空白 |
| SN-02 | `a // 注释\nb;</n>` | `//` 注释整段保留，`CLAngle` 在第 2 行 |
| SN-03 | `a /* 跨\n行 */ b;</n>` | 多行注释整段保留 |
| SN-04 | `a /* 未闭合` | 不是错误 |
| SN-05 | `x "a</b" 'p</q';</n>` | 引号里的 `</` 不误判 |
| SN-06 | `x "a\"b" 'c\'d';</n>` | 两种引号都转义 |
| SN-07 | `x "abc;</n>` | 1 错，报**起始行** `line 1` |
| SN-08 | `x "a\nb" c;</n>` | 引号跨行，行号跟着走 |

#### LEX-SP Stope 状态（10）

| 用例 | 输入（state=Stope） | 期望 |
| --- | --- | --- |
| SP-01 | `let a = 1;</sto>` | 整段一个 `StopeSrc` |
| SP-02 | `if a < b { c(); }</sto>` | 小于号不误判 |
| SP-03 | `let s = "a</b";</sto>` | 双引号里的 `</` 不误判 |
| SP-04 | `let t = '01 02';</sto>` | 单引号是 BinArr，不转义 |
| SP-05 | `let s = "a\"b\n";</sto>` | 双引号支持转义 |
| SP-06 | `a // c\nb;</sto>` | 单行注释 |
| SP-07 | `a /* 未闭合` | 不是错误 |
| SP-08 | `let s = "abc;</sto>` | 1 错，含 `unclosed string literal` |
| SP-09 | `a < !- b;</sto>` | `<!--` 在 Stope 里不是注释 |
| SP-10 | `let a = 1;\nlet b = 2;\n</sto>` | 多行，`CLAngle` 在第 3 行 |

#### LEX-SL 行号（3）· LEX-SE 错误（3）· LEX-SR 健壮性（6）

| 用例 | 输入 | 期望 |
| --- | --- | --- |
| SL-01 | `<a>\n<b>\n</b>\n</a>` | 四个骨架 token 分别在第 1/2/3/4 行 |
| SL-02 | `a\n\nb`（Text） | `Eof` 在第 3 行 |
| SL-03 | `a\r\nb`（Text） | `\r` 不计数 |
| SE-01 | `@ $` | 2 条错 |
| SE-02 | `a\n@` | 错误含 `line 2` |
| SE-03 | `@` | 文案 `line 1: unexpected character. ` |
| SR-01/02 | 空输入 / 纯空白 | 只有 `Eof` |
| SR-03 | `<!-- 未闭合的 xml 注释` | 只有 `Eof`，不死循环 |
| SR-04 | 5000 个 `a` | 一个 `Word` |
| SR-05 | 200 个 `"` | 100 个空 `String` + `Eof`，0 错 |
| SR-06 | `<!--` | 只有 `Eof` |

### 4.2 语法（59 用例 / 96 断言）

> `stateFunc` 缺省行为：`<sto>` → Stope、`<nev>` → Nevext、`<p>` → Text、其余 → Xml。

#### PARSE-PA 元素骨架（9）

| 用例 | 输入 | 期望形状 / 断言 |
| --- | --- | --- |
| PA-01 | `<a/>` | `Elem(a, L1, /)` |
| PA-02 | `<a></a>` | `Elem(a, L1)` |
| PA-03 | `  <a/>  ` | 首尾空白无影响 |
| PA-04 | `<a><b/></a>` | `Elem(a, L1, C=[Elem(b, L1, /)])` |
| PA-05 | `<a><b><c/></b></a>` | 深度 3 |
| PA-06 | `<a><b/><c/><d/></a>` | 3 个兄弟，按源码顺序 |
| PA-07 | `<a><b></b><c> </c></a>` | 2 个子元素 |
| PA-08 | `<a-b></a-b>` | 标签名含 `-` |
| PA-09 | `<a/><b/>` | 只解析根，剩余忽略（TD-5） |

#### PARSE-PB 属性（11）

| 用例 | 输入 | 期望形状 / 断言 |
| --- | --- | --- |
| PB-01 | `<a id="x"/>` | `Elem(a, L1, /, @id="x")` |
| PB-02 | `<a id='x'/>` | 同 PB-01 |
| PB-03 | `<a flag/>` | `Elem(a, L1, /, @flag)`（无值，B-9） |
| PB-04 | `<a id="x" flag/>` | `Elem(a, L1, /, @flag, @id="x")` |
| PB-05 | `<a flag id="x"/>` | 同 PB-04 —— **顺序无关** |
| PB-06 | `<a z="1" a="2"/>` | `Elem(a, L1, /, @a="2", @z="1")`（字典序，TD-2） |
| PB-07 | `<a b="1" c="2" d/>` | 3 个属性 |
| PB-08 | `<a id=""/>` | 成功，1 个属性 |
| PB-09 | `<a t="x>y"/>` | 值里可以含 `>` |
| PB-10 | `<a x:y="1" z-w="2"/>` | 属性名含 `:` `-` |
| PB-11 | `<a id="1"><b/></a>` | 属性与子元素共存 |

#### PARSE-PC 元素内容（12）

| 用例 | 输入 | 期望形状 / 断言 |
| --- | --- | --- |
| PC-01 | `<p>hello</p>` | `Elem(p, L1, T="hello")` |
| PC-02 | `<p>  hello  </p>` | 尾部空白已由词法裁掉 |
| PC-03 | `<p></p>` | 空文本，不是错误 |
| PC-04 | `<sto>let a = 1;</sto>` | `Elem(sto, L1, T="let a = 1;")` |
| PC-05 | `<nev>x 1, 2;</nev>` | `Elem(nev, L1, T="x 1, 2;")` |
| PC-06 | `<sto>let s = "a</b";</sto>` | 引号里的 `</` 不终止 |
| PC-07 | `<nev>x "a</b";</nev>` | 同上 |
| PC-08 | `<sto>let a = 1;\nlet b = 2;</sto>` | 换行保留在 text 里 |
| PC-09 | `<p>a<b/>c</p>` | Text 只认 `</`：text 是 `a<b/>c`（B-2/TD-4） |
| PC-10 | `<p>a <!-- b</p>` | `<!--` 在 Text 里不是注释 |
| PC-11 | `<a>text</a>` | 1 错 `expected "<" or "</".`（B-12） |
| PC-12 | `<nev>x "a\"b";</nev>` | Parser 不做任何解码 |

#### PARSE-PL 行号（4）

| 用例 | 输入 | 期望 |
| --- | --- | --- |
| PL-01 | `<a>\n<b/>\n</a>` | 根 `line == 1` |
| PL-02 | `\n\n<a/>` | 根 `line == 3` |
| PL-03 | `<a>\n<b>\n<c/>\n</b>\n</a>` | 深度 3 |
| PL-04 | `<sto>\nlet a = 1;\n</sto>` | 根 `line == 1`，text 是 `let a = 1;` |

#### PARSE-PE 错误恢复（12）

| 用例 | 输入 | 期望 |
| --- | --- | --- |
| PE-01 | `<>` | 1 错 `expected tag name.`，`Result::Error` |
| PE-02 | `a` | 1 错 `expected "<".` |
| PE-03 | ``（空） | 1 错 `expected "<".` |
| PE-04 | `<a></b>` | 1 错 `tag name mismatch.` |
| PE-05 | `<a id=></a>` | 1 错 `expected string.` |
| PE-06 | `<a 1></a>` | 1 条语法错 + 1 条词法错（B-16） |
| PE-07 | `<a>` | 1 错 `expected "<" or "</".` |
| PE-08 | `<a` | 1 错 `expected ">" or "/>" or attribute.` |
| PE-09 | `<a></a` | 1 错 `expected ">".` |
| PE-10 | `<a></a b>` | 1 错 `expected ">".` |
| PE-11 | `<a id="x></a>` | 1 条语法错 `expected string.` + 1 条词法错 |
| PE-12 | `<a><b id=></b></a>` | **2 条**：子元素的 `expected string.` + 父元素的 `tag name mismatch.`（TD-7） |

#### PARSE-PF stateFunc 与健壮性（7）

| 用例 | 输入 | 期望 |
| --- | --- | --- |
| PF-01 | `<a><b/></a>`，`stateFunc = null` | 同 PA-04 |
| PF-02 | `<p>hello</p>`，`stateFunc = null` | 1 错 `expected "<" or "</".` |
| PF-03 | `<any>hello</any>`，自定义回调 → Text | `Elem(any, L1, T="hello")` |
| PF-04 | 50 层 `<n>…</n>` | 成功，深度 50 |
| PF-05 | `<p>` + 2000 个 `x` + `</p>` | 成功，text 原样 |
| PF-06 | `<a><!-- c --><b/></a>` | 注释出现在子元素之间不影响 |
| PF-07 | `<p><!-- c --></p>` | text 是 `<!-- c -->`（Text 状态不认注释） |

#### PARSE-PH 混合（4）

| 用例 | 输入 | 期望 |
| --- | --- | --- |
| PH-01 | `div` 下挂 `p` / `sto` / `nev` 三段 | 见下方完整形状串 |
| PH-02 | `<sto>if a < b { s = "x</y"; t = '01 02'; /* c */ }</sto>` | 整段原样 |
| PH-03 | `<nev>title "a\nb"; /* x\ny */ size 1;</nev>` | 整段原样（含跨行引号与注释） |
| PH-04 | `<a><img src="i.png" alt=""/><p>cap</p></a>` | 自闭合 + 文本兄弟 |

PH-01 的完整形状串：

```
Elem(div, L1, @class="box", @hidden, C=[Elem(p, L2, T="hello") Elem(sto, L3, T="let a = 1;") Elem(nev, L4, T="windowSize 1280, 720;")])
```

---

## 5. 验收标准

| 维度 | 门槛 |
| --- | --- |
| 功能通过率 | §4 全部 121 个用例通过。**任一实现有 1 条不过就要在 §7 登记** |
| 两实现一致性 | C++ 与 GDScript 用**同一份**用例数据，不允许出现「GDScript 版少测几条」 |
| Token 覆盖 | 12 种 `TokenType` 全部被至少 1 个用例产出（C++ 侧由 `stmlTypeCoverage()` 自动查，当前 12/12） |
| 错误文案 | §3 表格里明写的英文子串必须逐字命中 |
| 行号 | 每条 error 的 `line N` 必须能对上 token / 元素的起始行 |
| 不停机 | 任何非法输入都不得死循环（LEX-SR 与 PARSE-PF 是硬门槛） |
| 形状串 | 两侧对同一份输入必须产出**逐字符相同**的形状串（属性按字典序） |

**跨实现一致性怎么验。** 两侧各自跑一遍本文全部用例，
把 `kind + line + lexeme + errors.size()` 与元素形状串导成可比对的文本，
一份输入都不能差。C++ 侧由 `ctest` 承担（`test_stml`）；
GDScript 侧由 `test/test_stml.gd` 承担，且它的期望值不是手写的 ——
`data/stml_cases.txt` 这份用例清单两侧共用，C++ 探针 `cpp/tools/golden_stml.cpp`
读它 dump 出 `data/golden_stml.txt`（见 §6）。

---

## 6. 执行方式

### C++

```bash
cd E:/lib/stope-lang/cpp
cmake -B build && cmake --build build
ctest --test-dir build          # 13 项，其中 stml 是新增的那一项
./build/test_stml.exe           # 单独跑 STML，看逐条断言
```

相关源文件：

| 文件 | 作用 |
| --- | --- |
| `cpp/test/test_stml.cpp` | 入口，跑词法 + 语法，打印覆盖统计与已知问题清单 |
| `cpp/test/test_stml_common.hpp` | 断言框架（S 前缀宏）、`slexAll` / `sparseAll` 驱动、`shapeElem` 形状串 |
| `cpp/test/test_stml_lexer.cpp` | §4.1 的 62 个词法用例 |
| `cpp/test/test_stml_parser.cpp` | §4.2 的 59 个语法用例 |

退出码：`0` 全过；`1` 有断言失败；`2` 全过但有 `FIXED-PENDING-FLIP`。

细化的 C++ 侧记录见 `cpp/docs/stml_test_plan.md`。

### GDScript

121 条用例全部落地在 `gdscript/test/`，随其它三组一起跑：

```bash
"/c/Program Files/Godot/Godot_v4.7.2-stable_mono_win64/godot_console.exe" \
    --headless --path gdscript --script res://test/run_tests.gd
```

输出里 `[4/4] STML` 那一段就是本组，602 条断言（62 × 4 + 59 × 6）。

与另三组不同，这一组**用例清单本身也是数据文件**，因为两侧要跑同一批输入：

| 文件 | 谁写 | 作用 |
| --- | --- | --- |
| `gdscript/test/data/stml_cases.txt` | 手写 | §4 的 121 条：ID / `KIND` / `ST`（词法初始状态）/ `SF`（宿主回调）/ `SRC` / `TIMES` |
| `cpp/tools/golden_stml.cpp` | 手写 | C++ 侧探针。读清单 → dump 期望值 |
| `gdscript/test/data/golden_stml.txt` | **机器生成** | 期望值，勿手工编辑 |
| `gdscript/test/test_stml.gd` | 手写 | GDScript 侧 runner。读清单 + golden，逐字段比对 |

加删用例**只改 `stml_cases.txt`**，然后重跑探针：`cmake --build cpp/build --target gen-golden`
（详见 `gdscript/docs/testing.md` §3.3）。

---

## 7. 已知差异登记

> `GD-S-n` = GDScript 侧相对 C++ 基准的差异，按顺序编号，修一条划一条（保留记录）。
> `TD-n` = 两侧共有的缺陷/定夺，完整清单见 `cpp/docs/stml_test_plan.md` §3。
>
> **2026-10-28**：GDScript 侧 STML 整体重写 —— 词法补 `Text` 态与 Xml 注释、语法改成宿主
> 回调并逐分支照抄 C++、错误文案换成 §3 那 10 条；同日又把 `Token.Type` 的三个枚举项改名
> 对齐 C++ 并删掉 `type_name()` 映射层（GD-S-03）。原有 16 条里 15 条已修，整改后又发现
> 两条（GD-S-17/18）。

| ID | 现象（GDScript 侧） | C++ 基准 | 状态 |
| --- | --- | --- | --- |
| **GD-S-01** | `State` 枚举只有 `Xml / Nevext / Stope` 三态，**没有 `Text`**；元素内文本是在 `Xml` 状态下由 `scan_text()` 产出的 `Text` token，且遇到任意 `<`（不只是 `</`）就停 | 有独立的 `Text` 状态，只认 `</` | ✅ 已修 2026-10-28（补 `Text` 状态） |
| **GD-S-02** | `Xml` 状态下任何既非标点又非 Word 首字符的字符，都走 `else: scan_text()` 开一段文本，**不报** `unexpected character.` | 报 `Invalid` + 错误，消费 1 个码元 | ✅ 已修 2026-10-28（`Invalid` + `unexpected character. ` 并消费 1 个字符） |
| **GD-S-03** | Token 类型名不同：`Str` / `NevSrc` / `StoSrc` | `String` / `NevextSrc` / `StopeSrc`（种类划分一致即可） | ✅ 已修 2026-10-28（枚举项直接改名，`type_name()` 那层映射已删） |
| **GD-S-04** | `Lexer` 里从未调用 `skip_xml_comment()`（该函数存在但是死代码），`<!-- -->` **完全不支持** | `skipWs()` 在 `Xml` 状态下跳过注释 | ✅ 已修 2026-10-28（`skip_ws` 在 Xml 态跳过注释） |
| **GD-S-05** | `skip_xml_comment()` 写 `src.substr(3)`（`<!--` 是 4 个字符） | `remove_prefix(4)` | ✅ 已修 2026-10-28（改 `substr(4)`） |
| **GD-S-06** | `scan_stope()` 直接 `return scan_nevext()`：Stope 的单引号 BinArr 也按转义串处理 | `scanStopeString` 对 `'` 不转义（§2.5） | ✅ 已修 2026-10-28（单引号不转义） |
| **GD-S-07** | `skip_src_str()` 对 `'` `"` 一律转义，且不区分 Nevext / Stope | 同上 | ✅ 已修 2026-10-28（拆成 `scan_nevext_str` / `scan_stope_str`） |
| **GD-S-08** | `is_word_char()` 只含 `[a-zA-Z_:]0-9`，**缺 `-`** | 续字符集含 `-` | ✅ 已修 2026-10-28（续字符集补 `-`） |
| **GD-S-09** | 元素内文本**多段拼接**：`ele.text = str(ele.text,'\n',cur_token.lexeme)` | 只有一段，不拼接（TD-3） | ✅ 已修 2026-10-28 |
| **GD-S-10** | 错误文案是另一套句式：`expected "<" for an element, but got <TypeName>. ` | §3 表格里的 10 条固定文案 | ✅ 已修 2026-10-28（改用 §3 的 10 条固定文案） |
| **GD-S-11** | 内容状态由标签名**硬编码**：`nev` → Nevext、`sto` → Stope（`sto` 带 `asm` 属性时走 Nevext） | `LexerStateFunc(tag, attrs)` 回调，宿主决定 | ✅ 已修 2026-10-28（宿主 `Callable` 回调） |
| **GD-S-12** | `Element` 有额外的 `text_begin_line` 字段 | 无该字段（元素只有一个 `line`） | ✅ 已修 2026-10-28（删掉 `text_begin_line`） |
| **GD-S-13** | 属性循环出错后**不 return**，只是 `break` 出循环继续往下走（违反 B-14）。实测 `<a name 5 />`、`<a flag>`（缺结束标签）都会在随后的内容循环里**挂死** | 报 `expected string.` / `expected ">" or "/>" or attribute.` 后**提前 return** | ✅ 已修 2026-10-28（每个错误分支提前 return） |
| **GD-S-14** | 词法与语法的 `errors` 都不含行号以外的统一格式约定（均为 `line N: msg`，此项一致） | 同 | 一致，无需改 |
| **GD-S-15** | 元素内出现裸文本时，`parse_element()` 的 `else` 分支**只报错不推进**，`while true` 卡在同一个 token 上：`<a name="x">plain</a>` 实测**永不返回** | 报错后推进，或把文本切成 `Text` 交给上层 | ✅ 已修 2026-10-28（`else` 报错后 return，不再空转） |
| **GD-S-16** | `scan_text()` / `scan_nevext()` / `scan_stope()` **不去尾部空白**：`<sto>let a=1;\n   </sto>` 实测 text = `let a=1;\n   ` | B-8：`Text` / 代码段的 lexeme **不含尾部空白**（`trimTrailingWs`） | ✅ 已修 2026-10-28（加 `trim_trailing_ws`） |
| **GD-S-17** | `Element.attrs` 是 `Dictionary`，**遍历顺序是插入序**（源码顺序）；形状串能对齐是因为 `shape_elem()` 先 `keys.sort()` | `std::map`，遍历顺序是键的字典序 | 未修（直接遍历 `attrs` 的宿主代码会看到不同顺序；要用顺序就自己排序） |
| **GD-S-18** | `String` 按**码点**推进，非 BMP 字符（emoji）一次吃掉整个字符 | `char16_t` 按 **UTF-16 码元**推进，非 BMP 字符会被当成两个 `Invalid` | 未修。§4 的用例不含非 BMP 字符，所以 121 条全绿也覆盖不到 |

### TD 编号索引

| ID | 内容 | 状态 |
| --- | --- | --- |
| TD-1 | `Word` 字符集的注释曾声明含 `.`，实现不支持 | [已修 2026-10-18] 改注释（LEX-SW-08 锁行为） |
| TD-2 | 属性装在 `std::map`，**顺序不保证** | 定夺：测试按字典序输出 |
| TD-3 | 元素内文本只有一段，不拼接 | 定夺（GD 侧已跟进，2026-10-28） |
| TD-4 | `Text` 状态只认 `</`，`<b/>` 会被当文本 | 未修 |
| TD-5 | 顶层只解析一个元素，忽略尾部内容 | 未修 |
| TD-6 | `lexer.errors` 不合并进 `parser.errors` | 未修（与 Stope 主语言的 PD-14 同源） |
| TD-7 | 子元素出错后父元素继续解析 → 级联报错 | 未修（建议 `parseElement` 返回 `bool`） |
| TD-8 | `scanString` 文案 `unclosed string literal` 比 `scanNevextString` 少一个句号 | 未修 |
| TD-9 | Xml 属性字符串**不做转义** | 未修 |
