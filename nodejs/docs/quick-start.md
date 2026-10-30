# Node.js 快速上手

> 目标读者：想在 Node 项目里嵌入 Stope 的人。
> 本文逐段讲 `nodejs/demo/01-quick-start.js`（可直接运行），最后给出一份可复制的最小骨架。
> 另外两个 demo 只做索引式介绍 —— 它们的主题各自有专文。

| 想看 | 去哪（相对本文件） |
| --- | --- |
| 本目录总览（定位、目录、测试怎么跑） | [`../README.md`](../README.md) |
| 每个模块的构造参数、方法、字段、返回码 | [`usage.md`](usage.md) |
| 解析 STML 文档（教程） | [`stml.md`](stml.md) |
| 给编译器加自定义指令（教程） | [`custom-opcode.md`](custom-opcode.md) |
| 词法测试计划与交叉验证做法 | [`lexer-test-plan.md`](lexer-test-plan.md) |
| Stope 的语法（跨实现） | [`../../docs/zh-cn/syntax-reference.md`](../../docs/zh-cn/syntax-reference.md) |
| 各模块行为契约（跨实现） | [`../../docs/zh-cn/`](../../docs/zh-cn/) 下的四份 `*-test-plan.md` |
| 标准范围（为什么虚拟机不算标准） | [`../../README.md`](../../README.md) |
| 自己写一个执行器 | [`../../docs/zh-cn/vm-guide.md`](../../docs/zh-cn/vm-guide.md) |
| C++ 侧同一篇 | [`../../cpp/docs/quick-start.md`](../../cpp/docs/quick-start.md) |
| GDScript 侧同一篇 | [`../../gdscript/docs/quick-start.md`](../../gdscript/docs/quick-start.md) |

依赖只有 **Node >= 20**（`node:test` 需要；覆盖率门禁要 >= 22.8），**零第三方依赖** ——
不需要 `npm install`。

---

## 0. 先说清楚：哪些 API 属于标准

Stope 只规定三件事：**语言**、**STML**、**编译器的产物 `Program`**（见仓库根
[`README.md`](../../README.md)）。**它不规定虚拟机**，所以本文示例里的接口分两类 ——
差别不在「会不会改」（两层都会维护），而在「算不算标准」：

| 部分 | 稳定性 | 涉及的类 |
| --- | --- | --- |
| 编译环节（§3） | **相对稳定**（标准的一部分） | `Lexer` `Parser` `AST` `Compiler` `Program` `CustomOpcodeConfig` |
| 虚拟机环节（§4–§6） | **会维护，接口不随意调整**（但不是标准） | `BasicVM.Api` `State` `Arguments` |

**编译环节**跟着编译器规格走：`Program` 有明确的编码契约（指令编号、操作数、跳转目标都是
`opcodes` 下标，见 [`compiler-test-plan.md`](../../docs/zh-cn/compiler-test-plan.md) §2），
改接口要同步改规格与测试，所以可以照着写。它今天叫「相对稳定」而不是「稳定」，是因为
`Program` 的字段仍在演进。

**虚拟机环节**是 `src/basic_vm.js` 这一份实现的接口。它**会一直维护** —— bug 会修、
`Program` 演进时同步、五份实现的语义彼此对齐；接口也**不会随意调整**，改名或增删参数只会
为了修 bug 或跟进 `Program`，不会为了换个风格而做，所以边界内的用法可以放心依赖。

它只是**不属于标准**：标准只覆盖语言、STML 和 `Program`，所以宿主换一台执行器时，
`BasicVM.*` 这些名字本来就不存在 —— 值怎么表示（这里直接用 JS 的原生类型）、栈怎么布局、
宿主函数怎么注册、错误怎么报，全由执行器自己定。

内置这台还是**基础虚拟机**：`Api.opMap` 默认只有 33 项，**不支持自定义指令**（跑 ≥ 33 的
编号会抛 `TypeError: ... is not a function`），也**不支持自定义数据类型**（值只有 `null` /
BigInt / Number / string / 二进制数组 / 函数）。这是能力边界，不是「临时凑合」——
边界内的行为会一直维护下去。

