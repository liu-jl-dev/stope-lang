# Python 版 API 用法

逐模块列出对外的东西：类、方法、字段、返回码、容易踩的地方。签名一律按源码抄，
方法名是 **snake_case**（对应 C++ 的 PascalCase，见每节的「C++」列）。

> **稳定性**：`common` … `stml_*` 这些模块是**编译器 / 解析器接口**（相对稳定，
> `Program` 的编码契约属标准）；`basic_vm` 是**内置的基础虚拟机** —— 会一直维护、
> 接口不随意调整，但不是标准。分界线见 [`quick-start.md`](quick-start.md) §0 与
> 根 README「标准范围」。

约定：

- **不抛异常**。词法 / 语法 / 编译器 / 执行器都把错误记进自己的 `errors: list[str]`，
  格式统一是 `line N: msg`（执行器是 `<指令下标>: msg`）。宿主自己实现 `Arguments.at()`
  时也一样：调 `state.error(...)` 而不是 `raise`。
- **返回码 `Result`**：

  | 成员 | 值 | 含义 |
  | --- | --- | --- |
  | `Result.Success` | 0 | 成功。⚠ `if rc:` 是「失败」，别写反 |
  | `Result.Error` | 1 | 一般错误（语法 / 编译 / 执行） |
  | `Result.UnknownError` | 2 | 未归类的错误 |
  | `Result.DuplicateWithBuiltinOpcode` | 3 | 自定义指令重名（见 `add_custom_opcode`） |

`stope/__init__.py` 导出了 31 个名字；AST 那 28 个节点类统一挂在 `stope.AST` 下。

---

## `stope` 顶层导出

```python
from stope import (
    AST, ASTVisitor, BinaryArrayParser, Compiler, CustomOpcode, CustomOpcodeConfig,
    Lexer, Opcode, Parser, Program, Result, Token, TokenType, disasm, disasm_no_custom,
    esc, fmt_bytes, fmt_g, kFirstCustomOpcode, optimize, type_name,
    StmlElement, StmlLexer, StmlParser, StmlState, StmlToken, StmlTokenType,
    Api, Arguments, Identifier, State,
)
```

内部模块也能按路径导入（`from stope.basic_vm import State`），顶层导出只是图省事。
STML 那一组带 `Stml` 前缀，是因为 `Lexer` / `Parser` / `Token` / `TokenType` 与 Stope 重名
—— 与 C# 侧 `using Stml = Stope.Stml` 是同一个理由。

---

## `common` —— 返回码与数值助手

C++ 没有对应物（那边直接写 `int64_t` 与 `double`）；这些东西存在的唯一理由是
**Python 的整数与浮点语义和 C++ 不一样**。

| 函数 | 说明 |
| --- | --- |
| `wrap64(v)` | 按 64 位补码回绕（等价 C++ 的 unsigned 算术 / C# 的 `unchecked`） |
| `int_div(a, b)` | 向零取整的整除，结果回绕。`b` 不能为 0 |
| `int_mod(a, b)` | 向零取整的余数（符号跟**被除数**） |
| `int_pow(base, exp)` | 快速幂，`exp >= 0`，溢出不检查、回绕 |
| `fdiv(a, b)` | IEEE 除法：`x/0 → ±inf`、`0/0 → nan`（Python 直接 `/` 抛异常） |
| `fmod(a, b)` | `std::fmod`：余数符号跟**被除数**（Python 的 `%` 跟除数）；`b == 0 → nan` |
| `trunc(v)` | `std::trunc`：向零取整但**保持浮点**；`±inf`/`nan` 原样返回 |
| `fpow(a, b)` | `std::pow`：负底数 + 非整数指数 → `nan`、溢出 → `±inf`、`0^-n → inf` |
| `is_special(v)` | 是不是 `nan` / `±inf` |
| `INT64_MIN` / `INT64_MAX` | `-2**63` / `2**63-1` |

**常量折叠与执行器共用这组函数** —— 同一个表达式折叠出来和执行出来的答案必须一样，
所以别在别处另写一份。

