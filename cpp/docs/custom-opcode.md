# 自定义指令：注册、编译、反汇编

> 目标读者：想在 C++ 里给自己的 Stope 程序加指令的人。
> 本文逐段讲 `cpp/demo/02-custom-opcode.cpp`（可编译运行，**只编译 + 反汇编，不接执行器**），
> §7 给一份可复制的最小骨架（按文档原文编译运行过）。

| 想看 | 去哪（相对本文件） |
| --- | --- |
| 自定义指令的**语言规则**（文法、命名、关键字优先） | [syntax-reference.md](../../docs/zh-cn/syntax-reference.md) §5.3 |
| 执行器侧怎么执行这些编号 | [vm-guide.md](../../docs/zh-cn/vm-guide.md) §5.5 |
| `Program` 的编码契约（哪条指令带操作数） | [compiler_test_plan.md](compiler_test_plan.md) §2、§4.4 |
| 完整的四步嵌入（编译 → 装配 → 运行） | [quick-start.md](quick-start.md) |
| 解析 STML 文档（另一种宿主扩展） | [stml.md](stml.md) |
| 反汇编函数本身 | `include/stope/debug.hpp` |
| 布局 / 构建 / 行尾 / 文档约定 | [development.md](development.md) |

---

## 0. 先摆正位置：它是**宿主扩展**，不是语言特性

Stope 只规定三件事：语言、STML、编译器产物 `Program` 的编码（见仓库根 `README.md`）。
指令集里内置的 **33** 条（`include/stope/opcode.hpp`，编号 0…32）是标准的一部分；
**从 33 起一个编号都没有被占用**，全部留给宿主。

于是加指令这件事只发生在你的 C++ 程序里，Stope 源码不需要任何新语法：

```
CustomOpcodeConfig： "my:add" -> #33，2 参
        │
        ├── Lexer     名字命中注册表 → TokenType::Custom
        ├── Parser    Custom token → AST::CustomOpcodeExpr
        └── Compiler  查编号与参数个数 → 写进 Program

Stope 源码：my:add(x, 4);      和普通函数调用长得一样，只靠名字区分
产物 Program：…… PushValue 0，PushInt 1，33，Pop ……
```

最后一行是关键：`Program` 里只剩下 **`33`** 这个编号 —— 它什么含义、谁来执行，全由宿主
决定。这正是本 demo 只编译不运行的原因（`BasicVM` 只实现了 33 条内置指令）。

> **一句话**：内置指令是「标准说好大家一起实现」的，自定义指令是「你自己定义、
> 自己执行」的。前者写进 `Program` 的契约，后者写进你的宿主程序。

---

## 1. 先跑起来

```bash
cd cpp
cmake -B build -G "MinGW Makefiles"     # 必须显式指定 generator
cmake --build build
./build/demo02.exe
```

不需要别的依赖（C++20 + CMake）。demo 分五段（`[1]`–`[5]`），§2–§4 讲前两段，
§5 讲剩下三段（三个误解）。

---

## 2. 登记：`CustomOpcodeConfig`

配置就是两个小结构（`include/stope/custom_opcode.hpp`）：

```cpp
struct CustomOpcode {
  short opcode;   // 指令编号，必须 > Opcode::Return
  bool isVarArg;  // 变长参数？（由 argNum < 0 推出来）
  short argNum;   // 定长时的参数个数；变长时无意义
};

struct CustomOpcodeConfig {
  std::map<std::u16string, CustomOpcode> opcodes;  // 名字 → 定义
  Result addCustomOpcode(std::u16string& name, short opcode, short argNum = -1);
};
```

demo 里登记三条：

```cpp
CustomOpcodeConfig config;
u16string addName = u"my:add";
u16string logName = u"my:log";
u16string haltName = u"my:halt";
config.addCustomOpcode(addName, kFirstCustomOpcode + 0, 2);   // 定长 2 参
config.addCustomOpcode(logName, kFirstCustomOpcode + 1, -1);  // 变长
config.addCustomOpcode(haltName, kFirstCustomOpcode + 2, 0);  // 定长 0 参
```

`[1]` 段的实际输出（demo 自己按编号排了序；`std::map` 的迭代顺序是**名字字典序**）：

```
[1] 登记自定义指令：
  my:add -> #33（定长 2 参）
  my:log -> #34（变长）
  my:halt -> #35（定长 0 参）
```

四个要注意的地方：

