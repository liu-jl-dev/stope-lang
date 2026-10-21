# Stope 编译器通用测试计划

> **跨实现的行为契约** —— 不绑定任何一门语言。C++ 与 GDScript 两套实现都按本文件验证。
>
> | 通用测试计划 | 覆盖范围 | C++ 侧 | GDScript 侧 |
> | --- | --- | --- | --- |
> | [lexer-test-plan.md](lexer-test-plan.md) | 字符流 → Token 流 | `cpp/include/stope/lexer.hpp` | `gdscript/stope/stope_token.gd` |
> | [parser-test-plan.md](parser-test-plan.md) | Token 流 → AST | `cpp/include/stope/parser.hpp` | `gdscript/stope/stope_parser.gd` |
> | **compiler-test-plan.md（本文）** | AST → Program | `cpp/include/stope/compiler.hpp` | `gdscript/stope/stope_compiler.gd` |
| [stml-test-plan.md](stml-test-plan.md) | STML 文本 → 元素树 | `cpp/include/stope/stml_lexer.hpp` + `cpp/include/stope/stml_parser.hpp` | `gdscript/stope/stml_lexer.gd` + `gdscript/stope/stml_parser.gd` |
>
> **权威实现：C++。** 两侧分歧以 `cpp/include/stope/compiler.hpp` 的实测行为为准。
>
> **本文所有期望值都是机器生成的**：由桥接 `cpp/include/stope/compiler.hpp` 的探针实测导出（2026-10-18）。
> 输入先走过词法 + 语法（规则见另两份计划），本文件只关心得到的 AST 编译出什么。

## 目录

