# Go 版自定义指令

项目只规定 **33 条内置指令**（`opcode.go` 的 `Op*` 常量）与 `Program` 的编码契约；再往上加指令
是宿主自己的事。三件事必须一起做：

1. 用 `stope.CustomOpcodeConfig` 登记「名字 → (编号, 参数个数)」；
2. **同一份 config 同时交给 `Parser` 与 `Compiler`**；
3. 反汇编时也要把同一份 config 交给 `stope.Disasm`。

完整可运行版本是 [`cmd/demo03/main.go`](../cmd/demo03/main.go)，本文逐段讲它。
语义权威在 [`cpp/docs/custom-opcode.md`](../../cpp/docs/custom-opcode.md)。

**只想从 Stope 调宿主函数？本文可以跳过**——隐式导出 + `Call` 就够了，所有实现的内置 VM 都支持。自定义指令解决的是另外几件事，见下文 §0。


## 0. 适用情况：什么时候值得用它

自定义指令与「隐式导出 + `Call`」都能调到宿主代码：运行期开销相同、产物只差
几个字节——**性能与产物体积不构成选型理由**。差别全在结构：

| 场景 | 用什么 |
| --- | --- |
| 只想调宿主函数（数学、打印、时间……） | 隐式导出 + `Call`——够用，本文可跳过 |
| 能力契约要写进字节：disasm 的 `custom opcodes:` 段自描述、可静态审计 | 自定义指令 |
| 指令名要与变量 / 导出名隔离（`Call` 路径的隐式导出占变量命名空间） | 自定义指令（lexer 阶段就分流，天然不撞名） |
| 固定参数个数要**编译期**校验（`Call` 的参数不匹配只能运行期发现） | 自定义指令 |
| 给「内置 33 条封顶」留制度出口：宿主要新能力时加自定义指令，而不是要求加内置 | 自定义指令 |

一句话：**`Call` 是「调用宿主」的通用路径，自定义指令是「把宿主能力写进字节契约」的路径。**

本实现的内置 VM 扩表即可执行，见 §6。

## 1. 先跑起来：`demo03` 的五段

```bash
go run ./cmd/demo03
```

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
...
```

读法：

- 自定义指令在产物里**就是一个数字**：`9`/`15`/`18`/`21` 那几格是编号本身，不是名字。
  名字只活在 config 里，`Program` 一概不知。
- **定长指令不带操作数**（`my:add` 后面直接是下一条 `Pop`）；**变长指令后面跟一个
  参数个数**（`my:log 2`、`my:log 0`）。这个数字是给执行器读的。
- 参数照常**先压栈**（`PushValue 0`、`PushInt 1` 之后才是 `my:add`），指令自己只负责消费。
- 表达式语句的收尾一定有一条 `Pop`（自定义指令产出一个值，语句层把它丢掉）。

`[3]`~`[5]` 三段分别是「不传 config」「参数个数不符」「编号撞内置」，见 §5。

## 2. 登记：`CustomOpcodeConfig` —— demo 的 `[1]` 段

```go
config := stope.NewCustomOpcodeConfig()
config.AddCustomOpcode("my:add", stope.KFirstCustomOpcode+0, 2)  // 定长 2 参
config.AddCustomOpcode("my:log", stope.KFirstCustomOpcode+1, -1) // 变长（默认值就是 -1）
config.AddCustomOpcode("my:halt", stope.KFirstCustomOpcode+2, 0) // 定长 0 参
```

| 参数 | 说明 |
| --- | --- |
| `name` | 普通标识符或命名空间形式 `a:b`（词法器保证）。名字里的 `:` 用来避开宿主函数名（`fmt:println` 那种） |
| `opcode` | 编号，必须 `>= stope.KFirstCustomOpcode`（= 33） |
| `argNum` | `>= 0` 定长；`< 0` 变长（产物里多写一个「本次调用的参数个数」） |

`AddCustomOpcode` 返回 `stope.Result`：

- `stope.RSuccess` —— 登记成功；
- `stope.RDuplicateWithBuiltinOpcode` —— **同名**已存在，**不插入**（注意这个名字有点误导：
  它同时用来表示「与内置指令重名」和「与已登记的自定义指令重名」）。

```go
if config.AddCustomOpcode("my:add", 40, 1) == stope.RDuplicateWithBuiltinOpcode {
	// 名字重复；原来那条没被覆盖
}
```

登记表是 `config.Opcodes`（`map[string]CustomOpcodeInfo`，每条有 `Opcode` / `ArgNum` /
`IsVarArg`），**`config.Order` 保存登记序**。打印想对齐 C++ 的名字序就自己排；demo 按
`Order` 打（登记序）。反汇编 `custom opcodes:` 段才是**按编号排序**的（见 §4）。

## 3. 编译：同一份 config 交给 Parser 和 Compiler —— demo 的 `[2]` 段

```go
lexer := stope.NewLexer(src)
parser := stope.NewParser(lexer, config) // ⚠ 第二参
tree := &stope.Prog{}
parser.ParseProgram(tree)