| 点 | 说明 |
| --- | --- |
| **编号起点** | 用 `kFirstCustomOpcode`（定义在 `debug.hpp`，等于 `Opcode::Return + 1` = **33**）。编号撞到 0…32 会被当成内置指令，见 §5.3 |
| **变长 = `argNum < 0`** | 传 `-1`（默认值）即变长；`isVarArg` 由它推出来，不用自己填 |
| **形参是非 const 引用** | `addCustomOpcode(std::u16string& name, …)`，所以 `addCustomOpcode(u"my:add", 33, 2)` **编译不过** —— 先声明变量再传 |
| **返回值** | `Result::Success`；同名重复注册返回 `DuplicateWithBuiltinOpcode`（名字叫 builtin，实际是「重名」，`addCustomOpcode` 目前**不**校验编号范围） |

名字的规则来自词法器：普通标识符或命名空间形式 `a:b`（`^[a-zA-Z_][a-zA-Z0-9_]*(?::…)*$`），
且**关键字优先** —— 注册一个叫 `if` 的指令是无效的，`if` 永远按关键字处理。

---

## 3. 编译：同一份 config 交给 Parser 和 Compiler

`my:add(x, 4);` 要变成一条自定义指令，三个环节都得知道这份 config：

| 环节 | 拿 config 做什么 | 查不到会怎样 |
| --- | --- | --- |
| `Lexer` | 标识符命中注册表 → 吐 `TokenType::Custom` | 当普通 `Ident` |
| `Parser` | `Custom` token → `AST::CustomOpcodeExpr{opcodeName, args}` | 走 `Call`（普通函数调用） |
| `Compiler` | 查 `opcode` / `argNum`，写编号（变长再多写一个参数个数） | 报 `undefined custom instruction "…"` |

```cpp
Lexer lexer(src);
Parser parser(lexer, &config);   // 非 const：Parser 内部按需查表
AST::Prog tree;
parser.ParseProgram(tree);

Compiler compiler(&config);      // const：只在构造时注入一次
Program program;
compiler.Compile(tree, program);
```

两个签名不一样是有原因的：`Parser` 的 config 参数是 `CustomOpcodeConfig*`（可空，形参非 const），
`Compiler` 的构造参数是 `const CustomOpcodeConfig*`。传同一份对象即可，别各建一份 ——
两边不一致时你会看到 `undefined custom instruction`（`compiler_test_plan.md` C-37），
或者干脆得到普通 `Call`（C-37b）。

demo 的源码：

```cpp
u16string src = uR"(
    let x = 3;

    my:add(x, 4);        // 定长 2 参
    my:log("x =", x);    // 变长 2 参
    my:log();            // 变长 0 参
    my:halt();           // 定长 0 参

    return x;
  )";
```

`[2]` 段的实际输出：

```
[0]     PushId     0
[2]     PushInt    0
[4]     Assign
[5]     PushValue  0
[7]     PushInt    1
[9]     my:add
[10]    Pop
[11]    PushString 0
[13]    PushValue  0
[15]    my:log     2
[17]    Pop
[18]    my:log     0
[20]    Pop
[21]    my:halt
[22]    Pop
[23]    PushValue  0
[25]    Return     1
custom opcodes:
  my:add     -> 33 (2 args)
  my:log     -> 34 (vararg)
  my:halt    -> 35 (0 args)
variables:
  ""
int consts:
  3  4
float consts:

string consts:
  "x ="
binary array consts:
max return num: 1
required stack size: 2
```

逐段对上：

| 指令 | 来自 | 说明 |
| --- | --- | --- |
| `[0] PushId 0` `[2] PushInt 0` `[4] Assign` | `let x = 3;` | 变量槽 0；`3` 进 `intConsts[0]` |
| `[5] PushValue 0` `[7] PushInt 1` `[9] my:add` | `my:add(x, 4);` | `x` 是**读值** → `PushValue`；参数照常先压栈，**定长指令本身不带操作数**（参数个数在注册时定死） |
| `[10] Pop` | 同上 | 表达式语句丢弃结果 |
| `[11] PushString 0` `[13] PushValue 0` `[15] my:log 2` | `my:log("x =", x);` | 变长 → 紧跟一个 `2` 表示本次调用的实参个数 |
| `[18] my:log 0` | `my:log();` | 0 参也要写 `0`，不是省略 |
| `[21] my:halt` | `my:halt();` | 定长 0 参 → 不带操作数 |
| `[23] PushValue 0` `[25] Return 1` | `return x;` | 读值 → `PushValue` |

