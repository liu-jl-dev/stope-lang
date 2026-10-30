# 自定义指令（GDScript）：注册、编译、反汇编、执行

> 目标读者：想在 Godot 项目里给自己的 Stope 程序加指令的人。
> 本文逐段讲 `gdscript/demo/demo_03.gd`（可运行，**只编译 + 反汇编，不接执行器**），
> §6 补上 demo 没做的那一步 —— **怎么真的执行这些编号**，§7 给一份含执行的骨架（实跑过）。
>
> 语义权威是 C++ 那篇（[`../../cpp/docs/custom-opcode.md`](../../cpp/docs/custom-opcode.md)）；
> 本文只写「用 GDScript 怎么做」以及 GDScript 侧真的不一样的地方。

| 想看 | 去哪（相对本文件） |
| --- | --- |
| 本目录总览（插件怎么装、文档导览） | [`README.md`](README.md) |
| 自定义指令的**语言规则**（文法、命名、关键字优先） | [`../../docs/zh-cn/syntax-reference.md`](../../docs/zh-cn/syntax-reference.md) §5.3 |
| 执行器侧怎么执行这些编号 | [`../../docs/zh-cn/vm-guide.md`](../../docs/zh-cn/vm-guide.md) §5.5 |
| `Program` 的编码契约（哪条指令带操作数） | [`../../docs/zh-cn/compiler-test-plan.md`](../../docs/zh-cn/compiler-test-plan.md) §2、§4.4 |
| 完整的四步嵌入（编译 → 装配 → 运行） | [`quick-start.md`](quick-start.md) |
| 解析 STML 文档（另一种宿主扩展） | [`stml.md`](stml.md) |
| API 表（`add_custom_opcode` / `disasm` 的签名） | [`usage.md`](usage.md) §7、§7.1 |
| 反汇编函数本身 | `addons/stope/debug.gd` |

---

## 0. 先摆正位置：它是**宿主扩展**，不是语言特性

Stope 只规定三件事：语言、STML、编译器产物 `Program` 的编码。指令集里内置的 **33** 条
（`addons/stope/opcode.gd`，编号 0…32）是标准的一部分；**从 33 起全部留给宿主**
（`StopeOpcode.FIRST_CUSTOM_OPCODE == 33`）。

于是加指令这件事只发生在你的 GDScript 里，Stope 源码不需要任何新语法：

```
CustomOpcodeConfig： "my:add" -> #33，2 参
        │
        ├── Lexer     名字命中注册表 → Custom token
        ├── Parser    Custom token → StopeAst.CustomOpcodeExpr
        └── Compiler  查编号与参数个数 → 写进 Program

Stope 源码：my:add(x, 4);      和普通函数调用长得一样，只靠名字区分
产物 Program：…… PushValue 0，PushInt 1，33，Pop ……
```

最后一行是关键：`Program` 里只剩下 **`33`** 这个编号 —— 它什么含义、谁来执行，全由宿主
决定。这正是 demo 只编译不运行的原因（内置执行器只实现了 33 条内置指令）。

> **一句话**：内置指令是「标准说好大家一起实现」的，自定义指令是「你自己定义、
> 自己执行」的。前者写进 `Program` 的契约，后者写进你的宿主程序。

---

## 1. 先跑起来

```bash
godot --headless --path gdscript res://demo/demo_03.tscn
```

demo 分五段（`[1]`–`[5]`），本文按同样的顺序讲，**每一节都对得上 demo 里的一段**：

| demo 段 | 那段代码在干什么 | 本文 |
| --- | --- | --- |
| `[1]` | 建 `CustomOpcodeConfig`、登记三条、按编号排好打印 | §2 |
| `[2]` | 编译 demo 里那段源码，`print(StopeDebug.disasm(program, config))` | §3、§4 |
| `[3]` | 同一个 `my:add(1, 2);`，**不传 config** → 退化成普通 `Call` | §5.1 |
| `[4]` | 定长 2 参却只给 1 个 → 编译期报错、`Program` 被清空 | §5.2 |
| `[5]` | 用内置 `Add` 的编号注册 → 反汇编只能按内置解码 + warning | §5.3 |

**demo 没有第六段**：它到反汇编为止，不执行。要执行得自己扩 `op_map` —— 那是 §6 补的，
§7 的骨架把它接上了。开头这两段的实际输出：

