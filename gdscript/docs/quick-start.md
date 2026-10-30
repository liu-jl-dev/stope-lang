# GDScript 快速上手

> 目标读者：想在 Godot 项目里嵌入 Stope 的人。
> 本文逐段讲 `gdscript/demo/demo_01.gd`（可直接运行），最后给出一份可复制的最小骨架。
> 另外两个 demo 只做索引式介绍 —— 它们的主题各自有专文。

| 想看 | 去哪（相对本文件） |
| --- | --- |
| 本目录总览（定位、目录、怎么装插件） | [`README.md`](README.md) |
| 每个 API 的签名、字段、返回码 | [`usage.md`](usage.md) |
| 解析 STML 文档（教程） | [`stml.md`](stml.md) |
| 给编译器加自定义指令（教程） | [`custom-opcode.md`](custom-opcode.md) |
| **报错了**该改哪（按阶段查文案） | [`troubleshooting.md`](troubleshooting.md) |
| 测试怎么跑、golden 数据怎么重生成 | [`testing.md`](testing.md) |
| GDScript 语言坑与代码约定 | [`gdscript-notes.md`](gdscript-notes.md) |
| Stope 的语法（跨实现） | [`../../docs/zh-cn/syntax-reference.md`](../../docs/zh-cn/syntax-reference.md) |
| 各模块行为契约（跨实现） | [`../../docs/zh-cn/`](../../docs/zh-cn/) 下的四份 `*-test-plan.md` |
| 标准范围（为什么虚拟机不算标准） | [`../../README.md`](../../README.md) |
| 自己写一个执行器 | [`../../docs/zh-cn/vm-guide.md`](../../docs/zh-cn/vm-guide.md) |
| C++ 侧同一篇 | [`../../cpp/docs/quick-start.md`](../../cpp/docs/quick-start.md) |

依赖只有 **Godot 4.7.2**（开发与实测版本），零第三方插件。低版本未验证 ——
`basic_vm.gd` 用到了 `@abstract`。

---

## 0. 先说清楚：哪些 API 是稳定的

Stope 只规定三件事：**语言**、**STML**、**编译器的产物 `Program`**（见仓库根
[`README.md`](../../README.md)）。**它不规定虚拟机**，所以本文示例里的接口分两类，
稳定性完全不同：

| 部分 | 稳定性 | 涉及的类 |
| --- | --- | --- |
| 编译环节（§3） | **相对稳定** | `StopeLexer` `StopeParser` `StopeAst` `StopeCompiler` `StopeProgram` `StopeOpcode.CustomOpcodeConfig` |
| 虚拟机环节（§4–§6） | **只是内置示例** | `StopeBasicVM.Api` `State` `Arguments` |

**编译环节**跟着编译器规格走：`Program` 有明确的编码契约（指令编号、操作数、跳转目标都是
`opcodes` 下标，见 [`compiler-test-plan.md`](../../docs/zh-cn/compiler-test-plan.md) §2），
改接口要同步改规格与测试，所以可以照着写。它今天叫「相对稳定」而不是「稳定」，是因为
`Program` 的字段仍在演进。

**虚拟机环节**是 `addons/stope/basic_vm.gd` 这一份实现的接口，**不是规范**：值怎么表示
（这里直接用 `Variant`）、栈怎么布局、宿主函数怎么注册、错误怎么报，全都属于实现者自由。
换一个执行器，`StopeBasicVM.*` 这些名字可能一个都不存在 —— 你可能直接遍历 AST、编译成
`Callable`、或者转译成别的 IR。

内置这台还是**基础虚拟机**：`Api.op_map` 只有 33 格，**不支持自定义指令**
（跑 ≥ 33 的编号直接 `Out of bounds get index`），也**不支持自定义数据类型**
（值只有 `null` / 整数 / 浮点 / 字符串 / 二进制数组 / `Callable`）。它会随实现维护，
但接口不承诺稳定。

要自己写执行器，读 [`../../docs/zh-cn/vm-guide.md`](../../docs/zh-cn/vm-guide.md)，
那是**指南**（讲一种可行解），不是要照抄的规范。

---

## 1. 先跑起来