compiler := stope.NewCompiler(config) // ⚠ 构造参（配置只在构造时注入一次）
program := stope.NewProgram()
if compiler.Compile(tree, program, nil) != stope.RSuccess {
	for _, e := range compiler.Errors {
		fmt.Println(e)
	}
}
```

**少给任何一处都不行**，而且失败方式不同：

| 漏了谁 | 症状 |
| --- | --- |
| `Parser` | `my:add` 只是个普通标识符 → 编译成 `Call`（调用一个名叫 `my:add` 的宿主函数）。**不报错**，产物完全不同 |
| `Compiler` | 报 `undefined custom opcode "my:add". `（Parser 认出来了，Compiler 查不到编号） |
| `Disasm` | 编号被当成内置指令或 `Custom#33` 印出来，而且变长指令后面那个参数个数会被当成下一条指令（读起来会全错位） |

定长指令的参数个数在**编译期**校验：

```
line 1: custom opcode "my:add" expected 2 args, but got 1.
```

报错后 `Compile` 会把 `program` 复原为空（`Opcodes` 剩 0 个 number），免得半成品被当成
能跑的东西 —— 这是四个阶段一致的约定。

## 4. 反汇编：`stope.Disasm(program, config)` —— demo 的 `[2]` 段末尾

```go
fmt.Println(stope.Disasm(program, config)) // 认得出自定义名字与参数个数
fmt.Println(stope.DisasmNoCustom(plain))   // 只按内置 33 条解码
```

带 config 时多出一段 `custom opcodes:`：

```
custom opcodes:
  my:add     -> 33 (2 args)
  my:log     -> 34 (vararg)
  my:halt    -> 35 (0 args)
```

⚠ 这一段**按编号排序**（C++ 侧是 `std::map<short, …>`），不是按名字。`golden_disasm.txt`
那 12 条里两种顺序恰好一致，所以看不出来 —— 由 Go 测试的 `DISP-SORT` 单测锁着。

## 5. 三个误解

### 5.1 「名字没登记，编译器也会报错」

不会。见 demo 的 `[3]` 段：

```
[3] 同样的调用，不传 config：
[0]     PushValue  0
[2]     PushInt    0
[4]     PushInt    1
[6]     Call       2
[8]     Pop
variables:
  "my:add"
```

`my:add` 变成了一个**普通变量名**（进 `Exports`），`Call 2` 调它 —— 也就是说，
「没登记的 `my:add(...)`」与「调用宿主函数 `my:add`」在产物里**完全一样**。这正是
命名空间写法的价值：宿主函数与自定义指令互不干扰，全看你给不给 config。

### 5.2 「参数个数不对是运行期的事」

编译期就报（demo 的 `[4]` 段）。定长指令的 `ArgNum` 是登记时给的，Parser 在
`my:add(1)` 时就知道少了，不用等运行。

### 5.3 「编号随便取，反正只是个数字」

不能撞内置（demo 的 `[5]` 段）：

```
[5] 用内置 Add 的编号注册 my:steal：
[0]     PushInt    0
[2]     PushInt    1
[4]     Add
[5]     Pop
...
warning: custom opcode "my:steal" uses #20, which collides with Add; builtin decoding wins.
```

编译器写出的仍是一个数字 `20`，谁也分不清它是 `Add` 还是 `my:steal`。`Disasm` 只能按
内置指令解码，并把它报成 warning。**编号千万别撞内置**：`stope.KFirstCustomOpcode`
就是为此存在的。

## 6. 怎么真的执行（demo 之外）

`stope/basicvm` **不该**实现你的指令 —— 它是内置的基础虚拟机（会一直维护，但不是标准），
默认只有内置那 33 项。Go 侧的扩展点是 `basicvm.Api` 接口：指令分派表（`OpTable()`）+
Handle 的三个开口。宿主**内嵌 `BaseApi`**（或直接用 `basicvm.NewApi()` 拿一个现成的），
用 `SetOpcode` 装处理函数 —— 它会先把中间的格子补成占位函数（报
`no implement for opcode N. `），跳号注册不留空洞。

下面这段是**真跑过的**（输出 `[3 6]`，`return a, b;` 会带回两个返回值）：

