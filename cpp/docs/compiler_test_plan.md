# `cpp/include/stope/compiler.hpp` 测试计划

- 被测对象：`cpp/include/stope/compiler.hpp` — `Stope::Compiler`（2026-10-18 起 `public` 继承 `ASTVisitor`，
  同目录的基类 `ast_visitor.hpp` 的测试在 `test_ast_visitor.cpp`；另外依赖 `scope_context.hpp`，
  AST 侧依赖 `ast.hpp`、`opcode.hpp`、`program.hpp`、`custom_opcode.hpp`）
- 计划版本：v1.3（2026-10-22）：**全部测试落地并全绿** ——
  53 个用例（C-01…C-52 + C-37b）/ 98 断言 / 0 失败，Opcode 覆盖 **33/33**；
  基类另有 `test_ast_visitor` 的 V 组 36 断言 / 0 失败；
  另有 `test_vm` 的 VM 组 156 断言 / 0 失败；`ctest` **15/15**。
  - v1.3 的变化只有一处：`Opcode` 新增 `PushValue`（编号 8），读变量与「当赋值
    目标」分成两条指令，见 §2.1 末尾。用例数与断言数不变，只是期望串里的读值位置
    由 `PushId` 改成 `PushValue`，覆盖口径 32 → 33。
- 实测环境：g++ (MinGW-w64 x86_64-win32-seh) 15.2.0，`-std=c++20`
- 参考实现（语义基准）：`gdscript/addons/stope/compiler.gd`（配 `opcode.gd` 的 `Opcode` / `has_a_param`、
  `program.gd` 的收尾）
- 上游依赖：`parser.hpp` + `lexer.hpp`（其测试计划见 `parser_test_plan.md` / `lexer_test_plan.md`）

---

## 1. 目标与非目标

### 1.1 目标

1. 为 `Compiler::Compile(AST::Prog&, Program&)` 建立回归基线：指令字节序、常量池去重、
   变量编号与回收、导出表、跳转目标回填、`maxReturnNum`、`requiredStackSize`。
2. 把「相对参考实现的 4 处偏离」逐条钉住（见 §3），防止后来者"照着参考实现改回去"。
3. 覆盖 33 个 `Opcode` 的全部产生路径（当前 33/33），未覆盖的要在 README 里点名。
4. 同时验证**折叠开 / 折叠关**两条端到端路径：`parser.constFolding` 的开关会影响指令长短。

### 1.2 非目标

- 不测试 VM 执行结果（`stope_vm.gd` 的职责；C++ 侧还没有 VM）。
- 不做「语义正确性」判断（如 `a[0] = 1;` 究竟该怎么翻译成 At + Assign，
  这里只锁定**与参考实现一致**的现状，见 CD-5）。
- 不做性能基准；不做 int16 溢出实测（32767 条指令的输入太长，见 §10）。

---

## 2. 被测接口契约

```cpp
struct Compiler : public ASTVisitor {            // 基类见 ast_visitor.hpp
  Program* prog = nullptr;                       // public，正在写入的 Program，不拥有
  const CustomOpcodeConfig* customOpcodeConfig = nullptr;
  std::vector<std::string> errors;               // public，格式 "line N: msg"
  // 自定义指令配置只在构造时注入；两个必填参数都传引用（见 development.md §7）
  Compiler(const CustomOpcodeConfig* custom = nullptr);
  Result Compile(AST::Prog& ast, Program& out);
};
```

> **继承关系**：2026-10-18 起分派与默认递归在基类 `ASTVisitor` 里，这里只剩语义动作。
> 边界说明见 §4.5；基类的测试是 `test_ast_visitor.cpp`（V 组）。

> **不要在 Compiler 里保存 Program 字段的副本**（2026-10-17 重写）。
> 参考实现 `compiler.gd` 的 `int_consts` / `float_consts` / `str_consts`
> 都是 Reference 对象，收尾时把 `data` 交给 Program 是**零拷贝**；C++ 里照着写成
> 成员 + 赋值就是真的复制一份。现在的实现**直接把指令写进 `out->opcodes`、
> 把常量写进 `out->intConsts` 等池子**，编译器自己只留两类「Program 里没有对应
> 字段」的记账状态：`varAlloc`（变量总表，收尾落到 `variableNum` / `exports`）
> 与 `stackSize`（运行中的栈深度，Program 只存最大值）。

