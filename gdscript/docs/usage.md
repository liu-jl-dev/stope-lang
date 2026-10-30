# GDScript 实现 · 使用手册

本文按调用顺序讲每个类的接口。**契约以 C++ 为准**（`cpp/include/stope/*.hpp`），
这里只写 GDScript 侧怎么用、哪些地方长得不一样。

> 总览（定位、目录、怎么装）见 [`README.md`](README.md)。

先记住三条全局约定：

1. **不抛异常。** 所有错误都追加到该对象的 `errors: Array[String]`，格式统一为
   `line N: msg`；`errors` 非空表示这一步不可信，后续阶段不该继续。
2. **`reset` 复用，不必重建对象。** 词法器、语法器、编译器都有 `reset`，与 C++ 的
   `Reset` 对应；`Compiler.compile()` 内部也会先清空输出。
3. **输入输出都是引用语义。** `parse_program(tree)`、`compile(tree, program)` 都是把结果
   **写进**传进去的对象，没有返回值（`compile` 返回的是错误码）。
4. **返回码只有一个枚举：`StopeResult`。** 编译器、STML 语法器、指令表注册共用它，
   `Success / Error / UnknownError / DuplicateWithBuiltinOpcode` 四项与 C++
   `Stope::Result` 一一对应。**`Success == 0`，别写 `if rc:` 当成功。**

---

## 1. 词法：`StopeLexer`

```gdscript
var lexer := StopeLexer.Lexer.new("let a = 1;")		# 也可以 new() 后 reset(src)
while true:
	var t := lexer.next_token()
	print(t.line, " ", StopeLexer.Token.type_name(t.type), " ", t.literal)
	if t.type == StopeLexer.Token.Type.Eof: break
print(lexer.errors)		# [] 表示没有词法错误
```

### 1.1 接口

| 成员 | 说明 |
| --- | --- |
| `Lexer.new(input := '')` | 构造即 `reset` |
| `reset(input: String)` | 换源码，行号归 1，清空 `errors` |
| `next_token(custom := null) -> Token` | 取下一个 token；`custom` 是 `StopeOpcode.CustomOpcodeConfig` |
| `errors: Array[String]` | `line N: msg` |
| `line: int` | 当前行号（1 起） |
| `input: String` | **未消费的剩余**原文（每取一个 token 就左移一截），不是完整源码 |

> 词法器**不保留完整原文**（早期有个 `src` 字段，只赋值过、没人读，已删）。要拿原文
> 自己存一份；`input` 只表示「还剩多少没扫」。

`custom` **不存在词法器里**，而是每次取 token 时传进来 —— 与 C++ `Lexer::NextToken(cfg)`
一致：换一张自定义指令表不必重建词法器。用 `StopeParser` 时它会在内部代传。

### 1.2 `Token`

| 字段 | 说明 |
| --- | --- |
| `type: int` | `StopeLexer.Token.Type`，共 47 项（`Invalid` … `Custom`） |
| `line: int` | 起始行号 |
| `literal: String` | 原文切片。**只有** String / BinArr / 数字 / 标识符有值，标点没有 |
| `parsed: String` | 规范形式：数字去掉 `_`、标识符拼好 `:`、字符串**转义之后**的文本 |
| `int_value: int` | 仅 `Integer` |
| `float_value: float` | 仅 `Float` |
| `invalidate()` | 把 `type` 打回 `Invalid` |

取值规则容易记错，列表摆在这里：

| token | 从哪取 |
| --- | --- |
| `Integer` | `int_value` |
| `Float` | `float_value` |
| `String`（`"..."`） | `parsed`（已去转义；`literal` 是原始切片） |
| `BinArr`（`'...'`） | `literal`（**不做任何转义**，字节由 `StopeBinArrParser` 解析） |
| `Ident` | `parsed`（`a : b` 的空白已吃掉，拼成 `a:b`） |

`Token.type_name(t)` 是静态方法，越界时返回 `"?(n)"`，可以直接拿去打日志。

### 1.3 数字

四种前缀 + 两种十进制形态，全部在**词法阶段**就判合法性（不是留给上层）：

| 写法 | 结果 |
| --- | --- |
| `0b1010` / `0o777` / `0x1F` | `Integer`，允许中间插 `_` |
| `123` / `1_000` | `Integer` |
| `1.5` / `1.` / `.5` | `Float` |
| `1e10` / `1.5E-3` / `.5e+2` | `Float` |