要自己写执行器，读 [`../../docs/zh-cn/vm-guide.md`](../../docs/zh-cn/vm-guide.md)，
那是**指南**（讲一种可行解），不是要照抄的规范。

---

## 1. 先跑起来

不需要构建、不需要安装依赖。**以下命令都在 `nodejs/` 目录下执行**：

```bash
node demo/01-quick-start.js   # 编译 + 运行
node demo/02-stml.js          # 只解析 STML
node demo/03-custom-opcode.js # 只编译 + 反汇编
```

`01` 的完整输出（本文所有输出都是实际跑出来的，末尾空白已裁掉）：

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

前一半是 `DisasmNoCustom(program)` 的反汇编，后一半是执行器真正跑出来的结果。
demo 的输出**不必**与其它实现逐字节相同：真正要对齐的是字节码本身（`Program` 属于标准），
不是打印格式。

---

## 2. 全景：四步

```
源码(string)
  │  Lexer      → Token 流
  │  Parser     → AST（默认做常量折叠）
  │  Compiler   → Program（字节码 + 常量池 + exports）
  ▼
Program ──┐
          │  BasicVM.Api   33 条指令的实现表（稠密数组）
          ▼
        State ── Arguments ── 宿主函数
          │  Run() / Step()
          ▼
       returns / errors
```

| 步 | 做什么 | 主要类型 | 稳定性 |
| --- | --- | --- | --- |
| 1 | 编译源码 | `Lexer` `Parser` `Compiler` → `Program` | 相对稳定（编译器接口） |
| 2 | 建指令表 | `BasicVM.Api` | 内置基础 VM（会维护，非标准） |
| 3 | `State` 装配 | `State.Reset(api, program, args)` | 内置基础 VM（会维护，非标准） |
| 4 | 传参并执行 | `Arguments` `Run()` / `Step()` / `returns` | 内置基础 VM（会维护，非标准） |

**step 1 和后面三步是分开的**：只想看字节码、只想做静态检查的话，编译完就可以收工，
完全不需要碰执行器。`demo/03-custom-opcode.js` 就是这么干的。

---

## 3. step 1：编译源码

```js
import { Lexer, Parser, AST, Compiler, Program, DisasmNoCustom, Result } from '@liu-jl-dev/stope'

const src = `
let result = 0.0;
let i = 0;
while i < argc {
  result = result + args[i];
  i = i + 1;
}
fmt:println("结果为: ", result);
return result;
`

const lexer = new Lexer(src)
const parser = new Parser(lexer) // 第二参是 CustomOpcodeConfig，可省
const tree = new AST.Prog()
parser.ParseProgram(tree)

const compiler = new Compiler() // 构造参同上，可省
const program = new Program()
const rc = compiler.Compile(tree, program) // AST 与 Program 都传引用
if (rc !== Result.Success) throw new Error(compiler.errors.join(''))
console.log(DisasmNoCustom(program))
```

注意点：

- **源码就是 `string`**（C++ 侧是 `u16string`，GDScript 是 UTF-32 码点串）。JS 的字符串是
  UTF-16，所以 `"ab"[i]` 取到的是**码元** —— 与 C++ 一致，与 GDScript 不同。
- **输入输出都是引用语义**：`ParseProgram(tree)`、`Compile(tree, program)` 都把结果**写进**
  传进去的对象。`Compile` 返回 `rc`，失败时按约定会**把 `program` 清空**
  （见 `compiler-test-plan.md` §2），所以失败后不要拿它去反汇编或执行。
- **`tree` 必须是 `new AST.Prog()`**。传 `{ stmts: [] }` 这种裸对象不会报错，但访问器按
  `nodeType` 分发时会静默跳过整棵树 → 编译出一个空 `Program`。这是本实现最容易踩的坑。
- **`Result.Success === 0`**，别写 `if (rc)` 当成功。这是与 C++ `Stope::Result` 同一份定义
  的直接后果。
