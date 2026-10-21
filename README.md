# Stope

**Stope** 是一门面向嵌入的小型脚本语言，配套一个内嵌标记语言 **STML**。本仓库存放它的语言标准与参考实现。

---

## 标准范围

Stope 只规定三件事：

1. **Stope 语言** —— 语法与语义；
2. **STML** —— 内嵌标记语言；
3. **Stope 编译器** —— AST → `Program` 的产物格式。

**虚拟机不在标准范围内。** `cpp/include/stope/basic_vm.hpp`（以及 `cpp/include/stope/debug.hpp`、  
GDScript 侧 `stope.gd` 的 `State` / `Api`）都**只是参考实现**，用途是验证产出的 `Program`  
确实能被执行。指令集的具体语义、栈的布局、宿主函数的调用约定均**不属于规范**——  
宿主程序完全可以用自己的执行器替代，只要它能消费编译器产出的 `Program`。

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
- 数据只有六种：整数、浮点、字符串、二进制数组、布尔、`null`。
- `args[i]` 与 `argc` 由宿主提供；`return` 可返回多个值；`export` 把变量交给宿主。
- 全字面量表达式在**解析期**就求值：`1 + 2 * 3` 在语法树里直接是 `7`。
- 通过**自定义指令**（宿主注册的操作码）扩展，语言本身不内置任何 IO。

完整语法见 [docs/zh-cn/syntax-intro.md](docs/zh-cn/syntax-intro.md)。

---

## STML

STML 是 Stope 项目内嵌的**标记语言**。它的写法像 XML，但规则更简单、也更严格
（差别见下面的「特点」）。一份 STML 文档是一棵元素树，元素里可以挂三类"代码段"：
普通文本、Nevext 脚本、Stope 脚本。

