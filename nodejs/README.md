# stope (Node.js)

Stope 语言的 Node.js 实现。**零第三方依赖**，测试用 Node 内置的 `node:test` 运行器。

需要 Node >= 20（覆盖率阈值门禁需 >= 22.8）。**全链路已落地**：词法 → 语法 → 编译 →
反汇编 → 参考执行器，外加 STML 三件套。780 条断言全绿，期望值全部由 C++ 侧探针 dump
（不是手写），且与本目录的 `golden` 数据逐字节比对。

| 能力 | 入口 |
| --- | --- |
| 词法 | `Lexer` |
| 语法 / AST | `Parser`、`AST`（28 种节点 + `shapeProg`） |
| 常量折叠 | `optimize`（由 `Parser` 自动调用，`constFolding = false` 可关） |
| 编译 | `Compiler` → `Program` |
| 反汇编 | `Disasm` / `DisasmNoCustom` |
| STML | `StmlLexer` / `StmlParser` / `StmlElement` |
| 内置基础 VM（会维护，**不是标准**：无自定义指令 / 自定义数据类型） | `BasicVM.Api` / `State` / `Arguments` |

## 使用

无需 `npm install` —— 这个包没有任何依赖。

想先看效果就跑三个 demo（demo 只在仓库里，发布的包不含 `demo/`）：

```bash
node demo/01-quick-start.js     # 编译 + 运行：反汇编 + 求和结果
node demo/02-stml.js            # 只解析 STML，不编译不执行
node demo/03-custom-opcode.js   # 自定义指令：只编译 + 反汇编
```

demo 的输出以可读为准，不追求跨实现逐字节相同 —— 五份 demo 现在大致一致，但那是
「照着一个思路写」的结果，不是契约（`02` 的输出各实现都带 `[1]`–`[4]` 编号，`03` 里
`short` / `number` 这类用词也各按本语言的类型叫）。

文档：[`docs/quick-start.md`](docs/quick-start.md)（四步上手，逐段讲 `demo/01`）、
[`docs/usage.md`](docs/usage.md)（每个模块的签名、字段、返回码、错误总表）、
[`docs/stml.md`](docs/stml.md)（解析 STML 文档）、
[`docs/custom-opcode.md`](docs/custom-opcode.md)（加自定义指令并执行）。
改实现的话再看 [`docs/testing.md`](docs/testing.md)（测试怎么跑、三种驱动方式、
哪些没覆盖）与 [`docs/lexer-test-plan.md`](docs/lexer-test-plan.md)（词法用例清单）。

```js
import { Lexer, Parser, Compiler, Program, AST, Disasm, BasicVM, Result } from '@liu-jl-dev/stope'

const src = 'let a = 1; let b = 2; return a + b;'

// 1. 编译
const parser = new Parser(new Lexer(src))
const tree = new AST.Prog()
parser.ParseProgram(tree)
const compiler = new Compiler()
const program = new Program()
if (compiler.Compile(tree, program) !== Result.Success) throw new Error(compiler.errors.join(''))
console.log(Disasm(program))

// 2. 跑（内置基础 VM：会维护，但不属于标准）
const state = new BasicVM.State()
state.Reset(new BasicVM.Api(), program, null)
if (state.Run() !== Result.Success) throw new Error(state.errors.join(''))
console.log(state.returns) // [3n]
```

本地开发时直接引用源码：`import { Lexer } from './src/index.js'`。

**整数是 `BigInt`**（`1n` 而不是 `1`），因为 Stope 的整数是 int64 且溢出不检查、按 64 位
回绕 —— JS 的 `Number` 只有 53 位精确整数。`Float` 仍然是 `Number`。这条贯穿词法器、
AST、`Program` 常量池与执行器，写断言时别忘 `n`。

## 目录