---

## `token` —— 词法单元

| 成员 | 说明 |
| --- | --- |
| `TokenType` | `IntEnum`，0..46，编号与 C++ 的 `stope::TokenType` 逐项相同。⚠ 两个成员叫 `True_` / `False_`（`True`/`False` 是 Python 关键字），打印一律走 `type_name` |
| `type_name(t)` | 编号 → 名字（`True_` 会打成 `True`） |
| `Token` | `__slots__ = ("line", "type", "lexeme", "parsed", "value")`。`value` 对整数是 `int`（已 int64 回绕）、浮点是 `float`、字符串是 `str`、二进制数组是 `bytes` |

---

## `lexer` —— 词法器

```python
lx = Lexer(src)                       # Lexer(input_src: str = "")
t = lx.next_token()                   # next_token(custom: CustomOpcodeConfig = None) -> Token
lx.errors                             # list[str]
```

| 成员 | C++ | 说明 |
| --- | --- | --- |
| `Lexer(src)` | `Lexer(u16string_view)` | 构造即持有整段源码 |
| `reset(src="")` | `Reset` | 换源码重来：清 `errors`、行号回到 1 |
| `next_token(custom=None)` | `NextToken(Token&)` | 取下一个 token。`custom` 让命名空间形式的自定义指令名识别成 `Custom` token |
| `errors` | `errors` | `line N: msg`，**不抛异常**；出错时产出一个 `Invalid` token 继续扫 |
| `line` | `line` | 当前行号（从 1 起） |
| `input` | `input` | **未消费**的剩余源码（C++ 是 `string_view` 左移，Python 是切片） |

错误文案（全部以 `line N: ` 开头）：`unexpected character. `、`invalid integer. `、
`invalid float. `、`unclosed string literal. `、`unclosed binary array. `、
`invalid escape character. `、`unclosed identifier. `、`unknown token. `。

---

## `opcode` —— 指令集与自定义指令登记

| 成员 | 说明 |
| --- | --- |
| `Opcode` | `IntEnum`，`Assign=0` … `Return=32`，共 33 项 |
| `kFirstCustomOpcode` | `33`（`Opcode.Return + 1`） |
| `CustomOpcode(opcode, arg_num=-1)` | 一条登记项。`arg_num < 0` 表示变长；属性 `is_var_arg` |
| `CustomOpcodeConfig()` | 名字 → 登记项。字段 `opcodes: dict[str, CustomOpcode]` |
| `config.add_custom_opcode(name, opcode, arg_num=-1)` | 登记一条；同名重复返回 `DuplicateWithBuiltinOpcode` 且**不插入** |

⚠ `Lexer` / `Parser` / `Compiler` **必须共用同一个 config 对象**。各建一份会出现
「编译期找不到指令」或「退化成普通函数调用」。

---

## `ast` —— 节点与形状串

| 成员 | 说明 |
| --- | --- |
| `AST.NodeType` | `IntEnum`，0..27（`Node` … `CustomOpcodeExpr`） |
| `AST.Prog` / `Stmt` / `Expr` / `Node` | 基类。每个节点都有 `line` 与 `node_type` |
| 24 个具体节点类 | `ExprStmt` … `CustomOpcodeExpr`，字段是 snake_case（`BinaryOpExpr(op, left, right)`、`LetStmt(...)`）。另有一个 `IfStmtElif`（`if` 分支的 `elif` 段，不是独立语句） |
| `AST.shape_prog` / `shape_stmt` / `shape_expr` | 形状串序列化（测试用，与 C++ 的 `Shape.cpp` 逐字一致） |
| `AST.BINOP_PREC` / `AST.BINOP_LITERAL` | 运算符优先级表与字面名表 |

⚠ `shape_*` 是**测试口径**，不进库的公开契约；golden 里的 `SHAPE=` 字段用它生成。

---

## `ast_visitor` —— 遍历骨架

