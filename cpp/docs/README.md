# C++ 实现 · 总览

`cpp/` 是 Stope 的**权威实现**：语言语义、`Program` 的产物格式、STML 的规则，
都以这一侧的实测行为为准。零第三方依赖，C++20，CMake 构建，产出静态库 `libstope.a`。

其它实现（[GDScript](../../gdscript/docs/README.md)、[Node.js](../../nodejs/)）
都按它**逐项对齐**；出现分歧时以 `include/stope/*.hpp` 的行为为准，差异登记在
[`docs/zh-cn/*-test-plan.md`](../../docs/zh-cn/) 的 §7 里。

> **本文件是给"想用 Stope / 想了解 C++ 这一侧"的人看的。**
> 要改 `cpp/` 的实现，去 [`development.md`](development.md)（布局 / 构建 / 测试 /
> 行尾 / 代码风格 / API 约定）—— 那份是给开发者看的，本文件不重复它的内容。

---

## 1. 这个目录里有什么

### 上手教程（配 `../demo/` 下可运行的示例）

| 文件 | 讲什么 |
| --- | --- |
| [`quick-start.md`](quick-start.md) | 四步把 Stope 嵌进自己的程序：编译 → 装配 → 执行 → 取返回值 |
| [`stml.md`](stml.md) | STML 文档怎么解析：树的形状归解析器，内容怎么切归宿主 |
| [`custom-opcode.md`](custom-opcode.md) | 给编译器加自己的指令：登记 → 编译 → 反汇编 |
| [`basic_vm.md`](basic_vm.md) | 内置参考执行器的语义约定（**不属于标准**，见 §3） |

### 实现笔记（改 `cpp/` 时才需要）

| 文件 | 讲什么 |
| --- | --- |
| [`development.md`](development.md) | 布局、构建与两个构建陷阱、行尾、代码风格、API 参数与所有权约定 |
| [`expr_optim.md`](expr_optim.md) | 常量折叠的规则总表（哪几种组合折、怎么折、与执行器怎么对齐） |
| 四份 `*_test_plan.md` | 词法 / 语法 / 编译器 / STML 的**实现笔记与缺陷流水** |

> ⚠ **两份"测试计划"不是一回事**，文件名只差一个字符：
>
> | 位置 | 命名 | 给谁 |
> | --- | --- | --- |
> | `docs/zh-cn/*-test-plan.md` | 连字符 | **跨实现的行为契约** —— 所有实现都该满足，给所有人看 |
> | `cpp/docs/*_test_plan.md` | 下划线 | **C++ 侧自己的**实现笔记、缺陷编号、踩坑记录，给改实现的人看 |

## 2. 从哪开始

| 我想…… | 去哪 |
| --- | --- |
| 在 C++ 程序里跑一段 Stope 脚本 | [`quick-start.md`](quick-start.md)（配 `demo/01-*.cpp`） |
| 单步执行 / 自己写调试器 | [`basic_vm.md`](basic_vm.md) §1（`State::Step()` 的终止条件与错误态约定） |
| 解析一份 STML 文档 | [`stml.md`](stml.md)（配 `demo/02-*.cpp`） |
| 给编译器加一条自己的指令 | [`custom-opcode.md`](custom-opcode.md)（配 `demo/03-*.cpp`） |
| 查 Stope 的语法与错误文案 | [`docs/zh-cn/syntax-reference.md`](../../docs/zh-cn/syntax-reference.md) |
| 查 Stope 从零开始的介绍 | [`docs/zh-cn/syntax-intro.md`](../../docs/zh-cn/syntax-intro.md) |
| 查常量折叠会折掉什么 | [`docs/zh-cn/constant-folding.md`](../../docs/zh-cn/constant-folding.md) |
| 查某个行为究竟怎么定 | [`docs/zh-cn/`](../../docs/zh-cn/) 下四份 `*-test-plan.md` |
| 自己写一个执行器 | [`docs/zh-cn/vm-guide.md`](../../docs/zh-cn/vm-guide.md) |
| 改 `cpp/` 的实现 | [`development.md`](development.md) |
| 刷新 GDScript 测试的期望值 | `cmake --build build --target gen-golden`（探针在 `tools/`） |
| 从仓库根看全貌 | [`README.md`](../../README.md) |

## 3. 标准范围（哪些是规范，哪些只是示例）

标准只有三项：**Stope 语言**、**STML**、`Program` 的**产物格式**。
`include/stope/` 里对应的头文件才是规范的一部分；下面这些**不是**：

- `basic_vm.hpp` / `debug.hpp` —— 参考执行器与反汇编器。指令怎么执行、栈怎么布局、
  宿主函数怎么约定，都**不由标准规定**，换一个执行器完全可以。
- `demo/` 下的三个示例 —— 只是演示调用顺序，不是官方用法模板。

理由与边界见根 [`README.md`](../../README.md)；自写执行器的指引见
[`docs/zh-cn/vm-guide.md`](../../docs/zh-cn/vm-guide.md)。

## 4. 目录

```
cpp/
  include/stope/   公共头文件，只放声明（basic_vm.hpp / debug.hpp 例外，header-only）
  src/             编译单元（.cpp）
  test/            ctest 用例，按模块分成多个二进制
  tools/           golden 数据生成器（gen-golden 用；不属于标准，不进 ctest）
  demo/            01-quick-start / 02-stml / 03-custom-opcode 三个可运行示例
  cmake/           run_gen.cmake（gen-golden 的驱动脚本）
  docs/            本目录
  CMakeLists.txt   libstope.a + 各测试目标 + demo 目标 + gen-golden
```

## 5. 构建与测试

```bash
cd cpp
cmake -B build -G "MinGW Makefiles"
cmake --build build
ctest --test-dir build                        # 全绿即通过（用例数会随实现增长）
./build/demo01.exe                            # 三个示例之一
cmake --build build --target gen-golden       # 重生成 GDScript 侧的期望值，不属于 ctest
```

`gen-golden` 只在改了 C++ 行为、或给测试加用例时才需要。GDScript 侧跑测试本身
**不需要 C++**（`data/*.txt` 已入库）。

当前状态：`ctest` 全绿。构建细节与两个坑（删过 `build/` 后必须显式写 `-G`、
**不要**加 `-DCMAKE_BUILD_TYPE=Release`）写在 [`development.md`](development.md) §2，
根 [`README.md`](../../README.md) 也有一份同样的速查。

## 6. 文档

| 想看 | 去哪 |
| --- | --- |
| 本目录（面向所有人） | 本文 |
| 改动 `cpp/` 的注意事项（面向开发者） | [`development.md`](development.md) |
| C++ 侧各模块对外接口的总表 | [`docs/zh-cn/syntax-impl.md`](../../docs/zh-cn/syntax-impl.md) |
| 跨实现的行为契约 | [`docs/zh-cn/`](../../docs/zh-cn/) 下四份 `*-test-plan.md` |
| GDScript 实现 | [`gdscript/docs/README.md`](../../gdscript/docs/README.md) |
| 从仓库根进入 | [`README.md`](../../README.md) |