```
[1] 登记自定义指令：
  my:add -> #33（定长 2 参）
  my:log -> #34（变长）
  my:halt -> #35（定长 0 参）

[2] 编译结果：
[0]     PushId     0
[2]     PushInt    0
[4]     Assign
[5]     PushValue  0
[7]     PushInt    1
[9]     my:add
[10]    Pop
[11]    PushString 0
[13]    PushValue  0
[15]    my:log     2
[17]    Pop
[18]    my:log     0
[20]    Pop
[21]    my:halt
[22]    Pop
[23]    PushValue  0
[25]    Return     1
custom opcodes:
  my:add     -> 33 (2 args)
  my:log     -> 34 (vararg)
  my:halt    -> 35 (0 args)
variables:
  ""
int consts:
  3  4
float consts:

string consts:
  "x ="
binary array consts:
max return num: 1
required stack size: 2
```

输出的格式（指令表 + 常量池）各实现一致 —— 那是 `Program` 的编码契约；demo 本身
**不追求**逐字节相同，所以 `[4]` 段那句「opcodes 剩 N 个 int / short」里用哪个类型名
随本语言的写法（GDScript 的 opcodes 是 `int` 混排，C++ 是 `std::int64_t` 拆成 short）。

---

## 2. 登记：`CustomOpcodeConfig` —— demo 的 `[1]` 段

```gdscript
# addons/stope/opcode.gd
class CustomOpcode:
	var name: String       # 名字（就是 config 里的键）
	var opcode: int        # 编号，必须 >= FIRST_CUSTOM_OPCODE
	var arg_num: int       # 定长时的参数个数；< 0 表示变长

class CustomOpcodeConfig:
	var opcodes: Dictionary[String, CustomOpcode]
	func add_custom_opcode(name: String, opcode: int, arg_num: int = -1) -> int
```

demo 的 `[1]` 段就是建表 + 登记三条 + 打印（**原文照抄**）：

```gdscript
var config := StopeOpcode.CustomOpcodeConfig.new()
config.add_custom_opcode('my:add', StopeOpcode.FIRST_CUSTOM_OPCODE + 0, 2)
config.add_custom_opcode('my:log', StopeOpcode.FIRST_CUSTOM_OPCODE + 1, -1)
config.add_custom_opcode('my:halt', StopeOpcode.FIRST_CUSTOM_OPCODE + 2, 0)
print('[1] 登记自定义指令：')
var items:Array[StopeOpcode.CustomOpcode] = []
for k in config.opcodes: items.append(config.opcodes[k])
items.sort_custom(func(a:StopeOpcode.CustomOpcode, b:StopeOpcode.CustomOpcode) -> bool:
	return a.opcode < b.opcode)
for info in items:
	print('  ', info.name, ' -> #', info.opcode,
		'（变长）' if info.arg_num < 0 else str('（定长 ', info.arg_num, ' 参）'))
```

四个要注意的地方：

| 点 | 说明 |
| --- | --- |
| **编号起点** | 用 `StopeOpcode.FIRST_CUSTOM_OPCODE`（= 33）。撞到 0…32 会被当成内置指令，见 §5.3 |
| **变长 = `arg_num < 0`** | 传 `-1`（默认值）即变长；GDScript 侧**没有** `is_var_arg` 字段，判断一律写 `info.arg_num < 0` |
| **返回值** | `StopeResult.Success`（0）；同名重复注册返回 `DuplicateWithBuiltinOpcode`（3）且**不插入**。GDScript 允许丢弃返回值，要查就接 |
| **不校验编号范围** | 和 C++ 一样，`add_custom_opcode('x', 20, 2)` 会成功 —— 撞内置只在反汇编时给 warning |

名字的规则来自词法器：普通标识符或命名空间形式 `a:b`，且**关键字优先** —— 注册一个叫
`if` 的指令无效，`if` 永远按关键字处理。

> demo 打印 `[1]` 段时把 `config.opcodes` 按编号排了序。`opcodes` 是 `Dictionary`
> （插入序），而 C++ 侧是 `std::map`（名字字典序）—— 想跟 C++ 输出对齐就得自己排，
> 按编号排是因为反汇编那一节也是编号序。

---

