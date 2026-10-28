# GDScript 实现 · 总览

`gdscript/` 是 Stope 的 **GDScript 参考实现**，以 **Godot 插件**的形式分发：一个纯库插件，
不含任何编辑器 UI。装进项目后，15 个全局类可直接当 API 用。

它和 C++ 实现的关系只有一句话：**C++ 是权威实现，本实现按它逐项对齐**。两侧出现分歧，
以 `cpp/include/stope/*.hpp` 的实测行为为准，差异登记在
[`docs/zh-cn/*-test-plan.md`](../../docs/zh-cn/) 的 §7 里。

当前状态（2026-10-28）：词法 / 语法 / 编译器 / STML / 执行器五组共 **3076 条断言全绿**，
期望值全部由 C++ 侧探针 dump，不是手写的 —— 但那些数据**已经入库**，所以跑测试只需要
Godot，不需要 C++ 工具链。

> **本文是给"想用这个插件"的人看的**：§1 有什么、§2 没什么、§4 怎么装、§5 怎么用、§7 还
> 有哪些文档。要**改** `addons/stope/` 的实现，另看 §6 改动顺序 +
> [`gdscript-notes.md`](gdscript-notes.md)（语言坑与代码约定）+
> [`testing.md`](testing.md)（测试与 golden 数据怎么重生成）。

---

## 1. 包含什么

| 全局类 | 文件 | 对应 C++ |
| --- | --- | --- |
| `StopeOpcode` | `opcode.gd` | `cpp/include/stope/opcode.hpp` |
| `StopeLexer` | `lexer.gd` | `cpp/include/stope/lexer.hpp` |
| `StopeParser` | `parser.gd` | `cpp/include/stope/parser.hpp` |
| `StopeAst` | `ast.gd` | `cpp/include/stope/ast.hpp` |
| `StopeASTVisitor` | `ast_visitor.gd` | `cpp/include/stope/ast_visitor.hpp` |
| `StopeBinArrParser` | `binarr_parser.gd` | `cpp/include/stope/parse_binarr.hpp` |
| `StopeExprOptim` | `expr_optim.gd` | `cpp/include/stope/expr_optim.hpp` |
| `StopeCompiler` | `compiler.gd` | `cpp/include/stope/compiler.hpp` |
| `StopeProgram` | `program.gd` | `cpp/include/stope/program.hpp` |
| `StopeBasicVM` | `basic_vm.gd` | `cpp/include/stope/basic_vm.hpp` |
| `STML` | `stml.gd` | `cpp/include/stope/stml.hpp` |
| `STMLLexer` | `stml_lexer.gd` | `cpp/include/stope/stml_lexer.hpp` |
| `STMLParser` | `stml_parser.gd` | `cpp/include/stope/stml_parser.hpp` |
| `StopeResult` | `stope_result.gd` | `cpp/include/stope/common.hpp` 的 `Result` |
| `StopeDebug` | `debug.gd` | `cpp/include/stope/debug.hpp` |

链路是：源码 →（`Lexer`）Token →（`Parser`）AST →（`Compiler`）`Program` →
（`BasicVM.State`）结果。`StopeASTVisitor` 是编译器的遍历骨架；`StopeExprOptim` 由
`Parser` 在构造一元 / 二元节点时直接调用。

## 2. 不包含什么

- **虚拟机不是标准。** `StopeBasicVM.State` / `Api` 只是**参考执行器**，用来证明编译器
  产出的 `Program` 确实能跑。指令语义、栈布局、宿主函数约定都不属于规范 —— 换个执行器
  完全可以。自写执行器见 [`docs/zh-cn/vm-guide.md`](../../docs/zh-cn/vm-guide.md)。