| 约束 | 说明 | 测试注意点 |
| --- | --- | --- |
| **出错时把 `out` 复原为空** | `Compile()` 在 `errors` 非空时 `clearOutput()` 后返回 Error | 期望指令串要写成空串 `""`；这等价于参考实现出错返回 `null`（半成品 Program 跑不了） |
| **`out` 是覆盖写，不是累加** | 一进去就 `clearOutput()` | 同一个 `Program` 可以复用，但别指望两次结果合并 |
| **cfg 是 `Compile` 的第三参** | 与 parser 的 cfg 是**两个**指针 | C-37 靠「两边传不同的 cfg」才走到未定义分支（详见 §4.3） |
| **`exports` 的判据是变量名非空** | `declareExported()` 在登记时就写 `prog->exports[name] = idx` | `let` 出来的局部变量（`newVar("")`）不导出；`export` 与「未声明就使用」都会导出 |
| **常量池去重是线性查找** | `constIndex()` 用 `std::find` | O(常量个数) 每条字面量；好处是不必再维护一份 map（那又是重复状态） |
| **排完仍需查 `errors`** | 返回值只有 Success/Error 两态 | `expectErrCount` 是每条用例的标配 |
| **`Compile` 的入参是指针** | `AST::Prog*` / `Program*`，不能是引用或临时值 | `ast` 必须活到调用结束；传 `nullptr` 会直接崩（目前不校验） |

### 2.1 指令形状（`opcodes` 是 `short` 混排序列）

| 指令 | 是否带操作数 | 操作数的含义 |
| --- | --- | --- |
| `PushNull` `PushFalse` `PushTrue` `Pop` `Minus` `Not` `Pow` `Mul` `Div` `IDiv` `Mod` `Add` `Sub` `EQ` `NE` `LT` `LE` `GT` `GE` `GetArg` `ArgNum` | 否 | — |
| `Assign` | 否 | （栈上取 target / value） |
| `PushInt` `PushFloat` `PushString` `PushBinArr` `PushValue` `PushId` | 是 | 常量池 / 变量表索引 |
| `Call` `At` | 是 | 参数个数 |
| `If` `GoTo` | 是 | 跳转目标（**code 的元素下标**，不是指令条数） |
| `Return` | 是 | 返回值个数 |
| 自定义指令 | 仅变长时有 | 参数个数 |

判断依据是 `gdscript/addons/stope/opcode.gd` 的 `StopeOpcode.has_a_param`；C++ 多出的 `PushBinArr`
让后面所有阈值整体后移一位（见测试里的 `opHasParam`）。

#### `PushId` 与 `PushValue` 的分工（2026-10-22 起）

两者都带一个变量表索引，**区别在压的是槽位还是槽位里的值**：

| 指令 | 压什么 | 谁会生成 |
| --- | --- | --- |
| `PushId` | 变量槽位**本身**（一个左值）；`Assign` 靠它才能写回去 | ① 有赋值的 `let` 的左侧　② 赋值语句等号左侧**恰好是裸标识符**时 |
| `PushValue` | 槽位**当前的值**（压栈时就取出来） | 其余一切「读变量」的位置：表达式里的变量、被调用者、被索引的容器、条件、`return` 的值… |

判据写在 `onVisitAssignStmt` 里：`s->leftExpr->type == AST::NodeType::IdentExpr` 才走
`PushId`，否则 `Visit(s->leftExpr.get())` 走普通读值。所以 `a[0] = 1;` 里的 `a` 是
`PushValue`（左侧是 `IndexExpr`，不是裸标识符）—— 这就是 C-48 的形状。

> 拆分前所有位置都是 `PushId`，执行器得在每条读值路径上自己解一次引用；拆分后
> 读值在编译期就定下来了。`basic_vm.hpp` 的 `opPushValue` 就是「从槽位取值压栈」。

### 2.2 跳转目标怎么数

`If(x)` / `GoTo(x)` 里的 `x` 是 **`opcodes` 数组的下标**，所以必须把每条带操作数指令的
操作数也算进去。首版手推期望时全组算错（`PushValue(0)` 占 2 个 short），排查口径统一为：

