# 变更历史

本文件记录 **Stope 语言**（含标准范围内的语言、STML、编译器产物 `Program`）与仓库内八份实现的变更。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循
[语义化版本](https://semver.org/lang/zh-CN/)。

## 版本规则

### 什么时候升哪一位

| 位 | 触发条件 | 例 |
| --- | --- | --- |
| **主版本** `X.0.0` | 不兼容变更：删除或改写既有语法、改变 `Program` 的字段含义或指令编码、改变内置指令的集合或编号、改变已有公开 API 的签名 | `0.9.0` → `1.0.0` |
| **次版本** `0.X.0` | 向后兼容的新增：新语法、新公开 API、新的编译期能力（不改变 `Program` 语义）、**新增一份实现** | `0.1.0` → `0.2.0` |
| **修订号** `0.0.X` | 向后兼容的缺陷修复与文档修正 | `0.1.0` → `0.1.1` |

内置指令只有 33 条（`Assign=0` … `Return=32`），宿主自定义指令从 33 起编号 —— 所以
**内置指令集只可能整体改变，不存在“追加一条”**：那会与已注册的自定义指令撞号，按主版本处理。

### 0.x 期间的承诺

`0.x` 期间语法与公开 API 仍可能调整：不兼容变更**升次版本号**（`0.1.0` → `0.2.0`）并在对应
版本的「变更」小节里标注。`1.0.0` 起承诺 `1.x` 内保持兼容，不兼容变更只能升主版本 —— 覆盖
三件标准（语言 / STML / `Program`）、八份实现的公开 API，以及**内置 BasicVM 的公开接口**。

BasicVM 不属于标准（见 [`cpp/docs/basic-vm.md`](cpp/docs/basic-vm.md) §1.1）—— 换一台执行器
可以完全不用它；但本仓库自带的这一台会一直维护，`1.x` 内 `Api` / `State` / `Value` 这些
公开名字与调用方式只增不减、不改签名。

### 为什么全仓只用一个版本号

八份实现由同一批 golden 用例（`gdscript/test/data/`）与跨实现差分测试绑成一个行为整体，
`Program` 的字节序列本身就是跨实现的契约 —— 按实现各自定版本没有意义。

正式版本用 annotated tag 锚定，tag 名带 `v` 前缀（`v0.1.0`）；五个实现内的版本字段**不带**
`v`，因为 CMake 的 `project(... VERSION ...)` 只接受数字。

### 落点与校验

版本号共六处，一致性由零依赖脚本守护：

| 落点 | 位置 |
| --- | --- |
| C++ | `cpp/CMakeLists.txt` 的 `project(Stope VERSION ...)` |
| GDScript | `gdscript/addons/stope/plugin.cfg` 的 `version` |
| Node.js | `nodejs/package.json` 的 `version` |
| C# | `csharp/Stope/Stope.csproj` 的 `<Version>` |
| Python | `python/stope/__init__.py` 的 `__version__` |
| 本文件 | 第一个纯版本号标题 `## [x.y.z]`（`[Unreleased]` 不计） |

```bash
python tools/check_version.py          # 全部一致才返回 0
python tools/check_version.py 0.2.0    # 发版前预检：与期望值比较
```

## [Unreleased]

### 新增

- **三份新实现**：Lua（`lua/`，Lua 5.4+）、Go（`go/`，1.27+）、Rust（`rust/`，edition 2021）。
  与既有五份读同一批 golden 用例（`gdscript/test/data/`，词法 147 / 语法编译器 201 /
  BinArr 86 / STML 126 / 反汇编 12 条），demo01–04 输出与既有实现逐字节一致；均为零第三方依赖。
- **移植指南**：[docs/zh-cn/porting-guide.md](docs/zh-cn/porting-guide.md) —— 实施顺序、golden 验收、
  跨语言语义坑与八份实现各自的专有坑、交付前检查单。
- **API Reference**：[docs/zh-cn/api-reference.md](docs/zh-cn/api-reference.md) —— Lexer / Parser /
  Compiler / Program / BasicVM / STML 的接口形状在八份实现中的对照与差异登记。

### 变更

- **GDScript 的 `State.Step()` / `Run()` 返回类型从 `bool` 改为 `StopeResult`**，
  消除八份间唯一的无故差异（其余七份本就返回 `Result`）。顺带对齐一处语义：
  指令流走完（`i` 越过末尾）后 `step()` 现在返回 `Success`，与 C++ 一致 ——
  原 GDScript 实现返回 `false`（= Error）；出错停机后再 `step()` 仍返回
  `Error`（`errors` 非空），两种情形靠 `errors` 区分。
- **删除 `BasicVM.State.Reset`**：装配改为分立注入器 `SetAPI` / `SetProgram` /
  `SetArguments`（snake_case 实现为 `set_api` / `set_program` / `set_arguments`），
  与 C++ 的五个分立 `SetXXX` 同构 —— `Stope` 不规定如何装配程序，`args` 是可选依赖，
  不再占构造签名。`SetProgram` 负责按 `variable_num` 开槽位、`i` 归零、清运行态
  （C++ 仍由宿主 `resize`，不变）。GDScript 的 `set_args` 更名 `set_arguments`。
- `Element` 新增 `textLine`（内容首行的物理行号，无内容 -1）：STML 词法器切内容前会跳过
  前导空白（含换行），宿主把它设给 `Lexer` 的起始行号，报错行号即与原文档对齐。
  配套：C# 的 `Lexer.Line` 由只读属性改为可读写；测试形状串的文本段写成 `T(L<n>)="…"`；
  STML 用例清单加 `PARSE-PL-05`（126 条）。

## [0.1.0] - 2026-11-03

首个正式版本。以下内容构成 0.1.0 的**完整能力边界** —— 没有列进来的，就是不支持
（比如没有标准库、没有函数定义、没有自定义数据类型）。

### 新增

**标准（三件）**

- **Stope 语言**：平铺语句序列、六种值类型（整数 / 浮点 / 字符串 / 二进制数组 / 布尔 / `null`）、
  `let` / `export`、`while` / `if`、`break` / `continue`、多值 `return`、宿主提供的 `argc` / `args[i]`。
  语义细节见 [docs/zh-cn/syntax-reference.md](docs/zh-cn/syntax-reference.md)。
- **STML**：写法像 XML 的标记语言，四态词法（Xml / Text / Nevext / Stope），元素的文本与子元素互斥、
  属性可无值、无字符实体；代码段原样切出来交给宿主。
  见 [docs/zh-cn/stml-test-plan.md](docs/zh-cn/stml-test-plan.md)。
- **编译器产物 `Program`**：指令序列 + 常量池 + 变量槽数 + 导出表 + 跳转回填规则，
  33 条内置指令（`Assign=0` … `Return=32`）。见
  [docs/zh-cn/compiler-test-plan.md](docs/zh-cn/compiler-test-plan.md) §2。

**编译器能力**

- 常量折叠：全字面量表达式在**解析期**求值（含算术、比较、串连接 / 重复、BinArr 运算）。
- 自定义指令：宿主可注册操作码（编号 ≥ 33）、定长或变长参数，参与编译与反汇编。
- 预导出（`preExports`）：`Compile` 的第三参，在遍历 AST 之前先占好变量槽位，供 STML 标签的
  `params` 之类的外部参数表使用。见 [docs/zh-cn/pre-export.md](docs/zh-cn/pre-export.md)。
- 嵌套深度上限：Parser 与 STML 解析默认 256 层（`0` = 不限），超限只报一条并中止。

**八份实现**（C++ 为权威，其余四份逐项对齐；期望值全部由 C++ 探针 dump，不手写）

- C++（`cpp/`）：C++20、零第三方依赖、CMake 静态库。
- GDScript（`gdscript/`）：Godot 4 插件，纯库、无编辑器 UI。
- Node.js（`nodejs/`）：零依赖 ESM 包，整数用 `BigInt` 对齐 int64。
- C#（`csharp/`）：.NET 10 类库，零 NuGet 包。
- Python（`python/`）：Python 3.9+，只用标准库。

**内置基础虚拟机**（不属于标准，但会维护、接口不随意调整）

- 33 条内置指令的执行器，六种可观测值，句柄 + 引用计数管理字符串 / 二进制数组。
- 宿主函数、`Step()` 单步、`returns` 多返回值。
- 明确的**不支持**：自定义指令（只实现编号 0–32，产物里 ≥ 33 的编号没有实现）、
  自定义数据类型（无对象 / 结构体 / 类）。

**工具与示例**

- 反汇编器 `Disasm` / `DisasmNoCustom`（单行格式由各实现的测试工具决定，不在库内）。
- `cpp/tools/` 下的 golden 探针：词法 / 语法编译器 / STML / 反汇编的期望值由它生成，
  五份测试共用 `gdscript/test/data/` 那一份数据。
- 四个可运行示例：`01` 编译 + 运行、`02` STML 解析、`03` 自定义指令、`04` 预导出。

**文档**

- 跨实现契约：`docs/zh-cn/` 下四份 `*-test-plan.md` + `syntax-*.md`、`constant-folding.md`、
  `vm-guide.md`、`pre-export.md`、提交信息规范。
- 各实现的上手教程、API 用法、STML 与自定义指令文档、测试说明。

### 说明

- 版本号首次同步到八份实现（此前只有 npm 包与 Godot 插件写了 `0.1.0`）。
- Stope 不规定虚拟机标准：`Program` 之后的执行方式、值表示、栈布局由实现者决定，
  内置虚拟机只是一种可行解。

[Unreleased]: https://github.com/liu-jl-dev/stope-lang/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/liu-jl-dev/stope-lang/releases/tag/v0.1.0
