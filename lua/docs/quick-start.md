# Lua 版快速上手

照这份文档走一遍，你会得到：一份能编译、能跑、能改的宿主程序骨架，以及「哪些 API 可以
依赖、哪些不属于标准（但同样会维护）」的分界线。

完整可运行的版本是 [`demo/01-quick-start.lua`](../demo/01-quick-start.lua)，本文逐段讲它
（输出与 Python 版逐字节一致）。

## 0. 先分清哪些能依赖

Stope 的标准只覆盖三件事：**语言**、**STML、编译器的产物 `Program`**。所以同一份 demo
里的代码要分两层看 —— 差别不在「会不会改」（两层都会维护），而在「算不算标准」：

| 段落 | 用到的东西 | 稳定性 |
| --- | --- | --- |
| step 1（编译） | `Lexer` / `Parser` / `Compiler` / `Program` | **编译器接口**，相对稳定（标准的一部分）。`Program` 的编码契约（指令编号、操作数、跳转目标是指令下标）是标准的，宿主可以依赖、可以复制 |
| step 2–4（运行） | `Api` / `State` / `Arguments` | **内置的基础虚拟机**：会一直维护、接口不随意调整，但**不属于标准**。值的表示、栈布局、宿主函数绑定、错误上报是这份实现自己的选择 |

## 1. 先跑起来

需要 **Lua 5.4+**（用到整数子类型与 `math.type`；实测 5.4.6）。零第三方依赖，不需要
LuaRocks。

```bash
lua lua/tests/run_tests.lua             # 八组测试全绿
lua lua/demo/01-quick-start.lua         # 编译 + 运行：反汇编 + 求和结果
lua lua/demo/02-stml.lua                # 只解析 STML
lua lua/demo/03-custom-opcode.lua       # 自定义指令：只编译 + 反汇编
lua lua/demo/04-pre-export.lua          # 预导出：形参先进作用域
```

`01` 的输出（节选）：

```
[0]     PushId     0
[2]     PushFloat  0
[4]     Assign
...
[Host] 结果为: 15
result: 15
```

## 2. 编译：源码 -> Program（标准的一部分）

```lua
local lexer = stope.Lexer.new('let a = 1; fmt:println("a=", a); return a + 2;')
local parser = stope.Parser.new(lexer) -- 第二参是 CustomOpcodeConfig，这里没有
local tree = stope.AST.Prog()
parser:parse_program(tree)

local compiler = stope.Compiler.new()
local program = stope.Program.new()
if compiler:compile(tree, program) ~= stope.Result.Success then
    -- 三个环节都不抛异常，错误各自攒在 .errors 里；编译失败时 program 已被清空
    error(table.concat(compiler.errors, "\n"))
end
print(stope.disasm(program)) -- 看一眼编出来的字节码
```

要点：

- **都不抛异常**：词法 / 语法 / 编译错误分别攒在 `lexer.errors` / `parser.errors` /
  `compiler.errors`（`"line N: msg. "` 形态的字符串数组）。
- **`compile` 的第三参是 `pre_exports`**（名字列表）：宿主想在源码运行前就注入的全局。
  传了它，源码里再 `export` 同名或顶层 `let` 同名都会报 duplicate —— 预导出的变量只能
  赋值。demo 04 演示完整用法。
- 常量折叠默认开着（`parser.const_folding = false` 可关）。折叠与执行器共用
  `common.lua` 的同一组数值函数，同一个表达式两条路径答案必然一致。

## 3. 执行：Program -> 结果（内置虚拟机，不是标准）

```lua
local state = stope.State.new()
state:set_api(stope.Api.new())
state:set_program(program)
state:set_arguments(args) -- 实参表（实现 Arguments 接口）是可选依赖，后补

-- 未声明的 fmt:println 被编译器当作外部变量登记进 exports；
-- 按名字取到槽位，填上宿主函数即可。
state.variables[program.exports["fmt:println"]] = function(argv)
    print("[Host] " .. stope.utf.utf16_to_utf8(stope.str_bytes(argv[1])))
end

if state:run() ~= stope.Result.Success then
    error(table.concat(state.errors, "\n")) -- "4: \"Div\" division by zero. " 形态
end
print(string.format("%d", state.returns[1])) -- 3
```

要点：

- **值怎么认**（这是 Lua 版最重要的契约）：

  | Stope 值 | Lua 里是 | 判断 / 装拆 |
  | --- | --- | --- |
  | Null | `stope.NULL` 哨兵 | `v == stope.NULL`（`nil` 不能上栈） |
  | 整数 | Lua integer | `math.type(v) == "integer"`；天生 int64 回绕 |
  | 浮点 | Lua float | `math.type(v) == "float"` |
  | 字符串 | 包装 table | `stope.is_str_value(v)`；`stope.str_bytes(v)` 取 UTF-16LE 字节 |
  | 二进制数组 | 裸 Lua string | `type(v) == "string"` |
  | 宿主函数 | Lua function | 返回 `true`/`false` 会被归一成 `1`/`0` |

- **实参表**：`args[i]` / `argc` 落到你传给 `reset` 的第三个对象上，继承
  `stope.Arguments` 实现 `at(state, index) -> 值`（0 起；取不到先
  `state:error("...")` 再返回 nil）与 `num() -> 个数`。demo 01 的 `MyArgs` 是最小样板。
- **单步**：`state:step()` 每次执行一条指令，返回 `Result.Success` / `Result.Error`；
  `run` 与 `step` 是两份独立实现，行为严格一致（V-21 锁着）。
- **自定义指令**：`Api:set_opcode(n, fn)` 装处理函数（会把中间补齐），配合
  `CustomOpcodeConfig` 让 Lexer / Parser / Compiler 都认得这个名字 —— demo 03 演示
  编译与反汇编，`tests/test_vm.lua` 的 V-05 演示执行。

## 4. STML

```lua
local lexer = stope.StmlLexer.new(doc)
local parser = stope.StmlParser.new(lexer)
local root = stope.StmlElement()
if parser:parse(root, state_func) ~= stope.Result.Success then
    error(table.concat(parser.errors, "\n"))
end
-- root.tag / root.attrs / root.children / root.text
-- root.text_line：内容首行的物理行号（无内容为 -1）——
-- 把它设给 stope.Lexer 的 line，报错行号才能和文档对上（demo 04 演示）
```

`state_func(tag, attrs) -> stope.StmlState` 由宿主提供：`<sto>` 返回 `Stope`、
`<nev>` 返回 `Nevext`、`<p>` 返回 `Text`、其余返回 `Xml`（递归子元素）—— 这是默认
回调 `stope.stml_parser.default_state_func` 的行为，你也可以完全自定（demo 02）。

## 5. 常见错误

| 症状 | 原因 |
| --- | --- |
| `-7 idiv 2` 得 `-4` | 直接用了 Lua 的 `//`（floor）。走 `common.int_div` |
| `2 ^ 64` 得 `1.8e19` | 直接用了 Lua 的 `^`（永远 float）。整数幂走 `common.int_pow` |
| `-7 % 2` 得 `1` | Lua 的 `%` 符号跟除数。走 `common.int_mod` |
| 字符串下标得到奇怪的字节对 | String 值是包装 table，先 `stope.str_bytes(v)` 再按码元取 |
| 往变量槽塞了 `nil` | 用 `stope.NULL`；Lua 的 `nil` 不能进栈与槽 |
| `math.fmod(1.5, 0)` 报错 | 整数 0 会抛错。浮点模走 `common.fmod`（得 nan） |
| 报错行号与文档对不上 | 从 STML 切出的代码段要把 `lexer.line` 设成 `Element.text_line` |