失败一律 `Invalid` + 错误，错误文案只有两种：`invalid integer. ` / `invalid float. `。
判失败的条件：前缀后面没有数字（`0x`）、出现该进制不允许的字符（`0b2`）、
超出 `int64`、指数绝对值超过 308、`is_inf` / `is_nan`。

### 1.4 字符串与二进制数组

- `"..."`：支持 `\\ \" \' \b \f \n \r \t \v`；非法转义报 `invalid escape character. `，
  报错后**停止收集**（`type` 仍是 `String`，`parsed` 截断在出错位置）；未闭合报
  `unclosed string literal. ` 并 `invalidate`。
- `'...'`：二进制数组，内容原样保留，**不转义**、**跨行会累加行号**（字符串跨行不累加，
  这一点与 C++ 一致，属已知待定项）。

### 1.5 标识符与自定义指令

标识符允许用 `:` 分段（`fmt:println`），`:` 两侧可以有空白。判定顺序与 C++ 一致：

1. 命中 `key_words` → 对应关键字类型（`if` / `let` / `export` …）；
2. 否则命中 `custom.opcodes` → `Type.Custom`；
3. 否则 `Type.Ident`。

所以注册一个叫 `if` 的自定义指令**不会生效**，它仍然是关键字。

未知字符：消费 1 个码元、`type = Invalid`、报 `unknown token. ` —— 必须消费，否则上层
循环没有终止条件（这是词法计划 `LEX-P-07` 的硬要求）。

---

## 2. 语法：`StopeParser`

```gdscript
var lexer := StopeLexer.Lexer.new(src)
var parser := StopeParser.Parser.new(lexer)		# 第二参 custom 可省
var tree := StopeAst.Prog.new()
parser.parse_program(tree)
print(parser.errors, " / 词法错误: ", lexer.errors)
```

### 2.1 接口

| 成员 | 说明 |
| --- | --- |
| `Parser.new(lexer, custom := null)` | 构造即预读两个 token（`cur` / `peek`） |
| `reset(lexer, custom := null)` | 复用解析器 |
| `parse_program(prog: StopeAst.Prog)` | 顶层：吃到 `Eof` 为止 |
| `parse_prog(prog, is_top_level: bool)` | 顶层 / 块内共用实现，区别在遇到 `}` 时怎么收尾 |
| `errors: Array[String]` | `line N: msg`，**不**合并词法错误 |
| `const_folding: bool = true` | 常量折叠开关，测试里按用例切换 |
| `max_depth: int = 256` | 嵌套深度上限（表达式与语句块共用一个计数器），`0` = 不限制；与 C++ 的 `Parser::maxDepth` 同值 |
| `has_err() -> bool` | 等价于 `not errors.is_empty()` |

词法错误和语法错误是**两套** `errors`，调用方自己决定怎么合并（C++ 侧同样不合并，
见 parser 计划 `B-12`）。

### 2.2 优先级与结合性

`StopeAst.Precedence` 共 10 档，从低到高：`Lowest` → `Or` → `And` → `Equals` →
`LessGreater` → `AddSub` → `MulDiv` → `Pow` → `Prefix` → `Paren`。

`^` 是**右结合**：`2^3^2` 解析成 `2^(3^2)`。实现方式是中缀函数里把阈值减 1
（`prec -= 1`）再递归，而不是改主循环 —— 主循环的 `while` 不要动。

### 2.3 错误恢复

缺分隔符时**只报错、不推进**（`expected ")". ` / `expected "]". ` …），避免吞掉后面的
token。少数语句解析入口（`let` / `return`）例外，与 C++ 保持一致。

不能出现的 token 会得到 `no prefix parse function for token type. `，此时返回一个裸
`StopeAst.Expr`（形状串打印成 `Err(行号)`），让解析继续。

嵌套超过 `max_depth` 时报 `line N: nesting too deep (max 256). ` 并**停止解析**：只报这
一条（连锁错误不再记账），已解析完的语句保留在 `prog.stmts` 里。此时 `left_expr` 之类的
子节点可能是 `null` —— **`errors` 非空就不要把 AST 交给编译器或执行器**。

### 2.4 AST 形状串

`StopeAst.shape_prog(tree)` 把整棵树压成一行文本，测试就是拿它逐字节对比 C++。格式：