- **错误不抛异常**，进各自的 `errors` 数组（格式 `line N: msg`）；词法的进 `lexer.errors`，
  语法的进 `parser.errors`，编译的进 `compiler.errors`，**三者不合并**，都要看。
- `Parser.constFolding` 默认 `true`（常量折叠）；设 `false` 可关。`Parser.maxDepth` 默认
  `256`（0 = 不限），超限只报一条 `nesting too deep (max 256). ` 并中止。
- `Disasm(prog)` / `DisasmNoCustom(prog)` 来自 `src/debug.js`，把 `Program` 转成可读文本。
  产物里有自定义指令时要改用 `Disasm(program, config)`（见 §9 与 `demo/03`）。

这一节用到的类（`Lexer` `Parser` `AST` `Compiler` `Program`）是**编译器接口**，围绕的正是
标准里规定的那一层 —— `Program` 的编码契约，所以这段代码相对稳定、值得照抄。
**到此为止就是一个完整的 Stope 编译器用法**，后面三节只是「怎么把产物跑起来」的一种做法。

---

## 4. step 2：建指令表

> **step 2–4 用的是内置基础虚拟机：会维护、接口不随意改，但不属于标准。** 这里的
> `BasicVM.*` 全部来自 `src/basic_vm.js`；项目不规定执行器的标准（§0），所以宿主可以
> 换一台 —— 自己写执行器时，只需满足 `vm-guide.md` 里的语义要求。
> 另外它是**基础虚拟机**：默认没有自定义指令（表就 33 项）、没有自定义数据类型。

```js
const api = new BasicVM.Api() // 33 个函数，下标 = 指令编号
```

- `Api.opMap` 是**稠密的 `function[]`**：`Run()` / `Step()` 直接 `opMap[opcode](state)` 取，
  没有 switch、没有字典查找。
- 想单步调试就改用 `State.Step()`（一条指令一步），不必自己解析字节码。
  `while (s.Step() === Result.Success) {}` 与 `s.Run()` 连走的条数都一样。
- 要跑**自定义指令**就必须先扩表：`api.opMap.length = N + 1` 并保证 0…N 每格都是函数
  （漏一格会 `TypeError: ... is not a function`）。做法见 [`usage.md`](usage.md) §7.1。
- `Api` 没有需要自己维护的「常量池」对象 —— 这一点与 C++ 不同：C++ 要显式建 `Allocator` +
  `ProgramConstants` 把常量装进句柄池，JS 直接读 `program.intConsts` 等数组。

---

## 5. step 3：建立 State 并绑定宿主函数

```js
const state = new BasicVM.State()
state.Reset(api, program, args) // args 见 §6
```

`Reset` 一次做完四件事：清 `returns` / `stack` / `errors`，并
`variables = new Array(program.variableNum).fill(null)` —— **C++ 侧那句必写的
`state.variables.resize(program.variableNum)` 在这里已经由 `Reset` 代做**。
复用同一个 `State` 换程序时再调一次 `Reset` 即可，不必重建对象。

**`fmt:println` 这类在源码里被调用、但从未声明的名字，会由 Compiler 隐式登记进
`program.exports`**，槽位随声明顺序变化。宿主侧按名字取槽位，再往里面填函数：

```js
// exports 是 Map（不是普通对象），按名字取槽位
state.variables[program.exports.get('fmt:println')] = println
```

- 宿主函数没有独立的「函数表」：`Call` 指令就是把栈上的一个值当函数调，这个值必须是
  `function`。所以「注册宿主函数」= 往变量槽里填一个函数。
- 签名统一是 `(argv: Array) => any`：参数**整包**进来，自己拆 —— 与 C++
  `void(State&, span<const Value>, Value&)` 同一思路，返回值就是 `Call` 的结果。
- ⚠ **名字拼错在这里是静默的**：`program.exports.get('typo')` 给 `undefined`，而
  `state.variables[undefined] = fn` 只是给数组挂了个 `undefined` 属性，不报错；
  直到 `Call` 取到 `null` 才报 `"Call" can only call a function. `。所以拿不到槽位就
  自己 `if (!program.exports.has(name)) throw ...`。C++ 的 `std::map::operator[]` 会静默
  插入槽位 0，GDScript 的 `Dictionary` 会当场 `SCRIPT ERROR` —— 三种语言三种表现。