```
nodejs/
├── package.json          # 纯 ESM；exports / files / engines 都在这里声明
├── .editorconfig         # 与仓库 .gitattributes 一致：LF 行尾
├── src/
│   ├── index.js          # 唯一公共入口，只做 re-export
│   ├── index.d.ts        # 手写类型声明（不引 TypeScript 工具链）
│   ├── common.js         # Result 枚举（对应 cpp/include/stope/common.hpp）
│   ├── token.js          # TokenType 枚举（47 项）+ Token
│   ├── opcode.js         # Opcode 枚举（33 项）+ 自定义指令登记
│   ├── lexer.js          # 词法
│   ├── ast.js            # 28 种 AST 节点 + 形状串 + %g 复刻
│   ├── ast_visitor.js    # 表驱动遍历骨架（visitMap）
│   ├── parser.js         # Pratt 解析器（含 256 层深度上限）
│   ├── expr_optim.js     # 常量折叠
│   ├── compiler.js       # AST -> Program
│   ├── program.js        # Program 数据结构 + toMap / toJsonString
│   ├── binarr_parser.js  # '...' 内容的字节解析
│   ├── debug.js          # 反汇编（对应 cpp/include/stope/debug.hpp）
│   ├── basic_vm.js       # 参考执行器（非标准）
│   ├── stml.js           # STML 的 Element / Token
│   ├── stml_lexer.js     # STML 四态词法
│   └── stml_parser.js    # STML 语法（宿主回调决定内容怎么切）
├── demo/
│   ├── 01-quick-start.js      # 编译 + 运行（对应 cpp/demo/01、gdscript/demo_01）
│   ├── 02-stml.js             # 只解析 STML
│   └── 03-custom-opcode.js    # 自定义指令：只编译 + 反汇编
├── test/
│   ├── smoke.test.js     # 工程自检：ESM / 零依赖 / exports 不悬空
│   ├── helpers.js        # lexer 的断言族（对应 C++ 的 EXPECT_* 宏）
│   ├── golden.js         # golden 数据读取 + 单行比对格式（dumpProgram）
│   ├── run_case.js       # 一条 golden 用例跑全链路
│   ├── lexer.test.js     # 词法用例，编号与 C++ 逐条对齐
│   ├── parser.test.js    # golden.txt 的 AST 形状 / 行号 / 错误 + 深度上限
│   ├── compiler.test.js  # golden.txt 的产物 / 错误
│   ├── binary.test.js    # 二进制数组 + 常量折叠矩阵
│   ├── disasm.test.js    # 反汇编输出（逐字节）
│   ├── stml.test.js      # STML 词法 + 语法（121 条共用清单）
│   └── vm.test.js        # 执行器：算术语义、宿主接口、运行期错误
└── docs/
    ├── quick-start.md      # 四步上手：编译 → 装执行器 → 传参 → 跑，附最小骨架与坑表
    ├── usage.md            # API 手册：逐模块签名 / 字段 / 返回码 + 错误总表
    ├── stml.md             # STML 教程：回调 → 解析 → 读树 + 可跑骨架
    ├── custom-opcode.md    # 自定义指令教程：登记 → 编译 → 反汇编 → 执行
    ├── testing.md          # 测试说明：怎么跑、三种驱动方式、加用例流程、没覆盖的
    └── lexer-test-plan.md  # lexer 测试计划：覆盖矩阵、与 C++ 的差异、交叉验证做法
```

## 测试

| 目的 | 命令 |
| --- | --- |
| 跑全部测试 | `npm test` |
| 单文件 | `node --test test/parser.test.js` |
| 按名字/编号过滤 | `node --test --test-name-pattern="S-0" test/parser.test.js` |
| 自动重跑 | `npm run test:watch` |
| 覆盖率 + 阈值门禁 | `npm run test:cov` |
| 语法自检 | `npm run check` |

`npm test` 展开后就是 `node --test "test/**/*.test.js"`。glob 必须加双引号，
否则 shell 会先展开成空格分隔的文件列表。

覆盖率标志至今仍是 `--experimental-test-coverage`（不是 `--test-coverage`），
输出格式仍可能随 Node 版本变动。`test:cov` 额外用 `--test-coverage-include="src/**"`
把统计范围限定在源码目录。阈值（行 80% / 分支 70%）不达标会让进程退出码为 1。

### 期望值从哪来

**不手写期望值。** 四份 golden 数据由 C++ 侧探针生成，入库在
`gdscript/test/data/`（仓库里只有这一份，GDScript 侧从 `res://test/data/` 读，本实现
从相对路径读同一个目录 —— 不复制第二份，否则 C++ 改行为时会出现「哪份才是真值」）。
重生成（在 `cpp/` 下）：

```bash
cmake --build build --target gen-golden
```

| 数据 | 谁生成 | 本实现怎么用 |
| --- | --- | --- |
| `golden.txt` | `cpp/tools/golden.cpp` | 一条用例跑全链路，比 AST 形状、行号、错误、产物、编译状态 |
| `golden_binarr.txt` | `cpp/tools/golden_binarr.cpp` | 直接打 `BinaryArrayParser` 与常量折叠矩阵 |
| `golden_disasm.txt` | `cpp/tools/golden_disasm.cpp` | 反汇编输出**逐字节**比对 |
| `golden_stml.txt` | `cpp/tools/golden_stml.cpp` | STML 词法 + 语法，用例清单是 `stml_cases.txt`（两侧共用） |

