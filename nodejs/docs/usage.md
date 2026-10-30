# Node.js API 手册

> 目标读者：已经跑过 [`quick-start.md`](quick-start.md)，要查具体签名 / 字段 / 返回码的人。
> 本文按模块顺序排：词法 → 语法 → AST → 编译 → 产物 → 反汇编 → 自定义指令 → 折叠 →
> 执行器 → STML。**最后一节是错误信息总表**，报错时先看那里。
>
> 稳定性前提：第 1–8 节与第 10 节（STML）是**编译器 / 解析器接口**（相对稳定），第 9 节的
> 执行器是**内置示例**（不是标准，且只是**基础虚拟机**：无自定义指令、无自定义数据类型）。
> 分界线的含义见 [`quick-start.md`](quick-start.md) §0。

## 0. 导入

```js
// 正常用法：只从包根导入
import { Lexer, Parser, AST, Compiler, Program, Disasm, Result } from '@liu-jl-dev/stope'

// 在本仓库里开发时直接引用源码
import { Lexer } from '../src/index.js'
```

- **纯 ESM**：`"type": "module"`。相对导入必须带 `.js` 后缀，不能用 `require`。
- `exports` 是封闭的：`@liu-jl-dev/stope/src/lexer.js` 这种深引用会失败，只能从包根导入。
- 需要 Node >= 20（`node:test`）。零第三方依赖 —— `src/` 只 import `node:` 内置模块和相对路径，
  `test/smoke.test.js` 会自动检查。

**`Result` 只有一份**（`src/common.js`），词法 / 语法 / 编译 / STML / 执行器共用：

```js
Result.Success                 // 0 —— 别写 if (rc) 当成功
Result.Error                   // 1
Result.UnknownError            // 2
Result.DuplicateWithBuiltinOpcode // 3 —— addCustomOpcode 重名
```

---

## 1. 词法：`Lexer`

```js
const lx = new Lexer(src)      // 构造即就绪；换源码用 lx.Reset(src)
let t = lx.NextToken()         // 每次前进一个 token
if (t.type === TokenType.Eof) { /* 到结尾 */ }
console.log(lx.errors)         // Array<string>，格式 "line N: msg"
```

| 成员 | 说明 |
| --- | --- |
| `new Lexer(input)` / `Reset(input)` | `input` 是 `string`；`Reset` 清 `errors`、行号归 1 |
| `NextToken(custom = undefined)` | 返回 `Token`。`custom` 是 `CustomOpcodeConfig`，传了才把登记过的名字识别成 `TokenType.Custom` |
| `errors: string[]` | 词法错误，**不抛异常**；与 `parser.errors` 不合并 |
| `line` | 当前行号（1 起算） |

`NextToken` 是 PascalCase，与 C++ 的 `Lexer::NextToken` 逐名对应 —— 不是 JS 惯用的
`nextToken`。这条约定贯穿全部模块（`ParseProgram` / `Compile` / `Reset` / `Run`）。

### 1.1 `Token`

| 字段 | 说明 |
| --- | --- |
| `line` | 1 起算 |
| `type` | `TokenType` 的一项（47 项，值与 C++ 完全一致） |
| `lexeme` | 词素原文（字符串 token 是**去掉引号**后的原文） |
| `parsed` | 处理过的文本：数字去掉 `_`、字符串解完转义、标识符去掉冒号两侧空白 |
| `value` | 仅数字 token：整数是 **`BigInt`**，浮点是 `Number` |

`TokenType` 是双向映射对象：`TokenType.Integer === 3` 且 `TokenType[3] === 'Integer'`，
所以打类型名直接 `TokenType[t.type]`。

### 1.2 数字

```js
new Lexer('0xFF').NextToken().value   // 255n
new Lexer('1_000').NextToken().value  // 1000n（parsed 已去掉下划线）
new Lexer('1.5e3').NextToken().value  // 1500（Float 是 Number）
```

整数是 **`BigInt`**，因为 Stope 的整数是 int64、溢出不检查、按 64 位回绕，而 JS 的 `Number`
只有 53 位精确整数。写测试断言时别忘 `n`：`assert.equal(t.value, 1n)`。

超出 int64 范围、`0b` 后没有合法位、`1e` 这种残缺浮点 → token 置 `TokenType.Invalid`
并往 `errors` 里写一条。

### 1.3 字符串与二进制数组

