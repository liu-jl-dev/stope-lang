# 变更历史

本文件记录 **Stope 语言**（含标准范围内的语言、STML、编译器产物 `Program`）与仓库内五份实现的变更。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循
[语义化版本](https://semver.org/lang/zh-CN/)。版本号在五处保持同步：

| 实现 | 位置 |
| --- | --- |
| C++ | `cpp/CMakeLists.txt` 的 `project(Stope VERSION ...)` |
| GDScript | `gdscript/addons/stope/plugin.cfg` 的 `version` |
| Node.js | `nodejs/package.json` 的 `version` |
| C# | `csharp/Stope/Stope.csproj` 的 `<Version>` |
| Python | `python/stope/__init__.py` 的 `__version__` |

## [Unreleased]

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

**五份实现**（C++ 为权威，其余四份逐项对齐；期望值全部由 C++ 探针 dump，不手写）

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

- 版本号首次同步到五份实现（此前只有 npm 包与 Godot 插件写了 `0.1.0`）。
- Stope 不规定虚拟机标准：`Program` 之后的执行方式、值表示、栈布局由实现者决定，
  内置虚拟机只是一种可行解。

[Unreleased]: https://github.com/liu-jl-dev/stope-lang/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/liu-jl-dev/stope-lang/releases/tag/v0.1.0
