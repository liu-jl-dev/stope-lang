# C++ 侧开发指南

> 布局、构建、测试、行尾、代码风格、API 参数约定、文档协作 —— 改动 `cpp/` 之前先看这一份。

| 想看 | 去哪 |
| --- | --- |
| 怎么在程序里嵌入 Stope | `quick-start.md`（本目录） |
| 虚拟机的约定 | `basic_vm.md`（本目录） |
| Lexer / Parser / Compiler / STML 的测试计划 | 四份 `*_test_plan.md`（本目录） |
| 语言的规格 | `../../docs/zh-cn/syntax-reference.md` |

---

## 1. 现状速览（2026-10-21）

| 项 | 值 |
| --- | --- |
| 布局 | **Pitchfork Layout（编译型）**，2026-10-19 起 |
| 头文件 | `include/stope/` 19 个，只放声明；自引用一律 `#include <stope/xxx.hpp>` |
| 编译单元 | `src/` 9 个 `*.cpp`：`ast` `ast_visitor` `compiler` `expr_optim` `lexer` `parse_binarr` `parser` `stml_lexer` `stml_parser` |
| 产物 | `add_library(stope STATIC ...)` → `build/libstope.a` |
| 测试 | ctest **14/14**：`lexer` `parser` `compiler` `ast_visitor` `stml` `vm` 六个目标 + 8 组 `parser-depth-*` |
| 示例 | `demo/01-quick-start.cpp` → 目标 `demo01`；`demo/02-custom-opcode.cpp` → `demo02`（都未接 ctest） |
| 依赖 | **零第三方**。C++20 |

19 个头文件里，只有 **`basic_vm.hpp` 与 `debug.hpp` 是 header-only**（内部全是 `inline`）；
`ast` `token` `opcode` `program` `custom_opcode` `scope_context` `common` 是零函数体的
纯数据头；其余 10 个的定义都在 `src/`。

> 2026-10-19 之前是 header-only 布局，已于当日迁移。**旧文档里若还写着
> 「`cpp/` 是 header-only」，是过期信息。**

---

## 2. 构建与测试

```bash
cd cpp
cmake -B build -G "MinGW Makefiles"
cmake --build build
ctest --test-dir build
./build/demo01.exe
```

### 2.1 五个坑（按踩到的频率排序）

1. **必须显式 `-G "MinGW Makefiles"`。** 删过 `build/` 后再 `cmake -B build`，
   CMake 会误选 Visual Studio 2022 并报 `No CMAKE_CXX_COMPILER could be found`。
   修的时候要连 `CMakeCache.txt` 与 `CMakeFiles/` 一起清。
2. **不要加 `-DCMAKE_BUILD_TYPE=Release`。** 优化后栈帧变小，8 组 `parser-depth-*`
   里有 4 组「应当栈溢出崩溃」的用例反而不崩 → 测试失败。默认（无优化）构建是对的。
3. **源码编译失败时 `ctest` 照样报「全部通过」** —— 它跑的是上一次的旧 exe。
   判断构建是否成功，**以 `cmake --build build` 的退出码为准**，不要看 ctest。
4. **崩栈的定位**：Bash 里跑 exe 只给 `exit=127` 且 stdout 因缓冲丢失，
   容易误判成「命令找不到」。要用 Windows 终端拿到
   `-1073741571`（0xC00000FD = STATUS_STACK_OVERFLOW），
   并给测试加 `setvbuf(stdout, nullptr, _IONBF, 0)` 才能看到崩溃前的进度。
5. **行号相关**：Windows 上 C++ 重定向输出是 CRLF、Godot 写出是 LF，
   golden 比对前要剥 `\r`。

### 2.2 深度阈值（实测，勿回退）

`(` 嵌套 **11500 层不崩 / 12000 层崩**。任何让递归多一层常驻栈帧的改动
都要回来复测 `parser-depth-*`。

---

## 3. header-only 文件的 ODR 约束

`include/stope/` 里 header-only 的文件（`basic_vm.hpp`、`debug.hpp`）以及
`test/test_common.hpp` 中的**任何非模板自由函数 / 命名空间变量**，
都必须 `inline` 或 `constexpr`，否则多 TU 链接会报 `multiple definition`。

同理，`ast.hpp` 里曾经的 `static const std::map<...> BinopPrecMap`
在每个 TU 各构造一份，已改成函数内的 `static`（`binopPrecMap()`）——
顺带避开静态初始化顺序问题。

---

## 4. 行尾与编码

2026-10-21 逐字节统计（Python 分开数 `\r\n` 与裸 `\n`，已排除 `.git` / `build`）：

