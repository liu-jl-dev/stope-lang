# Lua 版自定义指令

项目只规定 **33 条内置指令**（`stope/opcode.lua` 的 `Opcode` 表）与 `Program` 的编码契约；
再往上加指令是宿主自己的事。三件事必须一起做：

1. 用 `CustomOpcodeConfig` 登记「名字 → (编号, 参数个数)」；
2. **同一份 config 同时交给 `Parser` 与 `Compiler`**；
3. 反汇编时也要把同一份 config 交给 `disasm()`。

完整可运行版本是 [`demo/03-custom-opcode.lua`](../demo/03-custom-opcode.lua)，本文逐段讲它。
语义权威在 [`cpp/docs/custom-opcode.md`](../../cpp/docs/custom-opcode.md)。

## 1. 先跑起来：`demo 03` 的五段

```bash
lua lua/demo/03-custom-opcode.lua
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

⚠ 命名空间的一个小坑：**config 的构造器住在 `stope.opcode` 子表里**（`stope.opcode` 既是
模块也是聚合名），常量 `kFirstCustomOpcode` / `Opcode` 也在那里；而 `disasm` 在顶层。

```lua
local cfg = stope.opcode.CustomOpcodeConfig()
cfg:add_custom_opcode("my:add", stope.opcode.kFirstCustomOpcode + 0, 2)  -- 定长 2 参
cfg:add_custom_opcode("my:log", stope.opcode.kFirstCustomOpcode + 1, -1) -- 变长（默认值就是 -1）
cfg:add_custom_opcode("my:halt", stope.opcode.kFirstCustomOpcode + 2, 0) -- 定长 0 参
```

| 参数 | 说明 |
| --- | --- |
| `name` | 普通标识符或命名空间形式 `a:b`（词法器保证）。名字里的 `:` 用来避开宿主函数名（`fmt:println` 那种） |
| `op` | 编号，必须 `>= stope.opcode.kFirstCustomOpcode`（= 33） |
| `arg_num` | `>= 0` 定长；`< 0` 变长（产物里多写一个「本次调用的参数个数」） |

`add_custom_opcode` 返回 `stope.Result`：

- `stope.Result.Success` —— 登记成功；
- `stope.Result.DuplicateWithBuiltinOpcode` —— **同名**已存在，**不插入**（注意这个名字
  有点误导：它同时用来表示「与内置指令重名」和「与已登记的自定义指令重名」）。

```lua
if cfg:add_custom_opcode("my:add", 40, 1) == stope.Result.DuplicateWithBuiltinOpcode then
    -- 名字重复；原来那条没被覆盖
end
```

登记表是 `config.opcodes`（`{ [名字] = { opcode, arg_num, is_var_arg } }`），
**`config._order` 保存登记序**（Lua table 没有稳定顺序，靠它按登记序遍历）。打印想对齐
C++ 的名字序就自己排；demo 按 `_order` 打。反汇编 `custom opcodes:` 段才是
**按编号排序**的（见 §4）。

## 3. 编译：同一份 config 交给 Parser 和 Compiler —— demo 的 `[2]` 段

```lua
local lexer = stope.Lexer.new(src)
local parser = stope.Parser.new(lexer, cfg)      -- ⚠ 第二参
local tree = stope.AST.Prog()
parser:parse_program(tree)

local compiler = stope.Compiler.new(cfg)         -- ⚠ 构造参（配置只在构造时注入一次）
local program = stope.Program.new()
if compiler:compile(tree, program) ~= stope.Result.Success then
    for _, e in ipairs(compiler.errors) do print(e) end
end
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

报错后 `compile()` 会把 `program` 复原为空（`opcodes` 剩 0 个 number），免得半成品被当成
能跑的东西 —— 这是四个阶段一致的约定。

## 4. 反汇编：`disasm(program, config)` —— demo 的 `[2]` 段末尾

```lua
print(stope.disasm(program, cfg))     -- 认得出自定义名字与参数个数
print(stope.disasm_no_custom(plain))  -- 只按内置 33 条解码
```

带 config 时多出一段 `custom opcodes:`：

```
custom opcodes:
  my:add     -> 33 (2 args)
  my:log     -> 34 (vararg)
  my:halt    -> 35 (0 args)
```

⚠ 这一段**按编号排序**（C++ 侧是 `std::map<short, …>`），不是按名字。`golden_disasm.txt`
那 12 条里两种顺序恰好一致，所以看不出来 —— 由 Lua 测试的 `DISP-SORT` 单测锁着。

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
内置指令解码，并把它报成 warning。**编号千万别撞内置**：`stope.opcode.kFirstCustomOpcode`
就是为此存在的。

## 6. 怎么真的执行（demo 之外）

`stope.basic_vm` **不该**实现你的指令 —— 它是内置的基础虚拟机（会一直维护，但不是标准），
默认只有内置那 33 项。Lua 侧的扩展点：new 一个 `Api`，用 `set_opcode` 在实例上装处理函数
—— 它会先把中间的格子补成占位函数（报 `no implement for opcode N. `），跳号注册不留
空洞（`op_map` 是**稠密数组**：下标 = 编号 + 1，Lua 数组 1 起）。

