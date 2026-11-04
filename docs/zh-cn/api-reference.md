# API Reference（八份实现的接口形状对照）

> 定位：**有什么、叫什么、哪里不同** —— 按类给出八份实现的成员对照。
> 怎么用（示例、错误文案、排错）在各实现的 `docs/usage.md` 与 `docs/quick-start.md`；
> 行为契约在四份 `*-test-plan.md` 与 [vm-guide.md](vm-guide.md)，本文不复述语义。
>
> 命名只是风格：PascalCase（Node.js / C# / Go）与 snake_case（GDScript / Python /
> Lua / Rust）。**能力集合八份一致**；真正的差异集中在 §8「差异登记」。

## 0. 入口对照

| 实现 | 语言核心 | STML | BasicVM |
| --- | --- | --- | --- |
| C++ | 命名空间 `Stope::`（声明在 `include/stope/`、实现编译为静态库；仅 `basic_vm.hpp` / `debug.hpp` 带内联函数体） | `Stope::STML::` | `Stope::BasicVM::` |
| GDScript | `StopeLexer` / `StopeParser` / `StopeCompiler` / `StopeProgram`…（全局类，插件 `addons/stope/`） | `STMLLexer` / `STMLParser` / `STML` | `StopeBasicVM` |
| Node.js | `src/*.js` ESM 具名导出 | `stml_lexer.js` / `stml_parser.js` / `stml.js` | `basic_vm.js`（`BasicVM.State` / `Api` / `Arguments`） |
| C# | `namespace Stope` | `namespace Stope.Stml`（`Stml.Lexer` / `Stml.Parser` / `Stml.Element`） | `namespace Stope`（`State` / `Api` / `Arguments`） |
| Python | `stope.lexer` / `stope.parser` / …（`stope` 聚合导出） | `stope.stml_lexer` / `stope.stml_parser` / `stope.stml` | `stope.basic_vm` |
| Lua | `require("stope.lexer")`…（`stope` 聚合导出） | `stope.stml_lexer` / `stope.stml_parser` / `stope.stml` | `stope.basic_vm` |
| Go | 包 `stope`（module 根） | 包 `stope/stml` | 包 `stope/basicvm` |
| Rust | `stope::lexer` / `stope::parser` / …（`lib.rs` 扁平 `pub use`） | `stope::stml::lexer` / `stml::parser` / `stml` | `stope::basic_vm` |

## 1. Lexer（Stope 词法分析）

| 成员 | 对照 |
| --- | --- |
| 类型 | `Stope::Lexer` · `StopeLexer.Lexer` · `Lexer` · `Stope.Lexer` · `stope.lexer.Lexer` · `stope.lexer.Lexer` · `stope.Lexer` · `stope::lexer::Lexer` |
| 构造 | 全部收源码字符串：`new Lexer(src)` |
| 取下一 token | `NextToken(token, custom)`（C++ / Node.js / Go，token 与自定义指令配置作参）· `next_token(...)`（GDScript / Python / Lua / Rust / C#，返回或填充，见各自 usage） |
| 起始行号 | 公有字段 `line`（C++ / GDScript / Node.js / Python / Lua / Go）· C# 属性 `Line`（可写）· Rust `set_line()` |
| 重置 | `Reset(src)` —— 行号归 1、清 errors |
| 词法错误 | `errors` 列表，格式 `line N: msg`（**不**混进语法错误） |

## 2. Parser（Stope 语法分析）

