# Stope GDScript 实现

这是 Stope 语言的 **GDScript 实现**（最早是原型 / 参考实现，现已按 C++ 重写对齐）。

> **C++ 实现是权威实现**。`gdscript/` 下的一切行为以 `cpp/stope/*.hpp` 为准，
> 两侧必须能逐字节比对同一份输出。判断某条行为该是什么样时，看 C++ 或问
> `docs/zh-cn/` 下的三份通用测试计划，不要只看 GDScript 代码。

## 文档导览

| 文档 | 讲什么 |
| --- | --- |
| [testing.md](testing.md) | 测试怎么跑、期望值从哪来（golden 数据怎么重新生成）、当前结果 |
| [GDScript 编写注意.md](gdscript-notes.md) | 移植 / 改这块代码时必须知道的 GDScript 语言坑（都踩过） |
| `../docs/zh-cn/lexer-test-plan.md` | 词法的行为契约（语言无关），GD 侧差异登记在 §7 |
| `../docs/zh-cn/parser-test-plan.md` | 语法的行为契约（语言无关），GD 侧差异登记在 §7 |
| `../docs/zh-cn/compiler-test-plan.md` | 编译器的行为契约（语言无关），GD 侧差异登记在 §7 |

## 文件结构

```
gdscript/
  project.godot          Godot 工程
  stope/                 实现
    stope_token.gd         词法分析（Token 类型 + Lexer）
    stope_parser.gd        语法分析
    stope_ast.gd           AST 节点定义 + 形状串序列化（测试用）
    stope_parse_binarr.gd  '...' 内容的字节解析
    stope_expr_optim.gd    常量折叠
    stope_compiler.gd      编译器（AST -> Program）+ 辅助类（作用域、变量分配、栈记账）
    stope.gd               指令集 enum、Program、VM（State / Api）
    stope_asm.gd           Nevext 文本汇编 -> Program（另一个入口，与本轮三模块无关）
    nevext.gd / stml*.gd   Nevext / STML 工具库（Nevext 项目：<https://github.com/liu-jl-dev/nevext>）
  test/                  测试（见testing.md）
  docs/                  本文档所在目录
```

## 与 C++ 实现的对应关系

| 模块 | C++ | GDScript |
| --- | --- | --- |
| Token 类型 | `cpp/stope/token.hpp` | `stope_token.gd` 的 `StopeToken.Type` |
| 词法分析 | `cpp/stope/lexer.hpp` | `stope_token.gd` 的 `StopeToken.Lexer` |
| AST 定义 | `cpp/stope/ast.hpp` | `stope_ast.gd`（字段名 camelCase -> snake_case） |
| 优先级 | `cpp/stope/common.hpp` 的 `OpPrecedence` | `stope_ast.gd` 的 `Precedence` / `binop_prec_map` |
| 语法分析 | `cpp/stope/parser.hpp` | `stope_parser.gd` |
| 遍历骨架 | `cpp/stope/ast_visitor.hpp` | **没有抽** —— 用 `NodeType -> Callable` 字典代替，见下 |
| 二进制数组 | `cpp/stope/parse_binarr.hpp` | `stope_parse_binarr.gd` |
| 常量折叠 | `cpp/stope/expr_optim.hpp` | `stope_expr_optim.gd` |
| 作用域 | `cpp/stope/scope_context.hpp` | `stope_compiler.gd` 里的 `Scope/BlockScope/FileScope/WhileScope` |
| 编译器 | `cpp/stope/compiler.hpp` | `stope_compiler.gd` |
| 指令集 | `cpp/stope/opcode.hpp` | `stope.gd` 的 `Stope.Inst`（**32 条，编号必须一致**） |
| Program | `cpp/stope/program.hpp` | `stope.gd` 的 `Stope.Program` |
| 虚拟机 | （C++ 侧尚未实现） | `stope.gd` 的 `Stope.State` / `Stope.Api` |

### 为什么 GD 侧没有 ASTVisitor

C++ 侧把遍历骨架抽到 `ast_visitor.hpp`，是为了将来写解释器时能复用。GDScript 侧没有这个
需求，而 GD 的虚函数派发写起来笨重，所以 `stope_compiler.gd` 里改用一张
`NodeType -> Callable` 的字典（等价于 C++ 的 `ASTVisitor::visitMap`），语义动作直接写在各
`on_visit_xxx` 函数里，名字与 C++ 的 `onVisitXxx` 一一对应：**`on_visit_let_stmt` ↔
`onVisitLetStmt`**。对照两边时按这张名字表找即可。

## 两条最容易踩的红线

1. **`Stope.Inst` 的编号不能动顺序。** 它和 `cpp/stope/opcode.hpp` 的 `Opcode` 必须逐项对齐
   （2026-10-18 在索引 7 插入了 `PushBinArr`，并把 `PushStr` 改名为 `PushString`）。
   插入或改名都会平移后续编号，会让两侧产出完全不同的 `Program`。
2. **`else_prog` 可以为 null，`first_prog / WhileStmt.prog / BlockStmt.prog` 不可以。**
   C++ 侧后者是**值**成员（永远存在，错误恢复路径上是空 `Prog`），只有 `IfStmt::elseProg`
   是 `std::optional<Prog>`（`null` 表示没有 else 分支）。GD 侧是引用类型，因此那三个字段
   在构造函数里就被实例化了 —— 删掉会导致形状串输出 `Block{null}` 而不是 `Block{}`。

## 本轮整改做了什么（2026-10-18）

以 C++ 为准重写了词法、语法、编译器三个模块，并把 `docs/zh-cn/` 三份测试计划的 §7 差异
登记（`GD-L-01…10` / `GD-P-01…10` / `GD-C-01…10`）全部翻到「已修」。具体情况：

- **词法**：Token 类型拆成 `Integer/Float/String/BinArr` 四项；补 `errors`；未知字符必须消费；
  数字在词法期就做消费完整性与溢出校验；单引号内容不做任何转义。
- **语法**：完全按 `parser.hpp` 重写 —— `parse_prog(prog, is_top_level)`、缺分隔符只报错不
  推进、顶层孤立 `}` 报错并跳过、常量折叠挂在 `parse_unary_op_expr` / `parse_binary_op_expr`
  末尾；AST 节点改成与 `ast.hpp` 逐项对齐的 28 个 `NodeType`；新增形状串序列化。
- **编译器**：纠正了四处记账 / 映射错误（详见 `stope_compiler.gd` 文件头），补了 `PushBinArr` +
  `bin_arr_consts`、出错清空 Program、int16 越界保护、变量回收去重。
- **指令表与 VM**：`Inst` 补 `PushBinArr`、`PushStr` → `PushString`、`Api.op_map` 同步；
  `Program` 字段名改成 `program.hpp` 的 snake_case 形式，并新增
  `Stope.dump_program()` —— 两侧交叉比对用的那一行序列化格式。
