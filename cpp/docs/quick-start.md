# C++ 快速上手

> 目标读者：想在自己的 C++ 程序里嵌入 Stope 的人。
> 本文逐段讲 `cpp/demo/01-quick-start.cpp`（可以直接编译运行），最后给出一份可复制的最小骨架。

| 想看 | 去哪（相对本文件） |
| --- | --- |
| 语言的语法 | `../../docs/zh-cn/syntax-intro.md` |
| 各模块的对外接口 | `../../docs/zh-cn/syntax-impl.md` |
| 标准范围（为什么虚拟机不算标准） | `../../README.md` |
| 自己写一个执行器 | `../../docs/zh-cn/vm-guide.md` |
| 虚拟机的语义约定 | `basic_vm.md`（本目录） |
| 布局 / 构建 / 行尾 / 文档约定 | `development.md`（本目录） |
| API 参数与所有权约定 | `development.md` §7（本目录） |
| 常量折叠的规则总表 | `expr_optim.md`（本目录） |
| 给编译器加自定义指令 | `custom-opcode.md`（本目录） |
| 解析 STML 文档 | `stml.md`（本目录） |

依赖只有 C++20 编译器 + CMake，无第三方库。

---

## 0. 先说清楚：哪些 API 是稳定的

Stope 只规定三件事：**语言**、**STML**、**编译器的产物 `Program`**（见仓库根
[`README.md`](../../README.md)）。**它不规定虚拟机**，所以本文示例里的接口分两类，稳定性完全不同：

| 部分 | 稳定性 | 涉及的 API |
| --- | --- | --- |
| 编译环节（§3） | **相对稳定** | `Lexer` `Parser` `Compiler` `AST::Prog` `Program` `CustomOpcodeConfig` |
| 虚拟机环节（§4–§6） | **只是内置示例** | `BasicVM::Allocator` `ProgramConstants` `API` `State` `Value` `Arguments` |

**编译环节**跟着编译器规格走：`Program` 有明确的编码契约（指令编号、操作数、跳转目标都是
`opcodes` 下标，见 `compiler_test_plan.md` §2），改接口要同步改规格与测试，所以可以照着写。
它今天叫「相对稳定」而不是「稳定」，是因为 `Program` 的字段仍在演进。

**虚拟机环节**是 `include/stope/basic_vm.hpp` 这一份实现的接口，**不是规范**：
值怎么表示（这里用 `type` + `union`）、栈怎么布局、宿主函数怎么注册、错误怎么报，
全都属于实现者自由。换一个执行器，`BasicVM::*` 这些名字可能一个都不存在 ——
你可能直接遍历 AST、编译成宿主语言的闭包、或者转译成别的 IR。

要自己写执行器，读 [`../../docs/zh-cn/vm-guide.md`](../../docs/zh-cn/vm-guide.md)，
那是**指南**（讲一种可行解），不是要照抄的规范。

---

## 1. 先跑起来

```bash
cd cpp
cmake -B build -G "MinGW Makefiles"     # 必须显式指定 generator
cmake --build build                      # 产出 build/libstope.a 与各测试
ctest --test-dir build                   # 13/13
./build/demo01.exe
```

`demo01` 的完整输出（本文所有输出都是实际跑出来的）：

```
[0]     PushId     0
[2]     PushFloat  0
[4]     Assign
...
[44]    PushId     0
[46]    Return     1
variables:
  "" "" "fmt:println"
int consts:
  0  1
float consts:
  0
string consts:
  "结果为: "
binary array consts:
max return num: 1
required stack size: 3

[Host] 结果为: 15
result: 15
```

前一半是 `debug.hpp` 的反汇编，由 step 1 打印；后一半是 VM 真正执行的结果。

---

## 2. 全景：四步