- `"..."` → `TokenType.String`，`parsed` 已解转义（`\n` / `\t` / `\\` / `\"` / `\uXXXX` 等）。
- `'...'` → `TokenType.BinArr`，内容是**字节序列**，`parsed` 是原文，交给
  `BinaryArrayParser` 解析。**别把两者搞反**：Stope 里双引号才是字符串。

```js
import { BinaryArrayParser } from '@liu-jl-dev/stope'

// input 是**去掉单引号**后的内容；输出是 0..255 的普通数组
const bytes = []
const rc = new BinaryArrayParser().parseBinaryArray('d 72 105', bytes)
// rc === Result.Success, bytes === [72, 105]
```

写法：数字之间用空白分隔，**默认按十六进制**解析；整段开头放一个字母切换进制 ——
`b` 二进制、`o` 八进制、`d` 十进制、`x` 十六进制。超过 `0xFF` 静默截断（等价于 C++ 的
`static_cast<char>`）。完整规则见 [`docs/zh-cn/parser-test-plan.md`](../../docs/zh-cn/parser-test-plan.md)
的 `B-xx` 用例（实现就是照那张表来的）。

### 1.4 标识符与自定义指令

标识符允许命名空间写法：`^[A-Za-z_][A-Za-z0-9_]*(:[A-Za-z_][A-Za-z0-9_]*)*` —— 冒号两侧
可以有空白与注释。关键字优先：登记一个叫 `if` 的指令无效，`if` 永远按关键字处理。

---

## 2. 语法：`Parser`

```js
const parser = new Parser(new Lexer(src))   // 第二参是 CustomOpcodeConfig，可省
const tree = new AST.Prog()                  // 必须是 AST.Prog 实例
parser.ParseProgram(tree)
console.log(parser.errors)                   // Array<string>，格式 "line N: msg"
```

| 成员 | 默认 | 说明 |
| --- | --- | --- |
| `new Parser(lexer, custom = null)` | — | `custom` 用来识别自定义指令 |
| `Reset(lexer, custom = null)` | — | 换词法器、清 `errors` 与 `aborted` |
| `ParseProgram(prog)` | — | 结果**写进** `prog`（引用语义） |
| `constFolding` | `true` | 是否在构造二元/一元节点时做常量折叠 |
| `maxDepth` | `256` | 递归深度上限，`0` = 不限 |
| `errors` | `[]` | 语法错误 |
| `aborted` | `false` | 深度超限后置位，用于「只报一条错」 |

**深度上限**：超限时只报一条 `line N: nesting too deep (max 256). ` 并中止解析，不会逐层
级联。产物是一棵**不完整**的 AST —— 判 `parser.errors.length === 0` 再往下用。

**错误恢复**：缺分隔符时只报错、不推进 token（避免死循环）；`parseLetStmt` / `parseReturnStmt`
是例外。所以一次解析可能报出多条错误，别只读第一条。

### 2.1 优先级与结合性

10 档优先级，与 `cpp/include/stope/common.hpp` 的 `OpPrecedence` 同序同值
（`AST.Precedence`）。`^` 是**右结合**，其余二元运算符左结合。

---

## 3. AST

节点类都在 `AST` 命名空间下，字段与形状串一一对应：

```js
import { AST } from '@liu-jl-dev/stope'

const tree = new AST.Prog()      // tree.stmts: Stmt[]
tree.stmts[0].nodeType           // AST.NodeType.LetStmt === 5
AST.NodeType[tree.stmts[0].nodeType] // 'LetStmt'
AST.shapeProg(tree)              // 'Let[a]=Int(1)'（测试用序列化，见 parser-test-plan.md §2）
```

| 类别 | 节点 |
| --- | --- |
| 语句 | `ExprStmt` `LetStmt` `ReturnStmt` `ExportStmt` `BlockStmt` `IfStmt` `WhileStmt` `AssignStmt` `BreakStmt` `ContinueStmt` |
| 表达式 | `NullExpr` `BoolExpr` `IntExpr` `FloatExpr` `BinArrExpr` `StringExpr` `IdentExpr` `ArgcExpr` `ArgsExpr` `UnaryOpExpr` `BinaryOpExpr` `CallExpr` `AtExpr` `CustomOpcodeExpr` |
| 容器 | `Prog`（`stmts`）、`IfStmtElif`（`cond` + `prog`，挂在 `IfStmt.elifs` 上） |