## 3. 编译：同一份 config 交给 Parser 和 Compiler —— demo 的 `[2]` 段

`my:add(x, 4);` 要变成一条自定义指令，三个环节都得知道这份 config：

| 环节 | 拿 config 做什么 | 查不到会怎样 |
| --- | --- | --- |
| `StopeLexer.Lexer` | 标识符命中注册表 → 吐 `Custom` token | 当普通标识符 |
| `StopeParser.Parser` | `Custom` token → `StopeAst.CustomOpcodeExpr` | 走 `Call`（普通函数调用） |
| `StopeCompiler.Compiler` | 查编号 / 参数个数，写编号（变长再多写一个参数个数） | 报 `undefined custom opcode "…"` |

```gdscript
var lexer := StopeLexer.Lexer.new(src)
var parser := StopeParser.Parser.new(lexer, config)  # 第二参可空
var tree := StopeAst.Prog.new()
parser.parse_program(tree)

var compiler := StopeCompiler.Compiler.new(config)    # 只在构造时注入一次
var program := StopeProgram.Program.new()
var rc := compiler.compile(tree, program)
```

**必须是同一份 config 对象**（不是「内容相同的两份」）。两边不一致时会看到
`undefined custom opcode`，或者干脆得到一个普通 `Call`（§5.1）。

demo 把上面这几行收进了辅助函数 `compile_and_report()`（在 `demo_03.gd` 末尾），`[2]`–`[5]`
四段都调它 —— **原文照抄**：

```gdscript
# 编译一份源码并打印错误。config 为 null 时按「没有自定义指令」处理。
static func compile_and_report(src:String, config:StopeOpcode.CustomOpcodeConfig,
		out:StopeProgram.Program) -> bool:
	var lexer := StopeLexer.Lexer.new(src)
	var parser := StopeParser.Parser.new(lexer, config)	# 第二参：可空的 config
	var tree := StopeAst.Prog.new()
	parser.parse_program(tree)
	for e in lexer.errors: print('  lexer: ', e)
	for e in parser.errors: print('  parser: ', e)

	var compiler := StopeCompiler.Compiler.new(config)	# 配置只在构造时注入一次
	var rc := compiler.compile(tree, out)
	for e in compiler.errors: print('  compiler: ', e)
	return rc == StopeResult.Success and lexer.errors.is_empty() \
		and parser.errors.is_empty()
```

demo 的源码：

```gdscript
const src := """
    let x = 3;

    my:add(x, 4);        // 定长 2 参
    my:log("x =", x);    // 变长 2 参
    my:log();            // 变长 0 参
    my:halt();           // 定长 0 参

    return x;
  """
```

对照 §1 的 `[2]` 段：

| 指令 | 来自 | 说明 |
| --- | --- | --- |
| `[0] PushId 0` `[2] PushInt 0` `[4] Assign` | `let x = 3;` | 变量槽 0；`3` 进 `int_consts[0]` |
| `[5] PushValue 0` `[7] PushInt 1` `[9] my:add` | `my:add(x, 4);` | `x` 是**读值** → `PushValue`；参数照常先压栈，**定长指令本身不带操作数** |
| `[10] Pop` | 同上 | 表达式语句丢弃结果 |
| `[11] PushString 0` `[13] PushValue 0` `[15] my:log 2` | `my:log("x =", x);` | 变长 → 紧跟一个 `2` 表示本次调用的实参个数 |
| `[18] my:log 0` | `my:log();` | 0 参也要写 `0`，不是省略 |
| `[21] my:halt` | `my:halt();` | 定长 0 参 → 不带操作数 |
| `[23] PushValue 0` `[25] Return 1` | `return x;` | 读值 → `PushValue` |

栈容量的记账：自定义指令**没有 callee 入栈**，结果仍占 1 格，所以净变化是 `-(n-1)`。
定长 2 参的 `my:add` 只多占 1 格，这就是 `required stack size: 2` 的来历。

---

## 4. 反汇编：`StopeDebug.disasm(program, config)` —— demo 的 `[2]` 段末尾

| 函数 | 什么时候用 |
| --- | --- |
| `StopeDebug.disasm(prog, config)` | 产物里**可能**有自定义指令 —— 拿得到名字、变长操作数与注册表 |
| `StopeDebug.disasm(prog)` | 确定没有自定义指令的产物；等价于 `disasm(prog, null)` |