```
0:PushValue 1:(0) 2:If 3:(7) 4:PushTrue 5:GoTo 6:(15)
7:PushValue 8:(1) 9:If 10:(14) 11:PushTrue 12:GoTo 13:(15) 14:PushFalse 15:Pop
```

写新用例（尤其涉及 `If` / `GoTo` / `while`）时**先画这条下标轴**再写期望串，
否则会像 C-15/C-18…C-46 那样一次性错十几条。

---

## 3. 相对参考实现的偏离（CD-1…CD-5）

仿照不等于照抄。参考实现 `compiler.gd` 有几处在 C++ 侧会直接跑错或算错，
逐条登记如下，每条都有对应用例锁住。**改实现前先读这一节。**

| 编号 | 参考实现的做法 | C++ 的做法 | 原因 | 锁定的用例 |
| --- | --- | --- | --- | --- |
| **CD-1** | `binop_inst_map['-'] = Stope.Inst.Minus` | 二元 `-` 用 `Opcode::Sub` | VM 里 `Minus` 只弹一个操作数（一元取负），二元减法会跑错。C++ 的 `opcode.hpp` 本来就区分 `Minus` / `Sub` | C-14 / C-17 |
| **CD-2** | `visit_binary_op_expr` 末尾统一 `stack_size_mgr.dec()`，`PushTrue` / `PushFalse` 不 `inc` | `and` / `or` 各自记账：结果 +1，`PushTrue`/`PushFalse` 计 `inc`，分支用 `StackSizeManager::converge()` 扳回汇合点深度 | 参考实现算出来偏小（`and`/`or` 净变化是 +1 不是 0）；而线性记账又会算成「各分支深度之和」（`a or b;` 实测会算成 3，真值 1） | C-18 / C-19 |
| **CD-3** | `visit_custom_inst_expr` 末尾 `dec(len(args))` | `dec(len(args) - 1)` | 自定义指令没有 callee 入栈，结果仍占 1 格，净变化是 `-(n-1)` | C-34 / C-35 |
| **CD-4** | `visit_while_stmt` 无条件执行 `code[case_goto_end_idx] = len(code)` | 用 `caseGotoEndPos = -1` 表示"没有条件"，只在 >= 0 时回填 | 无条件 `while { }` 时参考实现会把 `code[0]` 写成 code 长度，把第一条指令改成跳转目标 | C-32 |
| **CD-5** | `visit_assigh_stmt` 直接 `visit(loc)` | 同（先算 `At` 再 `Assign`） | 现状照抄，但 `a[0] = 1;` 的 VM 语义存疑：这里先把元素取出来再赋值。等 VM 落地再定 | C-48 |

另外记录一条**未移植**的参考行为（属 `CustomOpcodeConfig` 的职责，不在本文件）：

- 参考实现 `set_custom_insts` 会校验 ①code 必须 > `Return` ②名字不能是关键字
  ③非变长时 `arg_num >= 0`。C++ 的 `addCustomOpcode` 目前**没有**这些校验。
  要补的话应改 `custom_opcode.hpp`，届时记得同步 `lexer_test_plan.md` 的 K 组。

---

## 4. 测试基础设施

### 4.1 文件与二进制

| 文件 | 职责 |
| --- | --- |
| `cpp/test/test_compiler.cpp` | 全部 C 组用例 + `main()`。自成二进制，与 `test_parser` / `test_lexer` 分开：编译产物的差异不至于互相掩盖，也让 `ctest` 能单独定位 |
| `cpp/test/test_ast_visitor.cpp` | V 组用例：基类 `ASTVisitor` 的遍历骨架（见 §4.5）。与 C 组分开二进制，因为断言锁的是「默认遍历顺序」，与指令流无关 |
| `cpp/test/test_common.hpp` | 复用 `g_total` / `g_failed` / `check()` / `section()` / `toUtf8()` |
| `cpp/docs/*_test_plan.md` | 计划文档统一放在 `cpp/docs/`（本文档、`parser_test_plan.md`、`lexer_test_plan.md`） |

`CMakeLists.txt` 里的登记：