- **STML 的两条残留差异**：属性遍历顺序是插入序（C++ 是字典序）、非 BMP 字符按码点推进
  （C++ 按 UTF-16 码元）。逐条列在
  [`docs/zh-cn/stml-test-plan.md`](../../docs/zh-cn/stml-test-plan.md) §7 的 GD-S-17/18；
  2026-10-28 之前那 14 条差异（含两条会挂死的）已全部修掉。
- **没有类型检查、没有优化 pass（常量折叠除外）、没有调试器。**

## 3. 目录

```
gdscript/
  addons/stope/          插件本体（13 个脚本 + plugin.cfg + plugin.gd）
    opcode.gd            指令集 33 条 + 自定义指令登记
    lexer.gd             Token 47 种 + 词法分析
    parser.gd            Pratt 解析器
    ast.gd               28 种节点 + shape 序列化
    ast_visitor.gd       visit_map 表驱动遍历骨架
    binarr_parser.gd     '...' 内容的字节解析
    expr_optim.gd        常量折叠
    compiler.gd          AST → Program
    program.gd           Program 数据结构（to_map / to_json_string）
    stope_result.gd      跨模块返回码（对齐 C++ 的 Stope::Result）
    debug.gd             反汇编（对齐 C++ debug.hpp 的 Disasm）
    basic_vm.gd          参考执行器（非标准）
    stml*.gd             STML 三件套（四态词法 + 宿主回调决定内容怎么切）
    plugin.cfg / .gd     插件入口，只做完整性自检
  demo/                  与 cpp/demo/ 一一对应，都要配 .tscn 才能跑
    demo_01.gd/.tscn     编译 + 运行（对齐 cpp/demo/01-quick-start.cpp）
    demo_02.gd/.tscn     解析 STML（对齐 cpp/demo/02-stml.cpp）
    demo_03.gd/.tscn     自定义指令：登记 → 编译 → 反汇编（对齐 03-custom-opcode.cpp）
  test/                  run_tests.gd + 五组测试 + golden 数据（数据由 cpp/tools/ 生成）
  docs/                  本目录
  project.godot          Godot 工程文件（已启用本插件）
```

## 4. 安装为一个插件

1. 把整个 `addons/stope/` 目录拷进目标项目的 `addons/` 下（目录名保持 `stope`）。
2. 在 **项目 → 项目设置 → 插件** 里启用 **Stope**；或直接在 `project.godot` 里写：

   ```ini
   [editor_plugins]

   enabled=PackedStringArray("res://addons/stope/plugin.cfg")
   ```

3. 首次拷入（或增删过带 `class_name` 的脚本）后跑一次导入，让 Godot 重建全局类缓存：

   ```bash
   godot --headless --path <目标项目> --import
   ```

4. 之后在任何脚本里直接用 `StopeLexer`、`StopeParser` 这些名字。引用**内层类**要写全名：
   `StopeLexer.Lexer`、`StopeCompiler.Compiler`、`STML.Element`。

插件在 `_enter_tree()` 里只做一件事：比对 13 个全局类是否都在
`ProjectSettings.get_global_class_list()` 里，缺了就 `push_warning` 说明目录被裁剪或
`class_name` 被改过。**它不往编辑器里加任何节点、菜单或 autoload。**

两条硬约束：

- **不要给 `addons/stope/` 下的脚本改名，也不要删 `class_name`。** 这 13 个类全靠全局类名
  互相引用，改一个就全链路失效。
- 全局类名都有 `Stope` / `STML` 前缀，与业务代码撞名概率很低，但并非不可能。

依赖：只用 Godot 内置能力（`RegEx`、`FileAccess`、`PackedByteArray`），零第三方插件。
`basic_vm.gd` 用到了 `@abstract`，低版本 Godot 未验证；开发与实测版本是 **4.7.2**。

## 5. 五分钟上手