```
Int(31) / Float(1.5) / Str("a\nb") / BinArr[04,01] / Ident(a) / Null / Bool(true) / Argc
Args(null) / Unary(Sub, Int(1)) / Bin(Add, Int(1), Int(2))
Call(f; Int(1)) / At(a; Int(1)) / Custom(myop; Int(1)) / Err(L-1)
ExprStmt(..) / Let[a,b]=Int(1) / Return(Int(1), Int(2)) / Export[a]
Block{..} / If(c){..}Elif(c){..}Else{..} / While(c){..} / Assign(l, r) / Break / Continue
```

语句之间用 ` ; ` 连接，没有外层包装；空程序是空串。

---

## 3. AST：`StopeAst`

28 种节点，`node_type` 与 C++ 的 `AST::NodeType` **同序同值**。字段名是 C++ 的
snake_case 版本，一一对应：

| 节点 | 字段 | 备注 |
| --- | --- | --- |
| `Prog` | `stmts` | |
| `ExprStmt` | `expr` | |
| `LetStmt` | `has_assign`、`idents: Array[String]`、`expr` | `let a, b;` 无初值 |
| `ReturnStmt` | `exprs` | 可空（`return;`） |
| `ExportStmt` | `idents` | |
| `BlockStmt` | `prog` | 永远非 null（C++ 是值成员） |
| `IfStmt` | `cond`、`first_prog`、`elifs`、`else_prog` | `else_prog == null` 表示没有 else |
| `IfStmtElif` | `cond`、`prog` | 不是 `Node_` 子类型，只挂在 `elifs` 里 |
| `WhileStmt` | `cond`、`prog` | `cond == null` 表示 `while { }` |
| `AssignStmt` | `left_expr`、`right_expr` | |
| `BreakStmt` / `ContinueStmt` | — | |
| `NullExpr` / `ArgcExpr` | — | 叶子 |
| `BoolExpr` / `IntExpr` / `FloatExpr` / `StringExpr` | `value` | |
| `BinArrExpr` | `value: PackedByteArray` | |
| `IdentExpr` | `ident: String` | |
| `ArgsExpr` | `key_expr` | `args[]` 缺下标时为 null |
| `UnaryOpExpr` | `op`（TokenType）、`expr` | |
| `BinaryOpExpr` | `left_expr`、`op`、`right_expr` | |
| `CallExpr` | `callee`、`args` | |
| `AtExpr` | `container`、`key_exprs` | |
| `CustomOpcodeExpr` | `opcode_name`、`args` | |

基类 `Node_` 有 `line` 与 `node_type`；`Stmt` / `Expr` 只是加了默认 `to_str`。
注意 `op` 存的是 `StopeLexer.Token.Type`，不是字符串；要显示用 `StopeAst.binop_literal_map`。

---

## 4. 遍历：`StopeASTVisitor`

```gdscript
class MyPass extends StopeASTVisitor.ASTVisitor:
	func on_visit_ident_expr(e: StopeAst.IdentExpr) -> void:
		print("用到了变量 ", e.ident, " @", cur_line)
```

| 成员 | 说明 |
| --- | --- |
| `visit(n)` | 按 `n.node_type` 查 `visit_map` 派发；`null` 直接返回 |
| `visit_map` | `NodeType -> 方法名字符串`，25 项 |
| `cur_line` | 最近一次 `visit` 看到的行号，给没有专属行号的诊断用 |
| `on_visit_xxx(n)` | 25 个钩子，默认实现是「按源码顺序递归子节点」 |

与 C++ 的唯一区别在分发表：C++ 存的是强转用的函数指针，GD 的节点本来就是对象，所以表里
存**方法名字符串**，用 `call(fn, n)` 派发 —— `call` 同样会走到子类的重写版本。

- 三个裸基类（`Node` / `Stmt` / `Expr`）**没有表项**，它们在错误恢复路径上出现，
  `visit()` 会静默跳过。
- `BinaryOpExpr` 有短路专用钩子：`on_visit_binary_op_expr` 命中 `or` / `and` 时会转给
  `on_visit_or_expr` / `on_visit_and_expr`。默认实现与普通路径等价，只有编译器重写它们。
- 重写后要继续下钻，调 `super.on_visit_xxx(n)`。

`StopeCompiler.Compiler` 就是这个骨架的子类：凡是需要发指令的钩子整段重写，其余靠基类递归。