```python
class MyVisitor(ASTVisitor):
    def on_visit_let_stmt(self, s) -> None:
        ...
```

| 成员 | C++ | 说明 |
| --- | --- | --- |
| `ASTVisitor` | `ASTVisitor` | 27 个 `on_visit_xxx` 空实现 + 递归下钻。子类只重写关心的那几个 |
| `visitor.visit(node)` | `Visit` | 按 `node.node_type` 查 `VISIT_MAP` 分发；钩子跑完**自动**递归子节点 |
| `VISIT_MAP` | `visitMap` | `NodeType -> 方法名`。⚠ 漏一项**不报错**，只静默跳过 |
| `on_visit_or_expr` / `on_visit_and_expr` | 同名 | 短路语义的钩子，默认不递归右子树 |

---

## `parser` —— 语法分析

```python
ps = Parser(lexer, config)      # Parser(lexer=None, custom=None)
ps.parse_program(tree)          # tree 必须是 AST.Prog() 实例
ps.errors                       # list[str]
```

| 成员 | C++ | 说明 |
| --- | --- | --- |
| `Parser(lexer, custom=None)` | `Parser(Lexer&, CustomOpcodeConfig*)` | 构造时就预读两个 token |
| `reset(lexer, custom=None)` | `Reset` | 换源码重来：清错误、重挂词法器、重读两个 token |
| `parse_program(prog)` | `ParseProgram` | 顶层入口。内部走 `parse_prog(prog, True, 1)` |
| `const_folding` | `constFolding` | 默认 `True`（构造 / `reset` 都会重置） |
| `max_depth` | `maxDepth` | 默认 256；`0` 表示不限 |
| `aborted` | `aborted` | 超深嵌套后置位：只报**一条**错误就停，避免刷上万条连锁错误 |
| `cur_token` / `peek_token` | `curToken` / `peekToken` | 当前 / 下一个 token |

⚠ 嵌套超限报 `line N: nesting too deep (max 256). `，返回**空节点**但**不逐层传染**
—— 下游解引用的地方自己判空（与另外四份实现一致）。

---

## `binarr_parser` —— `'...'` 里的字节

```python
buf = bytearray()
ok = BinaryArrayParser().parse_binary_array("d 1 2", buf)   # Result.Success
bytes(buf)                                                  # b"\x01\x02"
```

| 参数 | 说明 |
| --- | --- |
| `input_src` | 单引号**内部**的内容，不含引号 |
| `output` | `bytearray`，字节按顺序 append；调用方负责清空 |

默认十六进制；`b`/`o`/`d`/`x` 前缀（大小写都行）切二进制 / 八进制 / 十进制 / 十六进制；
空白与 `_` 可任意穿插；单个数超范围（> 255 或溢出）即失败。

---

## `expr_optim` —— 常量折叠

| 成员 | 说明 |
| --- | --- |
| `optimize(e)` | 对**一个**节点做折叠：折叠成功返回**新**节点，未折叠返回入参本身。不递归（挂在 parser 造节点的末尾，子节点已经折好） |
| `kind_of(e)` | 节点 → 常量分类（模块级整数常量：`NotConst=0`、`Null=1`、`Bool=2`、`Int=3`、`Float=4`、`String=5`、`BinArr=6`），与 C++ 的 `ConstKind` 同值 |

拿不准就一律不折叠：除零、含浮点的 `idiv`、跨类型 `==`、`null` 参与比较。
完整规则表见 [`cpp/docs/expr-optim.md`](../../cpp/docs/expr-optim.md) §4。

---

## `program` —— 编译产物

```python
p = Program()
p.opcodes              # list[int]，指令与操作数混排（int16 范围内）
p.variable_num         # 变量槽数量
p.exports              # dict[str, int]：导出名 -> 槽位
p.int_consts           # list[int]（已 int64 回绕）
p.float_consts         # list[float]
p.string_consts        # list[str]
p.binarr_consts        # list[bytes]
p.max_return_num       # return 语句的最大返回值数量
p.required_stack_size  # 求值栈峰值
p.clear()              # 清成刚构造的状态（Compile 开头会调）
p.to_map()             # 序列化成 dict（键名与 GD 的 to_map 一致）
```

