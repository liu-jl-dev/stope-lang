# GDScript 侧实现笔记

这份文件记两件事：**GDScript 这门语言本身的坑**（写实现时踩过的），以及**本实现自定的
代码约定**。语法语义不在这里 —— 那是 [`docs/zh-cn/syntax-reference.md`](../../docs/zh-cn/syntax-reference.md)
的事。

> 本文面向**改实现**的人；只想用这个插件的话看 [`README.md`](README.md)。

---

## 1. 语言坑

### 1.1 没有异常，错误只能靠返回值 / 错误数组

GDScript 没有 `try/catch`。所以整条链路的错误模型是统一的：

- 组件各自持有 `errors: Array[String]`，格式 `line N: msg`；
- 出错后**尽量继续**（错误恢复），但 `errors` 非空就说明结果不可信；
- 词法错误**不**合并进语法错误，语法错误**不**合并进编译器错误。调用方要三段一起看。

`push_error()` / `push_warning()` 只是往控制台 / 调试器发消息，**不会中断执行**，不能当
抛异常用。插件里用 `push_warning` 报「实现不完整」，就是因为它不阻断加载。

**运行期错误（`SCRIPT ERROR`）只中止「当前函数」并返回类型默认值，调用方照常继续**。
实测：

```gdscript
func b() -> bool:
	var m: Array[Callable] = []
	m[3].call()          # SCRIPT ERROR: Out of bounds get index '3'
	return true          # 不执行
func a() -> void:
	var r = b()          # r == false（bool 的默认值），a 继续往下跑
```

这条在写 VM 时尤其要命：错误发生在 `run()` 里，`run()` 返回 `false` 但 `errors` 是空的
（错误没走 `state.error`），宿主看到「返回失败 + 无错误」两头对不上。
所以分派表越界、`null` Callable、整数除零这类都得自己**提前判**，不能指望它抛出。
详见 [`troubleshooting.md`](troubleshooting.md) §6。

### 1.2 整数是 64 位有符号，溢出静默回绕

`int` 恒为 `int64`，加减乘溢出**不报错**，直接回绕（和 C++ 的有符号溢出行为在实际结果上
一致，但那是 UB vs 定义良好，别指望别的实现也一样）。因此：

- 词法器必须自己判整数溢出（`value > (I64_MAX - d) / base` 才安全）；
- 常量折叠用 `mul_overflow` / `div_mod_overflow` 判断后再决定折不折；
- **`-INT64_MIN` 会崩**（取负后仍溢出），`INT64_MIN / -1` 也会崩。折叠器里取负写成
  `~a + 1` 而不是 `-a`，就是为了绕开这两个边界。

`int()` 是**向零截断**，`floor()` 返回 `float`。做 `idiv` 时用 `int(a / b)` 与 C++ 的
截断除法一致；别用 `floor`。

另一个坑：**字面量形式的 `5 % 0` 是解析错误**（引擎在解析期就把常量折了，报
`Modulo by zero error in operator %.`），所以测试里没法用字面量写除零用例，得走变量或
直接构造 AST 节点 —— `test_parser.gd` 的折叠矩阵就是直接 `IntExpr.new(1, 0)`。

### 1.3 字符串按 UTF-32 索引，C++ 按 UTF-16 码元

GDScript 的 `String` 是 UTF-32：`s[i]` 是一个**码点**（类型还是 `String`，没有 char），
`s.length()` 数的是码点。C++ 侧 `std::u16string` 数的是 UTF-16 码元。

- BMP 内的字符（含中文）两边一致；
- 非 BMP（emoji、部分生僻字）在 C++ 是 2 个码元、GD 是 1 个码点 → 行号/列号、`At` 取
  元素的结果都会不同。

当前测试用例全部在 BMP 内，所以没暴露。加非 BMP 用例前先决定以谁为准。

另：`unicode_at(i)` 取码点（`int`），`substr(i, n)` 按码点切。词法器全程用 `substr`
推进输入，等于按码点走。

### 1.4 内层类必须写全名，类型标注也一样

`class_name` 只给**外层**脚本注册全局类。内层类没有全局名，任何地方都得写
`StopeLexer.Lexer`、`StopeCompiler.Compiler`、`STML.Element`。

最容易踩的是**静态函数的参数类型**：

```gdscript
# 错：外层名不是类型，:= 推断不出来，报 "Cannot infer the type of ..."
static func parse_ident_expr(p: StopeParser) -> StopeAst.Expr: ...

# 对：必须写内层名
static func parse_ident_expr(p: StopeParser.Parser) -> StopeAst.Expr: ...
```

解析器的前缀 / 中缀函数表全是静态函数、第一个参数都是 `p: Parser`，就是这个原因。

### 1.5 `const` 里不能放 Callable

所以 C++ 那种「静态常量分发表」在 GD 侧只能改成**构造函数里注册的实例字段**
（`_prefix_fns` / `_infix_fns`）。遍历骨架换个办法：表里存**方法名字符串**，用
`call(fn, n)` 派发 —— 好处是 `call` 同样会走到子类的重写版本。