---

## 5. 编译器：`StopeCompiler`

```gdscript
var compiler := StopeCompiler.Compiler.new()		# 第二参 custom 可省
var program := StopeProgram.Program.new()
var rc := compiler.compile(tree, program)
if rc != StopeResult.Success:
	print(compiler.errors)		# program 已被清空
```

### 5.1 接口

| 成员 | 说明 |
| --- | --- |
| `Compiler.new(custom := null)` | |
| `reset(custom := null)` | 清错误、换自定义指令表 |
| `compile(ast: Prog, out: Program) -> int` | 返回 `StopeResult`；**有错时清空 `out`** |
| `errors: Array[String]` | `line N: msg` |

返回值是 `StopeResult` 里的 `Success` / `Error`，与 C++ 的 `Stope::Result` 同一份定义
（见开头第 4 条）。`compile` 只会给出这两个值；另两个是保留项 ——
`DuplicateWithBuiltinOpcode` 现在由 `add_custom_opcode` 用来报重名，见 §7。

### 5.2 它负责的三件难事

1. **跳转回填**：`If` / `GoTo` 的操作数是 `opcodes` 的**槽位下标**，不是字节偏移。先写
   `-1` 占位，块解析完再 `_patch_index`。
2. **栈容量记账**：`StackSizeManager` 在每个分支汇合点 `converge(深度)`，算出的
   `max_size` 写进 `required_stack_size`。
3. **变量索引分配与回收**：块作用域退出时把局部变量索引还进 `MinHeap` 复用；未声明的
   标识符登记为**外部变量**，进 `Program.exports`（名字非空即导出）。

`_emit_index` / `_patch_index` 都做 **int16 越界检查**（`-32768..32767`），越界报
`compile output too large: ...`。回绕出来的跳转目标会把执行器带飞，所以宁可报错。

### 5.3 会报哪些错

| 文案 | 触发 |
| --- | --- |
| `duplicate declaration of 'x'. ` | 同一作用域重复 `let` |
| `duplicate export of "x". ` | 同一名字重复 `export` |
| `"export" can only be used at top scope. ` | 块内 `export` |
| `cannot use "break" outside of a loop. ` / `... "continue" ...` | 循环外跳转 |
| `undefined custom opcode "x". ` | 没注册就用了 |
| `custom opcode "x" expected N args, but got M. ` | 定长指令参数个数不符 |
| `compile output too large: ...` | 索引或跳转目标超 int16 |

行列信息取节点的 `line`；没有专属行号的用基类维护的 `cur_line`。

---

## 6. `Program` 与序列化

`StopeProgram.Program` 的字段与 C++ 同名（snake_case）：

| 字段 | 含义 |
| --- | --- |
| `opcodes: Array[int]` | 指令与操作数混排 |
| `variable_num: int` | 变量槽位数 |
| `exports: Dictionary[String, int]` | 导出变量名 → 槽位 |
| `int_consts` / `float_consts` / `string_consts` / `bin_arr_consts` | 四个常量池，同值只存一份 |
| `max_return_num: int` | 所有 `return` 里最大的返回值个数 |
| `required_stack_size: int` | 执行期栈深峰值 |

`Program.new()` 拿到的就是可直接编译的空程序（所有容器都有默认值）。

```gdscript
print(program.to_json_string())					# {"c":[...],"i":[...],...}
print(program.to_map())						# 同上，给 Dictionary
```

**文本形式不在这里，用 §6.1 的 `StopeDebug.disasm`**。理由和 C++ 侧一样：`Program`
是数据结构，人读的反汇编是另一件事（`debug.hpp` 的 `Disasm`），单行比对格式则是测试
专用的（C++ 放在 `tools/golden.cpp` 的私有 `dumpLine` 里，GD 放在 `test/test_util.gd`
的 `dump_program` 里），三方各归其位。

> 测试侧那个 `StopeTestUtil.dump_program(p, cis)` 产出跨实现比对用的单行文本
> （`code[...] vars=N stack=N ...`，格式见 `docs/zh-cn/compiler-test-plan.md` §2.3）。
> 它不是库 API —— 宿主代码不该依赖它，格式是测试契约、随时可能随契约调整。

### 6.1 人读格式：`StopeDebug.disasm`

与 C++ `debug.hpp` 的 `Disasm` / `DisasmNoCustom` **同名同形**：

