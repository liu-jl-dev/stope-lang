# Stope 的 Go 实现

这是 [stope-lang](../README.md) 的八份实现之一（Go 1.27+，纯标准库、零第三方依赖），
与 C++（权威）/ GDScript / Node.js / C# / Python / Lua / Rust 七份逐项对齐。标准只有三件：
**语言、STML、编译器产物 Program**；`stope/basicvm` 是内置参考执行器，不属于标准。

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `*.go`（module 根，`package stope`） | 语言核心：`token.go`（Token/TokenType）、`lexer.go`（词法）、`parser.go`（Pratt 语法 + 嵌套深度上限 256）、`ast.go`（AST + 形状串）、`binarr.go`（二进制数组字面量）、`expr_optim.go`（常量折叠，与 VM 共用算术 helper）、`compiler.go`（编译器 + DumpProgram）、`opcode.go`（33 条内置指令 + 自定义指令登记表）、`program.go`（Program）、`disasm.go`（反汇编 Disasm/DisasmNoCustom）、`common.go`（Result / int64 算术 / `%g` 格式化） |
| `stml/` | STML 标记语言：四态词法器（Xml/Text/Nevext/Stope）+ 语法解析器（`Element` 带 `line` 与 `textLine`） |
| `basicvm/` | 内置参考执行器（33 条指令；宿主函数是值；`Run` 与 `Step` 两份独立实现） |
| `cmd/demo01..04` | 四个示例：quick-start / STML / 自定义指令 / 预导出 |
| `tests/` | golden 驱动的测试（直接读 `gdscript/test/data/` 的 golden 数据，不复制第二份） |
| `docs/quick-start.md` | 安装 / 运行 / 最小示例 |

## 跑测试

```bash
cd go
go test ./...     # 全部测试（golden 用例 + 执行器 + 嵌套深度）
go vet ./...      # 应当零输出
```

golden 数据真源在 `../gdscript/test/data/`，测试以绝对路径读取并断言条数：
`golden_lex.txt` 147 条、`golden.txt` 201 条、`golden_binarr.txt` 86 条、
`golden_stml.txt` 126 条、`golden_disasm.txt` 12 条。改了行为需要重新生成 golden
时，去 C++ 侧跑探针（见 `cpp/` 的说明），**不要**手改数据文件。

## 跑 demo

```bash
cd go
go run ./cmd/demo01   # 编译 + 执行（输出与 python/demo/01-quick-start.py 逐字节一致）
go run ./cmd/demo02   # STML 解析
go run ./cmd/demo03   # 自定义指令：登记 + 编译 + 反汇编
go run ./cmd/demo04   # preExports + STML
```

## 关键语义（与其它实现对齐的要点）

* 整数 = int64，溢出按 64 位补码回绕；除法向零截断；`MinInt64 / -1` 与
  `MinInt64 % -1` 特判（Go 运行时会 panic，必须绕开）。
* 除零只在两侧都是整数时报错；任一侧是浮点走 IEEE（Go 原生满足）。
* `^` 右结合；整数幂回绕且仍整数；负指数 → Float；`math.Pow(-8, 0.5)` = NaN。
* `null` 不参与算术（`null == null` 仍为真）。
* 字符串值的下标 / 长度按 **UTF-16 码元**（`unicode/utf16`），不是 rune 也不是字节。
* 常量折叠只做单节点变换、两侧都是字面量才折；折叠与 VM 共用 `common.go` 的
  `IntDiv / IntMod / IntPow / FDiv / FMod / Trunc / FPow`。
* Parser 与 STML 解析器嵌套深度上限 256（0 = 不限），超限只报一条
  `line N: nesting too deep (max 256). ` 并中止、不级联。
* `Compile(ast, out, preExports)` 第三参：preExports 在遍历前按顺序登记进 exports。