```go
package main

import (
	"fmt"

	"stope"
	"stope/basicvm"
)

func myAdd(s *basicvm.State) {
	b := s.Stack[len(s.Stack)-1]
	a := s.Stack[len(s.Stack)-2]
	s.Stack = s.Stack[:len(s.Stack)-2]
	s.Stack = append(s.Stack, a.(int64)+b.(int64))
}

func mySum(s *basicvm.State) {
	s.I++ // 变长指令先读走参数个数（那是操作数）
	n := int(s.Program.Opcodes[s.I])
	total := int64(0)
	for k := 1; k <= n; k++ {
		total += s.Stack[len(s.Stack)-k].(int64)
	}
	s.Stack = s.Stack[:len(s.Stack)-n]
	s.Stack = append(s.Stack, total)
}

func main() {
	cfg := stope.NewCustomOpcodeConfig()
	cfg.AddCustomOpcode("my:add", stope.KFirstCustomOpcode+0, 2)
	cfg.AddCustomOpcode("my:sum", stope.KFirstCustomOpcode+1, -1)

	src := `let a = my:add(1, 2); let b = my:sum(1, 2, 3); return a, b;`
	lexer := stope.NewLexer(src)
	parser := stope.NewParser(lexer, cfg)
	tree := &stope.Prog{}
	parser.ParseProgram(tree)
	compiler := stope.NewCompiler(cfg)
	program := stope.NewProgram()
	if compiler.Compile(tree, program, nil) != stope.RSuccess {
		panic(compiler.Errors)
	}

	api := basicvm.NewApi()
	api.SetOpcode(stope.KFirstCustomOpcode+0, myAdd)
	api.SetOpcode(stope.KFirstCustomOpcode+1, mySum)

	state := &basicvm.State{}
	state.SetApi(api)
	state.SetProgram(program) // Variables 按 program.VariableNum 分配
	if state.Run() != stope.RSuccess {
		panic(state.Errors)
	}
	fmt.Println(state.Returns) // [3 6]
}
```

三条硬约束：

| 规则 | 为什么 |
| --- | --- |
| 变长指令先 `s.I++` 读走参数个数 | 那是**操作数**，留在那里会被当成下一条指令 |
| 处理器**自己消费栈、自己压结果** | Go 的 `atTop` / `popN` 是包内小写方法（未导出），宿主处理器直接操作导出的 `s.Stack` 切片：从尾部取参数、重新切片弹出、`append` 压回结果。执行器不替你管栈平衡，少弹一个就是栈泄漏 |
| 结果类型必须是 6 种值之一 | `nil` / `int64` / `float64` / `string` / `[]byte` / 可调用值。压别的类型（比如 `int` 而非 `int64`）进去后续算术会拿到「既不是整数也不是浮点」的值 |

## 7. 排错表

| 症状 | 原因 / 做法 |
| --- | --- |
| 产物里是 `Call` 而不是自定义编号 | `Parser` 没拿到 config，或名字拼错了（`Word` 不含 `.`，只能用 `_` 和 `:`） |
| 报 `undefined custom opcode "my:add". ` | `Compiler` 没拿到 config |
| 报 `custom opcode "my:add" expected 2 args, but got 1. ` | 定长指令实参个数不符。改登记时的 `ArgNum`，或改调用 |
| 反汇编里自定义指令后面那个数字被当成下一条指令 | `Disasm` 没拿到 config（变长指令的操作数没人认得） |
| 反汇编 warning `collides with Add; builtin decoding wins` | 编号撞内置。用 `stope.KFirstCustomOpcode + n` |
| `AddCustomOpcode` 返回 `RDuplicateWithBuiltinOpcode` | 同名已登记。名字里带 `:` 通常就够避开冲突 |
| 处理器里类型断言 panic | 栈上的整数是 `int64` 不是 `int`，断言写成 `.(int64)` |
| 执行后 `Returns` 少了值 / 栈不对 | 处理器没消费参数（定长弹 `ArgNum` 个、变长弹 `n` 个），或者没把结果压回 `s.Stack` |
| 变长指令执行时 `s.Program.Opcodes[s.I]` 取到奇怪的值 | 忘了 `s.I++` 读走参数个数 |

## 8. 下一步

- **STML 文档里的代码段想执行**：看 [`stml.md`](stml.md) §1 的 `[4]` 段。
- **宿主函数怎么传值进 VM**：看 [`quick-start.md`](quick-start.md)。
- **语义权威**：[`cpp/docs/custom-opcode.md`](../../cpp/docs/custom-opcode.md)。