栈容量的记账有个细节（`compiler_test_plan.md` CD-3）：自定义指令**没有 callee 入栈**，
结果仍占 1 格，所以净变化是 `-(n-1)`。定长 2 参的 `my:add` 只多占 1 格，这也是
`required stack size: 2` 的来历。

---

## 4. 反汇编：`DumpProgram(program, &config)`

`debug.hpp` 提供两个入口：

| 函数 | 什么时候用 |
| --- | --- |
| `DumpProgram(program, &config)` | 产物里**可能**有自定义指令 —— 拿得到名字、变长操作数与注册表 |
| `DumpProgramNoCustom(program)` | 确定没有自定义指令的产物；等价于 `DumpProgram(program, nullptr)`，输出与旧版**逐字节相同** |

带 config 时它多做三件事：

1. **印名字**：编号回查注册表，`32` 显示成 `my:add`（名字列宽度下限 10，自定义名更长时整列变宽）。
2. **按 `isVarArg` 决定要不要吃操作数**：`my:log 2` 里的 `2` 是参数个数；如果把它当指令，
   后面整段都会错位 —— 这是不带 config 时最容易看错的地方。
3. **多印一节 `custom opcodes:`**：名字 → 编号 → 参数形态。执行器分派看的是**编号**，
   所以这份映射值得直接印在产物里。

不带 config 时的退化行为（都是有意为之，不会崩）：

| 情况 | 输出 |
| --- | --- |
| 编号 ≥ 32 且不在注册表里 | `Custom40` 占位，**不猜**有没有操作数，文末 `warning: opcode #40 is not a builtin; …` |
| 注册时编号撞了内置指令 | 按内置指令解码，文末 `warning: … collides with Add; builtin decoding wins.` |
| 两个名字共用一个编号 | 前者生效，文末 `warning: … share #33; the former wins.` |
| 变长指令后面没有操作数（流截断） | 该行显示 `<missing operand>` + warning |

---

## 5. 三个容易踩的误解（demo 的 `[3]`–`[5]` 段）

下面三段都用 demo 里的辅助函数 `compileAndReport(src, cfg, out)` —— 它就是 §3 那四行
（lex → parse → compile），出错时直接把 `parser.errors` / `compiler.errors` 打到屏幕。
完整写法见 `demo/02-custom-opcode.cpp`。

### 5.1 名字没登记就只是普通调用

```cpp
Program plain;
compileAndReport(u"my:add(1, 2);", nullptr, plain);  // 不传 config
```

```
[0]     PushValue  0
[2]     PushInt    0
[4]     PushInt    1
[6]     Call       2
[8]     Pop
variables:
  "my:add"
```

`my:add` 变成了「调用一个名叫 `my:add` 的宿主函数」：callee 先入栈（`PushValue 0`），
`Call` 带实参个数 2。顺带注意 `variables:` 里的 `"my:add"` —— 未声明的标识符会被
隐式登记进 `Program.exports`，宿主得往这个槽位里放一个函数，否则运行期报错。

**所以：源码里写的是同一个名字，编译结果完全取决于你有没有那份 config。**

### 5.2 定长参数个数由编译器校验

```cpp
compileAndReport(u"my:add(1);", &config, bad);  // my:add 注册的是 2 参
```

```
[4] 定长 2 参却只给 1 个：
  compiler: line 1: custom instruction "my:add" expected 2 args, but got 1.
  -> 编译失败，Program 已清空（opcodes 剩 0 个 short）
```

变长指令不校验个数（`my:log()`、`my:log(1,2,3)` 都行）。报错后 `Compile()` 会把 `out`
复原为空 —— 半成品 `Program` 跑不了，留着只会误导。

### 5.3 编号撞内置指令：只有 warning

```cpp
collide.addCustomOpcode(stealName, static_cast<short>(Opcode::Add), 2);  // 用 Add 的编号
```

```
[0]     PushInt    0
[2]     PushInt    1
[4]     Add
[5]     Pop
warning: custom opcode "my:steal" uses #19, which collides with Add; builtin decoding wins.
```

`opcodes` 是 `short` 混排序列，编号撞了以后写进去的还是同一个 `short`，**编译器与反汇编
都无从区分**。所以 `addCustomOpcode` 拦不住（它不校验编号范围），反汇编只能按内置指令解码
并给出 warning。没有别的选择：自定义编号就从 `kFirstCustomOpcode` 往上排。

---

## 6. 拿到 `Program` 之后：宿主怎么执行这些编号

本 demo 到此为止 —— 再往下就进入「执行器」的领域，而项目**不规定虚拟机**
（见 `../../docs/zh-cn/vm-guide.md` 开头）。要做的话，自定义指令只有三条要求：