把 `addons/stope/` 拷进目标工程并启用插件（两步，见 [`README.md`](README.md) §4），
然后在**本仓库**里可以直接跑三个 demo：

```bash
godot --headless --path gdscript res://demo/demo_01.tscn   # 编译 + 运行
godot --headless --path gdscript res://demo/demo_02.tscn   # 只解析 STML
godot --headless --path gdscript res://demo/demo_03.tscn   # 只编译 + 反汇编
```

`demo_01` 的完整输出（本文所有输出都是实际跑出来的，末尾空白已裁掉）：

```
[0]     PushId     0
[2]     PushFloat  0
[4]     Assign
[5]     PushId     1
[7]     PushInt    0
[9]     Assign
[10]    PushValue  1
[12]    ArgNum
[13]    LT
[14]    If         35
[16]    PushId     0
[18]    PushValue  0
[20]    PushValue  1
[22]    GetArg
[23]    Add
[24]    Assign
[25]    PushId     1
[27]    PushValue  1
[29]    PushInt    1
[31]    Add
[32]    Assign
[33]    GoTo       10
[35]    PushValue  2
[37]    PushString 0
[39]    PushValue  0
[41]    Call       2
[43]    Pop
[44]    PushValue  0
[46]    Return     1
variables:
  "" "" "fmt:println"
int consts:
  0  1
float consts:
  0
string consts:
  "结果为: "
binary array consts:
max return num: 1
required stack size: 3

[Host] 结果为: 15
result: 15
```

前一半是 `StopeDebug.disasm(program)` 的反汇编，由 step 1 打印；后一半是执行器真正跑出来的
结果。**这份输出与 `cpp/demo/01-quick-start.cpp` 的完全一致**（`test/data/golden_disasm.txt`
就是拿 C++ 的产物当期望值）—— 两侧对同一份源码产出同一份字节码，是这套实现的核心承诺。

---

## 2. 全景：四步

```
源码(String)
  │  StopeLexer      → Token 流
  │  StopeParser     → AST（可选地做常量折叠）
  │  StopeCompiler   → Program（字节码 + 常量池 + exports）
  ▼
Program ──┐
          │  StopeBasicVM.Api    33 条指令的实现表
          ▼
        State ── Arguments ── 宿主 Callable
          │  run() / step()
          ▼
       returns / errors
```

| 步 | 做什么 | 主要类型 | 稳定性 |
| --- | --- | --- | --- |
| 1 | 编译源码 | `StopeLexer` `StopeParser` `StopeCompiler` → `Program` | 相对稳定（编译器接口） |
| 2 | 建指令表 | `StopeBasicVM.Api` | 内置示例 |
| 3 | `State` 装配 | `State.reset(api, program, args)` | 内置示例 |
| 4 | 传参并执行 | `Arguments` `run()` / `step()` / `returns` | 内置示例 |

**step 1 和后面三步是分开的**：只想看字节码、只想做静态检查的话，编译完就可以收工，
完全不需要碰执行器。`demo_03` 就是这么干的。

---

## 3. step 1：编译源码

```gdscript
const SRC := """
let result = 0.0;
let i = 0;
while i < argc {
  result = result + args[i];
  i = i + 1;
}
fmt:println("结果为: ", result);
return result;
"""

var lexer := StopeLexer.Lexer.new(SRC)
var parser := StopeParser.Parser.new(lexer)   # 第二参是 CustomOpcodeConfig，可省
var tree := StopeAst.Prog.new()
parser.parse_program(tree)

var compiler := StopeCompiler.Compiler.new()  # 构造参同上，可省
var program := StopeProgram.Program.new()
var rc := compiler.compile(tree, program)     # AST 与 Program 都传引用
if rc != StopeResult.Success:
	push_error(str(compiler.errors))
	return
print(StopeDebug.disasm(program))
```

注意点：

- **源码就是 `String`**（C++ 侧是 `u16string`）。GDScript 的字符串是 UTF-32 码点序列，
  所以两侧在**非 BMP 字符**上的推进单位不同 —— 这是 STML 那条已登记差异 GD-S-18 的来源。