```gdscript
print(StopeDebug.disasm(program, cfg))		# cfg 可省
print(StopeDebug.disasm_no_custom(program))	# 明确「没有自定义指令」
```

| 成员 | 说明 |
| --- | --- |
| `disasm(prog, config := null) -> String` | 编号列 + 对齐的名字列 + 自定义指令表 + 变量表 + 常量池 + warning |
| `disasm_no_custom(prog) -> String` | 同上，`config = null` |
| `opcode_has_arg(op) -> bool` | 内置指令是否带操作数（转发 `StopeOpcode.has_a_param`） |
| `custom_opcode_has_arg(raw, config) -> bool` | 自定义指令是否带操作数（只有变长才带「参数个数」） |

**含自定义指令时必须传注册时用的那份 config**：否则名字丢了，而且变长指令后面那个
「参数个数」会被当成下一条指令 —— 两者只差一个 int，整段会错位。编号撞内置会被报成
warning（`builtin decoding wins`），因为 `opcodes` 是 int 混排，运行时根本分不清。

输出与 C++ **逐字节一致**，warning 文案也是同一串（所以 `test/data/golden_disasm.txt`
能拿 C++ 的产物直接当期望值）。

---

## 7. 自定义指令

```gdscript
var cfg := StopeOpcode.CustomOpcodeConfig.new()
cfg.add_custom_opcode("myop", 100, 2)		# 定长 2 个参数
cfg.add_custom_opcode("vop", 101, -1)		# arg_num < 0 表示变长

var parser := StopeParser.Parser.new(StopeLexer.Lexer.new(src), cfg)
var compiler := StopeCompiler.Compiler.new(cfg)
```

| 类型 | 字段 |
| --- | --- |
| `CustomOpcode` | `name`、`opcode`、`arg_num`（`-1` = 变长） |
| `CustomOpcodeConfig` | `opcodes: Dictionary[String, CustomOpcode]` + `add_custom_opcode(name, opcode, arg_num := -1) -> int` |

规则：

- **重名不插入。** `add_custom_opcode` 与 C++ 的 `addCustomOpcode` 一样，同名再注册
  返回 `StopeResult.DuplicateWithBuiltinOpcode` 且保留第一次那个；新注册返回
  `StopeResult.Success`。返回值可以丢弃（GDScript 允许），要防手误就接一下。
- 编号必须 **> 32**，`StopeOpcode.FIRST_CUSTOM_OPCODE` 就是 33。占 0..32 会在反汇编时
  被当成内置指令解码，没有别的选择。**查重只看名字，不看编号** —— 用内置编号注册
  不会报错，`demo_03` 最后一段演示的正是这个坑。
- 定长指令参数个数不符时**报错但仍发指令**；变长指令会多写一个「实参个数」操作数。
- 编译器记账是 `dec(参数个数 - 1)`：自定义指令没有 callee 入栈，结果占 1 格。
- 词法器按名字认 `Type.Custom`，所以注册名不能与关键字重名（关键字优先）。

`StopeOpcode.has_a_param(inst)` 判断内置指令是否带一个操作数，分档与 golden 探针、
执行器的步进规则完全一致；序列化和反汇编共用它。

> ⚠ 想打印自定义指令的名字，用 `StopeDebug.disasm(prog, cfg)` —— 它拿 config 反查名字、
> 按变长决定吃不吃参数个数，编号撞内置还会报 warning。`StopeTestUtil.dump_program`
> 是测试比对格式，自定义指令一律打成 `Opcode(33)`，**不反查名字**。

### 7.1 怎么真的执行这些编号

编译器只负责把编号写进 `opcodes`，**执行是宿主的事**。参考执行器的分派表 `Api.op_map`
是**稠密的 `Array[Callable]`，下标就是编号**，`run()` / `step()` 直接 `op_map[opcode]` 取 ——
所以注册 N 号就必须让数组长度 ≥ N+1，且 0…N 每一格都是**有效** Callable。

```gdscript
class Host:
	# my:add：弹 2 个、压 1 个。s.i 已经指着这条指令本身
	func my_add(s:StopeBasicVM.State) -> void:
		var b = s._pop_and_get_value()
		var a = s._pop_and_get_value()
		s.stack.push_back(a + b)

var host := Host.new()
var api := StopeBasicVM.Api.new()
api.op_map.resize(34)					# 33 号要能下标取到 ⇒ 至少 34 项
api.op_map[33] = host.my_add				# 33 = my:add 的编号

var state := StopeBasicVM.State.new()
state.reset(api, program, args)				# args 是你自己的 Arguments 实现
print(state.run(), state.returns)			# true [3]
```

