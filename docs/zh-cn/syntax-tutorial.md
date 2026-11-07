# Stope 语法教程（配反汇编）

> 由易到难过一遍 Stope 的**全部语法**。每个示例都附上**编译产物的反汇编**——
> 你不仅能看到语法怎么写，还能看到它被编译成了什么。
>
> - 只想快速上手 → [syntax-intro.md](syntax-intro.md)
> - 查完整规则、边界情况、错误文案 → [syntax-reference.md](syntax-reference.md)
>
> 本文所有反汇编均由 C++ 实现（v0.3.1）**真实编译生成**，不是手写。生成方法见 §1.2。

---

## 目录

- [1. 认识反汇编](#1-认识反汇编)
- [2. 变量与赋值](#2-变量与赋值)
- [3. 数据字面量与常量池](#3-数据字面量与常量池)
- [4. 运算符与常量折叠](#4-运算符与常量折叠)
- [5. 分支：if / elif / else](#5-分支if--elif--else)
- [6. 循环：while / break / continue](#6-循环while--break--continue)
- [7. 入参、返回与导出](#7-入参返回与导出)
- [8. defer：退出时结算](#8-defer退出时结算)
- [9. 自定义指令](#9-自定义指令)
- [10. 下一步](#10-下一步)

---

## 1. 认识反汇编

### 1.1 第一个程序

```stope
let a = 1;
```

编译产物（下同，均由 C++ 的 `Disasm` 生成）：

```
[0]     PushId     0
[2]     PushInt    0
[4]     Assign
variables:
  ""
int consts:
  1
float consts:

string consts:
binary array consts:
max return num: 0
required stack size: 2
```

逐块解读：

- **指令流**：每行开头 `[i]` 是该指令在 `opcodes` 序列里的**下标**。
  带操作数的指令连操作数共占两个下标——`[2] PushInt 0` 的意思是
  「下标 2 处是 `PushInt`，操作数是 0」。注意 **操作数不是值本身，而是常量池下标**：
  `PushInt 0` = 取 int 常量池第 0 项（也就是 `1`）压栈。
- **`variables:`**：变量槽位表。`let a` 是局部变量，宿主看不到名字，所以打印为
  空串 `""`；用 `export` 导出的变量会显示名字（见 §7）。
- **常量池**：`int consts: 1` 表示整型常量池里存着一个 `1`。源码里的字面量先进池子，
  指令里只出现下标。
- **`max return num`**：整个程序 `return` 带的返回值个数的最大值，宿主据此准备接收数组。
- **`required stack size`**：跑这段产物需要的栈深度（以槽计）。

三条指令合起来就是一条赋值：`PushId` 把 **a 的槽位引用**（左值）压栈，
`PushInt` 把常量 `1` 压栈，`Assign` 弹出这两个值，把 `1` 写进 a 的槽位。

### 1.2 自己动手生成

反汇编不是黑盒，你用 C++ 实现二十行就能打出来（本教程全部示例即由此生成）：

```cpp
#include <iostream>
#include <string>
#include <stope/core.hpp>   // Lexer / Parser / Compiler / Program
#include <stope/debug.hpp>  // Disasm

using namespace std;
using namespace Stope;

u16string src = u"let a = 1;";
Lexer lexer(src);
Parser parser(lexer);
AST::Prog tree;
parser.ParseProgram(tree);
Compiler compiler;
Program program;
compiler.Compile(tree, program);   // 输入、输出都传引用
cout << DisasmNoCustom(program);   // 产物无自定义指令时的简写
```

> 产物里含自定义指令时必须改用 `Disasm(program, &config)` 并传入注册时的
> `CustomOpcodeConfig`，否则名字与变长参数个数无从得知（见 §9）。

本教程用到的内置指令速览（全集与栈效应见 [vm-guide.md](vm-guide.md)）：

| 指令 | 含义 |
| --- | --- |
| `PushId n` | 压入 n 号槽位的**引用**（左值，供 `Assign` 写入） |
| `PushValue n` | 压入 n 号槽位的**当前值**（右值，普通读变量） |
| `PushInt/Float/String/BinArr n` | 压入对应常量池第 n 项 |
| `PushNull` / `PushTrue` / `PushFalse` | 压入字面值（不占常量池） |
| `Assign` | 弹出「引用 + 值」，写入槽位 |
| `Add/Sub/Mul/Div/IDiv/Mod/Pow` | 弹两个操作数，运算后压回 |
| `LT/LE/GT/GE/EQ/NE` / `Not` / `Minus` | 比较 / 逻辑非 / 取负 |
| `If n` | 弹出条件，**为假时**跳到下标 n |
| `GoTo n` | 无条件跳到下标 n |
| `Call n` | 调用，n = 本次实参个数 |
| `GetArg` / `ArgNum` | 读 `args[...]` / `argc` |
| `Return n` | 结束程序，返回栈上 n 个值 |

---

## 2. 变量与赋值

```stope
let a;
let b = 2;
a = b + 3;
```

```
[0]     PushId     1
[2]     PushInt    0
[4]     Assign
[5]     PushId     0
[7]     PushValue  1
[9]     PushInt    1
[11]    Add
[12]    Assign
variables:
  "" ""
int consts:
  2  3
float consts:

string consts:
binary array consts:
max return num: 0
required stack size: 3
```

要点：

- **声明顺序决定槽位号**：a 是 0 号，b 是 1 号。`variables:` 里两个空串就是这两个局部变量。
- `[0..4]` 是 `let b = 2;`：`PushId 1`（b 的引用）+ `PushInt 0`（常量池[0] = 2）+ `Assign`。
- `[5..12]` 是 `a = b + 3;`：`PushId 0`（赋值目标 a）、`PushValue 1`（**读** b 的当前值）、
  `PushInt 1`（常量池[1] = 3）、`Add`、`Assign`。
- **`PushId` 与 `PushValue` 的分工**：赋值语句等号左侧恰好是裸标识符时压**引用**，
  其余一切读变量的位置（表达式、条件、`return` 的值……）压**值**。
  所以 `b` 出现了两次，一次是 `PushValue`，一次藏在赋值目标里。

---

## 3. 数据字面量与常量池

```stope
let i = 0xFF;
let f = 1.5e2;
let s = "hi\n";
let b = 'x 41 42';
let n = null;
let t = true;
```

```
[0]     PushId     0
[2]     PushInt    0
[4]     Assign
[5]     PushId     1
[7]     PushFloat  0
[9]     Assign
[10]    PushId     2
[12]    PushString 0
[14]    Assign
[15]    PushId     3
[17]    PushBinArr 0
[19]    Assign
[20]    PushId     4
[22]    PushNull
[23]    Assign
[24]    PushId     5
[26]    PushTrue
[27]    Assign
variables:
  "" "" "" "" "" ""
int consts:
  255
float consts:
  150
string consts:
  "hi
"
binary array consts:
  2 bytes
max return num: 0
required stack size: 2
```

要点：

- 六种可观测值各有入栈指令：`PushInt` / `PushFloat` / `PushString` / `PushBinArr` /
  `PushNull` / `PushTrue`（`false` 用 `PushFalse`，本例没出现）。
- **进池前已换算**：`0xFF` 在常量池里就是 `255`，`1.5e2` 就是 `150`——进制前缀与
  指数记法都是词法层的写法糖。
- 字符串常量 `"hi\n"` 是**原样内容**（反汇编里那个换行就是 `\n` 本身）。
- 二进制数组 `'x 41 42'` 在池子里只记「2 bytes」，字节内容由宿主侧的编码约定承载。

---

## 4. 运算符与常量折叠

### 4.1 全字面量：编译期就算完

```stope
let a = 1 + 2 * 3;
```

```
[0]     PushId     0
[2]     PushInt    0
[4]     Assign
variables:
  ""
int consts:
  7
float consts:

string consts:
binary array consts:
max return num: 0
required stack size: 2
```

`1 + 2 * 3` 在**解析阶段**就被折叠成常量 `7`——产物里没有任何 `Add`、`Mul` 指令。
折叠只在「运算符两侧都是字面量」时发生，完整行为矩阵见
[constant-folding.md](constant-folding.md)。

### 4.2 含变量：只折能折的

```stope
let x = 1;
let a = x + 2 * 3;
```

```
[0]     PushId     0
[2]     PushInt    0
[4]     Assign
[5]     PushId     1
[7]     PushValue  0
[9]     PushInt    1
[11]    Add
[12]    Assign
variables:
  "" ""
int consts:
  1  6
float consts:

string consts:
binary array consts:
max return num: 0
required stack size: 3
```

`2 * 3` 折成了常量池里的 `6`，但 `x + 6` 留到运行期（一条 `Add`）——
含变量、调用、下标的表达式不会预先计算。

### 4.3 幂运算与右结合

```stope
let r = 2 ^ 3 ^ 2;
```

```
[0]     PushId     0
[2]     PushInt    0
[4]     Assign
variables:
  ""
int consts:
  512
float consts:

string consts:
binary array consts:
max return num: 0
required stack size: 2
```

`^` 是**右结合**：`2 ^ 3 ^ 2` == `2 ^ (3 ^ 2)` == `2 ^ 9` == `512`，全折进常量池。
换成含变量的写法，就能看到 `Pow` 指令本尊：

```stope
let x = 2;
let r = x ^ 3 ^ 2;
```

```
[0]     PushId     0
[2]     PushInt    0
[4]     Assign
[5]     PushId     1
[7]     PushValue  0
[9]     PushInt    1
[11]    Pow
[12]    Assign
variables:
  "" ""
int consts:
  2  9
float consts:

string consts:
binary array consts:
max return num: 0
required stack size: 3
```

`3 ^ 2` 先折成 `9`，运行期只算一次 `x ^ 9`（`[11] Pow`）。

### 4.4 除法三分支

```stope
let a = 7 / 2;
let b = 7 idiv 2;
let c = 7 % 2;
```

```
[0]     PushId     0
[2]     PushFloat  0
[4]     Assign
[5]     PushId     1
[7]     PushInt    0
[9]     Assign
[10]    PushId     2
[12]    PushInt    1
[14]    Assign
variables:
  "" "" ""
int consts:
  3  1
float consts:
  3.5
string consts:
binary array consts:
max return num: 0
required stack size: 2
```

三个运算符在编译期各得其所：

- `7 / 2` 除不尽 → **浮点** `3.5`（进了 float 常量池）；
- `7 idiv 2` 整除 → `3`；
- `7 % 2` 取余 → `1`。

### 4.5 比较与逻辑

```stope
let a = 1 < 2 and 3 >= 3;
let b = not (1 == 2);
```

```
[0]     PushId     0
[2]     PushTrue
[3]     Assign
[4]     PushId     1
[6]     PushTrue
[7]     Assign
variables:
  "" ""
int consts:

float consts:

string consts:
binary array consts:
max return num: 0
required stack size: 2
```

全字面量的比较与逻辑同样在编译期出结果，产物只剩 `PushTrue`。
含变量的比较（`LT` / `EQ` / `GT`……）会在 §5、§6 的控制流里大量出现。

---

## 5. 分支：if / elif / else

```stope
let a = 5;
let r;
if a > 0 {
  r = 1;
} elif a == 0 {
  r = 0;
} else {
  r = -1;
}
return r;
```

```
[0]     PushId     0
[2]     PushInt    0
[4]     Assign
[5]     PushValue  0
[7]     PushInt    1
[9]     GT
[10]    If         19
[12]    PushId     1
[14]    PushInt    2
[16]    Assign
[17]    GoTo       38
[19]    PushValue  0
[21]    PushInt    1
[23]    EQ
[24]    If         33
[26]    PushId     1
[28]    PushInt    1
[30]    Assign
[31]    GoTo       38
[33]    PushId     1
[35]    PushInt    3
[37]    Assign
[38]    PushValue  1
[40]    Return     1
variables:
  "" ""
int consts:
  5  0  1  -1
float consts:

string consts:
binary array consts:
max return num: 1
required stack size: 2
```

要点：

- **`If` 跳的是「条件为假」那一支**（最容易搞反的点）：`[9] GT` 算出 `a > 0`，
  `[10] If 19` —— 条件为**假**就跳到下标 19（`elif` 的条件处）；为真则顺序执行
  `r = 1`，再由 `[17] GoTo 38` 跳出整个 if。
- `elif a == 0` 是第二层同样的结构（`[24] If 33`），`else` 分支就是落空的最后一段
  `[33..37]`。
- `[38..40]` 是 `return r;`：`PushValue 1` 压返回值，`Return 1` 的操作数 **1 = 返回值
  个数**，与 `max return num: 1` 呼应。
- 常量池 `5 0 1 -1`：`-1` 是字面量直接进池（取负不产生指令）。

---

## 6. 循环：while / break / continue

```stope
let i = 0;
let total = 0;
while i < 10 {
  i = i + 1;
  if i == 3 { continue; }
  if i == 8 { break; }
  total = total + i;
}
return total;
```

```
[0]     PushId     0
[2]     PushInt    0
[4]     Assign
[5]     PushId     1
[7]     PushInt    0
[9]     Assign
[10]    PushValue  0
[12]    PushInt    1
[14]    LT
[15]    If         53
[17]    PushId     0
[19]    PushValue  0
[21]    PushInt    2
[23]    Add
[24]    Assign
[25]    PushValue  0
[27]    PushInt    3
[29]    EQ
[30]    If         34
[32]    GoTo       10
[34]    PushValue  0
[36]    PushInt    4
[38]    EQ
[39]    If         43
[41]    GoTo       53
[43]    PushId     1
[45]    PushValue  1
[47]    PushValue  0
[49]    Add
[50]    Assign
[51]    GoTo       10
[53]    PushValue  1
[55]    Return     1
variables:
  "" ""
int consts:
  0  10  1  3  8
float consts:

string consts:
binary array consts:
max return num: 1
required stack size: 3
```

对照着读，循环的全部骨架就是两个下标：

- **循环头 = [10]**（条件开始处），**循环出口 = [53]**（循环体之后）。
- `[14] LT` + `[15] If 53`：条件为假 → 跳出循环。
- `[51] GoTo 10`：循环体走完，**回跳**到条件处——这就是循环的「回边」。
- `if i == 3 { continue; }` 编译成 `[30] If 34` / `[32] GoTo 10` 两条：
  `i == 3` → 落到 `[32]` 直接回循环头，跳过本轮剩余语句；
  `i != 3` → `[30] If` 跳到 34 继续往下走。
- `if i == 8 { break; }` 同理：`[39] If 43` / `[41] GoTo 53`——
  `i == 8` → `[41]` 跳到循环出口。
- 这两个 if 都没有 else，且分支以 continue / break 收尾——分支后面
  「跳到 if 出口」的 GoTo 永远执行不到（条件真已被 continue/break 带走，
  条件假已被 `If` 跳过），所以编译器直接省略，产物里没有多余指令。

---

## 7. 入参、返回与导出

```stope
export total;
let i = 0;
total = 0;
while i < argc {
  total = total + args[i];
  i = i + 1;
}
return total, i;
```

```
[0]     PushId     1
[2]     PushInt    0
[4]     Assign
[5]     PushId     0
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
[35]    PushValue  0
[37]    PushValue  1
[39]    Return     2
variables:
  "total" ""
int consts:
  0  1
float consts:

string consts:
binary array consts:
max return num: 2
required stack size: 3
```

要点：

- **导出变量有名字**：`variables:` 里 `"total"` 排在 0 号槽位——宿主可以按名字读写它，
  而 `i` 仍是空串（局部）。槽位按声明顺序分配。
- `argc` 编译成 `ArgNum`（无操作数，个数在运行期才知道）；`args[i]` 编译成
  `PushValue 1`（压下标 i）+ `GetArg`。
- **多值返回**：`return total, i;` 把两个值依次压栈（`[35]`、`[37]`），`Return 2`
  的操作数 = 返回值个数，`max return num: 2`。
- `export` 声明即导出，不能再对同一个名字用 `let`（双向都报
  `duplicate declaration`）。

---

## 8. defer：退出时结算

### 8.1 登记与 LIFO

```stope
let log = "";
defer log = log + "b";
defer log = log + "a";
return log;
```

```
[0]     PushId     0
[2]     PushString 0
[4]     Assign
[5]     PushId     0
[7]     PushValue  0
[9]     PushString 1
[11]    Add
[12]    Assign
[13]    PushId     0
[15]    PushValue  0
[17]    PushString 2
[19]    Add
[20]    Assign
[21]    PushValue  0
[23]    Return     1
variables:
  ""
int consts:

float consts:

string consts:
  ""
  "a"
  "b"
binary array consts:
max return num: 1
required stack size: 3
```

要点：

- **defer 不引入任何新指令，语句位置零指令**：`[4] Assign` 之后直接就是 `[5]`——
  两条 `defer` 语句没有产生任何东西；载荷被拼接在**退出点**上。
- **`return` 出口的三段结构（结算 → 求值 → Return）**：`[5..20]` 是两段载荷
  （结算），`[21] PushValue 0` 求返回值，`[23] Return` 退出。
- **后进先出**：登记顺序是 b、a，但拼接顺序是先 a（`[5..12]`，常量池下标 1 = `"a"`）
  后 b（`[13..20]`，下标 2 = `"b"`）——后登记的先执行。
- **结算先于返回值求值**：`[21] PushValue 0` 排在两段载荷之后，取到的是结算后的
  `"ab"`——defer 可以影响返回值（类似 Go 的具名返回值）。
- 读的是**当前值**：两段载荷里的 `log` 都编译成 `PushValue 0`，退出时才去取槽位
  内容，不是登记时快照。
- **没有 Return 之后的死代码**：程序尾结算在「最后一条已发射指令是 `Return`」时
  跳过——那段路径不可达，拼了也是多余指令；程序不经 `return` 自然结束时，结算
  才拼在末尾。

### 8.2 块作用域

```stope
let x = 1;
{
  defer x = 2;
}
return x;
```

```
[0]     PushId     0
[2]     PushInt    0
[4]     Assign
[5]     PushId     0
[7]     PushInt    1
[9]     Assign
[10]    PushValue  0
[12]    Return     1
variables:
  ""
int consts:
  1  2
float consts:

string consts:
binary array consts:
max return num: 1
required stack size: 2
```

defer 的触发范围是**所在的块**：`{ defer x = 2; }` 的载荷在块尾（`[5..9]`）结算，
先于 `return x` 求值，所以程序返回 `2` 而不是 `1`。
内层块的 defer 先于外层块的执行；载荷里不能写 `return`，`break` / `continue`
也不能跳出载荷（详见 [syntax-reference.md 的 defer 小节](syntax-reference.md#defer--退出结算)）。

---

## 9. 自定义指令

自定义指令由宿主在解析前注册。C++ 侧的注册代码：

```cpp
CustomOpcodeConfig cfg;
u16string n1 = u"myop";
cfg.addCustomOpcode(n1, /*opcode=*/100, /*argNum=*/2);   // 定长 2 参
u16string n2 = u"emit_even";
cfg.addCustomOpcode(n2, /*opcode=*/101, /*argNum=*/-1);  // -1 = 变长参数
```

**已注册**时（`Parser` / `Compiler` / `Disasm` 都传 `&cfg`）：

```stope
let a = myop(1, 2);
let b = emit_even(3);
```

```
[0]     PushId     0
[2]     PushInt    0
[4]     PushInt    1
[6]     myop
[7]     Assign
[8]     PushId     1
[10]    PushInt    2
[12]    emit_even  1
[14]    Assign
custom opcodes:
  myop       -> 100 (2 args)
  emit_even  -> 101 (vararg)
variables:
  "" ""
int consts:
  1  2  3
float consts:

string consts:
binary array consts:
max return num: 0
required stack size: 3
```

- 名字直接出现在指令流里；`custom opcodes:` 段交代编号与参数形态。
- **定长**指令（`myop`，2 参）不带操作数——参数个数注册时已定死；
  **变长**指令（`emit_even`）带一个操作数 = 本次调用的实参个数（`emit_even(3)` → 1）。
- 自定义指令编号必须从 33 起（内置指令占 0–32），注册撞号会返回
  `DuplicateWithBuiltinOpcode`。

**未注册**时，同样的源码会被当成**普通变量的函数调用**：

```
[0]     PushId     0
[2]     PushValue  1
[4]     PushInt    0
[6]     PushInt    1
[8]     Call       2
[10]    Assign
[11]    PushId     2
[13]    PushValue  3
[15]    PushInt    2
[17]    Call       1
[19]    Assign
variables:
  "" "myop" "" "emit_even"
int consts:
  1  2  3
float consts:

string consts:
binary array consts:
max return num: 0
required stack size: 4
```

`myop`、`emit_even` 变成了**隐式导出**的槽位（`variables:` 里看得到名字），
调用走通用 `Call`——运行期那个槽位上是什么（宿主函数？数据？），由宿主决定。
这也是「宿主函数」进入产物的方式：**名字进 `exports`，调用就是 `Call`**。
是否报「未注册」的错，取决于宿主如何处置这些导出槽位。

> 反汇编含自定义指令的产物时必须用 `Disasm(program, &cfg)`：
> 不带 config 只能印 `Custom#编号` 占位，且变长指令后面的参数个数会被
> 当成下一条指令，整段错位。

---

## 10. 下一步

- 语法快速上手（10 分钟版）→ [syntax-intro.md](syntax-intro.md)
- 完整语法规则、字面量边界、错误文案 → [syntax-reference.md](syntax-reference.md)
- 常量折叠的完整行为矩阵 → [constant-folding.md](constant-folding.md)
- 想自己实现虚拟机 / 了解每条指令的栈效应 → [vm-guide.md](vm-guide.md)
- 各宿主语言的接口对照 → [api-reference.md](api-reference.md)