| 成员 | 对照 |
| --- | --- |
| 类型 | `Stope::Parser` · `StopeParser.Parser` · `Parser` · `Stope.Parser` · `stope.parser.Parser` · `stope.parser.Parser` · `stope.Parser` · `stope::parser::Parser` |
| 解析整棵树 | `ParseProgram(tree)`（snake 组 `parse_program(tree)`），tree 是 `AST::Prog` / `AST.Prog` / `Prog` |
| 嵌套深度上限 | 公有字段 `maxDepth` / `max_depth` / `MaxDepth`（默认 256，0 = 不限；Node.js 另有常量 `kDefaultMaxDepth`，C# 为 `DefaultMaxDepth`） |
| 语法错误 | `errors` 列表，`line N: msg`；**深度超限只报一条**且中止（不级联） |
| AST 遍历 | `ASTVisitor`（表驱动 + 唯一钩子 `onVisitXxx`，教程 `cpp/docs/` §7.2） |

## 3. Compiler

| 成员 | 对照 |
| --- | --- |
| 类型 | `Stope::Compiler` · `StopeCompiler.Compiler` · `Compiler` · `Stope.Compiler` · `stope.compiler.Compiler` · `stope.compiler.Compiler` · `stope.Compiler` · `stope::compiler::Compiler` |
| 编译 | `Compile(tree, out, preExports)`（第三参可空；空名 / 重名报 `line 0`，详见 [pre-export.md](pre-export.md)） |
| 自定义指令登记 | `CustomOpcodeConfig` 上的 `AddCustomOpcode(name, opcode, argc)`（snake 组 `add_custom_opcode`）；重名返回 `DuplicateWithBuiltinOpcode` 且不插入 |
| 编译错误 | `errors` 列表 |

## 4. Program（编译产物）

`exports`（名字 → 槽位）、`variableNum`（曾经的最大变量数）、`opcodes`（指令流）、常量池。
**跨实现逐字节一致是编译器的验收标准**（golden_disasm 锁）；容器种类不同（C++ `std::map` /
JS `Map` / Go `[]ExportEntry` / Rust `BTreeMap`…），遍历顺序不保证 —— 需要参数表顺序时
用宿主自己的名单（[pre-export.md](pre-export.md) §6.5）。

## 5. BasicVM（内置参考执行器 —— **不属于标准，但会维护**）

### 5.1 State · 装配

| 成员 | 对照 |
| --- | --- |
| 类型 | `Stope::BasicVM::State` · `StopeBasicVM.State` · `BasicVM.State` · `State` · `stope.basic_vm.State` · `stope.basic_vm.State` · `basicvm.State` · `stope::basic_vm::State` |
| 绑定指令表 | `SetAPI(api)` / `set_api(api)`（GDScript / Python / Lua / Rust 为 snake） |
| 绑定程序 | `SetProgram(program)` / `set_program(program)` —— **按 `variableNum` 开好 `variables` 槽位、`i` 归零、清 `returns` / `stack` / `errors`**（C++ 例外：宿主自己 `variables.resize(...)`，且额外要 `SetAllocator` / `SetProgramConstants`） |
| 实参表 | `SetArguments(args)` / `set_arguments(args)` —— **可选依赖**，需要 `argc` / `args[i]` 才给 |

装配即「三个 Set，顺序无关」。Stope 不规定如何装配程序 —— BasicVM 只是内置的那一份
参考执行器的约定（[vm-guide.md](vm-guide.md)）。

### 5.2 State · 执行与状态

| 成员 | 对照 |
| --- | --- |
| 单步 / 连跑 | `Step()` / `Run()` —— **两份独立实现**（热循环不套函数调用），测试锁两条路径一致 |
| 返回值 | `Result`（`Success` / `Error`）—— 八份一致 |
| 公开状态 | `variables` / `returns` / `stack` / `errors` / `i`（指令指针） |
| 报错入口 | `Error(msg)` —— 追加 `"<i>: msg"`；`HasError()` |
| 栈辅助 | `AtTop(k)`（从栈顶数、1 起算）/ `Pop` / `PopN` / `PushInt`（Go 为包内私有） |

### 5.3 Api（指令表）