| 位置 | 行尾 |
| --- | --- |
| `include/stope/*.hpp` | 多数 CRLF（`lexer.hpp`、`parse_binarr.hpp`、`utf.hpp`、`ast_visitor.hpp` 是 LF） |
| `include/stope/stml_lexer.hpp` | **混合**（66 CRLF + 22 LF） |
| `src/*.cpp` | LF |
| `test/test_common.hpp` | CRLF |
| `test/test_*.cpp`、`test_stml_common.hpp`、`test/utf.hpp` | LF |
| `cpp/docs/*.md`、`docs/zh-cn/*.md` | LF（例外：`docs/zh-cn/constant-folding.md` 是 CRLF） |
| `docs/zh-cn/syntax-impl.md` | **混合**（533 CRLF + 1 LF） |
| `CMakeLists.txt`、`demo/01-quick-start.cpp`、`.vscode/settings.json`、`cpp/.clang-format` | CRLF |
| `gdscript/**/*.gd` | LF；`gdscript/test/data/*.txt` 是 CRLF |

合计 101 个文件：全 CRLF 21、全 LF 78、混合 2。
（`stml_parser.hpp` 原是混合，2026-10-21 改成 `Lexer&` 时被编辑器统一成了全 LF。）

- **判断行尾不要用 `grep -c $'\r'`** —— 在 Git Bash 下换行被吞，所有文件都会显示成
  「全是 CRLF」，据此写结论会全错（这个坑 2026-10-21 踩过，当天的 §4 因此写错过一次）。
  用 `python -c "d=open(p,'rb').read(); print(d.count(b'\r\n'), d.count(b'\n'))"`。
- `stml_lexer.hpp`、`syntax-impl.md` 两个混合行尾的文件待统一。
- 仓库根 `.gitattributes` 是 `* text=auto`：提交时 git 把 CRLF 归一成 LF 存进索引，
  检出时再按平台转回来 ——「行尾不一致」在别的克隆 / CI 上会更明显。
- 改文件时保持原样，不要顺手做全文件换行转换；Python 改写用 `newline=''`。
- 源码里含中文时 MSVC 目标要 `/utf-8`（`CMakeLists.txt` 已按 `if(MSVC)` 加）。

---

## 5. 代码风格与格式化

### 5.1 现在生效的是什么

| 项 | 值 | 存在哪 |
| --- | --- | --- |
| 格式化器 | MS C/C++ 扩展自带的 clang-format（扩展 1.35.4 → clang-format 23.1.1） | 扩展目录 |
| 本仓库风格 | 直接读 `cpp/.clang-format` | **扩展默认值**，不需要任何工作区设置 |
| 全局默认风格 | `"C_Cpp.clang_format_style": "Chromium"` | **VSCode 用户级** `settings.json`，只影响别的项目 |
| 缩进显示 | `"[cpp]": { "editor.tabSize": 2 }` | 同上（用户级） |
| 保存时格式化 | 未开（用户设置里没有 `editor.formatOnSave`） | — |

只有手动 `Shift+Alt+F` 才会跑。工作区设置**覆盖**用户设置，所以在这个仓库里按
`Shift+Alt+F` 用的是 `cpp/.clang-format`（见 §5.4），而不是全局的 `Chromium`。

`C_Cpp.clang_format_style` 的默认值就是 `"file"`（已在 cpptools 1.35.4 的
`package.json` 里核对），所以**新克隆的仓库什么都不用配**：只要 `cpp/.clang-format`
在，编辑器与命令行 `clang-format -i` 都会按它格式化。

因此 `.vscode/` 属于**编辑器私有目录**，已在 `.gitignore` 里，**不提交** —— 它混着
`${env:VCPKG_ROOT}` / `${env:VULKAN_SDK}` 这类依机器的 `includePath`，提交上去等于把
个人环境塞给别人。项目约定一律放在仓库级配置里：格式化 → `cpp/.clang-format`，
行尾 → `.gitattributes` 的 `* text=auto`。

（例外：如果团队统一 VSCode，想让 `tasks.json` / `launch.json` 或 `files.eol`、
`editor.formatOnSave` 这类设置开箱即用，可以提交一份**只含项目约定、不含个人路径**
的 `.vscode/settings.json`。）

### 5.2 Chromium 到底规定了什么（clang-format 23 实测）

| 项目 | Chromium | LLVM 默认（对照） |
| --- | --- | --- |
| 缩进 / Tab | 2 空格，`UseTab: Never` | 同 |
| 行宽 | 80 | 同 |
| 大括号 | 不换行（`Attach`） | 同 |
| 指针 | `int* p`（`PointerAlignment: Left`） | `int *p` |
| `public:` / `private:` | 缩进 1 格 | 不缩进 |
| `case` 标签 | 在 `switch` 内部缩进 | 与 `switch` 齐平 |
| 短函数体 | 强制换行（`AllowShortFunctionsOnASingleLine: Empty`） | 压成一行 |
| 中文注释 | **会被重排**（按字节算列宽） | 同 |