### 1.6 `@abstract` 类

`basic_vm.gd` 的 `Arguments` 是抽象类：

```gdscript
@abstract class Arguments:
	@abstract func at(index_or_key)
	@abstract func num() -> int
```

子类必须实现全部抽象方法，否则实例化时报错。低版本 Godot 没有这个关键字（本仓库在
4.7.2 上开发），拷到老版本会直接语法错误。

### 1.7 `Dictionary` 是插入序，`std::map` 是键序

跨实现逐字节比对时会撞上：`Program.exports` 在 C++ 是 `std::map`（天然升序），GD 是插入序。
`dump_program()` 因此显式排序再输出。**只影响序列化**，执行器不依赖遍历顺序。

属性表 `Element.attrs` 是 `Dictionary[String,String]`，同样不保证顺序 —— STML 测试计划
`TD-2` 已经把「按字典序输出」定为跨实现约定（`test_stml.gd` 的 `shape_elem()` 会先
`keys.sort()`；直接遍历 `attrs` 拿到的是插入序，见该计划 §7 的 GD-S-17）。

### 1.8 浮点格式化没有 `%g`

GDScript 的 `%` 运算符不支持 `%g`，`String.num()` 也没有科学计数法分支。C++ 的
`printf("%g")` 只能手写复刻，见 `StopeAst.fmt_g()`：

- 先求十进制指数 `X`（`10^X <= |v| < 10^(X+1)`），**必须用循环校正**，因为
  `log(a)/log(10)` 在边界上会差一位；
- `X < -4` 或 `X >= 6` 走科学计数法，否则定点；
- 舍入后尾数可能进位成 `10.00000`，此时 `X` 要 +1 重新决策，否则 `999999.9` 会打成
  `1e+06` 而 glibc 打 `100000`；
- `-0.0` 要单独判（`1.0 / v < 0`），否则打印成 `0`。

已知精度边界：`|v| < 2.2e-308` 的次正规数与 Python 的 `%g` 有偏差（`pow(10, x)` 在这个
区间本身就没剩几位有效比特）。通用测试计划**不**把次正规数纳入比对，选用例时要避开。

### 1.9 `RegEx` 的用法

`RegEx.create_from_string(pattern)` 建对象，`search(s)` 返回 `RegExMatch` 或 `null`，
`get_string(1)` 取第一个捕获组。词法器把它放在 `static var` 里只建一次 —— 正则编译不便宜，
每条 token 都新建会很慢。

`re_exp_part` 之类只用一次的正则，宁可写成 `static var` + 常量，也不要在函数里 `create`。

### 1.10 读文件：CRLF 与 `split`

`FileAccess.open(path, FileAccess.READ).get_as_text()` 不做换行归一化，`split('\n')` 之后
每行末尾可能还挂着 `\r`。golden 数据是 Windows 上 C++ 重定向出来的，**必须剥**：

```gdscript
if raw.ends_with('\r'): raw = raw.substr(0, len(raw) - 1)
```

`FileAccess.open` 失败返回 `null`（不报异常），要自己 `push_error`。测试里读不到数据文件
就是「整组没跑」，记成失败而不是静默跳过。

### 1.11 测试入口是 `SceneTree` 脚本

`run_tests.gd` 用 `extends SceneTree`，在 `_init()` 里跑完所有断言，最后
`quit(0 或 1)` 退出。不要用 `extends Node` —— 那种要挂场景，headless 下还得等一帧。

demo 反过来是普通 `Node` + `_ready()`，跑完主动 `get_tree().quit()`，否则 headless 会挂着。

### 1.12 全局类缓存要手动刷新

全局类列表缓存在 `.godot/global_script_class_cache.cfg`。**移动 / 改名 / 新增带
`class_name` 的脚本后**，编辑器可能还在用旧表，表现为
`Identifier "Xxx" not declared in the current scope` 或 `Could not find type "Xxx"`。

修法：先跑一次导入再跑测试。

```bash
godot --headless --path gdscript --import
```

这条在 `addons/` 目录搬动之后尤其容易忘。

---

## 2. 实现约定

### 2.1 命名：C++ 的 camelCase → GD 的 snake_case

一一对应，方便逐行对照：

```
leftExpr -> left_expr      rightExpr -> right_expr      keyExpr  -> key_expr
keyExprs -> key_exprs      firstProg -> first_prog      elseProg -> else_prog
opcodeName -> opcode_name  hasAssign -> has_assign      binArrConsts -> bin_arr_consts
```

钩子名是 C++ 的 `onVisitXxx` → `on_visit_xxx`；字段 / 类名保持 C++ 的语义不变。

### 2.2 错误文案逐字照抄 C++

包括**末尾那个空格和句号**（`invalid integer. `）。跨实现比对的是字符串，差一个空格就
红一片。改文案要两边一起改，并且重生成 golden。