---

## 6. step 4：传入参数并执行

Stope 程序里的 `argc` / `args[i]` 由宿主的 `Arguments` 提供，继承它实现两个方法：

```js
class MyArgs extends BasicVM.Arguments {
  constructor(values) {
    super()
    this.data = values
  }

  // 取不到就**自己报错**：state.Error(...) + 返回 null，执行器立刻停在这里
  at(state, indexOrKey) {
    if (typeof indexOrKey !== 'bigint') {
      state.Error('index must be an integer. ')
      return null
    }
    if (indexOrKey < 0n || indexOrKey >= BigInt(this.data.length)) {
      state.Error('index out of range. ')
      return null
    }
    return this.data[Number(indexOrKey)]
  }

  num() {
    return this.data.length
  }
}

const state = new BasicVM.State()
state.Reset(api, program, new MyArgs([1.0, 2.0, 3.0, 4.0, 5.0]))

if (state.Run() !== Result.Success) {
  // true/成功是 Result.Success === 0，不是「返回 true」
  for (const e of state.errors) console.error('[vm] ' + e)
  process.exit(1)
}
console.log(state.returns[0])
```

- `at()` 收到的下标是 **BigInt**（`0n`），因为 Stope 的整数是 int64 —— 索引前先
  `Number(...)`，但要自己判范围。报错走 `state.Error(msg)`，VM 会立刻停下并把消息放进
  `state.errors`（格式 `"<指令下标>: msg"`）。
- **读返回值用 `state.returns`，不是 `state.stack[0]`。** 源码没有 `return` 时它是空数组。
- **返回值是 BigInt 还是 Number 取决于源码类型**：`return 3;` 给 `3n`，`return 3.0;` 给 `3`。
  直接 `console.log(3n)` 会印 `3n`，所以打日志前统一 `String(v)`（demo 里的 `fmt`）。
- 用不到 `argc` / `args` 时，`args` 传一个 `at()` 返回 `null`、`num()` 返回 `0` 的实现即可
  （见 §7 骨架）。

---

## 7. 最小骨架（可直接复制）

不需要宿主函数、不需要传参时，四步压成这些：

> 骨架里 **1. 编译** 这段是编译器接口（相对稳定）；**2–4** 是 `basic_vm.js` 的
> 内置基础虚拟机（会维护、接口不随意改，但不是标准）。想换成自己的执行器，只要保留
> 第 1 段，后面整段重写。

```js
import { Lexer, Parser, AST, Compiler, Program, BasicVM, Result } from '@liu-jl-dev/stope'

class NoArgs extends BasicVM.Arguments {
  at() {
    return null
  }
  num() {
    return 0
  }
}

const src = 'let a = 1; let b = 2; return a + b;'

// 1. 编译
const parser = new Parser(new Lexer(src))
const tree = new AST.Prog()
parser.ParseProgram(tree)
const compiler = new Compiler()
const program = new Program()
if (compiler.Compile(tree, program) !== Result.Success) throw new Error(compiler.errors.join(''))

// 2-4. 装配并执行（非标准）
const state = new BasicVM.State()
state.Reset(new BasicVM.Api(), program, new NoArgs())
if (state.Run() !== Result.Success) throw new Error(state.errors.join(''))
console.log('return = ' + state.returns[0])
```

输出：`return = 3`。

---

## 8. 常见错误