```
源码(u16string)
  │  Lexer          → Token 流
  │  Parser         → AST（可选地做常量折叠）
  │  Compiler       → Program（字节码 + 常量池 + exports）
  ▼
Program ──┐
          │  Allocator + ProgramConstants  把常量装进句柄池
          ▼
        State ── API ── Arguments ── 宿主函数
          │  Run()
          ▼
       returns / errors
```

| 步 | 做什么 | 主要类型 | 稳定性 |
| --- | --- | --- | --- |
| 1 | 编译源码 | `Lexer` `Parser` `Compiler` → `Program` | 相对稳定（编译器接口） |
| 2 | 装配虚拟机 | `Allocator` `ProgramConstants` `API` | 内置示例 |
| 3 | 建立 State 并绑定依赖 | `State` 的五个 `SetXxx` | 内置示例 |
| 4 | 传入参数并执行 | `Arguments` `Run()` `returns` | 内置示例 |

**step 1 和后面三步是分开的**：只想看字节码、只想做静态检查的话，编译完就可以收工，
完全不需要碰 VM。

稳定性也是这么分开的：step 1 的四个类型属于编译器（相对稳定）；step 2–4 的 `BasicVM::*`
全部来自 `basic_vm.hpp` 这一份内置示例执行器，**换执行器就全变**（见 §0）。

---

## 3. step 1：编译源码

```cpp
u16string src = uR"(
    // example: sum all arguments

    let result = 0.0;
    let i = 0;
    while i < argc {
      result = result + args[i];
      i = i + 1;
    }

    fmt:println("结果为: ", result);
    return result;
)";

Lexer lexer(src);
Parser parser(lexer);              // 第一参是引用；第二参 CustomOpcodeConfig* 默认 nullptr
AST::Prog tree;
parser.ParseProgram(tree);
Compiler compiler;                 // 构造参：CustomOpcodeConfig*，默认 nullptr
Program program;
compiler.Compile(tree, program);  // AST 与 Program 都传引用
cout << DumpProgramNoCustom(program) << endl;
```

注意点：

- **源码是 `u16string`**（UTF-16），不是 `std::string`。整个前端都在 UTF-16 上工作。
- `Compile()` 返回 `Result`，失败时按约定会**把 `out` 复原为空**（见 `compiler_test_plan.md` §2）。
- **参数都传引用**：`Parser parser(lexer)`、`ParseProgram(tree)`、`Compile(tree, program)`
  前面不加 `&`。只有真正可能为空的依赖才用指针（`Parser` 第二参、`Compiler` 构造参），
  约定见 `development.md` §7。
- 词法/语法/编译的错误都不抛异常，分别进 `lexer.errors`、`parser.errors`；
  `Compile()` 失败时看返回值。
- `DumpProgramNoCustom()` 来自 `debug.hpp`，把 `Program` 转成可读文本，方便核对。
  产物里有自定义指令时改用 `DumpProgram(program, &config)`（见 §9 与 `demo/02-custom-opcode.cpp`）。

这一节用到的五个类型（`Lexer` `Parser` `AST::Prog` `Compiler` `Program`）是**编译器接口**，
它围绕的正是标准里规定的那一层 —— `Program` 的编码契约（`compiler_test_plan.md` §2），
所以这段代码相对稳定、值得照抄。**到此为止就是一个完整的 Stope 编译器用法**，
后面三节只是「怎么把产物跑起来」的一种示例。

---

## 4. step 2：装配虚拟机

> **step 2–4 是内置示例，不是规范。** 这里的 `BasicVM::*` 全部来自
> `include/stope/basic_vm.hpp`；项目不规定虚拟机的标准（§0），所以下文的名字、
> 结构、调用顺序都可能变。自己写执行器时，只需要满足 `vm-guide.md` 里的语义要求，
> 不必照抄这套 API。

```cpp
BasicVM::Allocator alloc;
BasicVM::ProgramConstants constants(alloc, program);
BasicVM::API api;
```

