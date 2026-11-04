# 移植指南（往本仓库加一份新的语言实现）

> 读者：要移植第九份语言实现的人（或 agent）。语义权威是 `cpp/`；
> 本文讲**怎么移植** —— 顺序、容易翻车的地方、交付前检查单。
> 行为契约本体在 [compiler-test-plan.md](compiler-test-plan.md)、
> [stml-test-plan.md](stml-test-plan.md) 与 [vm-guide.md](vm-guide.md)，本文不复述。

## 1. 参考材料与优先级

| 优先级 | 材料 | 用途 |
| --- | --- | --- |
| 1 | `python/`（`stope/` + `tests/` + `demo/`） | **主参考**：纯标准库、无语言特技，模块划分照抄它 |
| 2 | `cpp/src/` | 语义权威：折叠规则（`expr_optim`）、STML 四态、BasicVM 指令语义拿不准时看它 |
| 3 | `gdscript/test/data/` | golden 数据真源（**只读、绝不复制**）：`golden_lex` 147 / `golden` 201 / `golden_binarr` 86 / `golden_stml` 126 / `golden_disasm` 12 条（以文件实际行数为准，会随功能增长） |
| 4 | `python/tests/golden.py`、`gdscript/test/test_util.gd` | 转义规则的权威实现，照抄逻辑 |
| 5 | `nodejs/` | 看整数回绕（BigInt）与 `dumpProgram` 口径 |

三条铁律：

1. **golden 数据只读不复制** —— 新实现的测试直接读 `gdscript/test/data/`，复制一份就会出现「哪一份才是真值」。
2. **期望值不手写** —— 全部来自 golden dump，自己手推的期望值一文不值。
3. **零第三方依赖** —— 语言标准库之外什么都不拉（见根 README 实现状态表，八份全部如此）。

## 2. 建议的实施顺序

```
① 语言核心        lexer → parser（含深度上限）→ expr_optim → compiler（含 preExports）
                  每完成一个模块就对照 golden 验一段，别全写完才测
② 二进制数组       parse_binarr（对照 golden_binarr）
③ STML 三件套      stml_lexer（四态）→ stml_parser（line + textLine + maxDepth）
④ BasicVM         33 条内置指令；step() 与 run() 各写一遍（热循环不套函数调用），
                  测试锁两条路径一致
⑤ 反汇编          disasm / disasm_no_custom（custom opcodes 段按编号排序）
⑥ demo ×4         01 编译+运行、02 只解析、03 自定义指令、04 预导出
⑦ 测试跑器        读 golden 全绿（见 §3）
⑧ 文档            README + docs/quick-start.md（示例必须真跑过）
```

## 3. golden 验收（唯一权威）

### 3.1 转义规则 —— 每份数据都不一样，别想当然

| 文件 | 字段值 | `SRC` 列 |
| --- | --- | --- |
| `golden.txt` / `golden_disasm.txt` | 解一层（`\n \r \t \\ \"`） | 解**两层** |
| `golden_lex.txt` | **不解**（`TOKS`/`LEXEMES`/`ERRS` 原样比对） | 用 `unescape_lex`（额外认 `\v \f`） |
| `golden_stml.txt` | **不解**（错误串里的引号是 `\"`） | 不解 |
| `stml_cases.txt` | 清单本身 | 用 `unescape_lex` |

精确逻辑照抄 `python/tests/golden.py`（或 `gdscript/test/test_util.gd`）。

### 3.2 条数自检

测试开头先断言数据文件存在、用例条数等于当前行数 —— 条数变了（功能新增）会在这里
第一时间暴露，而不是悄悄少测。读文件后统一剥 `\r`（Windows 探针输出 CRLF）。

### 3.3 demo 对齐

demo01、demo02 的输出要与既有实现**逐字节一致**（剥行尾后 diff 为空，含中文与浮点
格式）。demo03、demo04 也应对齐（八份目前全部一致）；做不到就先对齐到段落级，并在
README 里写明差异。浮点输出用 C 的 `%g` 语义（很多语言默认格式与它不同，自己写 `fmt_g`）。