[Nevext](https://github.com/liu-jl-dev/nevext) 是另一门**汇编风格的数据描述语言**，与 Stope 相互独立；STML 只是负责把 Nevext 代码段**原样**切出来交给宿主。可以使用 Nevext 编写配置信息等，甚至用 Nevext 实现“汇编版本”的 Stope 编译器。

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
  换成 `sto` / `nev` / `p`（测试里用的那套）或任何别的名字都不影响，`func` 上那个 `stope`
  属性也只是给回调看的提示。
- **属性可以无值**：`<a flag>` 等价于 `flag=""`；**属性的顺序不保证**。
- **文本只认 `</`**：`<p>a < b</p>` 的文本是 `a < b`，其中的 `<` 不是标签起点。
- **代码段原样交出**。词法器只负责把整段代码完整切出来，不检查代码内部写得对不对。
- **元素的文本与子元素互斥**。如果标签内存在文本，则不能有子元素。反之亦然。

规格见 [docs/zh-cn/stml-test-plan.md](docs/zh-cn/stml-test-plan.md)，C++ 侧的
上手教程（回调怎么写、12 条语法注意事项）见 [cpp/docs/stml.md](cpp/docs/stml.md)。

STML 可以用来管理相互调用的 Stope 程序，或实现面向对象等编程范式。

---

## 目录结构

```
stope-lang/
  docs/zh-cn/              语言标准（跨实现，不绑定任何一门语言）
    syntax-intro.md          语法入门
    syntax-reference.md      语法参考（完整规则与边界情况）
    syntax-impl.md           各模块的对外契约
    constant-folding.md      常量折叠规则
    lexer-test-plan.md       词法：字符流 → Token 流
    parser-test-plan.md      语法：Token 流 → AST
    compiler-test-plan.md    编译器：AST → Program
    stml-test-plan.md        STML：文本 → 元素树
    vm-guide.md              怎么写一个自己的执行器（指南，不是规范）
  cpp/                     C++ 实现（权威）
    include/stope/           19 个头文件，只放声明
    src/                     9 个编译单元 → build/libstope.a
    test/                    ctest 13 组
    demo/01-quick-start.cpp  嵌入示例
    demo/02-custom-opcode.cpp 自定义指令（只编译 + 反汇编）
    demo/03-stml.cpp         STML：把三种代码段切出来
    docs/                    实现侧文档：教程 3 份 + 测试计划 4 份 + expr_optim / basic_vm / development
  gdscript/                GDScript 原型实现（不建议使用）
```

四份 `*-test-plan.md` 是**行为契约**，不是 C++ 专属的测试说明：C++ 与 GDScript 两套实现都按它验证，  
期望值由 C++ 侧实测导出，不手推。

---

## 实现状态

|         | C++                      | GDScript   |
| ------- | ------------------------ | ---------- |
| 定位      | **权威实现**                 | 早期原型       |
| 布局      | Pitchfork Layout（编译型静态库） | Godot 工程   |
| 标准 / 依赖 | C++20，零第三方依赖             | Godot 4    |
| 测试      | ctest 13 组，1347 条断言全绿    | 2429 条断言全绿 |

两侧出现分歧时**以 C++ 的实测行为为准**，差异登记在对应测试计划的 §7。

> **`gdscript/` 不建议使用。** 它是早期原型，其中一部分 API 由 LLM 生成、**未经一致性设计**，接口混乱，且与 C++ 侧**暂未对齐**。

---

## 构建与测试（C++）

```bash
cd cpp
cmake -B build -G "MinGW Makefiles"
cmake --build build
ctest --test-dir build
./build/demo01.exe
```

只需要 CMake 和一个支持 C++20 的编译器。两个坑：

- 删过 `build/` 后**必须**显式写 `-G "MinGW Makefiles"`，否则 CMake 会误选 Visual Studio  
  并报 `No CMAKE_CXX_COMPILER could be found`。
- **不要加 `-DCMAKE_BUILD_TYPE=Release`**。优化后栈帧变小，8 组 `parser-depth-*`  
  里有 4 组"应当栈溢出"的用例反而不崩，测试会失败。

更多（含"源码编译失败时 ctest 仍报全绿"这类陷阱）见  
[cpp/docs/development.md](cpp/docs/development.md)。

---

## 嵌入你的程序

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

宿主函数怎么注册、入参怎么传、有哪些必踩的坑，见  
[cpp/docs/quick-start.md](cpp/docs/quick-start.md)。

---

## 文档导览

| 想看             | 去哪                                                               |
| -------------- | ---------------------------------------------------------------- |
| 语法入门           | [docs/zh-cn/syntax-intro.md](docs/zh-cn/syntax-intro.md)         |
| 完整语法规则与错误文案    | [docs/zh-cn/syntax-reference.md](docs/zh-cn/syntax-reference.md) |
| 常量折叠规则         | [docs/zh-cn/constant-folding.md](docs/zh-cn/constant-folding.md) |
| 各模块对外契约        | [docs/zh-cn/syntax-impl.md](docs/zh-cn/syntax-impl.md)           |
| 四份跨实现行为契约      | [docs/zh-cn/](docs/zh-cn/) 下的 `*-test-plan.md`                   |
| 嵌入 C++ 程序（四步）  | [cpp/docs/quick-start.md](cpp/docs/quick-start.md)               |
| 解析 STML 文档       | [cpp/docs/stml.md](cpp/docs/stml.md)                             |
| 构建 / 测试 / 行尾约定 | [cpp/docs/development.md](cpp/docs/development.md)               |
| 虚拟机（参考实现）      | [cpp/docs/basic\_vm.md](cpp/docs/basic_vm.md)                    |
| 自己实现一个虚拟机       | [docs/zh-cn/vm-guide.md](docs/zh-cn/vm-guide.md)                 |
| C++ 侧实现笔记      | [cpp/docs/](cpp/docs/) 下的 `*_test_plan.md`、`expr_optim.md`       |

---

## 许可证

MIT，见 [LICENSE](LICENSE)。