最后一条是这套设置里唯一的真坑：一个汉字 3 字节，clang-format 当成 3 列，于是
80 列的换行落在句子中间，还会把相邻的两行注释并成一行。实测：

```cpp
// 输入
// 这一行是一个很长的中文注释，用来观察 clang-format 是按字节还是按显示宽度计算列数。
// 第二行注释
// 输出（ReflowComments 默认 true）
// 这一行是一个很长的中文注释，用来观察 clang-format
// 是按字节还是按显示宽度计算列数。 第二行注释
```

`ReflowComments: false` 才保持原样 —— 仓库的 `cpp/.clang-format` 已经这么设了（§5.4），
工作区设置也已经指向它。

### 5.3 为什么必须有仓库级配置

只靠用户级设置，CLI `clang-format -i`、CI、别人的编辑器（CLion / VS / vim）都会落到
**LLVM 默认**，也就是上表右列 —— 指针、`case`、短函数全被改成另一种样子。

量化过：不加 `cpp/.clang-format` 时，53 个 C++ 文件里有 **39 个**会被
`--style=Chromium` 改动；加上之后降到 **36 个**，再顺手格式化 `basic_vm.hpp` 后是 **35 个**。
剩下的都是零碎小改动（短的 `struct` 定义被合成一行、`custom )` 这类多余空格、
`}` 补 `// namespace` 注释、行尾注释重新对齐）。

### 5.4 仓库配置：`cpp/.clang-format`

```yaml
BasedOnStyle: Chromium
IndentWidth: 2
ColumnLimit: 80
SortIncludes: Never    # include 是按依赖顺序写的，字母序重排会看不出依赖
ReflowComments: false  # 中文注释按字节算列宽，重排会把句子拆错
```

放在 `cpp/` 而不是仓库根：clang-format 从被格式化文件所在目录往上找，`cpp/` 正好
覆盖全部 C++ 源码，不会波及 `gdscript/`。

实测（`--style=file`）：`core.hpp` 的 `parser.hpp` / `compiler.hpp` 顺序保持不变，
§5.2 那段中文注释原样保留，`int* q` 仍是 `int* q`。

本仓库的 `.vscode/settings.json` 已经设成 `"C_Cpp.clang_format_style": "file"`，
工作区设置覆盖用户设置，所以打开这个仓库就直接按上面这份配置格式化。
**别把用户级设置也改成 `"file"`** —— 那会让所有项目都去逐级找 `.clang-format`，
没有这个文件的工程就落到 LLVM 默认。

落地时**不要**顺手 `clang-format -i .` —— 会一次改 35 个文件把 diff 弄脏；
按「改到哪个文件就格式化哪个」推进。`include/stope/basic_vm.hpp` 已按这份配置格式化过，
可以拿它对照效果。单文件校验：

```bash
cd cpp
clang-format --style=file --dry-run --Werror include/stope/basic_vm.hpp
```

VSCode 里格式化按钮的等价效果，就是 `--style=file`（改完设置之后）。

---

## 6. 文档协作

### 6.1 分工

| 文档 | 记什么 |
| --- | --- |
| `../../docs/zh-cn/*` | 跨实现通用的**规格与契约**（语法、测试计划） |
| `lexer_test_plan.md` / `parser_test_plan.md` / `compiler_test_plan.md` / `stml_test_plan.md` | 各模块**测了什么** + 缺陷编号 |
| `expr_optim.md` | 常量折叠的规则总表 |
| `basic_vm.md` | 虚拟机的语义约定 |
| `quick-start.md` | 嵌入 Stope 的四步 |
| `custom-opcode.md` | 自定义指令：注册 → 编译 → 反汇编 |
| `stml.md` | STML 文档解析：回调决定内容模式 + 语法注意事项 |
| 本文 | 布局 / 构建 / ODR / 行尾 / **代码风格** / 文档约定 |

跨实现文档里，**`../../docs/zh-cn/syntax-impl.md` §7.2** 记着 `ASTVisitor` 这副遍历骨架
怎么用（继承它写解释器 / 检查器）—— 它属于「AST 长什么样」，不是 C++ 侧工程约定。

**实现侧的「为什么这么做」写在对应主题的文档里，不要另建笔记文件。**
（2026-10-21 之前有一份 `notes.md` 收这类内容，已按主题拆分并删除。）

### 6.2 缺陷编号