值类型一律跟词法器一致：`IntExpr.value` 是 `BigInt`，`FloatExpr.value` 是 `Number`，
`BinArrExpr.value` 是 `Uint8Array`，`StringExpr.value` 是 `string`。
`IfStmt.elseProg` 没有 else 分支时是 `null`（对应 C++ 的 `std::optional`）。

`AST.shapeProg(tree)` / `shapeStmt` / `shapeExpr` 是**测试用**序列化，严格照抄
`cpp/test/test_common.hpp` 的同名函数；它不是给宿主用的 API，格式见
[`parser-test-plan.md`](../../docs/zh-cn/parser-test-plan.md) §2。

### 3.1 遍历：`ASTVisitor`

表驱动：`NodeType` → 方法名，`visit()` 用 `this[fn]` 派发。继承后重写需要的 `onVisitXxx`，
默认实现一律「按源码顺序递归子节点」；重写后要继续下钻就调 `super.onVisitXxx(...)`。

```js
import { ASTVisitor } from '@liu-jl-dev/stope'

class CountCalls extends ASTVisitor {
  constructor() {
    super()
    this.n = 0
  }
  onVisitCallExpr(e) {
    this.n += 1
    super.onVisitCallExpr(e) // 继续看参数里的调用
  }
}
const c = new CountCalls()
c.visit(tree)
```

漏写表项不会报错，只会**静默跳过**那一类节点 —— 三个裸基类（`Node` / `Stmt` / `Expr`）
本来就没有表项，它们在错误恢复路径上出现，`visit()` 直接跳过。

---

## 4. 编译器：`Compiler`

```js
const compiler = new Compiler()      // 构造参：CustomOpcodeConfig，可空
const program = new Program()
const rc = compiler.Compile(tree, program)
if (rc !== Result.Success) throw new Error(compiler.errors.join(''))
```

| 成员 | 说明 |
| --- | --- |
| `new Compiler(custom = null)` | 配置只在构造时注入一次；`Reset(custom)` 可换 |
| `Compile(ast, out) -> Result` | 结果**写进** `out`；有错误时返回 `Error` 并把 `out` **清空** |
| `errors: string[]` | 格式 `line N: msg` |

`Compile` 每次开头都会把 `out` 复原成空 `Program`，所以同一个对象可以反复复用。
失败后**不要**拿 `out` 去反汇编或执行 —— 里面什么都没有，这正是不留半成品的意思。

编译器负责的三件难事（看代码前先知道）：

1. **变量槽位分配** —— `let` / `export` / 未声明就使用的名字都落到作用域，最终写成
   `program.variableNum` 与 `program.exports`；
2. **跳转回填** —— `If` / `GoTo` 的操作数是 **`opcodes` 下标**，先生成占位再回填；
3. **栈深度与返回值计数** —— `requiredStackSize`、`maxReturnNum`。

---

## 5. `Program`：编译产物

```js
const p = new Program()
p.opcodes        // number[]：指令与操作数混排
p.variableNum    // number
p.exports        // Map<string, number>：名字 -> 槽位
p.intConsts      // BigInt[]
p.floatConsts    // number[]
p.stringConsts   // string[]
p.binArrConsts   // Uint8Array[]
p.maxReturnNum   // number
p.requiredStackSize // number
```

`new Program()` 拿到的就是可直接编译 / 执行的空程序。序列化两个方法：

| 方法 | 说明 |
| --- | --- |
| `toMap()` | 普通对象，键名与 GDScript 侧一致（`c` `i` `f` `s` `ba` `vn` `e` `sc` `mr`）；BigInt 转字符串，JSON 才不报错 |
| `toJsonString()` | `JSON.stringify(toMap())` |

字段名取 C++ 的 camelCase 形式（`variableNum` 而不是 `variable_num`），方便两处对照。

---

## 6. 反汇编：`Disasm`

```js
import { Disasm, DisasmNoCustom } from '@liu-jl-dev/stope'

console.log(DisasmNoCustom(program))          // 产物里没有自定义指令时
console.log(Disasm(program, config))          // 有自定义指令时必须给 config
```

输出与 C++ / GDScript **逐字节一致**（`golden_disasm.txt` 是三方的共同期望值）：
编号列宽 8、名字列宽 `max(10, 最长名字)`、int / float 常量同列连排、字符串常量一行一个、
二进制数组只印字节数，最后是 `custom opcodes:` 段与 `warning:` 段。