下面这段是**真跑过的**（输出 `3	6`，`return a, b;` 会带回两个返回值）：

```lua
local stope = require("stope")

local cfg = stope.opcode.CustomOpcodeConfig()
cfg:add_custom_opcode("my:add", stope.opcode.kFirstCustomOpcode + 0, 2)
cfg:add_custom_opcode("my:sum", stope.opcode.kFirstCustomOpcode + 1, -1)

local src = "let a = my:add(1, 2); let b = my:sum(1, 2, 3); return a, b;"
local lexer = stope.Lexer.new(src)
local parser = stope.Parser.new(lexer, cfg)
local tree = stope.AST.Prog()
parser:parse_program(tree)
local compiler = stope.Compiler.new(cfg)
local program = stope.Program.new()
assert(compiler:compile(tree, program) == stope.Result.Success)

-- 定长 2 参：栈顶两个是参数，算完把结果压回去
local function my_add(s)
    local b = s:at_top(1)
    local a = s:at_top(2)
    s:pop_n(2)
    s.stack[#s.stack + 1] = a + b
end

-- 变长：产物里多写了一个「参数个数」，必须先吃掉它（s.i += 1）
local function my_sum(s)
    s.i = s.i + 1                       -- ⚠ 先吃操作数
    local n = s.program.opcodes[s.i + 1] -- Lua 的 opcodes 数组 1 起、s.i 0 起
    local total = 0
    for k = 1, n do
        total = total + s:at_top(k)
    end
    s:pop_n(n)
    s.stack[#s.stack + 1] = total
end

local api = stope.Api.new()
api:set_opcode(stope.opcode.kFirstCustomOpcode + 0, my_add)
api:set_opcode(stope.opcode.kFirstCustomOpcode + 1, my_sum)

local state = stope.State.new()
state:set_api(api)
state:set_program(program)
assert(state:run() == stope.Result.Success, table.concat(state.errors, "\n"))
print(state.returns[1], state.returns[2]) -- 3  6
```

三条硬约束：

| 规则 | 为什么 |
| --- | --- |
| 变长指令先 `s.i = s.i + 1` 读走参数个数 | 那是**操作数**，留在那里会被当成下一条指令。取值时 `opcodes[s.i + 1]`（opcodes 1 起、`s.i` 0 起），这是 Lua 版最容易错的一处 |
| 处理器**自己弹参数、自己压结果** | 执行器不替你管栈平衡；少弹一个就是栈泄漏。读参数用 `s:at_top(k)`、弹出用 `s:pop_n(n)`、压回用 `s.stack[#s.stack + 1] = v` |
| 结果类型必须是 6 种值之一 | `stope.NULL` / Lua integer / float / String 包装表（`stope.is_str_value` 认的那种，与 BinArr 的裸 string 区分）/ BinArr 裸 string / 可调用值。Lua 的 `nil` **不能上栈**，压「空」用哨兵 `stope.NULL` |

## 7. 排错表

| 症状 | 原因 / 做法 |
| --- | --- |
| 产物里是 `Call` 而不是自定义编号 | `Parser` 没拿到 config，或名字拼错了（`Word` 不含 `.`，只能用 `_` 和 `:`） |
| 报 `undefined custom opcode "my:add". ` | `Compiler` 没拿到 config |
| 报 `custom opcode "my:add" expected 2 args, but got 1. ` | 定长指令实参个数不符。改登记时的 `arg_num`，或改调用 |
| 反汇编里自定义指令后面那个数字被当成下一条指令 | `disasm()` 没拿到 config（变长指令的操作数没人认得） |
| 反汇编 warning `collides with Add; builtin decoding wins` | 编号撞内置。用 `stope.opcode.kFirstCustomOpcode + n` |
| `add_custom_opcode` 返回 `DuplicateWithBuiltinOpcode` | 同名已登记。名字里带 `:` 通常就够避开冲突 |
| 处理器里 `attempt to index a nil value` | 压「空」用了 Lua 的 `nil` —— 上栈要用哨兵 `stope.NULL` |
| 执行后 `returns` 少了值 / 栈不对 | 处理器没弹参数（定长 `s:pop_n(arg_num)`、变长 `s:pop_n(n)`），或者没把结果压回 `s.stack` |
| 变长指令执行时 `opcodes[s.i + 1]` 取到奇怪的值 | 忘了 `s.i = s.i + 1` 读走参数个数 |

## 8. 下一步

- **STML 文档里的代码段想执行**：看 [`stml.md`](stml.md) §1 的 `[4]` 段。
- **宿主函数怎么传值进 VM**：看 [`quick-start.md`](quick-start.md)。
- **语义权威**：[`cpp/docs/custom-opcode.md`](../../cpp/docs/custom-opcode.md)。