上面这段是照可运行代码抄的：`my:add` 注册在 33、源码 `let x = my:add(1, 2); return x;`。

三条不照做会踩：

| 漏了 | 现象 |
| --- | --- |
| 不 `resize` | `SCRIPT ERROR: Out of bounds get index '33'`，`run()` 当场中止并返回 `false`，**`errors` 却是空的**（错误没走 `state.error`），只在 Godot 控制台里 |
| `resize` 了但 33…N-1 留空 | `Attempt to call function 'null::null (Callable)'`，同样中止 |
| 把编号占进 0…32 | 内置实现赢，你的处理函数永远不会被调用（反汇编也只会印内置指令名） |

> 在自定义指令里调 `state.error()` 时，错误串的指令名印成 `Custom<N>` —— 枚举里没有这个
> 编号，别指望看到注册名。要看名字用 `StopeDebug.disasm(prog, cfg)`。

---

## 8. 常量折叠：`StopeExprOptim`

```gdscript
var folded := StopeExprOptim.optimize(expr)	# 折了就返回新节点，没折返回入参本身
```

`Parser` 已经接好了：在构造 `UnaryOpExpr` / `BinaryOpExpr` 的末尾调用，子节点返回时
就已折好，所以整棵树是**自底向上**折完的。要关掉就把 `parser.const_folding = false`。

契约：

- **只做单节点变换，不递归。** 别改成把 `parse_expr` 包一层 —— 那样会重复折。
- 折不了就原样返回：除零、整数溢出、含浮点的 `idiv`、跨类型 `==`、`null` 参与比较、
  `Bool` 参与比较 —— 全部保留原节点，把计算推给运行期。
- 折叠后的节点沿用运算符节点的 `line`。

算术规则以 [`cpp/docs/expr-optim.md`](../../cpp/docs/expr-optim.md) 为准，其中三条是
本项目自定的：`BinArr + BinArr` 是字节连接；`String / BinArr * 非负整数` 是串重复；
`+ - * / idiv % ^` 里 `Bool` 当 `0` / `1`（但比较运算仍按类型区分）。

> 折叠判定必须与执行期一致，否则「字面量」和「变量」两条路径会算出不同结果。
> 2026-10-21 用 2953 组输入对过 C++ 两支探针，零差异；GD 侧 2026-10-28 起也接了折叠，
> 由 `golden_binarr.txt` 的 `FB` / `FU` 记录守着。

---

## 9. 参考执行器：`StopeBasicVM`

**这不是标准。** 它只用来验证 `Program` 能跑，接口随时可能变；自己写执行器请照
[`docs/zh-cn/vm-guide.md`](../../docs/zh-cn/vm-guide.md)。

```gdscript
class MyArgs extends StopeBasicVM.Arguments:
	var data: Array = []
	func _init(v: Array) -> void: data = v
	# 取不到就自己报错：state.error(...) + 返回 null，VM 会立刻停在这个位置
	func at(state: StopeBasicVM.State, key) -> Variant:
		if not (key is int) or key < 0 or key >= data.size():
			state.error('argument out of range. ')
			return null
		return data[key]
	func num() -> int: return data.size()

var state := StopeBasicVM.State.new()
state.reset(StopeBasicVM.Api.new(), program, MyArgs.new([1, 2, 3]))
if not state.run():
	print(state.errors)
print(state.returns)
```

| 成员 | 说明 |
| --- | --- |
| `State.reset(api, program, args)` | 三样都要给；同时清 `returns` / `stack` / `errors` |
| `State.run() -> bool` | 跑到 `opcodes` 末尾；`errors` 非空立刻返回 false |
| `State.step() -> bool` | 单步执行一条指令：`true` = 这条跑完了、可以接着 step；`false` = 停了（`errors` 非空 = 出错，否则 = 指令流走完）。`while s.step(): pass` 与 `s.run()` 走同样的指令、得到同样的结果 |
| `State.returns: Array` | `return` 的返回值，按出现顺序 |
| `State.errors: Array[String]` | `"i OpName: msg"`（`i` 是指令下标） |
| `State.error(msg)` | 宿主的报错入口（对应 C++ `State::Error`）；写进 `errors` 后 `run`/`step` 立即停 |
| `Api.op_map: Array[Callable]` | 33 项，下标 = opcode；要跑自定义指令得先扩表，见 §7.1 |