带上 config 之后它会做三件事：

1. 把编号反查成注册名，并按 `isVarArg` 决定要不要吃掉后面那个「实参个数」；
2. 印出 `custom opcodes:` 表（**按编号排序**，与 C++ 的 `map<short, ...>` 一致）；
3. 编号撞内置 / 两条自定义指令撞号 → 写进 `warning:` 段。

`OpcodeHasArg(op)` / `CustomOpcodeHasArg(raw, config)` 是它内部用的判定，也导出了 ——
自己写反汇编时省得再猜「这条指令后面跟不跟操作数」，**猜错的后果是整段错位**。

---

## 7. 自定义指令

> 分步教程（登记 → 编译 → 反汇编 → **怎么真的执行**）见 [`custom-opcode.md`](custom-opcode.md)；
> 本节只列 API 与硬约束。

```js
import { CustomOpcodeConfig, kFirstCustomOpcode, Opcode } from '@liu-jl-dev/stope'

const config = new CustomOpcodeConfig()
config.addCustomOpcode('my:add', kFirstCustomOpcode + 0, 2)   // 定长 2 参
config.addCustomOpcode('my:log', kFirstCustomOpcode + 1)      // 省略 = -1 = 变长
config.addCustomOpcode('my:halt', kFirstCustomOpcode + 2, 0)  // 定长 0 参
```

| 成员 | 说明 |
| --- | --- |
| `config.opcodes` | `Map<string, CustomOpcode>`，名字 → 登记项 |
| `addCustomOpcode(name, opcode, argNum = -1) -> Result` | 重名返回 `DuplicateWithBuiltinOpcode` 且**不插入** |
| `CustomOpcode` | `opcode: number`、`isVarArg: boolean`、`argNum: number` |

四条硬约束：

| 约束 | 不照做的后果 |
| --- | --- |
| 编号必须 `>= kFirstCustomOpcode`（= `Opcode.Return + 1` = 33） | 与内置指令撞号，谁也分不清；`Disasm` 只能按内置解码并报 warning |
| 同一个名字不能被两条指令占用 | 后注册的返回 `DuplicateWithBuiltinOpcode`，**不插入** |
| **同一份 config** 要交给 `Lexer`/`Parser`、`Compiler`、`Disasm` | 漏给 `Parser` → 退化成普通函数调用；漏给 `Disasm` → 名字与变长操作数都认不出 |
| 定长指令的 `argNum` 必须与实际调用一致 | 编译期报 `expected N args, but got M. `，`Program` 被清空 |

名字的 `:` 是词法器支持的命名空间写法，用来避开宿主函数名（`fmt:println` 那种）。

### 7.1 怎么真的执行这些编号

编译器只负责把编号写进 `opcodes`，**执行是宿主的事**。参考执行器的分派表
`Api.opMap` 是**稠密的 `function[]`，下标就是编号**，`Run()` / `Step()` 直接
`opMap[opcode](state)` 取 —— 所以注册 N 号就必须让数组长度 ≥ N+1，且 0…N 每一格都是
**有效函数**。

```js
const api = new BasicVM.Api()
api.opMap.length = 34                                   // 33 号要能下标取到 ⇒ 至少 34 项
api.opMap[33] = (s) => {                                // my:add：弹 2 个、压 1 个
  const b = s.stack.pop()                               // 栈上一定是值：读变量走 PushValue
  const a = s.stack.pop()
  s.stack.push(BigInt.asIntN(64, a + b))                // 整数字义要按 64 位回绕
}

const state = new BasicVM.State()
state.Reset(api, program, new NoArgs())
state.Run()                                             // 源码：let x = my:add(1, 2); return x;
console.log(state.returns)                              // [3n]
```

上面这段是照可运行代码抄的（`my:add` 注册在 33）。三条不照做会踩：

| 漏了 | 现象 |
| --- | --- |
| 不 `.length = N + 1` | `TypeError: this.api.opMap[...] is not a function`，`Run()` 直接抛异常 |
| 扩了但中间留空 | 同上，`opMap[k]` 是 `undefined` |
| 把编号占进 0…32 | 内置实现赢，你的处理函数永远不会被调用（反汇编也只会印内置指令名） |

