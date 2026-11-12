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

版本号共八处，一致性由零依赖脚本守护（Go 用 git tag，无版本字段）：

| 落点 | 位置 |
| --- | --- |
| C++ | `cpp/CMakeLists.txt` 的 `project(Stope VERSION ...)` |
| GDScript | `gdscript/addons/stope/plugin.cfg` 的 `version` |
| Node.js | `nodejs/package.json` 的 `version` |
| C# | `csharp/Stope/Stope.csproj` 的 `<Version>` |
| Python | `python/stope/__init__.py` 的 `__version__` |
| Rust | `rust/Cargo.toml` 的 `version`（0.2.0 起纳入） |
| Lua | `lua/stope/init.lua` 的 `stope.version`（0.2.0 起纳入） |
| 本文件 | 第一个纯版本号标题 `## [x.y.z]`（`[Unreleased]` 不计） |

```bash
python tools/check_version.py          # 全部一致才返回 0
python tools/check_version.py 0.2.0    # 发版前预检：与期望值比较
```

## [0.5.1] - 2026-11-12

### 修复

- **GDScript 门面引用的文档同步**：57e0459 去掉全部 `class_name`、改
  `stope.gd` 门面后，api-reference（§0 入口表与 §1/§2/§3/§5.1 类型行）、
  lexer-test-plan（§7 与 C++↔GDScript 对照表）、stml-test-plan（结果枚举行）、
  compiler-test-plan（`has_a_param` 判定）仍按旧全局类名（`StopeLexer` /
  `StopeResult` 等）引用，统一改为门面 preload 访问（`Stope.Lexer.Lexer` /
  `Stope.Result.Success` 等）。纯文档改动，零代码变更。
- **lua/README 补「在 stope 中使用 nevext 的字符串」**：nevext 字符串是
  UTF-8 裸字节串、stope（Lua 版）是 UTF-16LE + `str_value` 包装，补形态对照、
  两个方向的 `stope.utf` 转换公式、nevext 解析 → Stope 值 → 取回的完整示例
  与编码 / 代理区 / 开销注意点。

## [0.5.0] - 2026-11-12

### 新增