- **`Allocator`** 持有所有字符串 / BinArr 的 refcount 句柄池。
- **`ProgramConstants(alloc, program)`** 在构造时就把 `program` 的常量装进 `alloc`，
  所以**必须先有 `alloc`**。
- **`API`** 持有 32 条内置指令的实现表（`static inline std::array<OpFunc, kOpCount> opFuncs`），
  `State::Run()` 就是 `api->opFuncs[opcode](*api, *this)`。目前没有可替换的余地，
  但 `SetAPI` 是必需的——漏了 `api` 就是空指针。

生命周期：`alloc` 要活得比 `constants` 和 `state` 都长。都在同一个作用域里时，
按 `alloc` → `constants` → `state` 的顺序声明即可（析构是逆序）。

---

## 5. step 3：建立 State 并绑定宿主函数

```cpp
BasicVM::State state;
state.SetAPI(api);
state.SetAllocator(alloc);
state.SetProgramConstants(constants);
state.SetProgram(program);
state.variables.resize(program.variableNum);   // 必做，否则变量槽位是空的
```

**`fmt:println` 这类在源码里被调用、但从未声明的名字，会由 Compiler 隐式登记进
`program.exports`**，槽位随声明顺序变化。宿主侧按名字取槽位，再往里面填函数：

```cpp
auto hostPrintln = [](BasicVM::State& state,
                      std::span<const BasicVM::Value> args,
                      BasicVM::Value& output) -> void {
  cout << "[Host] ";
  for (auto& arg : args) {
    if (arg.type == BasicVM::Value::Type::Float) {
      cout << arg.data.floating;
    } else if (arg.type == BasicVM::Value::Type::String) {
      u16string& u16s = state.alloc->GetString(arg.data.handle);
      cout << UTF::Utf16ToUtf8(u16s);
    }
  }
  cout << endl;
};

auto& v_fmtPrintln = state.variables[program.exports[u"fmt:println"]];
v_fmtPrintln.type = BasicVM::Value::Type::HostFunction;
v_fmtPrintln.data.hostFuncPtr = hostPrintln;
```

- 宿主函数签名是 `void(State&, std::span<const Value>, Value&)`。
  **只有不捕获的 lambda 才能转成这个函数指针**——类型里没有 udata 通道。
  需要上下文就放在全局变量 / 单例里，不要指望闭包。
- 字符串值是 refcount 句柄：先 `state.alloc->GetString(handle)` 拿到 `u16string&`，
  再用 `UTF::Utf16ToUtf8()` 转码才能输出。
- 注册多个宿主函数就是重复上面三行，`exports` 里的名字逐个取。

---

## 6. step 4：传入参数并执行

Stope 程序里的 `argc` / `args[i]` 由宿主的 `Arguments` 提供，需要实现两个纯虚函数：

```cpp
struct MyArgs : BasicVM::Arguments {
  std::vector<double> data;
  Result at(BasicVM::State& s,
            const BasicVM::Value& indexOrKey,
            BasicVM::Value& out) override {
    if (indexOrKey.type != BasicVM::Value::Type::Integer) {
      s.Error("index must be an integer");
      return Result::Error;
    }
    out.type = BasicVM::Value::Type::Float;
    out.data.floating = data[indexOrKey.data.integer];
    return Result::Success;
  }
  std::int64_t num() override { return data.size(); }
};

MyArgs args;
args.data = {1.0, 2.0, 3.0, 4.0, 5.0};
state.SetArguments(args);          // 用不到 argc/args 时可以整步跳过

state.Run();
cout << "result: " << state.returns[0].data.floating << endl;
```

- `at()` 报错走 `s.Error(msg)` + 返回 `Result::Error`，VM 会立刻停下。
- **读返回值用 `state.returns`（`span<Value>`），不是 `state.stack[0]`。**

---

## 7. 最小骨架（可直接复制）

不需要宿主函数、不需要传参时，四步可以压成这些：