带 config 时它多做三件事：

1. **印名字**：编号回查注册表，`33` 显示成 `my:add`（名字列宽度下限 10，名字更长时整列变宽）。
2. **按 `arg_num < 0` 决定要不要吃操作数**：`my:log 2` 里的 `2` 是参数个数；如果把它当
   指令，后面整段都会错位 —— 这是不带 config 时最容易看错的地方。
3. **多印一节 `custom opcodes:`**：按**编号**排序，名字 → 编号 → 参数形态。

不带 config（或 config 对不上）时的退化行为，都不会崩：

| 情况 | 输出 |
| --- | --- |
| 编号 ≥ 33 且不在注册表里 | `Custom<N>` 占位，**不猜**有没有操作数，文末 `warning: opcode #N is not a builtin; …` |
| 注册时编号撞了内置指令 | 按内置指令解码，文末 `warning: … collides with Add; builtin decoding wins.` |
| 两个名字共用一个编号 | 前者生效，文末 `warning: … share #33; the former wins.` |

> 反汇编是**调试**用的，它不属于标准。真正给执行器看的是 `Program.opcodes` 里那一串编号。

---

## 5. 三个容易踩的误解（demo 的 `[3]`–`[5]` 段）

下面三段都用 demo 里的辅助函数 `compile_and_report(src, cfg, out)` —— 它就是 §3 那几行
（lex → parse → compile），出错时把 `lexer.errors` / `parser.errors` / `compiler.errors`
打到屏幕。完整写法见 `demo_03.gd` 末尾。

### 5.1 名字没登记就只是普通调用

demo 的 `[3]` 段（第二参传 `null`，即不传 config）：

```gdscript
var plain := StopeProgram.Program.new()
if compile_and_report('my:add(1, 2);', null, plain):
```

```
[0]     PushValue  0
[2]     PushInt    0
[4]     PushInt    1
[6]     Call       2
[8]     Pop
variables:
  "my:add"
```

`my:add` 变成了「调用一个名叫 `my:add` 的宿主函数」：callee 先入栈（`PushValue 0`），
`Call` 带实参个数 2。注意 `variables:` 里的 `"my:add"` —— 未声明的标识符会被隐式登记进
`program.exports`，宿主得往这个槽位里放一个 `Callable`，否则运行期报
`"Call" can only call a function. `。

**所以：源码里写的是同一个名字，编译结果完全取决于你有没有那份 config。**

### 5.2 定长参数个数由编译器校验

demo 的 `[4]` 段（`my:add` 注册的是 2 参，这里只给 1 个）：

```gdscript
var bad := StopeProgram.Program.new()
if not compile_and_report('my:add(1);', config, bad):
```

```
[4] 定长 2 参却只给 1 个：
  compiler: line 1: custom opcode "my:add" expected 2 args, but got 1.
  -> 编译失败，Program 已清空（opcodes 剩 0 个 int）
```

变长指令不校验个数（`my:log()`、`my:log(1,2,3)` 都行）。报错后 `compile()` 会把 `out`
复原为空 —— 半成品 `Program` 跑不了，留着只会误导。

### 5.3 编号撞内置指令：只有 warning

demo 的 `[5]` 段（用内置 `Add` 的编号注册）：

```gdscript
var collide := StopeOpcode.CustomOpcodeConfig.new()
collide.add_custom_opcode('my:steal', StopeOpcode.Opcode.Add, 2)
```

```
[0]     PushInt    0
[2]     PushInt    1
[4]     Add
[5]     Pop
warning: custom opcode "my:steal" uses #20, which collides with Add; builtin decoding wins.
```

`opcodes` 是 int 混排序列，编号撞了以后写进去的还是同一个 int，**编译器与反汇编都无从
区分**。`add_custom_opcode` 拦不住（它不校验编号范围），反汇编只能按内置指令解码并给出
warning。没有别的选择：自定义编号就从 33 往上排。

顺带一句：反汇编认不出注册名时，**报错文案里的指令名也会是 `Custom<N>`**，不是注册名 ——
因为错误是在执行期打的，那时候只有编号。

---

## 6. 拿到 `Program` 之后：怎么真的执行这些编号