### `State` 的字段

写指令处理函数、或者自己接管执行流程时要用到这些（`returns` / `errors` 见上表，不重复）：

| 字段 | 说明 |
| --- | --- |
| `api` / `program` / `args` | `reset` 传进来的三样，执行期间只读 |
| `i: int` | 指令指针。**执行中**指着当前这条指令；`run` / `step` 在末尾统一 `+1` |
| `stack: Array` | 数据栈，栈顶是 `stack.back()`（= `stack[-1]`） |
| `variables: Array` | 变量槽位，长度 = `program.variable_num`；`reset` 已 `resize` 好，初值 `null` |

### 写一条指令处理函数

签名固定 `func(s:State) -> void`，靠副作用干活：

| 约定 | 说明 |
| --- | --- |
| 操作数 | `s.i` 已指着这条指令，**先 `s.i += 1` 再读** `s.program.opcodes[s.i]`；循环末尾还会统一 `+1`，别自己多推 |
| 栈效果 | 参数已按从左到右压好；结果压回栈顶、占 **1 格**；自定义指令**没有 callee 入栈**（编译器 `dec(参数个数 - 1)` 就是这条） |
| 变长指令 | 流里在参数之后多一个「实参个数」操作数，先读它 |
| 取值 | 用 `s._pop_and_get_value()` 弹栈并自动解引用 `Identifier`；直接读 `s.stack[-1]` 可能拿到槽位引用 |
| 报错 | `s.error(msg)`（等价于 `s._error(msg)`）：写进 `errors`，`run` / `step` 立刻停 |
| 跳转 | 改 `s.i` 时目标要 `-1`（末尾还有 `+1`）；`Return` 的做法是把 `s.i` 拨到 `len(opcodes)` |

`Api.op_map` 里那 33 个 `_xxx` 就是按这套写的，可以直接当模板。`_pop_and_get_value()` /
`_error()` 虽然带下划线，但 GDScript 没有访问控制，处理函数里直接调就是 —— 下划线只是
「内部用」的约定。

`step()` 与 `run()` 是**两份独立实现**，`run()` 不在循环里调 `step()`（热循环里每条指令
多一次函数调用，GDScript 下是实打实的开销）。代价是改步进规则要同时改两处 ——
`test/test_vm.gd` 就是防止它们漂开的锁：同一程序走两条路径，`returns`、`errors`、
停机时的 `i` 必须逐项相同。

C++ 侧是反过来的：`State::Run()` 就复用 `State::Step()`（header-only + 隐式 inline，展开后
没有额外开销），只有一份步进规则，见 [`cpp/docs/basic-vm.md`](../../cpp/docs/basic-vm.md) §1。

### 宿主函数怎么进去

执行器没有独立的「函数表」：`Call` 就是把栈上的一个值当函数调，这个值必须是 `Callable`。
所以做法是**往变量槽里填 Callable**：

```gdscript
# 编译器把未声明的 fmt:println 当成外部变量，登记进了 exports
state.variables[program.exports["fmt:println"]] = Callable(host, "println")
```

宿主函数签名统一为 `func(args: Array) -> Variant`：参数整包进来，自己拆 —— 与 C++ 的
`args` span 同一思路。`demo/demo_01.gd` 里有完整例子。

`Arguments.at(state, key)` 与 C++ 的 `at(State&, const Value&, Value& out) -> Result` 等价：
错误走 `state.error(msg)` 进同一个 `errors`，VM 立即停 —— 宿主不再有「取不到参却只能
`push_error` 到 Godot 控制台」的情况。

### 与 C++ 执行器的已知差别

