# Stope 语言

**Stope** 是一门面向嵌入的轻量级脚本语言，配套一个内嵌标记语言 **STML**。本仓库存放它的语言标准与实现。

一般来说，Stope 不适合作为应用程序的主开发语言，而适合作为脚本语言或领域特定语言。

Stope 的特点：
- 无编程范式。可通过 STML 实现不同的编程范式，而不在 Stope 语法层面实现。
- 没有标准库。
- 语法简单、稳定。不会为了支持不同的编程范式而修改语法。
- 动态类型。

如果你认为提供编程范式与标准库才算编程语言，那么 Stope 应当称为“编程语言框架”，可以用来快速搭建定制化的脚本系统。

---

## 标准范围

Stope 只规定三件事：

1. **Stope 语言** —— 语法与语义；
2. **STML** —— 内嵌标记语言；
3. **Stope 编译器** —— AST → `Program` 的产物格式。

**虚拟机不在标准范围内。** Stope **不规定虚拟机的标准**：拿到 `Program` 之后怎么执行、
值怎么表示、栈怎么布局、宿主函数怎么调，全由实现者决定 —— 栈式字节码解释、寄存器机、
直接遍历 AST、转译成 C / 宿主语言的闭包，都合规。宿主程序完全可以用自己的执行器替代，
只要它能消费编译器产出的 `Program`。

本项目**会维护**一台内置虚拟机：`cpp/include/stope/basic_vm.hpp`（反汇编在同目录的
`debug.hpp`）、GDScript 侧 `gdscript/addons/stope/basic_vm.gd` 的 `StopeBasicVM.State` / `Api`、
Node.js 侧 `nodejs/src/basic_vm.js` 的 `BasicVM.State` / `Api`。它是**基础虚拟机** ——
定位是「能跑通编译器产物的最小实现 + 宿主接入的样板」，能力边界是明确的：

| 内置虚拟机**支持** | 内置虚拟机**不支持** |
| --- | --- |
| 33 条内置指令、变量槽与栈、`exports`、宿主函数、`argc` / `args[i]`、单步 `Step()` | **自定义指令**：分派表只有内置的那 33 项，产物里 ≥ 33 的编号没有实现，直接跑会越界（C++ 是未定义行为） |
| 空、整数、浮点、字符串、二进制数组、宿主函数 —— 布尔以整数 1 / 0 表示 | **自定义数据类型**：不能注册新的值类型，也没有对象、结构体、类 |

「会维护」指的是：bug 会修、编译器产物演进时同步、三份实现的语义彼此对齐。但它
**不承诺接口稳定** —— `BasicVM::*` / `StopeBasicVM.*` / `BasicVM.*` 这些名字只属于这几份实现，
换一个执行器可能一个都不存在。要执行自定义指令只有两条路：自己扩指令表（C++ 的
`API::opFuncs` 是定长 `std::array`，扩不了；GDScript / Node.js 的是动态数组，可以扩），
或者干脆自写执行器 —— 见 [cpp/docs/custom-opcode.md](cpp/docs/custom-opcode.md) §6 与
[docs/zh-cn/vm-guide.md](docs/zh-cn/vm-guide.md)。

---

## 一段 Stope

```stope
// 把所有入参加起来
let result = 0.0;
let i = 0;

while i < argc {
    result = result + args[i];
    i = i + 1;
}

fmt:println("结果为: ", result);   // 宿主注册的函数，语言本身不内置 IO
return result;
```

特征：

- **平铺的语句序列** —— 没有函数定义、没有类型标注、没有入口函数，从上到下执行。
- 有六种内置数据类型：整数、浮点、字符串、二进制数组、布尔、`null`。
- `args[i]` 与 `argc` 由宿主提供；`return` 可返回多个值；`export` 把变量交给宿主。
- 全字面量表达式在**解析期**就求值：`1 + 2 * 3` 在语法树里直接是 `7`。
- 可以通过**自定义指令**（宿主注册的操作码）扩展。

完整语法见 [docs/zh-cn/syntax-intro.md](docs/zh-cn/syntax-intro.md)。

---

## STML

STML 是 Stope 项目内嵌的**标记语言**。它的写法像 XML，但规则更简单、更严格。一份 STML 文档是一棵元素树，元素里可以挂三类"代码段"：
普通文本、Nevext 脚本、Stope 脚本。