```gdscript
extends Node

class MyArgs extends StopeBasicVM.Arguments:
	func at(_key): return null
	func num() -> int: return 0

func _ready() -> void:
	var src := "let a = 1; let b = 2; return a + b;"

	# 1. 源码 -> AST
	var lexer := StopeLexer.Lexer.new(src)
	var parser := StopeParser.Parser.new(lexer)		# 第二参是 CustomOpcodeConfig，可省
	var tree := StopeAst.Prog.new()
	parser.parse_program(tree)
	if not lexer.errors.is_empty() or not parser.errors.is_empty():
		push_error(str(lexer.errors) + str(parser.errors))
		return

	# 2. AST -> Program
	var compiler := StopeCompiler.Compiler.new()
	var program := StopeProgram.Program.new()
	if compiler.compile(tree, program) != StopeResult.Success:
		push_error(str(compiler.errors))
		return
	print(StopeDebug.disasm(program))

	# 3. 装配参考执行器并运行（这一段不是标准，可以整个换掉）
	var state := StopeBasicVM.State.new()
	state.reset(StopeBasicVM.Api.new(), program, MyArgs.new())
	if not state.run():
		push_error(str(state.errors))
		return
	print(state.returns)	# [3]
```

完整示例（含宿主函数注册、`args` / `argc` 注入）见 `demo/demo_01.gd`：

```bash
godot --headless --path gdscript res://demo/demo_01.tscn
```

预期输出 `[Host] 结果为: 15` 与 `result: 15`，与 `cpp/demo/01-quick-start.cpp` 一致。

另两个 demo 与 C++ 侧同名同序：

| demo | 跑法 | 对齐 |
| --- | --- | --- |
| `demo_02.gd` | `... res://demo/demo_02.tscn` | `cpp/demo/02-stml.cpp`（只解析，不执行） |
| `demo_03.gd` | `... res://demo/demo_03.tscn` | `cpp/demo/03-custom-opcode.cpp`（只编译 + 反汇编） |

> `demo_02` 的宿主回调（`config` → Nevext、带 `stope` 属性 → Stope、其余 → Xml）与
> `cpp/demo/02-stml.cpp` 的 lambda 逐条对应，输入文档也是同一份。

## 6. 改动顺序

语义是 C++ 定的，所以**不要先改 GDScript**：

1. 改 `cpp/include/stope/*.hpp`（必要时同步 cpp 测试）；
2. 重跑 `cpp/tools/golden*.cpp` 刷新 `test/data/*.txt`（一条命令：`gen-golden` target）；
3. 改 `addons/stope/*.gd`；
4. `godot --headless --path gdscript --script res://test/run_tests.gd` 应当回到全绿；
5. 有必要时在 `docs/zh-cn/*-test-plan.md` §7 登记差异或划掉已修项。

反过来做（先改 GD 再改 C++）会让 golden 数据和实现互相打架，最后谁也说不清谁对。

## 7. 文档

| 想看 | 去哪 |
| --- | --- |
| 每个 API 怎么调、参数与返回 | [usage.md](usage.md) |
| 测试怎么跑、数据怎么重生成 | [testing.md](testing.md) |
| GDScript 本身的坑与实现约定 | [gdscript-notes.md](gdscript-notes.md) |
| Stope 语法（跨实现） | [../../docs/zh-cn/syntax-reference.md](../../docs/zh-cn/syntax-reference.md) |
| 词法 / 语法 / 编译器 / STML 行为契约 | [../../docs/zh-cn/](../../docs/zh-cn/) 下的四份 `*-test-plan.md` |
| 执行器（不是标准，只是参考实现） | [../../docs/zh-cn/vm-guide.md](../../docs/zh-cn/vm-guide.md) |
| 指令集与 `Program` 格式 | [../../docs/zh-cn/compiler-test-plan.md](../../docs/zh-cn/compiler-test-plan.md) §2 |
| 自己写执行器 | [../../docs/zh-cn/vm-guide.md](../../docs/zh-cn/vm-guide.md) |
| C++ 侧用法 | [../../cpp/docs/quick-start.md](../../cpp/docs/quick-start.md) |