> 在自定义指令里 `state.Error()` 报错时，反汇编仍按 `Custom<N>` 印 —— 编号不在内置表里，
> 别指望看到注册名。要看名字用 `Disasm(prog, config)`。

---

## 8. 常量折叠：`optimize`

```js
import { optimize } from '@liu-jl-dev/stope'

const folded = optimize(expr)   // 折了就返回新节点，没折返回入参本身
```

`Parser` 已经接好了：在构造 `UnaryOpExpr` / `BinaryOpExpr` 的末尾就折好，所以整棵树是
**自底向上**折完的。要关掉就 `parser.constFolding = false`。

契约：

- **只做单节点变换，不递归。** 别改成把 `parseExpr` 包一层 —— 那样会重复折。
- 折不了就原样返回：除零、整数溢出、含浮点的 `idiv`、跨类型 `==`、`null` 参与比较、
  `Bool` 参与比较 —— 全部保留原节点，把计算推给运行期。
- 折叠后的节点沿用运算符节点的 `line`。

算术规则以 [`cpp/docs/expr-optim.md`](../../cpp/docs/expr-optim.md) 为准，其中三条是本项目
自定的：`BinArr + BinArr` 是字节连接；`String / BinArr * 非负整数` 是串重复；
`+ - * / idiv % ^` 里 `Bool` 当 `0` / `1`（但比较运算仍按类型区分）。

> 折叠判定必须与执行期一致，否则「字面量」和「变量」两条路径会算出不同结果。
> 本实现的折叠矩阵由 `golden_binarr.txt` 的 `FB` / `FU` 记录守着。

---

## 9. 参考执行器：`BasicVM`

**这不是标准，是内置的基础虚拟机。** 它只用来验证 `Program` 能跑，接口随时可能变。
能力边界：**不支持自定义指令**（`opMap` 默认 33 项，怎么自己扩见 §7.1）、
**不支持自定义数据类型**（值只有 `null` / BigInt / Number / string / 二进制数组 / 函数，
布尔用整数表示）。自己写执行器请照
[`docs/zh-cn/vm-guide.md`](../../docs/zh-cn/vm-guide.md)。

```js
class MyArgs extends BasicVM.Arguments {
  constructor(v) {
    super()
    this.data = v
  }
  // 取不到就自己报错：state.Error(...) + 返回 null，VM 会立刻停在这个位置
  at(state, key) {
    if (typeof key !== 'bigint' || key < 0n || key >= BigInt(this.data.length)) {
      state.Error('argument out of range. ')
      return null
    }
    return this.data[Number(key)]
  }
  num() {
    return this.data.length
  }
}

const state = new BasicVM.State()
state.Reset(new BasicVM.Api(), program, new MyArgs([1, 2, 3]))
if (state.Run() !== Result.Success) console.log(state.errors)
console.log(state.returns)
```

| 成员 | 说明 |
| --- | --- |
| `State.Reset(api, program, args = null)` | 三样都要给；同时清 `returns` / `stack` / `errors`，并按 `variableNum` 开好 `variables` |
| `State.Run() -> Result` | 跑到 `opcodes` 末尾；`errors` 非空立刻返回 `Error` |
| `State.Step() -> Result` | 单步执行一条指令：`Success` = 这条跑完了、可以接着 step；`Error` 要配合 `errors` 区分（非空 = 出错，空 = 指令流走完） |
| `State.returns: any[]` | `return` 的返回值，按出现顺序 |
| `State.errors: string[]` | `"<i>: msg"`（`i` 是指令下标） |
| `State.Error(msg)` | 宿主的报错入口（对应 C++ `State::Error`）；写进 `errors` 后 `Run` / `Step` 立即停 |
| `Api.opMap: function[]` | 33 项，下标 = opcode；要跑自定义指令得先扩表，见 §7.1 |

`while (s.Step() === Result.Success) {}` 与 `s.Run()` 等价，连走的条数都一样 —— 两条路径
各写一遍（热循环里不套函数调用），由 `test/vm.test.js` 锁着不许漂开。

### 9.1 值的 JS 表示

| Stope 类型 | JS 表示 | 备注 |
| --- | --- | --- |
| Null | `null` | |
| Integer | `BigInt` | 溢出不检查、按 64 位回绕（`BigInt.asIntN(64, ...)`） |
| Float | `number` | |
| String | `string` | UTF-16；`s[i]` 取到的是**码元** |
| BinArr | `Uint8Array` | 元素是 0…255 的 number |
| HostFunction | `function` | 调用约定 `(argv: any[]) => any` |
| Identifier | `BasicVM.Identifier` | `PushId` 压它，只有 `Assign` 认它 |