| 点 | GD 侧 |
| --- | --- |
| `Identifier` 包装 | 有（`StopeBasicVM.Identifier`），`PushId` 压它，`Assign` 靠它取槽位 |
| `At` 的 key 数 | 只支持 1 个，其它报 `no implement for key num != 1. ` |
| `At` 的容器 | 只支持 `PackedByteArray` 与 `String`；取字符串给的是**码点**（`unicode_at`） |
| `-true`、`true + 1`、`"ab" * 3` | **报错**：`_minus` / `_add` / `_mul` 只接受数值（GDScript 里 `bool` 不是 `int`）。常量折叠已按 C++ 规则折成 `Int(-1)` / `Int(2)` / `String(ababab)`，所以字面量形态看不出来；变量形态（`let x = true; -x;`）会撞上 |
| 整数除零 | 引擎级 `SCRIPT ERROR`，**当前函数直接中断**、`errors` 里看不到（`_div` 先做 `a % b`，所以 `1 / 0` 同样会撞） |

前两条是刻意保留的简化：它只是参考实现，`vm-guide.md` 是给自写执行器看的。
第四条是与 C++ 的**真实差异**，登记在 [`cpp/docs/expr-optim.md`](../../cpp/docs/expr-optim.md) §7。

---

## 10. STML：`STML` / `STMLLexer` / `STMLParser`

STML 是"两半"：**树的形状**由 `STMLParser` 管（标签名、属性、嵌套、结束标签配对），
**内容怎么切**由宿主管 —— 就是 `parse()` 的第二个参数。

```gdscript
func _state_func(tag:String, attrs:Dictionary) -> int:
	if tag == 'config': return STMLLexer.State.Nevext
	if 'stope' in attrs: return STMLLexer.State.Stope
	return STMLLexer.State.Xml    # 其余按子元素列表解析

var lx := STMLLexer.Lexer.new(src)
var p := STMLParser.Parser.new(lx)
var root := STML.Element.new()
var result:int = p.parse(root, _state_func)   # 传 Callable() 等价于不传回调（一律 Xml）
print(root.to_str())
print(p.errors, lx.errors)                    # 两边不合并，都要看
```

| 类型 | 成员 |
| --- | --- |
| `STMLLexer.Lexer` | `new(source := "")`、`next_token()`、`state`（`Xml` / `Text` / `Nevext` / `Stope`）、`errors` |
| `STMLParser.Parser` | `new(lex)`、`parse(root, state_func) -> int`、`errors` |
| `STML.Element` | `line`、`tag`、`attrs: Dictionary[String,String]`、`self_closing`、`children`、`text`、`to_str(level := 0)` |
| `STML.Token` | `line`、`type`、`lexeme`；`Type` 的 12 项**名字与 C++ 完全一致**（`String` / `NevextSrc` / `StopeSrc`），打名字直接用 `Type.keys()[t]`，没有 `type_name()` |

`parse()` 返回的就是 `StopeResult.Success` / `StopeResult.Error`（与编译器共用同一份枚举，
见开头第 4 条），不再有 `STMLParser.Result` 这一份独立的。

回调返回什么，元素内容就按哪种状态扫，与 C++ 的 `LexerStateFunc` 一一对应：

| 返回 | 后果 |
| --- | --- |
| `Xml` | 元素内容是**子元素列表**；此时出现裸文本是错误 |
| `Text` | 整段当普通文本（只认 `</`，`<b/>` 会被吃掉） |
| `Nevext` / `Stope` | 整段当代码段（跳过引号串与注释，其中的 `</` 不算结束标签） |

宿主侧要注意的四点（都不是 bug，是设计如此）：

1. **词法与语法的 `errors` 不合并**：`lx.errors` 与 `p.errors` 各查各的。
2. **顶层只解析一个元素**，根之后的剩余输入被忽略。
3. **属性顺序不保证**：`attrs` 是 `Dictionary`（插入序）；要稳定顺序就自己排序。
4. **元素内文本只有一段**、不拼接；`children` 与 `text` 互斥。

回调收到的 `attrs` 是**副本**（`stml_parser` 里 `e.attrs.duplicate()`）：删键、加键、
改值都不会影响解析结果，与 C++ 按值收 `std::map` 等价。

剩下的两条差异（遍历顺序、非 BMP 字符）登记在
[`docs/zh-cn/stml-test-plan.md`](../../docs/zh-cn/stml-test-plan.md) §7 的 GD-S-17/18。
完整的 STML 语义看 [`cpp/docs/stml.md`](../../cpp/docs/stml.md) 与
[`docs/zh-cn/stml-test-plan.md`](../../docs/zh-cn/stml-test-plan.md)。

可运行的例子见 `demo/demo_02.gd`（对着 `cpp/demo/02-stml.cpp` 写的，回调逐条对应）。