因为跑测试只需要这四份**已入库**的文本，`npm test` 不需要 C++ 工具链。

八份测试文件各自的驱动方式（golden / 自写 / 自洽）、条数、加用例流程，见
[`docs/testing.md`](docs/testing.md)。

## 新增一个模块

1. 实现放 `src/<module>.js`；
2. 在 `src/index.js` 加一行 `export ... from './<module>.js'`；
3. 测试放 `test/<module>.test.js`。

测试文件的写法：

```js
import { test, describe } from 'node:test'
import assert from 'node:assert/strict'
import { Lexer } from '../src/lexer.js'

describe('Lexer', () => {
  test('tokenize integer literal', () => {
    assert.equal(new Lexer('123').NextToken().value, 123n)
  })
})
```

## 约定

- **零依赖是硬约束**：`package.json` 里不得出现 `dependencies` / `devDependencies`，
  `src/` 下只允许 import `node:` 内置模块和相对路径。`test/smoke.test.js` 会自动检查这两条。
- **纯 ESM**：`"type": "module"`，源码里不用 `require`、不写 `.cjs`。
- **API 命名跟 C++ 走**：`NextToken` / `ParseProgram` / `Compile` / `Reset` 都是 PascalCase，
  与 `cpp/include/stope/*.hpp` 逐名对应，方便对照阅读；不是 JS 惯用的 `nextToken`。
- **错误不抛异常**：词法/语法/编译的错误进各自的 `errors`（格式 `line N: msg`），
  执行器的进 `state.errors`（格式 `<指令下标>: msg`）。只有「宿主没实现抽象方法」这类
  编程错误才 `throw`。
- **`Result.Success === 0`**，别写 `if (rc)` 当成功。
- **断言分族**：lexer 用无前缀的 `expectType` / `expectSeq`，parser 一组带 `P` 前缀，
  STML 一组带 `STOK`/`SP` 前缀；公用断言抽到 `test/helpers.js`。
- **用例编号与 C++ 对齐**：`test/lexer.test.js` 的 `I-xx` / `F-xx` / `D-xx` … 全部沿用
  `cpp/test/test_lexer_*.cpp` 的编号，清单见 `docs/lexer-test-plan.md`。
- **`exports` 封闭包内路径**：外部只能从包根导入，深引用 `pkg/src/x.js` 会失败，这是刻意的。

## 与另外两个实现的关系

语义基准是 **C++**（`cpp/include/stope/*.hpp`）；行为契约（两侧/三方都必须满足的部分）
在 [`docs/zh-cn/*-test-plan.md`](../docs/zh-cn/)。本实现的取舍：

- **整数用 `BigInt`**：C++ 是 int64，GDScript 是 64 位 int，JS 只有 BigInt 能对齐。
- **字符串是 UTF-16**（JS 原生），所以 `"ab"[i]` 取到的是**码元** —— 与 C++ 的
  `u16string` 一致，与 GDScript（UTF-32 码点）不同。
- **执行器不是标准，但会一直维护**：`BasicVM` 是能跑通 `Program` 的内置基础虚拟机 ——
  修 bug、跟 `Program` 演进同步、五份实现语义对齐；接口不会随意调整（改名、增删参数只为
  修 bug 或跟进 `Program`），边界内的用法可以放心依赖，只是别当规范引用。能力边界：
  **默认不支持自定义指令**（`Api.opMap` 默认 33 项，产物里 ≥ 33 的编号会抛 `TypeError`，
  要执行得自己扩表，见 [`docs/custom-opcode.md`](docs/custom-opcode.md) §6）、
  **不支持自定义数据类型**（值只有 `null` / BigInt / Number / string / `Uint8Array`
  一类的二进制数组 / 函数，布尔用整数表示）。
  自己写执行器看 [`docs/zh-cn/vm-guide.md`](../docs/zh-cn/vm-guide.md)。

## 发布

```sh
npm pack --dry-run   # 先确认打进去的文件（test/ 不应在内）
npm publish --access public
```

`files` 白名单只放行 `src`、`docs`、`README.md`、`LICENSE` —— 测试与 demo 不进包，
但文档随包发布，README 里的相对链接在 npm 上不会 404。