⚠ **C++ 里没有 Bool 值类型**：`PushTrue` / `PushFalse` 压的是 Integer `1n` / `0n`，
所以运行期 `1n === 1n`，源码里的 `true` 取回来是 `1n`。常量折叠里的 `Bool` 是 AST 层的
类型，别把这两件事混起来。

### 9.2 `State` 的字段

写指令处理函数、或者自己接管执行流程时要用到这些：

| 字段 | 说明 |
| --- | --- |
| `api` / `program` / `args` | `Reset` 传进来的三样，执行期间只读 |
| `i` | 指令指针。**执行中**指着当前这条指令；`Run` / `Step` 在末尾统一 `+1` |
| `stack` | 数据栈，栈顶是 `stack[stack.length - 1]` |
| `variables` | 变量槽位，长度 = `program.variableNum`，初值 `null` |
| `AtTop(k)` | 从栈顶数第 `k` 格（1 起算） |
| `Pop()` / `PopN(n)` | 弹 1 格 / 弹 n 格 |
| `stack.pop()` | 直接弹栈顶 —— 栈上**一定是值**（读变量走 `PushValue`）。执行器**没有**解引用 helper，`Identifier` 只在 `Assign` 里出现 |
| `storeBinary(result)` | 二元运算收尾：弹掉右操作数，结果写回左操作数位置 |

### 9.3 写一条指令处理函数

签名固定 `(s: State) => void`，靠副作用干活：

| 约定 | 说明 |
| --- | --- |
| 操作数 | `s.i` 已指着这条指令，**先 `++s.i` 再读** `s.program.opcodes[s.i]`；循环末尾还会统一 `+1`，别自己多推 |
| 栈效果 | 参数已按从左到右压好；结果压回栈顶、占 **1 格**；自定义指令**没有 callee 入栈** |
| 变长指令 | 流里在参数之后多一个「实参个数」操作数，先读它 |
| 报错 | `s.Error(msg)`：写进 `errors`，`Run` / `Step` 立刻停 |

`Api.opMap` 里那 33 个函数就是按这套写的，可以直接当模板。

### 9.4 宿主函数怎么进去

执行器没有独立的「函数表」：`Call` 就是把栈上的一个值当函数调，这个值必须是 `function`。
所以做法是**往变量槽里填函数**：

```js
// 编译器把未声明的 fmt:println 当成外部变量，登记进了 exports
state.variables[program.exports.get('fmt:println')] = (argv) => {
  console.log(argv.map(String).join(''))
  return null
}
```

⚠ `exports` 是 `Map`，`get` 不到返回 `undefined`；`state.variables[undefined] = fn` 不报错，
只是挂了个属性。所以名字拼错在 JS 侧是**静默**的，直到 `Call` 才报
`"Call" can only call a function. `。要立刻发现就自己判 `program.exports.has(name)`。

### 9.5 与 C++ 执行器的已知差别

| 点 | JS 侧 |
| --- | --- |
| `variables` 分配 | `Reset` 代做（C++ 要宿主自己 `variables.resize`）——参考实现可以比 C++ 少一个坑 |
| `BinArr` 表示 | `Uint8Array`（C++ 是托管句柄 + 引用计数） |
| `At` 的 key 数 | 只支持 1 个，其它报 `no implement for key num != 1. ` |
| `At` 的容器 | 只支持 `Uint8Array` 与 `string`；取字符串给的是**码元**（`charCodeAt`） |
| 整数除法 | `BigInt` 原生向零取整，`INT64_MIN / -1` 按 64 位回绕 |
| 除零 | 仅**两侧都是整数**才报 `division by zero. `；任一侧浮点走 IEEE（`1.0 / 0` = `Infinity`） |

这些取舍与 C++ 的语义一致，唯一「多做的」是 `Reset` 顺手分配 `variables`。

---

## 10. STML：`StmlLexer` / `StmlParser` / `StmlElement`

STML 是「两半」：**树的形状**由 `StmlParser` 管（标签名、属性、嵌套、结束标签配对），
**内容怎么切**由宿主管 —— 就是 `Parse()` 的第二个参数。