demo 到此为止 —— 再往下就是执行器，而项目**不规定虚拟机**
（[`../../docs/zh-cn/vm-guide.md`](../../docs/zh-cn/vm-guide.md)）。但内置执行器留了扩展点：
`Api.op_map` 是**稠密的 `Array[Callable]`，下标就是编号**，`run()` / `step()` 直接
`op_map[opcode].call(self)` 取 —— 所以注册 N 号就必须让数组长度 ≥ N+1，且 0…N 每一格都是
**有效 Callable**。默认只有 33 格：把带自定义编号的产物直接扔给内置执行器，会在
`op_map[33]` 上抛 `Out of bounds get index '33'`（引擎级报错，`run()` 返回 `false` 而
`errors` 仍是空的）。所以内置执行器是「基础虚拟机」—— 它**不自带**任何自定义指令，
能跑的前提是你自己把表扩了。

```gdscript
class Host:
	# my:add：弹 2 个、压 1 个。s.i 已经指着这条指令本身
	func my_add(s: StopeBasicVM.State) -> void:
		var b = s.stack.pop_back()	# 栈上一定是值：读变量走 PushValue
		var a = s.stack.pop_back()
		s.stack.push_back(a + b)

var host := Host.new()
var api := StopeBasicVM.Api.new()
api.op_map.resize(34)          # 33 号要能下标取到 ⇒ 至少 34 项
api.op_map[33] = Callable(host, 'my_add')

var state := StopeBasicVM.State.new()
state.reset(api, program, NoArgs.new())
print(state.run(), state.returns)   # true [3]
```

上面这段是**照可运行代码抄的**：`my:add` 注册在 33、源码 `let x = my:add(1, 2); return x;`，
实跑输出 `run=true returns=[3] errors=[]`。

写处理函数时的约定（与 `op_map` 里那 33 个内置实现同一套）：

| 约定 | 说明 |
| --- | --- |
| 签名 | `func(s: StopeBasicVM.State) -> void`，靠副作用干活 |
| 操作数 | `s.i` 已指着这条指令，**先 `s.i += 1` 再读** `s.program.opcodes[s.i]`；循环末尾还会统一 `+1`，别自己多推 |
| 栈效果 | 参数已按从左到右压好；结果压回栈顶、占 **1 格**；自定义指令**没有 callee 入栈** |
| 变长指令 | 流里在参数之后多一个「实参个数」操作数，先读它再决定弹几个 |
| 取值 | 直接 `s.stack.pop_back()` —— 栈上**一定是值**（读变量走 `PushValue`），不需要解引用 |
| 报错 | `s.error(msg)`：写进 `state.errors`，`run` / `step` 立刻停 |

三条不照做会踩：

| 漏了 | 现象 |
| --- | --- |
| 不 `resize` | 引擎报 `Out of bounds get index '33'`，`run()` 中止，**`errors` 却是空的**（错误没走 `state.error`），只在控制台 |
| `resize` 了但中间留空 | `Attempt to call function 'null::null (Callable)'`，同样中止 |
| 把编号占进 0…32 | 内置实现赢，你的处理函数永远不会被调用（反汇编也只会印内置指令名） |

---

## 7. 最小骨架（已运行）

把 `demo_03.gd` 的五段压成一条直线（只要 `[1]` 的登记 + `[2]` 的编译/反汇编，不要三个误解），
再接上 §6 的执行 —— 一份能从源码跑到结果的完整例子：