| 成员 | 对照 |
| --- | --- |
| 表 | `opFuncs`（C++：`static` 定长 `std::array`，33 项，**不可扩**）· `opMap`（Node.js / C# / Go，可扩）· `op_map`（GDScript / Python / Lua / Rust，可扩） |
| 扩表 | 动态语言：`resize(N+1)` / 补齐 0..N 每格有效 handler 后，从 `kFirstCustomOpcode`（=33）起登记；**C++ 内置 VM 不执行自定义指令**（demo03 只编译 + 反汇编） |
| 宿主函数 | 栈上的一个值：C++ `Value::Type::HostFunction` · GDScript `Callable` · Node.js / Python / Lua 函数对象 · Go / Rust 对应变体 |

### 5.4 Arguments（实参表）

`at(state, index)` / `num()` 两个方法（`GetArg` / `ArgNum` 指令回调）。宿主实现接口或
继承基类；没有实参表时执行 `argc` / `args[i]` 报 `no args. `。

## 6. STML

| 成员 | 对照 |
| --- | --- |
| 词法器 | 与 Stope Lexer 同构：`NextToken` / `line` / `errors` / `Reset`；**四态**（Xml / Text / Nevext / Stope），扫到 `</` 交还 Xml；token.line 在跳过前导空白**之后**取值 |
| 解析器 | `Parse(root, stateFunc)`（stateFunc 决定元素内容按哪种状态扫；可空 = 一律 Xml）；公有字段 `maxDepth`（默认 256，0 = 不限） |
| `Element` | `line`（标签行）、`textLine`（**内容首行**的物理行号，无内容 -1）、`tagName` / `tag`、`attrs`（无值属性 = 空串，顺序不保证）、`selfClosing`、`children`、`text`（与 children 互斥，只有一段） |
| 内容行号用法 | 把代码段交给 Stope Lexer 时 `lexer.line = e.textLine`，报错行号即与原文档对齐 |

## 7. BinaryArrayParser 与反汇编

| 成员 | 对照 |
| --- | --- |
| BinArr 字面量解析 | `Parse(input, output)`（单引号字面量、不转义、默认十六进制、`b`/`o`/`d`/`x` 切进制） |
| 反汇编 | `Disasm(prog, config)` / `DisasmNoCustom(prog)`（snake 组 `disasm` / `disasm_no_custom`）；单行 dump 的比对格式**不在库里**（在各实现的测试工具里） |

## 8. 差异登记

| # | 差异 | 状态 |
| --- | --- | --- |
| D-1 | C++ 的 State 多 `SetAllocator` / `SetProgramConstants`，且 `variables` 由宿主开槽 | 语言使然（值语义 / 引用计数），**保留** |
| D-3 | Go 的栈辅助（`atTop` / `pop` / `popN` / `pushInt`）为包内私有 | 语言使然，**保留** |
| D-4 | 宿主函数相等语义：Python 按身份、Go 恒 false（函数值不可比较） | 无用例依赖 |
| D-5 | GDScript 词法按码点推进非 BMP 字符、attrs 插入序不保证（GD-S-17/18） | 未修，见 [stml-test-plan.md](stml-test-plan.md) §7 |
| D-6 | BasicVM 错误串前缀：GD 为 `"<下标> <指令名>: "`（自定义指令印 `Custom<N>`），其余七份为 `"<下标>: "`；`: ` 之后的消息八份逐字一致 | 既定口径（差分只比 `: ` 之后），**保留** |

## 9. 相关文件

- 各实现入口：`cpp/docs/README.md`、`gdscript/docs/README.md`、`nodejs/README.md`、
  `csharp/README.md`、`python/README.md`、`lua/README.md`、`go/README.md`、`rust/README.md`
- 用法与错误总表：各实现 `docs/usage.md`；上手动线：各实现 `docs/quick-start.md`
- 装配 / 预导出专题：[pre-export.md](pre-export.md)（§7.1 有 `textLine` → 起始行号的写法对照）
- 新增实现的流程：[porting-guide.md](porting-guide.md)