```cmake
add_executable(test_compiler test/test_compiler.cpp)
target_include_directories(test_compiler PRIVATE stope)
add_test(NAME compiler COMMAND test_compiler)

add_executable(test_ast_visitor test/test_ast_visitor.cpp)
target_include_directories(test_ast_visitor PRIVATE stope)
add_test(NAME ast_visitor COMMAND test_ast_visitor)
```

### 4.2 核心辅助

| 辅助 | 作用 |
| --- | --- |
| `dumpCode(prog, cfg)` | 把 `opcodes` 序列化成 `"PushInt(0) Pop"` 这样的串；顺手把见过的 opcode 记进 `g_seenOpcodes` |
| `opHasParam(raw)` | 是否带操作数。**必须**先把 > `Return` 的自定义指令排除掉（见 §4.4） |
| `customHasParam(raw, cfg)` | 自定义指令只在变长时带参数个数 |
| `dumpExportNames(prog)` | `"a:0 b:1"` 形式，按 `map` 的字典序 |
| `compileSrc(src, cfg, fold, compileCfg)` | 端到端：lex → parse → `Compiler(cfg).Compile(ast, r.prog)` |
| `expectCode(r, want, id, cfg)` / `expectErrCount(r, n, id)` | 两条标配断言 |

默认 **`fold = false`**（关常量折叠），这样多数用例锁的是「完整树形 → 完整指令」。
只有 C-43 / C-45 特意打开折叠，验证常量被吃掉后指令变短。

### 4.3 怎么用不同的 cfg 触发防御分支

```cpp
CustomOpcodeConfig emptyCfg;
auto r = compileSrc(u"myop(1);", &cfg, /*fold*/ false, /*compileCfg*/ &emptyCfg);
```

parser 识别 `myop`（把它变成 `Custom` token），编译器这边查不到 → `undefined custom instruction`。
单用同一个 cfg 是走不到的：名字不在 cfg 里时 parser 根本不认，**退化成普通调用**（C-37b 锁定这一点）。

### 4.4 踩过的坑

1. **`opHasParam` 的兜底 `return true` 吃掉了自定义指令**：自定义 opcode 编号都 > `Return`，
   落进最后那个 `return true`，于是把紧跟的 `Pop` 当操作数吞了
   （`Custom100(11)` 里的 `11` 其实就是 `Pop`）。修法是在函数开头先判 `raw > Return → false`。
2. **跳转目标把操作数算漏**：见 §2.2，一次性错过十几条期望。
3. **`check()` 的第三参原本是 `const char*`**： `"stack size == " + to_string(n)` 这类
   拼接传不进去。已把签名放宽成 `const std::string&`（对既有调用点完全兼容）。
4. **Windows 上要 `#include <Windows.h>`** 才能用 `SetConsoleOutputCP(CP_UTF8)`，
   缺了就是编译错误（第一次落 CMake 时踩到）。

### 4.5 `Compiler` 与基类 `ASTVisitor` 的分工（2026-10-18）

2026-10-18 起，遍历骨架已从 `compiler.hpp` 抽到 `cpp/include/stope/ast_visitor.hpp`，且用
**表驱动 + `onVisitXxx` 钩子**：`visit(Node*)` 按 `NodeType` 在静态表 `visitMap` 里查到
分发函数，分发函数把 `Node*` 转成具体类型后交给 `onVisitXxx`。
抽这条线是为了让将来的 Interpreter、静态检查、格式化打印能复用同一副骨架。
**真要做那个 Interpreter（直接跑 AST，不经过 `Program`）**时，继承方式、钩子的取舍与
一份可编译的例子写在 [`../../docs/zh-cn/syntax-impl.md`](../../docs/zh-cn/syntax-impl.md) §7.2。
`Compiler` 已于同日完成改名跟进，98 条断言一字未改全绿。

| 留在基类 `ASTVisitor` | 留在子类 `Compiler` |
| --- | --- |
| `visit(Node*)`：查 `visitMap` 分派 | `Program* prog`、`emit*()` / `patchIndex()` / `constIndex()` |
| 静态分发函数 × 26（`visitXxx(ASTVisitor&, AST::Node*)`） | **重写 `onVisitXxx` 系列**（这才是子类的契约） |
| 各 `onVisitXxx` 的默认实现：按源码顺序递归子节点 | 作用域栈、`VariableAllocator`、`StackSizeManager` |
| `curLine`（由 `visit()` 更新） | `errors` / `error()`、`Compile()` |

