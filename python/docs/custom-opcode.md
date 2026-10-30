# Python 版自定义指令

项目只规定 **33 条内置指令**（`stope/opcode.py`）与 `Program` 的编码契约；再往上加指令
是宿主自己的事。三件事必须一起做：

1. 用 `CustomOpcodeConfig` 登记「名字 → (编号, 参数个数)」；
2. **同一份 config 同时交给 `Parser` 与 `Compiler`**；
3. 反汇编时也要把同一份 config 交给 `disasm()`。

完整可运行版本是 [`demo/03-custom-opcode.py`](../demo/03-custom-opcode.py)，本文逐段讲它。
语义权威在 [`cpp/docs/custom-opcode.md`](../../cpp/docs/custom-opcode.md)。

## 1. 先跑起来：`demo/03` 的五段

```bash
python python/demo/03-custom-opcode.py
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

```python
from stope import CustomOpcodeConfig, kFirstCustomOpcode

config = CustomOpcodeConfig()
config.add_custom_opcode("my:add", kFirstCustomOpcode + 0, 2)   # 定长 2 参
config.add_custom_opcode("my:log", kFirstCustomOpcode + 1, -1)  # 变长（默认值就是 -1）
config.add_custom_opcode("my:halt", kFirstCustomOpcode + 2, 0)  # 定长 0 参
```

| 参数 | 说明 |
| --- | --- |
| `name` | 普通标识符或命名空间形式 `a:b`（词法器保证）。名字里的 `:` 用来避开宿主函数名（`fmt:println` 那种） |
| `opcode` | 编号，必须 `>= kFirstCustomOpcode`（= 33） |
| `arg_num` | `>= 0` 定长；`< 0` 变长（产物里多写一个「本次调用的参数个数」）。默认 `-1` |

`add_custom_opcode` 返回 `Result`：

- `Result.Success` —— 登记成功；
- `Result.DuplicateWithBuiltinOpcode` —— **同名**已存在，**不插入**（注意这个名字有点误导：
  C++ 里它同时用来表示「与内置指令重名」和「与已登记的自定义指令重名」）。

```python
if config.add_custom_opcode("my:add", 40, 1) == Result.DuplicateWithBuiltinOpcode:
    ...   # 名字重复；原来那条没被覆盖
```

登记表是 `config.opcodes: dict[str, CustomOpcode]`（插入序），每条有 `opcode` / `arg_num` /
`is_var_arg`。**打印时按编号排序**，否则 Python 的插入序与 C++ 的名字序对不上：

```python
for name, info in sorted(config.opcodes.items(), key=lambda kv: kv[1].opcode):
    ...
```

## 3. 编译：同一份 config 交给 Parser 和 Compiler —— demo 的 `[2]` 段

```python
from stope import AST, Compiler, Lexer, Parser, Program, Result

lexer = Lexer(src)
parser = Parser(lexer, config)      # ⚠ 第二参
tree = AST.Prog()
parser.parse_program(tree)

compiler = Compiler(config)         # ⚠ 构造参
program = Program()
if compiler.compile(tree, program) != Result.Success:
    for e in compiler.errors:
        print(e)
```

**少给任何一处都不行**，而且失败方式不同：

| 漏了谁 | 症状 |
| --- | --- |
| `Parser` | `my:add` 只是个普通标识符 → 编译成 `Call`（调用一个名叫 `my:add` 的宿主函数）。**不报错**，产物完全不同 |
| `Compiler` | 报 `undefined custom opcode "my:add". `（Parser 认出来了，Compiler 查不到编号） |
| `disasm` | 编号被当成内置指令或 `Custom#33` 印出来，而且变长指令后面那个参数个数会被当成下一条指令（读起来会全错位） |

定长指令的参数个数在**编译期**校验：

```
line 1: custom opcode "my:add" expected 2 args, but got 1.
```

报错后 `compile()` 会把 `program` 复原为空（`opcodes` 剩 0 个数字），免得半成品被当成
能跑的东西 —— 这是四个阶段一致的约定。

## 4. 反汇编：`disasm(program, config)` —— demo 的 `[2]` 段末尾

```python
from stope import disasm, disasm_no_custom

print(disasm(program, config))       # 认得出自定义名字与参数个数
print(disasm_no_custom(program))     # 只按内置 33 条解码
```

带 config 时多出一段 `custom opcodes:`：

```
custom opcodes:
  my:add     -> 33 (2 args)
  my:log     -> 34 (vararg)
  my:halt    -> 35 (0 args)
```

⚠ 这一段**按编号排序**（C++ 侧是 `std::map<short, …>`），不是按名字。`golden_disasm.txt`
那 12 条里两种顺序恰好一致，所以看不出来 —— 由 `tests/test_disasm.py` 的 `DISP-SORT`
单测锁着。

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

`my:add` 变成了一个**普通变量名**（进 `exports`），`Call 2` 调它 —— 也就是说，
「没登记的 `my:add(...)`」与「调用宿主函数 `my:add`」在产物里**完全一样**。这正是
命名空间写法的价值：宿主函数与自定义指令互不干扰，全看你给不给 config。