- **`\uXXXX` 转义（八份）**：字符串字面量新增 4 位十六进制码点转义（大小写均可），
  对齐 [nevext](https://github.com/liu-jl-dev/nevext) 的 NevextEscape。不足 4 位或含
  非十六进制位报 `invalid escape character.` 并截断已展开前缀。码点按 UTF-16 码元
  落盘、不组合代理对；代理区码点落盘方式各实现按各自运行时规则（Go 落 U+FFFD、
  Rust 判非法，其余原样落码元），不建议在脚本里依赖。向后兼容：只有 `\u` 从非法
  变合法。golden 重生成 147→153 条（新增 LEX-S-10…S-15），八份全部逐字节通过。

## [0.4.0] - 2026-11-09

### 新增

- **defer 语句（八份）**：`defer <语句|块>` 把载荷登记到当前块，在退出点
  （块尾 / `break` / `continue` / `return` / 程序结束）结算。**零新指令**——
  编译期把载荷拼接到每个出口，次序为「结算 → PushValue → Return」；同块
  后进先出，内层块先于外层块；读变量当前值；名字绑定冻结在 defer 语句处
  （引用后文声明的名字绑定宿主变量，不报错）。语义权威：[syntax-reference.md 的 defer 小节](docs/zh-cn/syntax-reference.md)。
- **语法教程** [docs/zh-cn/syntax-tutorial.md](docs/zh-cn/syntax-tutorial.md)：
  由易到难九讲，每个示例配真实反汇编并逐行解读（15 个反汇编块由探针真实
  生成并逐块校验，非手写）。
- **待定夺与决定记录** [docs/zh-cn/open-questions.md](docs/zh-cn/open-questions.md)：
  跨实现设计取舍的统一登记处（状态三档：待定夺 / 已定夺未落地 / 已落地）。

### 变更

- **defer 前向引用改为绑定宿主变量（八份，OQ-8）**：载荷引用的名字按
  `defer` 语句位置的可见性解析；不可见的名字（含后文声明的本地名）不再
  报错（原 `"X" is declared after the defer statement.`）、也不被捕获，
  按隐式导出宿主变量处理。后文块内声明的同名本地变量与载荷互不相干；
  后文顶层 `let` / `export` 同名则报 `duplicate export`（重名冲突）。
- **编译产物死代码消除（八份）**：语句终止标志局部判定（无 CFG）——`return`
  / `break` / `continue` 之后的语句、体终止的 while 回跳、体终止的 if 分支尾
  `GoTo`、以 return 结尾时 Return 之后的 defer 程序尾副本不再发射。运行结果
  零变化，产物更小；死代码里的隐式导出不再登记、编译错误不再上报。
  `while { }`（无条件且无 break）仍是唯一被认定的死循环；字面量条件折叠
  （`if true` / `while 0.0` 等）**未定夺**（OQ-2）。
- **golden 重生成（201 → 216 条）**：CM-44 / 51 / 52 / 53 随死代码消除更新；
  新增 DF-01…DF-15 defer 用例。八份实现的测试全部逐字节通过。
- **字面量条件折叠（八份，OQ-2）**：`if` / `elif` / `else` / `while` 的条件为
  字面量常量（含解析期折叠出的，如 `1 < 2`）时按语言真值表静态判定——常量真
  只发该分支（零条件、零跳转指令），常量假整支（`while` 则整环）消除；
  `while true` 折叠为无条件循环，其后语句按不可达处理（体里有 `break` 则不算
  死循环）。判定在编译器层：AST 结构不变，只有产物字节变；被消除分支中的
  语句不编译（名字不占槽位、defer 不登记）。golden 新增 CF-01…CF-08（224 条）。
- `defer` 成为关键字（占用原可用作标识符的名字——0.x 次版本兼容承诺内）。

## [0.3.1] - 2026-11-07

### 修复

- **quick-start 路由补全（七份）**：demo 清单在 0.3.0 长到六个，各实现的
  quick-start「下一步」未同步——gdscript/nodejs 索引表与「下一步」停留在
  demo01–03；csharp/python 缺 demo04–06 路由；lua 没有路由节；go 的「更多」
  指向了 python 的文档（错链）且 STML 指到测试计划而非教程；rust 未提任何
  配套教程。统一补齐 demo02–06 各自专文的可达路由，并注明完整教程以
  `cpp/docs/` 为权威。纯文档改动，零代码变更。

## [0.3.0] - 2026-11-06

### 新增

- **demo06 宿主侧垃圾回收（八份）**：宿主自建引用计数 + 标记清除，管理挂在
  BasicVM `Value::Handle` 缝上的宿主对象。裸侵入式循环双向链表（gc 头内嵌
  对象，无数组中转）；引用计数 = 字段引用（`SetField` 精确维护）+ 根引用
  （安全点同步，**先加后删**）；安全点 = 每个 `obj:*` 开口入口 + Collect 入口；
  循环引用等标记清除裁决；节点上限 `maxNodes`（顶到上限先 Collect 仍不够
  则开口报 `too many gc nodes.`）。八份实现各配一篇 `docs/gc.md`，
  语义权威在 [cpp/docs/gc.md](cpp/docs/gc.md)。
- **demo05 存活对象上限 `maxObjects`（八份）**：0 = 不限（对齐 Parser / STML
  `maxDepth` 约定），顶到上限构造器报 `too many objects.`，走 Stope 正常
  错误通道。
- **帧栈执行模型（八份，demo05/06）**：宿主显式 `State` 帧栈取代递归调用栈
  ——方法调用压帧、返回弹帧；`RunSteps(maxSteps)` 每帧限步（弹栈不消耗
  步数，预算跨嵌套调用共享）与 `RunAll()` 一口气跑完两种驱动随时可切；
  析构 `<delete>` 保持同步旁路（级联释放中间不能让出执行权）。游戏嵌入的
  「每帧限步」与单步调试由此成立。

### 变更

- **删 demo06 的 `gc:Collect` 宿主函数**：宿主本来就能直接调 `Collect()`，
  注册成 VM 函数只是让脚本能「主动要求 gc」，却让每份移植版都背一条桥接
  通道。gc 时机完全归宿主帧循环（demo6 每 25 帧一次 Collect）；顺带删
  `gcTrigger` 死代码。八份 README 导览同步（demo06 + gc.md）。
- **BasicVM 库公开 API 零改动**：`State` / `Value` / `Api` 签名、指令集、
  `Program` 编码不变 —— 本版本全部变更都在宿主侧 demo 与文档。

## [0.2.0] - 2026-11-04

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

[Unreleased]: https://github.com/liu-jl-dev/stope-lang/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/liu-jl-dev/stope-lang/releases/tag/v0.2.0
[0.1.0]: https://github.com/liu-jl-dev/stope-lang/releases/tag/v0.1.0