四条改代码前必须知道的：

1. **只存在一套钩子。** 早期草稿曾同时有 `visitXxx` 与 `onVisitXxx`，两套虚函数槽位
   不同 —— 静态表拨的是 `onVisitXxx`，而 Compiler 覆盖的是 `visitXxx`，结果**全部静默
   失效**（不报错、`override` 也不报错）。现在只有 `onVisitXxx`。
2. **所有覆盖都带 `override`。** 这次它真救了场：改名漏一处会静默退回基类版本，
   默认递归把子孙再走一遍，指令流成倍重复且看不出原因。
3. **覆盖里不调基类版本 = 不再下钻。** 默认递归写在基类的 `onVisitXxx` 里（V-06 锁住）。
4. **不要在 `Compiler` 里再声明 `curLine`。** 名字隐藏会让 `emitIndex()` 读到永远停在
   `-1` 的 `Compiler::curLine`，而被 `visit()` 更新的是 `ASTVisitor::curLine`。
5. **`private:` 之后要重新开 `protected:` / `public:`。** 曾因为漏开，27 个 `onVisitXxx`
   全成了私有：子类能重写，却**调不到基类版本**，而这正是默认递归的入口（2026-10-21 修）。
   `visitMap` 是 public —— `test_ast_visitor.cpp` 的 V-07 要断言每个 NodeType 都有表项。

另外两条：

- **`Prog` 也有钩子**（`onVisitProg(AST::Prog*)`），块 / 分支 / 循环体里嵌的裸 Prog 走
  `visit(&xxx->prog)` 递归回同一个表项；**没有 `visitProg(Prog&)` 这个便利重载了**，
  入口只有 `visit(Node*)`。
- **漏登记表项不报错**，只会让 `visit()` 静默跳过整类节点。`test_ast_visitor.cpp`
  的 **V-07** 锁住：除 `Node` / `Stmt` / `Expr` 三个裸基类外，每个 NodeType 都必须有表项。

**刻意没有抽进基类的**：作用域栈（`BlockScope::idMap` 存的是 VM 槽位下标，解释器要的
是名字到值的映射，共同部分只剩「逐层往外查」）、常量池与指令输出、`errors`（解释器要
的是抛运行时错误，不是攒一串字符串）。

默认的遍历顺序是有定义的，由 `test_ast_visitor.cpp` 的 V-02 组逐构造锁死。

---

## 5. 用例清单

共 **53 个用例 / 98 条断言**，全绿（`./build/test_compiler.exe` 的实测值）。

### 5.1 C-01…C-12 字面量、变量、作用域

| ID | 输入 | 锁什么 |
| --- | --- | --- |
| C-01…C-06 | `1;` `1.5;` `"ab";` `'x 41';` `true;` `null;` | 6 个字面量各自的 Push 指令 + `Pop`；每种都断言 `requiredStackSize == 1` |
| C-07 | `1; 2; 1; 2.0; 2.0;` | 常量池去重：int 池 2 项、float 池 1 项 |
| C-08 | `a; b; a;` | 未声明就使用 → `newUniqueVar` 登记到 file scope，出现在 `exports`（`a:0 b:1`）；三处都是读值 → 全 `PushValue` |
| C-09 | `let a = 1;` | 等号左侧 → `PushId` + 值 + `Assign`；局部变量不导出 |
| C-10 | `let a, b; a = 1; b = a;` | 无赋值的多标识符 let 不产生指令；`b = a` 左侧 `PushId`、右侧 `PushValue` |
| C-11 | `{ let a = 1; } let b = 2;` | 出块后索引进回收堆复用，`variableNum == 1` |
| C-12 | `export a, b;` | 只登记变量，**不产生任何指令** |

### 5.2 C-13…C-19 运算符

| ID | 输入 | 锁什么 |
| --- | --- | --- |
| C-13 / C-14 | `a + b;` / `a - b;` | **CD-1**：二元 `-` 必须是 `Sub` |
| C-15 | `a * b / c % d idiv e ^ f;` | `^` 优先级高于 `* / idiv %`（`common.hpp` 的 `OpPrecedence`）→ `((a*b)/c%d) idiv (e^f)` |
| C-16 | 六个比较运算 | `EQ NE LT LE GT GE` 的一一映射 |
| C-17 | `-a; !b; not c;` | 一元 `-` 是 `Minus`，`!` / `not` 都是 `Not` |
| C-18 / C-19 | `a or b;` / `a and b;` | 短路的两组 `If` / `GoTo` / `PushTrue` / `PushFalse` 布局，**CD-2**：`requiredStackSize == 1` |