- **输入输出都是引用语义**：`parse_program(tree)`、`compile(tree, program)` 都把结果
  **写进**传进去的对象。`compile` 返回 `rc`，失败时按约定会**把 `program` 清空**
  （见 `compiler-test-plan.md` §2），所以失败后不要拿它去反汇编或执行。
- **`Success == 0`**，别写 `if rc:` 当成功。这是 `StopeResult` 与 C++ `Stope::Result`
  同一份定义的直接后果。
- **内层类要写全名**：`StopeLexer.Lexer`、`StopeCompiler.Compiler`、`StopeAst.Prog`。
  只写 `StopeLexer` 是那个只有常量与内层类的门面，`new()` 不出来。
- **错误不抛异常**，进各自的 `errors: Array[String]`（格式 `line N: msg`）；词法的进
  `lexer.errors`，语法的进 `parser.errors`，两者**不合并**，都要看。
- `StopeDebug.disasm()` 来自 `debug.gd`，把 `Program` 转成可读文本。产物里有自定义指令时
  要改用 `StopeDebug.disasm(program, config)`（见 §9 与 `demo_03.gd`）。

这一节用到的类（`StopeLexer` `StopeParser` `StopeAst` `StopeCompiler` `StopeProgram`）
是**编译器接口**，围绕的正是标准里规定的那一层 —— `Program` 的编码契约，所以这段代码
相对稳定、值得照抄。**到此为止就是一个完整的 Stope 编译器用法**，后面三节只是「怎么把
产物跑起来」的一种示例。

---

## 4. step 2：建指令表

> **step 2–4 是内置示例，不是规范。** 这里的 `StopeBasicVM.*` 全部来自
> `addons/stope/basic_vm.gd`；项目不规定执行器的标准（§0），所以下文的名字、结构、
> 调用顺序都可能变。自己写执行器时，只需要满足 `vm-guide.md` 里的语义要求。
> 另外它是**基础虚拟机**：没有自定义指令（表就 33 格）、没有自定义数据类型。

```gdscript
var api := StopeBasicVM.Api.new()   # 33 个 Callable，下标 = 指令编号
```

- `Api.op_map: Array[Callable]` 是**稠密的**：`run()` / `step()` 直接
  `op_map[opcode].call(self)` 取，没有 switch、没有字典查找。
- 想单步调试就改用 `State.step()`（一条指令一步），不必自己解析字节码。
- 要跑**自定义指令**就必须先扩表：`api.op_map.resize(N + 1)`，并要求 0…N 每一格都是
  有效 `Callable`（漏一格 GDScript 只报引擎错、`errors` 里看不见）。做法见
  [`usage.md`](usage.md) §7.1。

`Api` 没有需要自己 `resize` 的「常量池」对象 —— 这一点与 C++ 不同：C++ 要显式建
`Allocator` + `ProgramConstants` 把常量装进句柄池，GDScript 直接用 `Variant`，
`program` 里的常量数组本身就能取。

---

## 5. step 3：建立 State 并绑定宿主函数

```gdscript
var state := StopeBasicVM.State.new()
state.reset(api, program, args)   # args 见 §6
```

`reset` 一次做完四件事：清 `returns` / `stack` / `errors`，并
`variables.resize(program.variable_num)` —— **C++ 侧那句必写的
`state.variables.resize(program.variableNum)` 在这里已经由 `reset` 代做了**。
复用同一个 `State` 换程序时再调一次 `reset` 即可，不必重建对象。

**`fmt:println` 这类在源码里被调用、但从未声明的名字，会由 Compiler 隐式登记进
`program.exports`**，槽位随声明顺序变化。宿主侧按名字取槽位，再往里面填函数：

```gdscript
# 编译器把未声明的 fmt:println 当成外部变量，登记进了 exports
state.variables[program.exports["fmt:println"]] = Callable(host, "println")
```

- 宿主函数没有独立的「函数表」：`Call` 指令就是把栈上的一个值当函数调，这个值必须是
  `Callable`。所以「注册宿主函数」= 往变量槽里填一个 `Callable`。
- 签名统一是 `func(args: Array) -> Variant`：参数**整包**进来，自己拆 —— 与 C++
  `void(State&, span<const Value>, Value&)` 同一思路，但不用操心函数指针与捕获
  （GDScript 的 `Callable` 天然带对象上下文）。