## 4. 跨语言的语义坑（按主题）

### 4.1 整数 = int64

- **溢出回绕不报错**：Rust 要全程 `wrapping_add/sub/mul`（debug 模式普通算术会 panic）；
  Go/Java 类语言规范保证 wrap；Lua 5.4 整数天生回绕。
- **除法向零截断**，不是 floor：Python 的 `//` 与 `%`、Lua 的 `//` 与 `%` 都是 floor 语义
  → 必须自写向零版本，`-7 idiv 2` 是 `-3`。
- **`MIN / -1` 与 `MIN % -1`**：C# 抛异常、Go 与 Rust 会 panic → 必须特判；GDScript 直接
  中止整个脚本，更要单独兜。
- **除零只在两侧都是整数时报错**；任一侧浮点走 IEEE（±inf / NaN），语言原生 `1.0/0`
  会抛异常的（Python）要兜。
- 整数与浮点要能区分（`7` 与 `7.0` 输出不同）；布尔不是独立值，就是整数 1 / 0。

### 4.2 幂与浮点

- `^` **右结合**（由递归下降的实现结构决定，别按左结合写）。
- 整数幂回绕且仍是整数（`2 ^ 64` = 0）；负指数 → Float。
- 浮点幂与 C `pow` 对齐：`(-8.0) ^ 0.5` 是 **NaN**（Python 的 `(-8.0) ** 0.5` 会返回复数
  → 必须绕开）；`fmod(x, 0)` 各语言行为不一（Python 抛 ValueError、Lua 对整数 0 报错）
  → 折叠与 VM 共用一个 `fmod` helper。
- `math.floor(2^63.0)`（Lua）、`math.trunc(inf)`（Python）都会抛 → 都要兜。

### 4.3 字符串按 UTF-16 码元

- 下标、长度、切片都按**码元**（C++ 的 `u16string` 口径），不是码点、不是字节：
  `"😀"[0]` 是高位代理 `55357`。
- Python 的 `str` 下标是码点 → 取下标时转 UTF-16；Go 的 `range` 按 rune 迭代 → 别用它实现
  码元语义；Rust 的 `char` 同理。
- 内部表示两条路：**值语义存码元**（Go `[]uint16`、Rust `Rc<Vec<u16>>`、Lua UTF-16LE
  字节串），或存原生字符串、按需转换（Python）—— 选一条贯彻到底，别混。
- 词法器在 UTF-8 字节上扫没问题（结构字符都是 ASCII）；字符串字面量反转义后再转内部表示。
- BinArr 字面量是单引号、内容**不做任何转义**；BinArr 按字节（不是码元）。

### 4.4 折叠与 VM 必须共用 helper

常量折叠（`expr_optim`）与执行器对同一个表达式必须给出同一个答案 —— 除法、取模、幂、
浮点边界全部走同一组函数（Python 的 `common.py`、Go 的 `common.go`、Rust 的 `common.rs`、
Lua 的 `common.lua` 都是干这个的）。折叠只在两侧都是字面量时做、只做单节点变换。

### 4.5 深度上限与 textLine

- Parser 与 STML 解析都有嵌套深度上限 **256（0 = 不限）**，超限只报一条
  `line N: nesting too deep (max 256). ` 并中止、不级联（`error()` 也要检查 aborted）。
- STML 词法器 `NextToken` **先跳空白再定 `token.line`** —— `Element.textLine`（内容首行，
  无内容 -1）的精确性完全依赖这个顺序。`text` 里没有前导空白，别用「标签行 + 1」这种偏移。

### 4.6 preExports

`Compile(ast, out, preExports)` 第三参：在遍历 AST **之前**按顺序登记进 `exports`；
空名 / 重名报 `line 0: ...`；源码顶层 `let` / `export` 与名单撞名报 duplicate（块内
`let` 是遮蔽）。详见 [pre-export.md](pre-export.md)。