### 5.3 C-20…C-27 调用 / 索引 / args / argc / return

| ID | 输入 | 锁什么 |
| --- | --- | --- |
| C-20 / C-21 | `f();` / `f(1, 2);` | `Call(n)`，callee 先入栈 |
| C-22 / C-23 / C-24 | `a[];` / `a[1, 2];` / `a(b[0]);` | `At(n)`；`a[]` 是 `At(0)`（空下标合法） |
| C-25 | `f(1, 2);` | 调用峰值 = `n + 1` → `requiredStackSize == 3` |
| C-26 | `args[0]; argc;` | `GetArg`（栈大小不变）与 `ArgNum` |
| C-27 | `return 1, 2; return;` | `Return(n)`，`maxReturnNum == 2` |

### 5.4 C-28…C-33 控制流

| ID | 输入 | 锁什么 |
| --- | --- | --- |
| C-28 | `if a { b; }` | 单个分支也要有收尾 `GoTo`（与参考实现同） |
| C-29 | `if / elif / else` | 各分支的 `If` 目标与汇聚的 `GoTo` 目标 |
| C-30 | `while a { continue; }` | `continue` 回到**条件开头**（索引 0） |
| C-31 | `while a { break; }` | `break` 跳到**循环末尾** |
| C-32 | `while { b; }` | **CD-4**：无条件 while 不回填，首条指令不被污染 |
| C-33 | `if a { let x = 1; } let y = 2;` | 分支是独立 BlockScope，出分支后索引复用 |

### 5.5 C-34…C-37b 自定义指令

| ID | 输入 | 锁什么 |
| --- | --- | --- |
| C-34 | `myop(1, 2);`（固定 2 参） | 不带 arity |
| C-35 | `myva(1, 2, 3);`（变长） | 多写一个参数个数 `Custom101(3)` |
| C-36 | `myop(1);` | 参数个数不符 → 报错，文案含 `expected 2 args, but got 1` |
| C-37 | parser 用 `cfg`、compiler 用空 cfg | `undefined custom instruction "myop".`；**报错不产出**（`expectCode(r, "")`） |
| C-37b | `nope(1);` | 名字不在 cfg 里时退化成普通 `Call` |

### 5.6 C-38…C-42 错误场景

| ID | 输入 | 期望的错误子串 |
| --- | --- | --- |
| C-38 | `break;` | `cannot use "break" outside of a loop.` |
| C-39 | `continue;` | `cannot use "continue" outside of a loop.` |
| C-40 | `if a { export b; }` | `"export" can only be used at top scope.` |
| C-41 | `let a; let a;` | `duplicate declaration of 'a'.` |
| C-42 | `export a; export a;` | `duplicate export of "a".` |

错误文案刻意与参考实现措辞对齐（含标识符），便于两边对照。

### 5.7 C-43…C-45 折叠与编译的配合

| ID | 输入 / 开关 | 期望 |
| --- | --- | --- |
| C-43 | `1 + 2 * 3;`（fold = on） | `PushInt(0) Pop`，且常量池里就是 `7` |
| C-44 | 同（fold = off） | `PushInt(0) PushInt(1) PushInt(2) Mul Add Pop` |
| C-45 | `a + 2 * 3;`（fold = on） | 只有含变量的子树保留：`PushValue(0) PushInt(0) Add Pop`，常量是 `6` |

### 5.8 C-46…C-52 综合与边界