> 骨架里 **1. 编译** 这一段是编译器接口（相对稳定）；**2–4** 是 `basic_vm.hpp` 的
> 内置示例 API。想换成自己的执行器，只要保留第 1 段，后面整段重写。

```cpp
#include <iostream>
#include <stope/basic_vm.hpp>
#include <stope/core.hpp>

using namespace std;
using namespace Stope;

int main() {
  u16string src = u"let a = 1; let b = 2; return a + b;";

  // 1. 编译
  Lexer lexer(src);
  Parser parser(lexer);
  AST::Prog tree;
  parser.ParseProgram(tree);
  Compiler compiler;
  Program program;
  if (compiler.Compile(tree, program) != Result::Success) return 1;

  // 2. 装配
  BasicVM::Allocator alloc;
  BasicVM::ProgramConstants constants(alloc, program);
  BasicVM::API api;

  // 3. State
  BasicVM::State state;
  state.SetAPI(api);
  state.SetAllocator(alloc);
  state.SetProgramConstants(constants);
  state.SetProgram(program);
  state.variables.resize(program.variableNum);

  // 4. 执行
  if (state.Run() != Result::Success) {
    for (auto& e : state.errors) cout << "  err: " << e << "\n";
    return 1;
  }
  cout << "return = " << state.returns[0].data.integer << "\n";
  return 0;
}
```

输出：`return = 3`。

---

## 8. 常见错误

| 现象 | 原因 |
| --- | --- |
| 变量访问越界 / 读到空槽位 | 忘了 `state.variables.resize(program.variableNum)` |
| 用 `if (state.Run())` 判成功，逻辑反了 | **`Result::Success == 0`**。要写 `== Result::Success` |
| 宿主函数被静默绑到变量 0 | `program.exports[u"名字"]` 是 `std::map::operator[]`，**名字不存在时会插入并返回 0**。源码里没有这个名字时，要用 `find()` 先确认 |
| 取 `state.returns[0]` 崩 | 源码没有 `return` 语句时 `returns` 是空的（`Run()` 仍返回 Success）。先判 `!returns.empty()` |
| 捕获 lambda 转不成 `HostFunction` | 函数指针没有 udata 通道，只能用不捕获的 lambda |
| 输出的中文是乱码 | Windows 控制台要先 `SetConsoleOutputCP(CP_UTF8)`；字符串值要先 `GetString()` 再 `Utf16ToUtf8()` |
| `cmake -B build` 报找不到编译器 | 缺 `-G "MinGW Makefiles"`，或删 `build/` 没删干净 |
| 4 组 `parser-depth-*` 用例忽然全过 | 加了 `-DCMAKE_BUILD_TYPE=Release`，栈帧变小后「应崩溃」的用例不崩了 |

更多约定：`nextToken()` 的规则见 `parser_test_plan.md` §2.2，
栈深度阈值、行尾、构建陷阱见 `development.md`。

---

## 9. 下一步

- 只想把 Stope 当表达式求值器：只用 step 1 的 `Compiler` + `debug.hpp` 就够。
- 想加自己的指令：填 `CustomOpcodeConfig`，传给 `Parser` 与 `Compiler`。
  `cpp/demo/02-custom-opcode.cpp` 是可编译的完整例子（只编译 + 反汇编），
  它同时演示了 `DumpProgram(program, &config)` —— 产物含自定义指令时必须带
  config，否则名字和变长指令后面那个参数个数都无从得知。
  **教程见 `custom-opcode.md`（本目录）**，规则见 `compiler_test_plan.md` §4.4。
- 想换掉内置的虚拟机：读 `../../docs/zh-cn/vm-guide.md`。它讲的是「`Program` 的契约 +
  执行器必须实现出哪些语义」，`basic_vm.hpp` 只是其中一种写法；你可以只保留本文 §3 的
  编译环节，执行部分整段自己写。
- 想看各模块怎么测的：四份 `*_test_plan.md`。