## 5. 已实现语言的专有坑（速查）

| 实现 | 最容易踩的坑 |
| --- | --- |
| C++（权威） | 无（其他实现都对着它对齐）；注意 `= delete` 拷贝（ProgramConstants 二次释放） |
| GDScript | 取负 / 除 `-1` / `% -1` 会**静默中止整个脚本** → 写 `~a + 1` 并单兜；`int ** int` 不能用；`==` 遇类型不匹配抛引擎错误 → 自写 `_equals` |
| Node.js | 整数全 BigInt，运算后 `BigInt.asIntN(64, …)`；`Parser` 必须吃 `new AST.Prog()`（裸对象静默跳过整棵树） |
| C# | 关 `CheckForOverflowUnderflow`；顶层语句入口类撞名 `Stope.Program`；`Runtime.Equals` 隐藏 `object.Equals`（CS0108）→ 改名 `AreEqual` |
| Python | `int` 无限精度 + `//`/`%` 向下取整 → 自写 `wrap64` / `int_div` / `int_mod` / `int_pow`；`(-8.0) ** 0.5` 返回**复数**、`math.trunc(inf)` 抛异常 → 全走 `common.py`；`isinstance(True, int)` 为真 → 判整数先排掉 `bool` |
| Lua | `//`、`%` 是 floor、`^` 永远 float → 自写 `int_div` / `int_mod` / `int_pow`；字符串是字节串 → String 值用 UTF-16LE 字节串 + 包装表（Lua 分不清 String 与 BinArr 的下标语义）；`nil` 不能上栈 → Null 用唯一哨兵表 |
| Go | `MinInt64 / -1` 与 `% -1` panic → 特判；`range string` 按 rune —— 别用它实现码元；`%g` 是最短表示而非 C 语义 → 自写 `fmt_g`；函数值不可比较 → 宿主函数 `Equals` 恒 false |
| Rust | 溢出全程 `wrapping_*`（debug 下普通算术 panic）；`f64::parse` 不认 `"5."` / `".5"` → 先规范化再解析；Token 里别放 `&str` 视图（生命周期传染），用值 |

## 6. 交付前检查单

```text
[ ] 五份 golden 全绿（147 / 201 / 86 / 126 / 12，以文件实际行数为准；测试先断言条数）
[ ] 自写断言：深度上限、textLine、preExports（line 0）、VM step ≡ run 各有覆盖
[ ] demo01、demo02 与 Python 份逐字节一致（剥行尾 diff 为空）；03、04 对齐或在 README 写明差异
[ ] 零第三方依赖（依赖清单为空；Rust 无 [dependencies]、Go 无 go.sum）
[ ] 溢出 / MIN/-1 / 除零 / NaN 路径不崩溃、不静默，与 golden 一致
[ ] README.md + docs/quick-start.md（示例真跑过）
[ ] 根 README 实现状态表加一列；CHANGELOG [Unreleased] 记一条
[ ] 「N 份实现」的全仓口径同步（README、vm-guide、commit-convention、pre-export §7 表）
```

最后一条最容易漏 —— 口径散在约 40 处文档里，新增实现是**次版本**事件，改完跑一遍
`python tools/check_version.py` 确认版本落点没被顺手碰坏。

## 7. 相关文件

- 各实现入口：`cpp/docs/README.md`、`gdscript/docs/README.md`、`nodejs/README.md`、
  `csharp/README.md`、`python/README.md`、`lua/README.md`、`go/README.md`、`rust/README.md`
- 契约：[compiler-test-plan.md](compiler-test-plan.md)、[stml-test-plan.md](stml-test-plan.md)、
  [vm-guide.md](vm-guide.md)、[syntax-reference.md](syntax-reference.md)、
  [constant-folding.md](constant-folding.md)
- 用法参考：[pre-export.md](pre-export.md) §7（八份 `Compile` 签名对照）、
  [commit-convention.md](commit-convention.md)（提交怎么写）