### 5.2 「参数个数不对是运行期的事」

编译期就报（demo 的 `[4]` 段）。定长指令的 `arg_num` 是登记时给的，Parser 在
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

编译器写出的仍是一个数字 `20`，谁也分不清它是 `Add` 还是 `my:steal`。`disasm()` 只能按
内置指令解码，并把它报成 warning。**编号千万别撞内置**：`kFirstCustomOpcode` 就是为此存在的。

## 6. 怎么真的执行（demo 之外）

`stope.basic_vm` **不该**实现你的指令 —— 它是内置示例执行器，不是标准。但 Python 侧比
C++ 多一个方便：`Api.set_opcode(n, fn)` 会把中间补齐再装上你的处理函数（C++ 的分派表是
定长 `std::array`，扩不了；GD/JS/C# 要自己 `resize` / `Add`）。

下面这段是**真跑过的**（`return a, b;` 会带回两个返回值）：

```python
from stope import (Api, AST, Compiler, CustomOpcodeConfig, Lexer, Parser, Program,
                   Result, State, kFirstCustomOpcode)

cfg = CustomOpcodeConfig()
cfg.add_custom_opcode("my:add", kFirstCustomOpcode + 0, 2)
cfg.add_custom_opcode("my:sum", kFirstCustomOpcode + 1, -1)

src = "let a = my:add(1, 2); let b = my:sum(1, 2, 3); return a, b;"
lexer = Lexer(src)
parser = Parser(lexer, cfg)
tree = AST.Prog()
parser.parse_program(tree)
compiler = Compiler(cfg)
program = Program()
assert compiler.compile(tree, program) == Result.Success, compiler.errors


def my_add(s):
    """定长 2 参：栈顶两个是参数，算完把结果压回去。"""
    b = s.at_top(1)
    a = s.at_top(2)
    s.pop_n(2)
    s.stack.append(a + b)


def my_sum(s):
    """变长：产物里多写了一个「参数个数」，必须先吃掉它（s.i += 1）。"""
    s.i += 1
    n = s.program.opcodes[s.i]
    argv = [s.at_top(k) for k in range(n, 0, -1)]
    s.pop_n(n)
    total = 0
    for v in argv:
        total += v
    s.stack.append(total)


api = Api()
api.set_opcode(kFirstCustomOpcode + 0, my_add)
api.set_opcode(kFirstCustomOpcode + 1, my_sum)

state = State()
state.reset(api, program)
assert state.run() == Result.Success, state.errors
print(state.returns)      # [3, 6]
```

三条硬约束：

| 规则 | 为什么 |
| --- | --- |
| 变长指令先 `s.i += 1` 读走参数个数 | 那是**操作数**，留在那里会被当成下一条指令 |
| 处理器**自己弹参数、自己压结果** | 执行器不替你管栈平衡；少弹一个就是栈泄漏 |
| 结果类型必须是 6 种值之一 | `None` / `int`（已 int64 回绕）/ `float` / `str` / `bytes` / 可调用对象。压 `bool` 进去后续算术会拿到「既不是整数也不是浮点」的值 |

`Api.op_map` 是**稠密列表**（下标 = 编号），所以 `set_opcode` 会先把中间那些格子填成
占位处理函数（报 `no implement for opcode N. `）。跳号注册不会留 `IndexError` 的空洞。

## 7. 排错表

| 症状 | 原因 / 做法 |
| --- | --- |
| 产物里是 `Call` 而不是自定义编号 | `Parser` 没拿到 config，或名字拼错了（`Word` 不含 `.`，只能用 `_` 和 `:`） |
| 报 `undefined custom opcode "my:add". ` | `Compiler` 没拿到 config |
| 报 `custom opcode "my:add" expected 2 args, but got 1. ` | 定长指令实参个数不符。改登记时的 `arg_num`，或改调用 |
| 反汇编里自定义指令后面那个数字被当成下一条指令 | `disasm()` 没拿到 config（变长指令的操作数没人认得） |
| 反汇编 warning `collides with Add; builtin decoding wins` | 编号撞内置。用 `kFirstCustomOpcode + n` |
| `add_custom_opcode` 返回 `DuplicateWithBuiltinOpcode` | 同名已登记。名字里带 `:` 通常就够避开冲突 |
| `api.op_map[33]` 抛 `IndexError` | 用 `api.set_opcode(33, fn)`，别直接按下标赋值 |
| 执行后 `returns` 少了值 / 栈不对 | 处理器没弹参数（定长 `pop_n(arg_num)`、变长 `pop_n(n)`），或者没把结果压回去 |
| 变长指令执行时 `opcodes[s.i]` 取到奇怪的值 | 忘了 `s.i += 1` 读走参数个数 |

## 8. 下一步

- **STML 文档里的代码段想执行**：看 [`stml.md`](stml.md) §1 的 `[5]` 段。
- **每个 API 的签名**：看 [`usage.md`](usage.md)。
- **语义权威**：[`cpp/docs/custom-opcode.md`](../../cpp/docs/custom-opcode.md)。