1. **分派表得认识这些编号。** `BasicVM` 的 `API::opFuncs` 只有 33 项
   （`kOpCount = Opcode::Return + 1`），`State::Run()` 直接 `opFuncs[opcode]` 下标取 ——
   自定义编号会越界。换成你自己的执行器时，分派要么做成 `switch`，要么把表扩到最大编号。
2. **栈效果是 `[a₁ … aₙ] → [ret]`。** 参数已经按从左到右压好了，结果占 1 格；
   注意**没有 callee 入栈**（这点与 `Call` 不同，也是 CD-3 的由来）。
3. **变长指令先读一个 `short` 当 `n`。** 定长指令的参数个数在注册表里，流里不重复写。

编号 → 名字的映射留给你自己保管（`CustomOpcodeConfig` 就是现成的地方）；
`DumpProgram` 印出来的 `custom opcodes:` 一节，正好可以拿来核对。

---

## 7. 最小骨架（已编译运行）

```cpp
#include <iostream>
#include <string>

#include <stope/compiler.hpp>
#include <stope/debug.hpp>
#include <stope/lexer.hpp>
#include <stope/parser.hpp>

using namespace Stope;

int main() {
  CustomOpcodeConfig config;
  std::u16string name = u"my:emit";
  config.addCustomOpcode(name, kFirstCustomOpcode, -1);  // 变长：多一个参数个数

  std::u16string src = uR"(my:emit(1, "a");)";
  Lexer lexer(src);
  Parser parser(lexer, &config);
  AST::Prog tree;
  parser.ParseProgram(tree);

  Program program;
  Compiler compiler(&config);  // 同一份 config
  if (compiler.Compile(tree, program) != Result::Success) {
    for (const auto& e : compiler.errors) {
      std::cerr << e << "\n";
    }
    return 1;
  }
  std::cout << DumpProgram(program, &config);
}
```

输出：

```
[0]     PushInt    0
[2]     PushString 0
[4]     my:emit    2
[6]     Pop
custom opcodes:
  my:emit    -> 33 (vararg)
variables:

int consts:
  1
float consts:

string consts:
  "a"
binary array consts:
max return num: 0
required stack size: 2
```

`variables:` 后面是空的 —— 这段程序没有变量，也没有未声明的标识符（`my:emit` 已被识别成
自定义指令，不会进 `exports`）。**记住这一点：能不能进 `exports` 只取决于名字有没有注册。**

把一个 `.cpp` 塞进 `cpp/` 后，单文件编译就是（`build/libstope.a` 由 §1 的 `cmake --build` 产出）：

```bash
g++ -std=c++20 -Iinclude sk.cpp build/libstope.a -o sk.exe
```

---

## 8. 排错表

| 现象 | 原因 |
| --- | --- |
| `expected "(" after custom opcode.` | 调用漏了括号，自定义指令的括号不可省（`myop 1;`） |
| 编译报 `undefined custom instruction "myop"` | Parser 有这份 config，Compiler 没有（或名字拼错） |
| 编出来是 `Call` 而不是自定义指令 | 名字没进 config，或与关键字同名（关键字优先） |
| `expected 2 args, but got 1` | 定长指令的 `argNum` 与实际调用不符 |
| 反汇编里出现 `Custom40` | `DumpProgram` 没传 config |
| 反汇编从某条变长指令开始整段错位 | 同上：参数个数被当成了下一条指令 |
| `addCustomOpcode(u"x", 33, 2)` 编译不过 | 形参是 `std::u16string&`，先声明变量再传 |
| 程序跑起来越界/崩 | 执行器不认识这个编号：`BasicVM` 只有 33 项 |

---

## 9. 相关文件

| 文件 | 作用 |
| --- | --- |
| `demo/02-custom-opcode.cpp` | 本文讲的例子（目标 `demo02`，未接 ctest） |
| `include/stope/custom_opcode.hpp` | `CustomOpcode` / `CustomOpcodeConfig` |
| `include/stope/debug.hpp` | `DumpProgram` / `DumpProgramNoCustom` / `kFirstCustomOpcode` |
| `compiler_test_plan.md` §4.4 | 自定义指令的坑（编号 > `Return`、`opHasParam` 的兜底分支） |
| [syntax-reference.md](../../docs/zh-cn/syntax-reference.md) §5.3 | 语言侧规则（文法、命名、关键字优先） |
| [vm-guide.md](../../docs/zh-cn/vm-guide.md) §5.5 | 执行器侧要求 |