⚠ **`opcodes` 是混排序列**：带操作数的指令后面紧跟一个数字（那是操作数，不是指令）。
判断某条指令带不带操作数用 `debug.opcode_has_arg(op)`；自定义指令用
`debug.custom_opcode_has_arg(op, config)`。

---

## `compiler` —— AST → Program

```python
c = Compiler(config)                      # Compiler(custom=None)
rc = c.compile(tree, program)             # 全引用；成功时 program 已填好
c.errors                                  # list[str]
```

| 约定 | 内容 |
| --- | --- |
| 失败时 | `compile()` 已把 `program` 清空（`opcodes` 为空），别拿去执行或反汇编 |
| 跳转 | `If(x)` / `GoTo(x)` 的 `x` 是 **`opcodes` 的下标**，不是指令序号 |
| 作用域 | `let` 只分配槽位；`export` 声明 + 进 `exports`；同名字双向报错 |
| 未声明就用 | `fmt:println(...)` 这种隐式登记进 `exports`，槽位号由编译器分配 |
| 自定义指令 | 未在 config 里登记的名字只是普通函数调用；登记了但参数个数不符 → 编译期报错且不产出 |

---

## `debug` —— 反汇编

| 函数 | C++ | 说明 |
| --- | --- | --- |
| `disasm(prog, config=None)` | `Disasm` | 带自定义指令名。`config` 缺省时 ≥33 的编号印成 `Custom#N` |
| `disasm_no_custom(prog)` | `DisasmNoCustom` | 只按内置 33 条解码（产物里不该有自定义指令时用） |
| `opcode_has_arg(op)` | `opcodeHasArg` | 内置指令是否带一个操作数 |
| `custom_opcode_has_arg(raw, config)` | 同名 | 自定义指令是否带操作数（只有变长指令带） |

输出与另外四份实现**逐字节一致**（`golden_disasm.txt` 是共同期望值）：编号列宽 8、
名字列宽 `max(10, 最长名字)`、`custom opcodes:` 段按**编号**排序、末尾是 warning 段。

⚠ 这不是「单行产物格式」——测试里那份更紧凑的格式在 `tests/golden.py` 的
`dump_program`，与 C++ 的私有 `dumpLine` 对应，**不进库**。

---

## `stml` / `stml_lexer` / `stml_parser` —— STML

```python
from stope import StmlElement, StmlLexer, StmlParser, StmlState

lx = StmlLexer(doc)                       # StmlLexer(source="", state=StmlState.Xml)
ps = StmlParser(lx)
root = StmlElement()
rc = ps.parse(root, state_func)           # state_func(tag, attrs) -> StmlState
```

| 成员 | 说明 |
| --- | --- |
| `StmlTokenType` | `IntEnum`，0..11（`Invalid` … `StopeSrc`），与 C++ 的值和名字都一样 |
| `StmlState` | `IntEnum`：`Xml` / `Text` / `Nevext` / `Stope` |
| `StmlElement` | `line` / `tag` / `attrs: dict[str,str]` / `self_closing` / `children: list` / `text`。**只有这 6 个字段** |
| `StmlLexer.next_token()` | `NextToken`。扫完 Text / Nevext / Stope 后自动交还 `Xml` |
| `StmlLexer.HAS_LEXEME` | 哪些类型的 `lexeme` 是跨实现可比的（标点与 Eof 不比） |
| `StmlParser.parse(root, state_func=default_state_func)` | 传 `None` 表示「一律 Xml」 |
| `default_state_func` | `<sto>` → Stope、`<nev>` → Nevext、`<p>` → Text，其余 Xml |

⚠ `attrs` 是 `dict`，**顺序不保证**（C++ 是 `std::map`，按名字排）。要稳定输出就
`sorted(e.attrs)`。同名属性保留**先出现的**那个（对应 `std::map::emplace`）。