- `program.exports` 是 `Dictionary`，与 C++ 的 `std::map::operator[]` **行为不同**：名字不存在
  时不会静默插入一个槽位，而是当场报 `SCRIPT ERROR: Invalid access to property or key ...`
  并给出 `null`，接着 `state.variables[null]` 又是一条错。所以在 GDScript 侧「名字拼错」
  会立刻炸出来，不会像 C++ 那样静默绑到变量 0。

---

## 6. step 4：传入参数并执行

Stope 程序里的 `argc` / `args[i]` 由宿主的 `Arguments` 提供，继承它实现两个方法：

```gdscript
class MyArgs extends StopeBasicVM.Arguments:
	var data: Array[float] = []

	func _init(values: Array[float]) -> void:
		data = values

	# 取不到就**自己报错**：state.error(...) + 返回 null，执行器立刻停在这里
	func at(state: StopeBasicVM.State, index_or_key) -> Variant:
		if not (index_or_key is int):
			state.error('index must be an integer. ')
			return null
		if index_or_key < 0 or index_or_key >= data.size():
			state.error('index out of range. ')
			return null
		return data[index_or_key]

	func num() -> int:
		return data.size()

var state := StopeBasicVM.State.new()
state.reset(api, program, MyArgs.new([1.0, 2.0, 3.0, 4.0, 5.0]))

if not state.run():                 # true = 跑完且没出错
	for e in state.errors: print('[vm] ', e)
	return
print('result: ', state.returns[0])
```

- `at()` 报错走 `state.error(msg)`，VM 会立刻停下并把消息放进 `state.errors`
  （格式 `"<指令下标> <指令名>: msg"`）。以前这里没有 `state`，宿主只能 `push_error`
  到 Godot 控制台、VM 那边当成功继续跑 —— 那是修掉的 bug，不是约定。
- **读返回值用 `state.returns`，不是 `state.stack[0]`。** 源码没有 `return` 时它是空数组。
- 用不到 `argc` / `args` 时，`args` 传一个 `at()` 返回 `null`、`num()` 返回 0 的实现即可
  （见 §7 骨架）。

---

## 7. 最小骨架（可直接复制）

不需要宿主函数、不需要传参时，四步压成这些：

> 骨架里 **1. 编译** 这段是编译器接口（相对稳定）；**2–4** 是 `basic_vm.gd` 的
> 内置示例 API。想换成自己的执行器，只要保留第 1 段，后面整段重写。

```gdscript
extends Node

class NoArgs extends StopeBasicVM.Arguments:
	func at(_state: StopeBasicVM.State, _key) -> Variant: return null
	func num() -> int: return 0

func _ready() -> void:
	var src := "let a = 1; let b = 2; return a + b;"

	# 1. 编译
	var lexer := StopeLexer.Lexer.new(src)
	var parser := StopeParser.Parser.new(lexer)
	var tree := StopeAst.Prog.new()
	parser.parse_program(tree)
	var compiler := StopeCompiler.Compiler.new()
	var program := StopeProgram.Program.new()
	if compiler.compile(tree, program) != StopeResult.Success:
		push_error(str(compiler.errors))
		return

	# 2-4. 装配并执行（非标准）
	var state := StopeBasicVM.State.new()
	state.reset(StopeBasicVM.Api.new(), program, NoArgs.new())
	if not state.run():
		push_error(str(state.errors))
		return
	print("return = ", state.returns[0])

	get_tree().quit()
```

输出：`return = 3`。

---

## 8. 常见错误