| 现象 | 原因 |
| --- | --- |
| 编译「成功」但 `program.opcodes` 是空的 | `tree` 传成了裸对象 `{ stmts: [] }`。必须 `new AST.Prog()`，否则访问器按 `nodeType` 分发时静默跳过整棵树 |
| `TypeError: Cannot mix BigInt and other types` | 拿 BigInt（`3n`）和 Number（`3`）直接运算。源码字面量 `3` 是整数 → BigInt，`3.0` 是浮点 → Number；宿主侧自己算也一样 |
| 断言 `assert.equal(ret, 3)` 失败，实际是 `3n` | 测试文件一律 `import assert from 'node:assert/strict'`，那里的 `equal` 是 `===`，`3n === 3` 为假。整数断言一律写 `3n`（`deepEqual` 同理） |
| `if (state.Run())` 判断反了 | `Run()` 返回 `Result`，**`Success === 0`**；写成 `if (state.Run())` 会把成功当失败 |
| `"Call" can only call a function. ` | 槽位里没有函数：要么 `program.exports` 里没这个名字（拼错/没被引用），要么填的不是 `function` |
| `TypeError: this.api.opMap[...] is not a function` | 跑自定义指令没扩表，或 `opMap` 中间留了空位。见 [`usage.md`](usage.md) §7.1 |
| 自定义指令的处理函数永远不被调用 | 编号占进了 0…32，内置实现赢；反汇编也只会印内置指令名 |
| `state.returns[0]` 是 `undefined` | 源码没有 `return`，`returns` 是空数组。先判 `length` |
| 打印出来是 `15n` / `[ 3n ]` | 忘了 `console.log` 会把 BigInt 印成 `15n`。日志统一 `String(v)` 或 `Number(v)` |
| `import` 报 `ERR_MODULE_NOT_FOUND` | 本目录是纯 ESM（`"type": "module"`），相对导入**必须带 `.js` 后缀**，且不能用 `require` |

---

## 9. 下一步

- **只想把 Stope 当表达式求值器**：只用 step 1 的 `Compiler` + `Disasm` 就够，
  不碰执行器。
- **解析 STML 文档**：看 [`stml.md`](stml.md)（语言版教程：回调 → 解析 → 读树 + 可跑骨架）
  与 [`../demo/02-stml.js`](../demo/02-stml.js)，API 表在 [`usage.md`](usage.md) §10。输出是：

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
  ```

  要点是**内容怎么切由宿主决定**：`parser.Parse(root, stateFunc)` 的回调按标签名 / 属性返回
  `StmlState.Xml` / `Text` / `Nevext` / `Stope` 四态之一。STML 只规定树的形状。
  属性是 `Map`（`attrs.get('stope')` 判有无用 `attrs.has(...)`）。
- **加自己的指令**：填 `CustomOpcodeConfig`，同一份对象传给 `Parser` 与 `Compiler`，
  编译完用 `Disasm(program, config)` 反汇编。[`custom-opcode.md`](custom-opcode.md) 是完整教程
  （含**怎么真的执行**这些编号），[`../demo/03-custom-opcode.js`](../demo/03-custom-opcode.js)
  是可运行的例子（只编译不执行），输出节选：

  ```
  [1] 登记自定义指令：
    my:add -> #33（定长 2 参）
    my:log -> #34（变长）
    my:halt -> #35（定长 0 参）
  ...
  [9]     my:add
  ...
  [15]    my:log     2
  ...
  custom opcodes:
    my:add     -> 33 (2 args)
    my:log     -> 34 (vararg)
    my:halt    -> 35 (0 args)
  ...
  [5] 用内置 Add 的编号注册 my:steal：
  ...
  warning: custom opcode "my:steal" uses #20, which collides with Add; builtin decoding wins.
  ```

  规则见 [`custom-opcode.md`](custom-opcode.md)、
  [`compiler-test-plan.md`](../../docs/zh-cn/compiler-test-plan.md) §4.4；
  「怎么真的执行这些编号」见该教程 §6。
- **想换掉内置执行器**：读 [`../../docs/zh-cn/vm-guide.md`](../../docs/zh-cn/vm-guide.md)。
  它讲的是「`Program` 的契约 + 执行器必须实现出哪些语义」，`basic_vm.js` 只是其中一种写法。
- **想看各模块怎么测的**：[`../README.md`](../README.md) §测试，跨实现的契约在
  [`../../docs/zh-cn/`](../../docs/zh-cn/)。