---

## `basic_vm` —— 内置基础虚拟机（**不是标准，但会一直维护**）

会一直维护：bug 会修、跟 `Program` 演进同步、与其他四份实现语义对齐；接口不会随意调整
（改名、增删参数只为修 bug 或跟进 `Program`）。标准里没有它的位置，所以别把这些签名当
规范引用。能力边界见根 README「标准范围」的表格。

```python
from stope import Api, Arguments, State

state = State()
state.reset(Api(), program, args)          # 三样都给；同时清 returns/stack/errors
state.variables[program.exports["f"]] = fn # 宿主函数就是槽位里的一个值
state.run()
state.returns                              # list，return 带回来的值
```

| 成员 | C++ | 说明 |
| --- | --- | --- |
| `Api()` | `API` | 分派表 `op_map`（下标 = 指令编号，稠密 33 项） |
| `Api.set_opcode(n, fn)` | —（C++ 定长数组，扩不了） | 装自定义指令；**会把中间补齐**，跳号注册不留空洞 |
| `Arguments` | `BasicVM::Arguments` | 抽象基类，宿主实现 `at(state, key)` 与 `num()` |
| `Identifier(index)` | `Value{Identifier}` | 槽位引用。`PushId` 压它，只有 `Assign` 认它 |
| `State.reset(api, program, args=None)` | `SetAPI` + `SetProgram` + … | 一次做完：清 `returns` / `stack` / `errors`，按 `variable_num` 开槽位 |
| `State.run()` | `Run` | 跑到结束；出错立即停 |
| `State.step()` | `Step` | 走一条。与 `run()` 是两份独立实现，语义必须一致（`V-21` 锁着） |
| `State.error(msg)` | `Error` | 记一条 `"<指令下标>: msg"` |
| `State.at_top(k)` / `pop()` / `pop_n(n)` / `push_int(v)` | 同名 | 栈操作。`at_top(1)` 就是栈顶 |
| `State.variables` / `stack` / `returns` / `errors` / `i` | 同名 | 槽位 / 求值栈 / 返回值 / 错误 / 指令指针 |

值的表示：`None` / `int`（int64 语义）/ `float` / `str` / `bytes` / 可调用对象 / `Identifier`。
**没有 `bool`**：`PushTrue`/`PushFalse` 压的是整数 1/0；宿主函数返回 `bool` 会被归一。

运行期错误文案（全部是 `"<下标>: "` + 下面某一条）：

| 消息 | 触发 |
| --- | --- |
| `"Add" cannot operate on null. ` | `null` 参与算术 |
| `"Add" can only operate on numbers, strings or bin arrays. ` | 类型不支持 |
| `"Div" division by zero. ` | 两侧**都是整数**且除数为 0（任一侧浮点走 IEEE） |
| `"Call" can only call a function. ` | 被调值不是函数 |
| `index must be integer. ` / `index out of range. ` | `a[i]` 的 `i` |
| `no implement for container type. ` | 对非 String / BinArr 取下标 |
| `no args. ` | 没给实参表却用了 `argc` / `args[i]` |
| `stack underflow. ` / `no implement for value type. ` | `Assign` 的左值不是 `Identifier` |
| `"Mul" cannot repeat a sequence by a negative number. ` | 负数次重复 |
| `only on integer or float can be compared. ` | `<` / `>` 用在非数值上 |

跨实现比对时**只比 `: ` 之后那段** —— 前缀各实现不同（GD 是 `"<下标> <指令名>: "`）。

---

## `format` —— 跨实现逐字节一致的小工具

| 函数 | 说明 |
| --- | --- |
| `esc(s)` | `escUtf8`：`\ " \n \r \t` 转义，**非 ASCII 一律 `?`** |
| `fmt_g(v)` | `printf("%g")`，浮点常量与形状串共用 |
| `fmt_bytes(b)` | 二进制数组 → `01,0a,ff` |