跨文档一致：`PD-x`（Parser）、`CD-x`（Compiler）、`D-x`（Lexer）、`TD-x`（STML）。

### 6.3 文件名

`docs/zh-cn/`、`cpp/docs/`、`gdscript/docs/` 的文件名**一律 ASCII kebab-case**，
目录名可以是 `zh-cn`。中文标题放在文件的一级标题里即可 —— 这样链接里不会再出现
`%20` 与 `%E8%AF%AD…`。

改文件名后要按「任意非 ASCII 字符 + `.md`」再扫一遍残留引用，
不能只 grep 已知的旧名（子串匹配会漏，例如 `测试执行说明.md` 里没有 `测试说明.md`）。

### 6.4 路径写法

文档里写路径时：

- 本目录内的文件写**裸名**（`basic_vm.md`）
- 仓库根下的写 `../../docs/zh-cn/xxx.md`
- `cpp/` 下的写 `cpp/docs/xxx.md`

不要写既非裸名也非根相对的 `docs/xxx.md` —— 在 `cpp/docs/` 里它会解析成
`cpp/docs/docs/` 而失效。

### 6.5 示例必须真跑

文档里的示例**必须真跑一遍再写**。`quick-start.md` §7 的骨架就是直接从文档代码块
里抽出来编译验证过的。

---

## 7. API 参数与所有权

clang-format 管不了的「风格」在这里定死，改接口前先对一遍。

### 7.1 参数：必填用引用，只有可空才用指针

| 情况 | 写法 | 例子 |
| --- | --- | --- |
| 必填的输入 / 输出 | **引用**（改不改由 `const` 标注） | `Lexer` 由 `Parser(Lexer&, ...)` 借用、`ParseProgram(AST::Prog&)`、`Compile(AST::Prog&, Program&)`、`Arguments::at(..., Value& out)` |
| 真正可以为空的依赖 | 指针，默认 `= nullptr` | `Parser(..., CustomOpcodeConfig* = nullptr)`、`Compiler(const CustomOpcodeConfig* = nullptr)` |
| 会被改的借用对象 | 非 const 指针 / 引用 | `Parser` 持有 `Lexer*`（要 `NextToken()` 推进位置） |

不用指针表达「必填」：`Program* out` 里那个 `*` 只会让调用方多写一个 `&`，
还会让人误以为可以传空。反过来，可空的东西也不要写成 `T&`——调用方没法表达「没有」。

`const` 按**是否修改**标：`Compile(AST::Prog& ast, ...)` 是非 const，因为
`ASTVisitor::Visit(AST::Node*)` 收非 const 指针（折叠等操作可能改写节点），不是忘了写。

**构造参数用引用、成员却存指针是可以的**：`Parser(Lexer& lexer)` 只是声明「不能传空」，
构造体里仍写 `this->lexer = &lexer`。指针成员表达的是「借用、不拥有」，与参数是否可空无关。

### 7.2 配置只在构造函数注入一次

`Compiler` 的自定义指令配置只有一个入口：`Compiler(const CustomOpcodeConfig*)`。
**不要再给 `Compile` 加同义参数**——2026-10-21 之前就有过，`Compile` 的默认实参
`nullptr` 会把构造时传的配置覆盖掉，属于「传了等于没传」的静默 bug。需要换配置就新建
一个 `Compiler`。

### 7.3 所有权：谁声明，谁持有

- 前端全部是**借用**：`Parser` 不拥有 `Lexer`，`Compiler::prog` 不拥有 `Program`，
  `State` 的 `alloc` / `program` / `api` / `args` 都是借来的指针。
  宿主必须保证这些对象活得更久 —— 典型顺序是 `alloc` → `constants` → `state`。
- `Lexer(std::u16string_view)` **不拷贝源码**，`src` 必须活得比 `Lexer` 长。
- 需要「传进来还要留着」的地方不用 `unique_ptr` 成员，直接在文档里写清生命周期，
  保持结构体可平凡移动。

### 7.4 历史

2026-10-21：`Compile(AST::Prog*, Program*, const CustomOpcodeConfig*)` 改成
`Compile(AST::Prog&, Program&)`，并把 `custom` 收敛到构造函数。改这条时只有
demo / `test_compiler.cpp` / `gdscript/test/tools/golden.cpp` 三处调用点 ——
接口虽然公开，但用的人少，趁早改比拖到以后便宜。

同日：`Parser(Lexer*, ...)` 改成 `Parser(Lexer&, ...)`，`STML::Parser` 同步。
`customOpcodeConfig` 因为真的可空，仍是 `CustomOpcodeConfig* = nullptr`；`Parser` 内部的
`lexer` 成员也仍是 `Lexer*`（借用语义）。