```js
import { StmlLexer, StmlParser, StmlElement, StmlState, Result } from '@liu-jl-dev/stope'

const stateFunc = (tag, attrs) => {
  if (tag === 'config') return StmlState.Nevext
  if (attrs.has('stope')) return StmlState.Stope
  return StmlState.Xml // 其余按子元素列表解析
}

const lx = new StmlLexer(src)
const p = new StmlParser(lx)
const root = new StmlElement()
const result = p.Parse(root, stateFunc) // 传 null 等价于不传回调（一律 Xml）
console.log(root.toStr())
console.log(p.errors, lx.errors) // 两边不合并，都要看
```

| 类型 | 成员 |
| --- | --- |
| `StmlLexer` | `new StmlLexer(source = '')`、`NextToken()`、`state`（`StmlState.Xml` / `Text` / `Nevext` / `Stope`）、`errors` |
| `StmlParser` | `new StmlParser(lex)`、`Parse(root, stateFunc) -> Result`、`errors` |
| `StmlElement` | `line`、`tag`、`attrs: Map<string,string>`、`selfClosing`、`children`、`text`、`toStr(level = 0)` |
| `StmlToken` | `line`、`type`、`lexeme` |
| `StmlTokenType` | 12 项，**名字与 C++ 完全一致**（`String` / `NevextSrc` / `StopeSrc`），`StmlTokenType[t]` 直接得名字 |

回调返回什么，元素内容就按哪种状态扫：

| 返回 | 后果 |
| --- | --- |
| `Xml` | 元素内容是**子元素列表**；此时出现裸文本是错误 |
| `Text` | 整段当普通文本（只认 `</`，`<b/>` 会被吃掉） |
| `Nevext` / `Stope` | 整段当代码段（跳过引号串与注释，其中的 `</` 不算结束标签） |

宿主侧要注意的四点（都不是 bug，是设计如此）：

1. **词法与语法的 `errors` 不合并**：`lx.errors` 与 `p.errors` 各查各的。
2. **顶层只解析一个元素**，根之后的剩余输入被忽略。
3. **属性顺序不保证**：`attrs` 是 `Map`（插入序）；要稳定顺序就自己排序。
4. **元素内文本只有一段**、不拼接；`children` 与 `text` 互斥。

回调收到的 `attrs` 是**副本**（`new Map(e.attrs)`）：删键、加键、改值都不会影响解析结果，
与 C++ 按值收 `std::map` 等价。

**分步教程**见 [`stml.md`](stml.md)（回调 → 解析 → 读树 + 可跑骨架）；
语义权威是 [`cpp/docs/stml.md`](../../cpp/docs/stml.md)（含 12 条语法坑），
行为契约在 [`docs/zh-cn/stml-test-plan.md`](../../docs/zh-cn/stml-test-plan.md)。
可运行的例子见 [`../demo/02-stml.js`](../demo/02-stml.js)。

---

## 11. 错误信息总表

各阶段**都不抛异常**（除了「宿主没实现抽象方法」这类编程错误），错误进各自的数组：

| 阶段 | 位置 | 格式 | 示例 |
| --- | --- | --- | --- |
| 词法 | `lexer.errors` | `line N: msg` | `line 1: unclosed string literal. ` |
| 语法 | `parser.errors` | `line N: msg` | `line 1: expected identifier after "let". ` |
| 编译 | `compiler.errors` | `line N: msg` | `line 1: custom opcode "my:add" expected 2 args, but got 1. ` |
| STML 词法 | `lx.errors` | `line N: msg` | `line 1: expected tag name. ` |
| STML 语法 | `p.errors` | `line N: msg` | `line 1: expected "<" or "</". ` |
| 执行 | `state.errors` | `<i>: msg` | `4: "Div" division by zero. ` |

两条容易忽略的：

- **文案以 `. `（点 + 空格）结尾**，逐字比对时别裁掉。这是与 C++ 对齐的结果。
- 执行期的下标 `i` 是**出错时**的指令下标；`Call` / `At` 这类先 `++i` 再读操作数的指令，
  下标指向的是操作数那一格，不是指令本身。

具体某条报错该改什么，翻 [`../../docs/zh-cn/`](../../docs/zh-cn/) 下对应模块的测试计划
（§错误用例），那里的用例编号与 `test/*.test.js` 一一对应。