| 现象 | 原因 |
| --- | --- |
| `Cannot infer the type of "x" variable` | 类型写成了外层类。静态函数的参数类型也要写内层名：`func f(p: StopeParser.Parser)`，写 `StopeParser` 会让 `:=` 推不出来 |
| `Could not find type "StopeLexer"` | 插件没启用，或增删过带 `class_name` 的脚本却没重新导入。跑一次 `godot --headless --path <项目> --import` |
| 用 `if state.run():` 判失败，逻辑反了 | `run()` 返回 `true` 才是成功；而 `compile()` 返回的是 `StopeResult`，**`Success == 0`**，要写 `== StopeResult.Success` |
| 取 `state.returns[0]` 报越界 | 源码没有 `return`，`returns` 是空数组。先判 `is_empty()` |
| `Out of bounds get index '33'`（控制台，`errors` 却是空的） | `op_map` 没扩到 N+1，或扩了但中间留空 `null`。见 [`usage.md`](usage.md) §7.1 |
| 自定义指令的处理函数永远不被调用 | 编号占进了 0…32，内置实现赢；反汇编也只会印内置指令名 |
| 宿主函数调用时提示「不是 Callable」 | 槽位里填的是别的东西。GDScript 里 `host.println` 本身就是 `Callable`，但手写 `Callable(host, "println")` 更明确 |
| `1 / 0` 让整个函数静默中断 | 引擎级 `SCRIPT ERROR`，`errors` 里看不到 —— 已知差异，见 [`usage.md`](usage.md) §9 |
| `-9223372036854775808` 直接崩脚本 | GDScript 的 `-INT64_MIN` 不做回绕。实现里取负统一写 `~a + 1`；自己写执行器时也要注意 |

更多约定：词法/语法/编译各阶段会报哪些文案按阶段查
[`troubleshooting.md`](troubleshooting.md)；GDScript 语言本身的坑集中记在
[`gdscript-notes.md`](gdscript-notes.md)。

---

## 9. 下一步

- **只想把 Stope 当表达式求值器**：只用 step 1 的 `StopeCompiler` + `StopeDebug` 就够，
  不碰执行器。
- **解析 STML 文档**：看 [`stml.md`](stml.md)（语言版教程：回调 → 解析 → 读树 + 可跑骨架）
  与 [`demo_02.gd`](../demo/demo_02.gd)，API 表在 [`usage.md`](usage.md) §10。
  demo 的输出是：

  ```
  [1] 根元素 <stml>，属性 package="MyPkg"
  [2] 它的直接子元素：
    config
    func
    class
  [3] <class> 的子元素：
    property(自闭合)
    property(自闭合)
    method(自闭合)
  [4] <func> 里的 Stope 代码段：
  let a = 1;
    return a + argc;
  [5] 同一段代码，交给 Stope 词法器扫一遍 token 数：
    10 个 token
  [6] parse() 的返回值：Success
  ```

  要点是**内容怎么切由宿主决定**：`parse(root, state_func)` 的回调按标签名 / 属性返回
  `Xml` / `Text` / `Nevext` / `Stope` 四态之一。`STML` 只规定树的形状。
- **加自己的指令**：填 `StopeOpcode.CustomOpcodeConfig`，同一份对象传给 `Parser` 与
  `Compiler`，编译完用 `StopeDebug.disasm(program, config)` 反汇编。
  [`custom-opcode.md`](custom-opcode.md) 是完整教程（含**怎么真的执行**这些编号），
  [`demo_03.gd`](../demo/demo_03.gd) 是可运行的例子（只编译不执行），输出：

  ```
  [1] 登记自定义指令：
    my:add -> #33（定长 2 参）
    my:log -> #34（变长）
    my:halt -> #35（定长 0 参）
  ...
  [5] 用内置 Add 的编号注册 my:steal：
  ...
  warning: custom opcode "my:steal" uses #20, which collides with Add; builtin decoding wins.
  ```

  规则见 [`custom-opcode.md`](custom-opcode.md)、
  [`compiler-test-plan.md`](../../docs/zh-cn/compiler-test-plan.md) §4.4；
  「怎么真的执行这些编号」见该教程 §6。
- **想换掉内置执行器**：读 [`../../docs/zh-cn/vm-guide.md`](../../docs/zh-cn/vm-guide.md)。
  它讲的是「`Program` 的契约 + 执行器必须实现出哪些语义」，`basic_vm.gd` 只是其中一种
  写法；你可以只保留本文 §3 的编译环节，执行部分整段自己写。
- **想看各模块怎么测的**：[`testing.md`](testing.md) 一份覆盖五组，跨实现的契约在
  [`../../docs/zh-cn/`](../../docs/zh-cn/)。