```gdscript
extends Node

func _ready() -> void:
	# 1. 登记
	var config := StopeOpcode.CustomOpcodeConfig.new()
	config.add_custom_opcode('my:add', StopeOpcode.FIRST_CUSTOM_OPCODE, 2)

	# 2. 编译（同一份 config 交给 Parser 与 Compiler）
	var lexer := StopeLexer.Lexer.new('let x = my:add(1, 2); return x;')
	var parser := StopeParser.Parser.new(lexer, config)
	var tree := StopeAst.Prog.new()
	parser.parse_program(tree)
	var compiler := StopeCompiler.Compiler.new(config)
	var program := StopeProgram.Program.new()
	if compiler.compile(tree, program) != StopeResult.Success:
		push_error(str(compiler.errors))
		get_tree().quit(1)
		return

	# 3. 看一眼产物
	print(StopeDebug.disasm(program, config))

	# 4. 执行：把 33 号挂上自己的处理函数
	# 先存进变量再构造 Callable —— 内联写 Callable(Host.new(), 'my_add') 时
	# 那个临时对象会被回收，运行期报 ... on a null instance（§8 最后一行）
	var host := Host.new()
	var api := StopeBasicVM.Api.new()
	api.op_map.resize(34)
	api.op_map[33] = Callable(host, 'my_add')
	var state := StopeBasicVM.State.new()
	state.reset(api, program, NoArgs.new())
	if not state.run():
		push_error(str(state.errors))
		get_tree().quit(1)
		return
	print('return = ', state.returns[0])

class Host:
	func my_add(s: StopeBasicVM.State) -> void:
		var b = s.stack.pop_back()	# 栈上一定是值：读变量走 PushValue
		var a = s.stack.pop_back()
		s.stack.push_back(a + b)

class NoArgs extends StopeBasicVM.Arguments:
	func at(_state: StopeBasicVM.State, _key) -> Variant: return null
	func num() -> int: return 0
```

输出（`--headless` 实跑）：

```
[0]     PushId     0
[2]     PushInt    0
[4]     PushInt    1
[6]     my:add
[7]     Assign
[8]     PushValue  0
[10]    Return     1
custom opcodes:
  my:add     -> 33 (2 args)
variables:
  ""
int consts:
  1  2
float consts:

string consts:
binary array consts:
max return num: 1
required stack size: 3

return = 3
```

---

## 8. 排错表

| 现象 | 原因 |
| --- | --- |
| `expected "(" after custom opcode. ` | 调用漏了括号，自定义指令的括号不可省（`myop 1;`） |
| 编译报 `undefined custom opcode "myop". ` | Parser 有这份 config，Compiler 没有（或名字拼错） |
| 编出来是 `Call` 而不是自定义指令 | 名字没进 config，或与关键字同名（关键字优先） |
| `custom opcode "my:add" expected 2 args, but got 1. ` | 定长指令的 `arg_num` 与实际调用不符 |
| 反汇编里出现 `Custom33` | `disasm` 没传 config |
| 反汇编从某条变长指令开始整段错位 | 同上：参数个数被当成了下一条指令 |
| `Out of bounds get index '33'`（控制台，`errors` 空） | `op_map` 没扩到 N+1，或扩了但中间留空 |
| 自定义指令的处理函数永远不被调用 | 编号占进了 0…32，内置实现赢 |
| 处理函数里 `s.stack[-1]` 是 `Identifier` 对象 | 编译器产物错了（读变量本该走 `PushValue`）；别在 VM 里兜底成变量值 |
| 变长指令执行后栈不平衡 | 忘了先读「实参个数」那一个操作数，或把它也算成了参数 |
| `Attempt to call function 'null::my_add (Callable)' on a null instance. ` | 处理函数写成内联 `Callable(Host.new(), 'my_add')`：临时对象被回收，Callable 的宿主变成 null。先存变量再构造（§7） |

---

## 9. 相关文件

| 文件 | 作用 |
| --- | --- |
| `demo/demo_03.gd` | 本文讲的 demo（场景 `demo_03.tscn`），只编译 + 反汇编 |
| `addons/stope/opcode.gd` | `Opcode` / `CustomOpcode` / `CustomOpcodeConfig` / `FIRST_CUSTOM_OPCODE` |
| `addons/stope/debug.gd` | `StopeDebug.disasm` / `disasm_no_custom` / `opcode_has_arg` |
| `addons/stope/basic_vm.gd` | `Api.op_map`、`State`、`Arguments` —— 执行自定义指令要扩的那张表 |
| [`usage.md`](usage.md) §7、§7.1 | 登记与反汇编的 API 表、扩表的三条坑 |
| [`stml.md`](stml.md) | 另一种宿主扩展：解析 STML 文档 |
| [`../../cpp/docs/custom-opcode.md`](../../cpp/docs/custom-opcode.md) | 语义权威（登记 / 编译 / 反汇编的完整推导） |
| [`../../docs/zh-cn/compiler-test-plan.md`](../../docs/zh-cn/compiler-test-plan.md) §4.4 | 自定义指令的行为契约 |