- [1. 目标与非目标](#1-目标与非目标)
- [2. 通用契约：Program 与它的序列化](#2-通用契约program-与它的序列化)
- [3. 行为基线](#3-行为基线)
- [4. 用例清单](#4-用例清单)
- [5. 验收标准](#5-验收标准)
- [6. 执行方式](#6-执行方式)
- [7. 已知差异登记](#7-已知差异登记)

---

## 1. 目标与非目标

**目标**

1. 把「AST 该怎么变成指令」从实现里抽出来写成两边共用的规格。
2. 钉死三件最容易错的事：**跳转目标的回填**、**栈容量的记账**、**变量索引的分配与回收**。
3. 让新实现能通过同一份用例被验收。

**非目标**

- 不测试 VM 怎么执行指令（`gdscript/stope/stope.gd` 的行为不属于本文）。
  Stope **不制定虚拟机的规范**；要自己写执行器见 [vm-guide.md](vm-guide.md)。
- 不测试自定义指令的业务含义，只测试「编译出什么指令、什么操作数、怎么记账」。
- 不做性能基准。

---

## 2. 通用契约：Program 与它的序列化

### 2.1 Program 的字段

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `opcodes` | 整数序列 | 指令与操作数**混排**在一个序列里 |
| `variableNum` | int | 变量总表的长度（含已回收、不再使用的槽位） |
| `exports` | 名字 → 索引 | 会被宿主看到的顶层变量 |
| `intConsts` / `floatConsts` / `stringConsts` / `binArrConsts` | 数组 | 四个常量池，同值只存一份 |
| `maxReturnNum` | int | 所有 `return` 里最大的返回值个数 |
| `requiredStackSize` | int | 执行过程中栈深度的最大值 |

> **不要保存副本。** 编译器应把常量直接写进 Program 的池子里。
> （GDScript 参考实现里的 `int_consts:ConstantManager` 是 Reference 对象，照抄成成员 + 赋值在
> 其它语言里就变成了真拷贝。）

### 2.2 指令表（32 条，编号必须两侧一致）

```
0  Assign      1  PushNull    2  PushFalse   3  PushTrue    4  PushInt
5  PushFloat   6  PushString  7  PushBinArr  8  PushId      9  Call
10 At          11 Pop         12 Minus       13 Not         14 Pow
15 Mul         16 Div         17 IDiv        18 Mod         19 Add
20 Sub         21 EQ          22 NE          23 LT          24 LE
25 GT          26 GE          27 If          28 GoTo        29 GetArg
30 ArgNum      31 Return
```

**带操作数的**（其余无操作数）：

| 指令 | 操作数 |
| --- | --- |
| `PushInt` / `PushFloat` / `PushString` / `PushBinArr` / `PushId` | 常量池或变量表的**索引** |
| `Call` / `At` | **实参个数**（不含 callee / container） |
| `If` / `GoTo` | 跳转目标 = **opcodes 的槽位索引**（不是字节偏移） |
| `Return` | 返回值个数 |
| 自定义指令 | 值 **> Return（31）**；变长参数时多带一个「实参个数」 |

### 2.3 Program 序列化格式（跨实现比较用）

```
code[Inst(param) Inst(param) ...]  vars=N  stack=N  maxRet=N
ints=[1,2]  floats=[1.5]  strs=[s]  binarrs=[[0f]]  exports=[a:0,b:1]
```

| 段 | 规则 |
| --- | --- |
| `code[...]` | 指令名 + `()` 内写操作数，**用空格分隔**；无操作数的指令不写括号 |
| `vars` | `variableNum` |
| `stack` | `requiredStackSize` |
| `maxRet` | `maxReturnNum` |
| `ints` / `floats` | 十进制；浮点按 `%g`；逗号分隔 |
| `strs` | 逗号分隔，控制字符用 `\n` `\r` `\t` `\\` `\"` 转义 |
| `binarrs` | 每个数组写作 `[xx,yy]`（小写十六进制），多个数组之间用**空格**分隔 |
| `exports` | **按名字升序**排列，`name:index`，逗号分隔 |
| 空 | `code[]` `ints=[]` `binarrs=[]`

**示例**：`let a = 1;` →
`code[PushId(0) PushInt(0) Assign] vars=1 stack=2 maxRet=0 ints=[1] floats=[] strs=[] binarrs=[] exports=[]`

---

## 3. 行为基线

**B-1 编译入口。** `Compile(AST::Prog&, Program&) -> Result`，`CustomOpcodeConfig` 由构造函数
注入（不再作为 `Compile` 的参数）。成功写满 `out`；失败返回 Error 并把
`out` **清空**（半成品 Program 跑不了，留着反而误导）。

**B-2 二元 `-` 必须用 `Sub`（20），不是 `Minus`（12）。**
`Minus` 只弹一个操作数，是**一元**取负。参考实现把 `-` 映成 `Minus` 是错的。

**B-3 短路 `and` / `or` 要用 `converge()` 把栈深度扳回汇合点。**
线性记账沿一条路径走会把 `a or b;` 算成 3；不记账（像参考实现那样末尾统一 `dec(1)`）又会偏小。
正确做法：在每个分支被 `GoTo` 送走之后，把 size 设成「另一条路径到这里时」应有的深度。

**B-4 自定义指令的记账是 `dec(实参个数 - 1)`。**
它没有 callee 入栈，但结果仍占 1 格。参考实现写的是 `dec(实参个数)`。

**B-5 无条件 `while { }` 不能回填。**
参考实现里 `case_goto_end_idx` 没有初值，条件为空时会执行 `code[0] = len(code)`，
把第一条指令改成一个跳转目标。约定用 `-1` 表示「没有条件、无需回填」。

**B-6 变量索引回收。** 块结束时释放内部变量的索引，可被后续块复用；
已用过的最大槽位数不下降（所以 `variableNum` 是「曾经用到的最大数量」）。
`export` 与「未声明就使用」的标识符走 `newUniqueVar`，**不参与回收**。

**B-7 `export` 只能在顶层。** 块内使用 → `line N: "export" can only be used at top scope.`

**B-8 重复声明** → `line N: duplicate declaration of 'a'.`（注意是**单引号**）
**重复导出** → `line N: duplicate export of "a".`（注意是**双引号**）

**B-9 未声明就使用的标识符**当作外部变量，登记到文件作用域，**并出现在 `exports` 里**。

**B-10 `requiredStackSize` 只在栈增长时更新**，下降不更新最大值。

**B-11 索引超过实现能表示的范围时要报错**（C++ 侧是 int16 越界检查），
不能让回绕出来的跳转目标把 VM 带飞。

---

## 4. 用例清单

> 「输出」列是 §2.3 的完整序列化。省略了全空的段时用 `—` 表示。
> 自定义指令一律预设：`myop` → opcode **100**，定长 **2** 参；`vop` → opcode **101**，**变长**。

### 4.1 CM-01…CM-10 字面量、变量、作用域

| ID | 输入 | 输出 |
| --- | --- | --- |
| CM-01 | `let a;` | `code[] vars=1 stack=0 maxRet=0`（全过程为空） |
| CM-02 | `let a, b, c;` | `code[] vars=3 stack=0 maxRet=0` |
| CM-03 | `let a = 1;` | `code[PushId(0) PushInt(0) Assign] vars=1 stack=2 maxRet=0 ints=[1]` |
| CM-04 | `a;` | `code[PushId(0) Pop] vars=1 stack=1 maxRet=0 exports=[a:0]` |
| CM-05 | `a = 1;` | `code[PushId(0) PushInt(0) Assign] vars=1 stack=2 ints=[1] exports=[a:0]` |
| CM-06 | `a[0] = 1;` | `code[PushId(0) PushInt(0) At(1) PushInt(1) Assign] vars=1 stack=2 ints=[0,1] exports=[a:0]` |
| CM-07 | `a; a;` | `code[PushId(0) Pop PushId(0) Pop] vars=1 stack=1 exports=[a:0]` |
| CM-08 | `let a; a = 1;` | `code[PushId(0) PushInt(0) Assign] vars=1 stack=2 ints=[1] exports=[]`（已声明 → **不导出**） |
| CM-09 | `{ let a; } { let b; }` | `code[] vars=1 stack=0`（索引被回收复用） |
| CM-10 | `export a, b;` | `code[] vars=2 exports=[a:0,b:1]` |

**常量池去重（CM-11…CM-14）**

| ID | 输入 | 期望 |
| --- | --- | --- |
| CM-11 | `1; 1;` | `ints=[1]`（同值一份）→ `code[PushInt(0) Pop PushInt(0) Pop]` |
| CM-12 | `1; 1.5; "s"; 'ab';` | `code[PushInt(0) Pop PushFloat(0) Pop PushString(0) Pop PushBinArr(0) Pop]`，`ints=[1] floats=[1.5] strs=[s] binarrs=[[ab]]`，`stack=1` |
| CM-13 | `'b 0100 0001';` | `binarrs=[[04,01]]`，`code[PushBinArr(0) Pop]` |
| CM-14 | `'';` | `binarrs=[[]]`（空数组），`code[PushBinArr(0) Pop]` |

### 4.2 CM-15…CM-24 字面量指令与一元运算

| ID | 输入 | 输出（code 段） | 附加 |
| --- | --- | --- | --- |
| CM-15 | `null;` | `code[PushNull Pop]` | `stack=1` |
| CM-16 | `true;` / `false;` | `code[PushTrue Pop]` / `code[PushFalse Pop]` | `stack=1` |
| CM-17 | `1;` | `code[PushInt(0) Pop]` | `ints=[1]` `stack=1` |
| CM-18 | `0x1F;` | `code[PushInt(0) Pop]` | `ints=[31]` |
| CM-19 | `1.5;` | `code[PushFloat(0) Pop]` | `floats=[1.5]` |
| CM-20 | `"a\nb";` | `code[PushString(0) Pop]` | `strs=[a\nb]` |
| CM-21 | `argc;` | `code[ArgNum Pop]` | `stack=1` |
| CM-22 | `args[0];` | `code[PushInt(0) GetArg Pop]` | `ints=[0]` `stack=1` |
| CM-23 | `-1;` | `code[PushInt(0) Minus Pop]` | 一元是 `Minus` |
| CM-24 | `!a;` | `code[PushId(0) Not Pop]` | `stack=1` |

### 4.3 CM-25…CM-36 二元运算符

| ID | 输入 | 输出（code 段） | stack |
| --- | --- | --- | --- |
| CM-25 | `1 + 2 * 3;` | `code[PushInt(0) PushInt(1) PushInt(2) Mul Add Pop]` `ints=[1,2,3]` | 3 |
| CM-26 | `1 - 2 - 3;` | `code[PushInt(0) PushInt(1) Sub PushInt(2) Sub Pop]` | 2 |
| CM-27 | `2 ^ 3 ^ 2;` | `code[PushInt(0) PushInt(1) Pow PushInt(0) Pow Pop]` `ints=[2,3]` | 2 |
| CM-28 | `1 < 2 == true;` | `code[PushInt(0) PushInt(1) LT PushTrue EQ Pop]` | 2 |
| CM-29 | `-a * b;` | `code[PushId(0) Minus PushId(1) Mul Pop]` | 2 |
| CM-30 | `1 - -2;` | `code[PushInt(0) PushInt(1) Minus Sub Pop]` `ints=[1,2]` | 2 |
| CM-31 | `a idiv b % c;` | `code[PushId(0) PushId(1) IDiv PushId(2) Mod Pop]` | 2 |
| CM-32 | `a \|\| b && c;` | `code[PushId(0) If(7) PushTrue GoTo(25) PushId(1) If(18) PushId(2) If(18) PushTrue GoTo(19) PushFalse If(24) PushTrue GoTo(25) PushFalse Pop]` `vars=3 exports=[a:0,b:1,c:2]` | **1**（B-3） |
| CM-33 | `a && b \|\| c;` | `code[PushId(0) If(11) PushId(1) If(11) PushTrue GoTo(12) PushFalse If(17) PushTrue GoTo(25) PushId(2) If(24) PushTrue GoTo(25) PushFalse Pop]` | **1** |
| CM-34 | `a \|\| b;` | `code[PushId(0) If(7) PushTrue GoTo(15) PushId(1) If(14) PushTrue GoTo(15) PushFalse Pop]` `vars=2 exports=[a:0,b:1]` | 1 |
| CM-35 | `a && b;` | `code[PushId(0) If(11) PushId(1) If(11) PushTrue GoTo(12) PushFalse Pop]` `vars=2 exports=[a:0,b:1]` | 1 |

### 4.4 CM-36…CM-44 调用 / 索引 / return

| ID | 输入 | 输出（code 段） | 附加 |
| --- | --- | --- | --- |
| CM-36 | `f();` | `code[PushId(0) Call(0) Pop]` | `vars=1 stack=1 exports=[f:0]` |
| CM-37 | `f(1, 2);` | `code[PushId(0) PushInt(0) PushInt(1) Call(2) Pop]` `ints=[1,2]` | `stack=3` |
| CM-38 | `f()();` | `code[PushId(0) Call(0) Call(0) Pop]` | `stack=1` |
| CM-39 | `a[0];` | `code[PushId(0) PushInt(0) At(1) Pop]` | `stack=2` |
| CM-40 | `a[0, 1];` | `code[PushId(0) PushInt(0) PushInt(1) At(2) Pop]` | `stack=3` |
| CM-41 | `return;` | `code[Return(0)]` | `stack=0 maxRet=0` |
| CM-42 | `return 1;` | `code[PushInt(0) Return(1)]` | `stack=1 maxRet=1` |
| CM-43 | `return 1, 2, 3;` | `code[PushInt(0) PushInt(1) PushInt(2) Return(3)]` `ints=[1,2,3]` | `stack=3 maxRet=3` |
| CM-44 | `{ return 1; } return 2;` | `code[PushInt(0) Return(1) PushInt(1) Return(1)]` `ints=[1,2]` | `stack=2 maxRet=1` |

### 4.5 CM-45…CM-54 控制流

| ID | 输入 | 输出（code 段） | stack |
| --- | --- | --- | --- |
| CM-45 | `if a { }` | `code[PushId(0) If(6) GoTo(6)]` | 1 |
| CM-46 | `if a { } else { }` | `code[PushId(0) If(6) GoTo(6)]` | 1 |
| CM-47 | `if a { } elif b { }` | `code[PushId(0) If(6) GoTo(12) PushId(1) If(12) GoTo(12)]` | 1 |
| CM-48 | `if a { } elif b { } else { }` | 同 CM-47 | 1 |
| CM-49 | `while { }` | `code[GoTo(0)]`（**不得回填 code[0]**，B-5） | 0 |
| CM-50 | `while a { }` | `code[PushId(0) If(6) GoTo(0)]` | 1 |
| CM-51 | `while a { break; }` | `code[PushId(0) If(8) GoTo(8) GoTo(0)]` | 1 |
| CM-52 | `while a { continue; }` | `code[PushId(0) If(8) GoTo(0) GoTo(0)]` | 1 |
| CM-53 | `while a { if b { break; } else { continue; } }` | `code[PushId(0) If(16) PushId(1) If(12) GoTo(16) GoTo(14) GoTo(0) GoTo(0)]` | 1 |
| CM-54 | `{ }` | `code[]`（空块不产任何指令） | 0 |

### 4.6 CM-55…CM-62 自定义指令

| ID | 输入 | 输出（code 段） | stack |
| --- | --- | --- | --- |
| CM-55 | `myop(1, 2);` | `code[PushInt(0) PushInt(1) Inst(100) Pop]` `ints=[1,2]` | **2** |
| CM-56 | `vop();` | `code[Inst(101)(0) Pop]` | **0**（B-4 + B-10：dec 不改变最大值） |
| CM-57 | `vop(1, 2, 3);` | `code[PushInt(0) PushInt(1) PushInt(2) Inst(101)(3) Pop]` | 3 |
| CM-58 | `myop(1, 2) + vop(1);` | `code[PushInt(0) PushInt(1) Inst(100) PushInt(0) Inst(101)(1) Add Pop]` `ints=[1,2]` | 2 |
| CM-59 | `f(myop(1, 2));` | `code[PushId(0) PushInt(0) PushInt(1) Inst(100) Call(1) Pop]` | 3 |
| CM-60 | `myop(1);` | **编译失败** | `custom instruction "myop" expected 2 args, but got 1.` |
| CM-61 | `myop() + 1;` | **编译失败** | `custom instruction "myop" expected 2 args, but got 0.` |
| CM-62 | `undefined_op(1);` | `code[PushId(0) PushInt(0) Call(1) Pop] exports=[undefined_op:0]` | 2（未注册 → 普通调用） |

> `Inst(100)` 的形状：opcode 值是宿主注册时的数。定长指令**不带**操作数；
> 变长指令带一个「实参个数」操作数（CM-56 的 `(0)`）。

### 4.7 CM-63…CM-68 错误场景

| ID | 输入 | 期望 |
| --- | --- | --- |
| CM-63 | `break;` | 失败，`line 1: cannot use "break" outside of a loop.` |
| CM-64 | `continue;` | 失败，`line 1: cannot use "continue" outside of a loop.` |
| CM-65 | `let a; let a;` | 失败，`line 1: duplicate declaration of 'a'.` |
| CM-66 | `export a; export a;` | 失败，`line 1: duplicate export of "a".` |
| CM-67 | `{ export a; }` | 失败，`line 1: "export" can only be used at top scope.` |
| CM-68 | 任何失败用例 | `Compile` 返回 Error **且 Program 被清空**（`code[] vars=0 stack=0` 全空） |

### 4.8 CM-69…CM-72 折叠与编译的配合

折叠发生在语法阶段，编译器看到的已经是折过的 AST。折叠默认**开启**。

| ID | 输入 | 输出（code 段） | 附加 |
| --- | --- | --- | --- |
| CM-69 | `1 + 2;` | `code[PushInt(0) Pop]` | `ints=[3]`（没有 `Add`） |
| CM-70 | `"ab" + "cd";` | `code[PushString(0) Pop]` | `strs=[abcd]` |
| CM-71 | `f(1 + 2);` | `code[PushId(0) PushInt(0) Call(1) Pop]` | `ints=[3]`，Call 保留 |
| CM-72 | `1 / 0;` | `code[PushInt(0) PushInt(1) Div Pop]` | `ints=[1,0]`，除零不折 |

---

## 5. 验收标准

| 维度 | 门槛 |
| --- | --- |
| 指令序列 | §4 每个用例的 `code[...]` 逐项一致（指令名 + 操作数） |
| 四个数字 | `vars` / `stack` / `maxRet` / 常量池内容逐项一致 |
| 导出表 | `exports` 按名字升序，逐项一致 |
| 错误 | 失败用例必须返回 Error **并清空 Program**（CM-68 是硬门槛） |
| 记账正确性 | CM-32 / CM-33 的 `stack=1` 是 `converge()` 的硬证明；CM-49 的 `code[GoTo(0)]` 是无条件 while 回填的硬证明 |

---

## 6. 执行方式

### C++

```bash
cd E:/lib/stope-lang/cpp
cmake -B build && cmake --build build
ctest --test-dir build
```

compiler 相关：`test_compiler`（C 组 98 条）、`test_ast_visitor`（V 组 36 条）。
细化的 C++ 侧记录见 `cpp/docs/compiler_test_plan.md`。

### GDScript

```bash
"/d/Program Files/Godot/Godot_v4.7.2-stable_mono_win64/Godot_v4.7.2-stable_mono_win64.exe" \
    --headless --path gdscript --script res://test/run_tests.gd
```

---

## 7. 已知差异登记

| ID | 现象（GDScript 侧） | C++ 基准 | 状态 |
| --- | --- | --- | --- |
| **GD-C-01** | `binop_inst_map` 把 `-` 映成 `Minus` | B-2：二元必须用 `Sub` | [已修 2026-10-18] |
| **GD-C-02** | 短路 `and/or` 末尾统一 `stack_size_mgr.dec(1)`，`PushTrue/PushFalse` 没有 inc，也没有 converge | B-3：`stack` 会偏小 | [已修 2026-10-18] |
| **GD-C-03** | 自定义指令 `dec(实参个数)` | B-4：`dec(实参个数 - 1)` | [已修 2026-10-18] |
| **GD-C-04** | 无条件 `while {}` 时 `case_goto_end_idx` 无初值，`code[0]` 被改成跳转目标 | B-5：用 `-1` 表示不回填 | [已修 2026-10-18] |
| **GD-C-05** | 编译器持有 `int_consts/float_consts/str_consts` 三份 `ConstantManager`，最后才拷进 Program | §2.1：直接写进 Program | [已修 2026-10-18] |
| **GD-C-06** | 没有 `PushBinArr`，二进制数组被塞进 `strings` | §2.2 的第 7 号指令 + `binArrConsts` 池 | [已修 2026-10-18] |
| **GD-C-07** | 出错时没有统一的「清空 Program」出口 | B-1 / CM-68 | [已修 2026-10-18] |
| **GD-C-08** | `Program.to_map()` 缺 `binarrs` | §2.3 | [已修 2026-10-18] |
| **GD-C-09** | 变量索引回收用自定义 `MinHeap`，回收后不对已释放索引去重 | B-6 | [已修 2026-10-18] |
| **GD-C-10** | 索引/跳转目标没有 int16 越界保护 | B-11 | [已修 2026-10-18] |
