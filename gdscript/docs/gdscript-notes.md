# GDScript 编写注意

改 `gdscript/stope/` 下任何代码前先看这份。每一条都是实际踩出来的
（报错原文照抄），不是猜的。

## 1. 内部类看不到外部脚本的静态函数

`class_name Xxx` 的脚本里，`class Inner` 内部**不能**裸调用脚本级的 `static func helper()`：

```gdscript
class_name Foo
static func helper() -> int: return 1
class Inner:
	func f() -> int:
		return helper()        # ✗ Function "helper()" not found in base self
		return Foo.helper()    # ✓ 必须用脚本类名限定
```

`stope_ast.gd` 的格式化小工具（`esc / fmt_bytes / fmt_g / node_type_name / indent / _e /
op_text`）必须在**所有内部类之前**声明 —— 顺序反了内部类同样看不到它们，
内部类里一律写成 `StopeAst.xxx()`。

## 2. `const` 不能装 Callable

```gdscript
const D := {1: some_method}   # ✗ Assigned value for constant isn't a constant expression
```

`const` 里写不了函数引用，别指望 `const _PREFIX_FNS := {...}`。改成实例字段，在 `_init` 里注册：

```gdscript
var _prefix_fns:Dictionary = {}
func _init(...) -> void:
    _prefix_fns[SomeType.A] = parse_a_expr     # register_parse_fns() 里做
```

`stope_parser.gd` 的 `register_parse_fns()` 与 `stope_compiler.gd` 的 `_register_visit_fns()`
都是这么写的。**构造函数里注册，别放字段初始化器** —— 初始化器求值顺序不清，容易读到空表。

## 3. `Callable.call()` 的返回值没有类型

```gdscript
var x := dict[..].call(self)              # ✗ Cannot infer the type of "x" variable
var x:StopeAst.Expr = dict[..].call(self) # ✓ 必须显式标注
```

同理，`optimize()` 这类返回 `Expr` 但实际子类多样的函数，返回类型标注要写到具体类，
调用侧必要时 `as StopeAst.Expr`。

## 4. `elif` 是关键字，不能做变量名

```gdscript
var elif := ...   # ✗ Expected variable name after "var"
```

`stope_parser.gd` 里遍历 if 的 elif 分支时局部变量名叫 `ei`。

## 5. `for x in A, B, C:` 不支持

```gdscript
for t in A, B, C:            # ✗ Expected ":" after "for" condition
for t in [A, B, C]:          # ✓ 数组字面量
```

注意报错定位到的是 `for` 那一行，容易误判成别的问题。

## 6. 类型化 Array 不能被整体赋 untyped Array

```gdscript
class Prog:
	var stmts:Array[Stmt] = []
# ...
p.stmts = some_untyped_array   # ✗ Invalid assignment of property or key 'stmts'
```

要逐个 `append`，或者把来源声明成同样的类型。

## 7. `%` 不支持 `%g`，浮点的格式化得自己写

GDScript 的 `%` 运算符不支持 `%g`，`String.num()` 也没有科学计数法分支。但形状串与
`Program` 序列化里的浮点必须两侧一致 —— C++ 用的是 `printf("%g")`，所以 GD 侧得自己复刻。

`StopeAst.fmt_g()` 手工复刻了 `%g`（精度 6）的全部决策：先取十进制指数 X，
`X < -4 或 X >= 6` 走科学计数法，否则走定点；两种都要去掉尾部多余的 0 与孤立的小数点；
**舍入进位会让尾数变成 `10.00000`，此时 X 要 +1 再重新决策**（否则 `999999.9`
会印成 `1e+06` 而另一个实现印 `100000`）。

### 精度边界（实测）

浮点发生器 dump 了 3166 个样本（10 的各次幂、0/1/1.5/边界值、1500 组随机尾数×随机二的幂、
60 个次正规数），按比特位交给 Python 的 `"%g"` 逐位对照：**3127 条一致，39 条失配，
失配的全部落在次正规区间（|v| < 2.2e-308）**。原因是 `pow(10.0, x)` 在这个区间本身只剩
个位数有效比特，`a / pow(10.0, x)` 保不住 6 位有效数字。

⇒ **通用测试计划不把次正规数纳入比对**，选测试用例时要避开（Stope 的正常词法产物
如 `1e-320` 会落到这一档）。

### Godot 会折叠某些字面量

`-0.0` 与 `5e-324` 这类写在源码里的字面量会被 Godot 直接折成 `0.0`。要构造这些值只能
走「位模式往返」（`int` bits ↔ `float`），不能用字面量赋值。

## 8. 整数会静默回绕

GD 的 int 溢出不报错。`stope_expr_optim.gd` 自己实现了
`add_overflow / sub_overflow / mul_overflow / neg_overflow / div_mod_overflow / int_pow`，
全部返回 `[是否溢出, 结果]`。**凡是做算术折叠的地方都要先过溢出检查**，别依赖语言行为。

## 9. 换行符：C++ 探针产出 CRLF，Godot 写出 LF

比对数据文件前必须先把两边拉到同一套行尾，否则会对出大量假失败。两个来源：

- C++ 探针把 stdout 重定向到文件时，Windows 上是 **CRLF**；Godot 的 `FileAccess` 写出是 **LF**。
  比对数据文件要么用 `diff --strip-trailing-cr`，要么在读取时把行尾的 `\r` 剥掉
  （`test_util.gd` 的 `read_golden()` / `read_lines()` 已经这么做了）。
  症状很好认：**所有行的最后一个字段都「看起来一样却判定不同」**。
- `cpp/stope/*.hpp`、`cpp/test/*.cpp`、`cpp/stope/*.md` 目前都是 **LF** 行尾。
  用脚本改写时用 Python 的 `io.open(..., newline='')`，并传【确切】的字符串 ——
  在 shell heredoc 里写 `\n` 会被当成两个字符写进文件，曾经一次性破坏 21 个构造函数。

## 10. 新建 / 删除带 `class_name` 的脚本后要先 import

新建带 `class_name` 的脚本后，`--script` 直接跑会报
`Identifier "Xxx" not declared in the current scope`，因为 `.godot/global_script_class_cache.cfg`
还没更新。先跑：

```bash
godot --headless --path gdscript --import
```

这个文件是 GDScript 全局类名的注册表，手改没有意义。删文件同理要重新 import。

## 11. 构造函数签名的约定

`stope_ast.gd` 里所有叶子 / 节点统一是 `func _init(line_:int = -1) -> void:`，
这样可以用 `make_null(line)` 的方式构造，也为将来加字段留位置。叶子类在
`_init` 里同时把 `line` 与 `value` 一次设完（如 `IntExpr.new(line, v)`）。

## 12. 与 C++ 对照时的命名映射

| C++ | GDScript |
| --- | --- |
| `leftExpr` | `left_expr` |
| `rightExpr` | `right_expr` |
| `keyExpr` / `keyExprs` | `key_expr` / `key_exprs` |
| `firstProg` / `elseProg` | `first_prog` / `else_prog` |
| `hasAssign` | `has_assign` |
| `opcodeName` | `opcode_name` |
| `onVisitLetStmt` | `on_visit_let_stmt` |
| `parseLetStmt` | `parse_let_stmt` |

两侧的函数体刻意一行一行对得上。改一边**必须**同步改另一边，否则
`godot --headless --path gdscript --script res://test/run_tests.gd` 会立刻告诉你。