| ID | 输入 | 锁什么 |
| --- | --- | --- |
| C-46 | 一段小程序（export + let + while + args + return） | 端到端：`export main` 占 0 号，`a`/`b` 由 `let` 拿到 1/2，`sum` 拿 3；`variableNum == 4`；指令 34 个字；`stack size >= 3` |
| C-47 | `f(g(1), 2);` | 嵌套调用峰值 = 3 |
| C-48 | `a[0] = 1;` | **CD-5**：先 `At(1)` 再 `Assign`；左侧不是裸标识符 → `a` 走 `PushValue` |
| C-49 | `{ let a = 1; { let a = 2; } }` | 内层块可遮蔽外层同名变量（不同 BlockScope） |
| C-50 | `{ let a = 1; let a = 2; }` | 同一作用域内重复声明才报错 |
| C-51 | `while a { while b { break; } continue; }` | `break` / `continue` 归**最近**的那层 |
| C-52 | `while a { if b { break; } else { continue; } }` | 循环里嵌 if 时跳转目标仍正确 |

---

## 6. 覆盖率与验收标准

| 口径 | 当前值 | 验收线 |
| --- | --- | --- |
| 用例数 | 53 | — |
| 断言数 | 98 | 全部通过 |
| `Opcode` 覆盖 | 33/33 | **必须保持 33/33**。测试里统计见过的 opcode，缺哪个会打印名字 |
| `AST::NodeType` 产生路径 | 26 个可编译节点全覆盖 | — |
| 错误路径 | 7 类 error + 6 类错误信息全覆盖 | — |
| `ctest` | 15/15 | 全部通过（lexer + parser + compiler + stml + ast_visitor + vm + 9 组深度用例） |
| `test_ast_visitor` 断言数 | 36 | 全部通过（V 组，锁基类遍历顺序与分发表完整性） |

跑完的尾部输出：

```
== Opcode 覆盖: 33/33
== 汇总
   断言总数 98 | 失败 0
RESULT: PASSED
```

退出码：`0` 全过；`1` 有断言失败。

---

## 7. 缺陷处理流程

1. 新增失败先判断是**期望写错**还是**实现错**。
   - 期望写错（尤其跳转型）：按 §2.2 重新数下标，把数轴写进用例注释。
   - 实现错：先看是否属于 §3 的 CD-1…CD-5；属于的话**不要改回去**，更新 CD 表的说明。
2. 要偏离参考实现时，先在 §3 补一行（编号递增），再改代码，最后补对应用例。
3. 允许出现"现状照抄但存疑"的条目（如 CD-5），但要写明等什么条件再定。

---

## 8. 执行方式

```bash
cd cpp
cmake -B build && cmake --build build
./build/test_compiler.exe                    # 单跑 compiler
ctest --test-dir build --output-on-failure   # 全套（12 项）
```

注意：Bash 工具每次调用的 cwd 会重置，一律用绝对路径或先 `cd`。
`main()` 里设了 `setvbuf(stdout, nullptr, _IONBF, 0)`，崩栈时已打印的进度不会丢。

---

## 9. 里程碑

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| M1 | 读通参考实现与 C++ 侧的 `opcode.hpp` / `program.hpp` / `ast.hpp` | 完成 |
| M2 | 补齐 `scope_context.hpp`（`FileScope` / `BlockScope` / `WhileScope`） | 完成 |
| M3 | 实现 `compiler.hpp` 的全部 visit | 完成 |
| M4 | `test_compiler` 落地并校准全部 C 组期望 | 完成（98 断言全绿） |
| M5 | 接入 `CMakeLists.txt`，`ctest` 11/11 | 完成 |
| M6 | 抽出基类 `ASTVisitor` + V 组用例，`ctest` 12/12 | 完成（2026-10-18） |
| M7 | VM 落地后回看 CD-5（`a[0] = 1`）并按实际语义调整 | 待做 |

---

## 10. 风险与注意事项

1. **跳转目标的意义是字节下标，不是指令条数**（§2.2）——写新期望的第一杀手。
2. `opcodes` 是 `short`：超过 32767 要走 `emitIndex` / `patchIndex` 的溢出分支（报错）。
   这条路径**没有用例覆盖**，因为构造 3 万条指令的输入太长；要覆盖得手写超大 AST。
3. `requiredStackSize` 是线性记账的结果，`Return` 之后**没有**归零（沿用"偏大总比偏小安全"）。
   死代码会把这个数抬上去，属已知行为。
4. `Compile()` 出错时会把 `out` 复原为空：任何依赖"半成品 Program"的下游逻辑都要先确认约定。
5. 参考实现还在演进（`compiler.gd` 若有改动），改之前比对 §3 的 CD 表。