[Nevext](https://github.com/liu-jl-dev/nevext) 是另一门**汇编风格的数据描述语言**，与 Stope 相互独立；STML 只是负责把 Nevext 代码段**原样**切出来交给宿主。可以使用 Nevext 编写配置信息等，甚至可以用 Nevext 实现“汇编版本”的 Stope 编译器。

```xml
<stml package="MyPkg">

<config>
  windowTitle "demo";
  windowSize 1280, 720
</config>
<func name="myFunc" stope>
  let a = 1;
  return a + argc;
</func>
<class name="Person">
  <property name="name" />
  <property name="age" />
  <method name="greet" />
</class>

</stml>
```

特点：

- **标签语义由宿主决定**。宿主提供 `stateFunc(tag, attrs)`，返回该元素的内容该按哪种状态扫描
  （Xml / Text / Nevext / Stope）。上面这份示例用的 `config` / `func` 是**随便起的名字**——
  换成任何别的名字都不影响，`func` 上那个 `stope`
  属性也只是给回调看的提示。
- **属性可以无值**：`<a flag>` 等价于 `flag=""`；**属性的顺序不保证**。
- **文本结束只认 `</`**：`<p>a < b</p>` 的文本是 `a < b`，其中的 `<` 不是标签起点。
- **代码段原样交出**。词法器只负责把整段代码完整切出来，不检查代码内部写得对不对。
- **元素的文本与子元素互斥**。如果标签内存在文本，则不能有子元素。反之亦然。
- **没有字符实体**。没有 XML 中以 `&` 开头的字符实体。

规格见 [docs/zh-cn/stml-test-plan.md](docs/zh-cn/stml-test-plan.md)，C++ 侧的
上手教程（回调怎么写、12 条语法注意事项）见 [cpp/docs/stml.md](cpp/docs/stml.md)。

STML 可以用来管理相互调用的 Stope 程序，或实现面向对象等编程范式。

---

## 实现状态

|         | C++                      | GDScript                        | Node.js                     |
| ------- | ------------------------ | ------------------------------- | --------------------------- |
| 定位      | **权威实现**                 | 参考实现（逐项按 C++ 对齐）                | 参考实现（逐项按 C++ 对齐）            |
| 布局      | Pitchfork Layout（编译型静态库） | Godot 工程，以 `addons/stope/` 插件分发 | npm 包，纯 ESM、`src/` 下按模块分文件   |
| 标准 / 依赖 | C++20，零第三方依赖             | Godot 4（实测 4.7.2），零第三方插件         | Node >= 20，零第三方依赖           |
| 测试      | ctest 15 组，1505 条断言全绿    | 3153 条断言全绿                      | `npm test` 780 条断言全绿        |

三者出现分歧时**以 C++ 的实测行为为准**，差异登记在对应测试计划的 §7。

> **`gdscript/` 与 `nodejs/` 都是参考实现，不是第二套标准。** 词法 / 语法 / 编译器 / STML
> 四块已与 C++ 逐项对齐 —— 期望值全部由 C++ 探针 dump，两侧都不手写（STML 那 121 条用例
> 跑的是**同一份清单** `gdscript/test/data/stml_cases.txt`）。残留的两条差异见
> [stml-test-plan.md](docs/zh-cn/stml-test-plan.md) §7 的 GD-S-17/18；`nodejs/` 的整数用
> `BigInt`（对应 int64）、字符串是 UTF-16（与 C++ 的 `u16string` 一致），所以它没有那两条
> 差异。参考执行器（`basic_vm.hpp` / `basic_vm.gd` / `basic_vm.js`）**都不属于规范**。
> 安装与用法见 [gdscript/docs/README.md](gdscript/docs/README.md)、
> [nodejs/README.md](nodejs/README.md)。

---

## Quick Start：嵌入你的程序
详见  
[cpp/docs/quick-start.md](cpp/docs/quick-start.md)。

四步：编译源码 → 装配虚拟机 → 建立 `State` 并注入依赖 → 执行。

```cpp
#include <iostream>
#include <stope/basic_vm.hpp>
#include <stope/core.hpp>

using namespace std;
using namespace Stope;

int main() {
  u16string src = u"let a = 1; let b = 2; return a + b;";

  // 1. 编译：源码 → AST → Program
  Lexer lexer(src);
  Parser parser(lexer);
  AST::Prog tree;
  parser.ParseProgram(tree);
  Compiler compiler;
  Program program;
  if (compiler.Compile(tree, program) != Result::Success) {
    cout << "compile failed\n";
    return 1;
  }

  // 2. 装配虚拟机
  BasicVM::Allocator alloc;
  BasicVM::ProgramConstants constants(alloc, program);
  BasicVM::API api;

  // 3. 建立 State，注入依赖
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
  // 返回值在 state.returns（span<Value>），不是 stack[0]
  cout << "return = " << state.returns[0].data.integer << "\n";
  return 0;
}
```

---

## 构建与测试（C++）

```bash
cd cpp
cmake -B build -G "MinGW Makefiles"
cmake --build build
ctest --test-dir build
./build/demo01.exe
cmake --build build --target gen-golden   # 重生成 GDScript 侧的期望值，不属于 ctest
```

只需要 CMake 和一个支持 C++20 的编译器。两个坑：

- 删过 `build/` 后**必须**显式写 `-G "MinGW Makefiles"`，否则 CMake 会误选 Visual Studio  
  并报 `No CMAKE_CXX_COMPILER could be found`。
- 加不加 `-DCMAKE_BUILD_TYPE=Release` 都行：深度用例的判据是 `Parser::maxDepth`（默认
  256 这个逻辑值），不依赖栈容量。（加限额之前必须跑无优化构建 —— 那 4 组"应当崩溃"的
  用例在优化后不会崩。）

更多（含"源码编译失败时 ctest 仍报全绿"这类陷阱）见  
[cpp/docs/development.md](cpp/docs/development.md)。

---

## 构建与测试（GDScript）

无需构建步骤，只要有 Godot 4（实测 4.7.2）：

```bash
godot --headless --path gdscript --script res://test/run_tests.gd
godot --headless --path gdscript res://demo/demo_01.tscn
godot --headless --path gdscript res://demo/demo_02.tscn
godot --headless --path gdscript res://demo/demo_03.tscn
```

第一条跑 3153 条断言（词法 / 语法 / 编译器 / STML / 执行器五组，前四组对齐 C++）；三个 demo 与 `cpp/demo/` 下的
`0N-*.cpp` 一一对应
（`01` 编译+运行 / `02` STML 解析 / `03` 自定义指令）。
更多见 [gdscript/docs/testing.md](gdscript/docs/testing.md)。

---

## 构建与测试（Node.js）

无需构建，也无需 `npm install`（零依赖）：

```bash
cd nodejs
node demo/01-quick-start.js   # 编译 + 运行（还有 02-stml / 03-custom-opcode）
npm test                  # 780 条断言：词法 / 语法 / 编译器 / 反汇编 / 执行器 / STML
npm run test:cov          # 覆盖率 + 阈值门禁（行 80% / 分支 70%）
```

期望值与另外两个实现共用同一份 golden 数据（`gdscript/test/data/`，由
`cmake --build cpp/build --target gen-golden` 生成），所以**跑 Node.js 测试也不需要
C++ 工具链**。更多见 [nodejs/README.md](nodejs/README.md)。

---

## 文档导览

| 想看             | 去哪                                                               |
| -------------- | ---------------------------------------------------------------- |
| 语法入门           | [docs/zh-cn/syntax-intro.md](docs/zh-cn/syntax-intro.md)         |
| 完整语法规则与错误文案    | [docs/zh-cn/syntax-reference.md](docs/zh-cn/syntax-reference.md) |
| 常量折叠规则         | [docs/zh-cn/constant-folding.md](docs/zh-cn/constant-folding.md) |
| 各模块对外契约        | [docs/zh-cn/syntax-impl.md](docs/zh-cn/syntax-impl.md)           |
| 四份跨实现行为契约      | [docs/zh-cn/](docs/zh-cn/) 下的 `*-test-plan.md`                   |
| C++ 实现总览（入口）    | [cpp/docs/README.md](cpp/docs/README.md)                         |
| 嵌入 C++ 程序（四步）  | [cpp/docs/quick-start.md](cpp/docs/quick-start.md)               |
| 解析 STML 文档（上手） | [C++](cpp/docs/stml.md) · [GDScript](gdscript/docs/stml.md) · [Node.js](nodejs/docs/stml.md) |
| 加自定义指令（上手） | [C++](cpp/docs/custom-opcode.md) · [GDScript](gdscript/docs/custom-opcode.md) · [Node.js](nodejs/docs/custom-opcode.md) |
| 构建 / 测试 / 行尾约定 | [cpp/docs/development.md](cpp/docs/development.md)               |
| 内置虚拟机（基础 VM）   | [cpp/docs/basic-vm.md](cpp/docs/basic-vm.md)                     |
| 自己实现一个虚拟机       | [docs/zh-cn/vm-guide.md](docs/zh-cn/vm-guide.md)                 |
| GDScript 实现与插件安装 | [gdscript/docs/README.md](gdscript/docs/README.md)               |
| 嵌入 GDScript / Godot 项目（四步） | [gdscript/docs/quick-start.md](gdscript/docs/quick-start.md) |
| GDScript API 用法   | [gdscript/docs/usage.md](gdscript/docs/usage.md)                 |
| GDScript 报错排查（按阶段查文案） | [gdscript/docs/troubleshooting.md](gdscript/docs/troubleshooting.md) |
| GDScript 测试与数据重生成 | [gdscript/docs/testing.md](gdscript/docs/testing.md)             |
| GDScript 语言坑与代码约定 | [gdscript/docs/gdscript-notes.md](gdscript/docs/gdscript-notes.md) |
| Node.js 实现（模块、约定、测试） | [nodejs/README.md](nodejs/README.md)               |
| 嵌入 Node.js 项目（四步）     | [nodejs/docs/quick-start.md](nodejs/docs/quick-start.md)           |
| Node.js API 用法与错误总表   | [nodejs/docs/usage.md](nodejs/docs/usage.md)                       |
| C++ 侧实现笔记（改 `cpp/` 前看） | [cpp/docs/development.md](cpp/docs/development.md)             |
| C++ 侧各模块实现笔记    | [cpp/docs/](cpp/docs/) 下的 `*-test-plan.md`、`expr-optim.md`       |

---

## 许可证

MIT，见 [LICENSE](LICENSE)。