### 2.3 序列化格式是跨实现契约

`StopeAst.shape_*`、`StopeTestUtil.dump_program`、`STML.Element.to_str` 的输出格式都写在
`docs/zh-cn/*-test-plan.md` 里，**不是调试用的随便格式**。改格式等于改测试基线。

### 2.4 每个文件头部写清对应关系

`addons/stope/*.gd` 每个文件开头都有注释说明对应哪个 C++ 头文件、有哪些有意的偏差。
新增偏差时先在那里写清楚，再在测试计划 §7 登记。

### 2.5 不要做「防御性兜底」

执行器不在运算指令里解引用 `Identifier` —— 编译器产物错了就该暴露，兜底只会掩盖 bug。
同理，`_binary_opcode` 末尾那个 `return Opcode.Pop` 是「到不了」的保险，不是正常路径。

### 2.6 缩进用 Tab

工程统一 Tab，与 Godot 默认一致。混用空格会报
`Used space character for indentation instead of tab`。

### 2.7 返回码只有一个枚举：`stope_result.gd`

`StopeResult.Success / Error / UnknownError / DuplicateWithBuiltinOpcode` 对应 C++
`common.hpp` 的 `Stope::Result`。**别在模块里另立一份** —— 以前 `compiler.gd` 内嵌 4 项、
`stml_parser.gd` 内嵌 2 项，同名不同义，跨模块拿到返回值根本比不了。

用匿名 `enum {}` 而不是 `enum Result {}`，引用才是 `StopeResult.Success`；写成后者会变成
`StopeResult.Result.Success`。注意 `Success == 0`，**不要用真假判断**。

### 2.8 性能敏感处允许写两份循环

`BasicVM.State.run()` 与 `step()` 是两份独立实现，`run()` 不在循环里调 `step()`：
GDScript 每次函数调用 + `Callable.call` 在热循环里都是实打实的开销。同理 `run()` 把
`program.opcodes` 和它的长度提到循环外。

代价是两处必须手工同步 —— 所以 `test/test_vm.gd` 拿同一程序跑两条路径逐项比对，
改了一处忘了另一处，它会立刻红。**加性能捷径的前提是先有这条锁。**

### 2.9 写文档

五条，与 [`cpp/docs/development.md`](../../cpp/docs/development.md) §6 是同一套规则
（那边写得更细，这里只记 GDScript 侧要注意的）：

1. **文件名一律 ASCII kebab-case**：`README.md` / `usage.md` / `testing.md` /
   `troubleshooting.md` / `gdscript-notes.md`。中文标题写进文件的一级标题，链接里就不会
   冒出 `%E8%AF%AD…`。（`cpp/docs/` 有 6 个下划线文件，是历史遗留，别照着学。）
2. **分工**：`README.md` 面向所有人（是什么、怎么装、从哪开始）；`usage.md` 是 API 手册；
   `testing.md` 与本文件面向改实现的人；报错查 `troubleshooting.md`。
   同一件事只在一处写，其它地方给链接 —— 这个仓库最怕的是同一事实有三个真源。
3. **路径写法**：同目录写裸名（`usage.md`），跨目录写相对路径
   （`../../cpp/docs/stml.md`），别写 `docs/stml.md` 这种半截路径（会失效）。
4. **示例必须真跑**。代码块要么从 `demo/` 抄，要么跑一遍再贴 —— 尤其 `op_map` 扩容、
   `--import`、golden 重生成这类「不跑看不出来」的地方。
5. **缺陷编号**：本实现独有的问题登记成 `GD-P-xx`（解析）/ `GD-S-xx`（STML）等，跨实现的
   差异写进 `docs/zh-cn/*-test-plan.md` §7 的偏差表；别只在 commit 或聊天里说。

---

## 3. 本机调试速查

Godot 没进 PATH，本机（4.7.2 mono）写全路径：

```bash
GODOT="/c/Program Files/Godot/Godot_v4.7.2-stable_mono_win64/godot_console.exe"

"$GODOT" --headless --path gdscript --import                                     # 刷新全局类
"$GODOT" --headless --path gdscript --script res://test/run_tests.gd            # 跑测试
"$GODOT" --headless --path gdscript res://demo/demo_01.tscn                     # 跑 demo 01
"$GODOT" --headless --path gdscript res://demo/demo_02.tscn                     # 跑 demo 02
"$GODOT" --headless --path gdscript res://demo/demo_03.tscn                     # 跑 demo 03
```

重生成期望值不在这张表里 —— 它走 C++ 侧的 CMake target（数据已入库，跑测试不需要 C++）：

```bash
cmake --build cpp/build --target gen-golden
```

`godot_console.exe` 才保证有控制台输出；用 `Godot_v4.7.2-stable_mono_win64.exe`（GUI 版）
在 Git Bash 里通常看不到 `print` 的结果。
