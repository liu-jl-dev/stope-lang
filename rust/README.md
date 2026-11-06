# stope（Rust 实现）

Stope 语言与 STML 标记语言的八份实现之一 —— Rust 版。与仓库里另外七份
（C++ / GDScript / Node.js / C# / Python / Lua / Go）逐项对齐，golden 数据共用
`gdscript/test/data/` 下那一份（本目录**不含任何测试数据**）。

**标准只有三件**：Stope 语言、STML 标记语言、编译器产物 `Program`。
内置的 `basic_vm` 是参考执行器，会一直维护但不属于标准。

## 是什么

- 零第三方依赖的 crate（`Cargo.toml` 无 `[dependencies]`），Rust 1.91.0 可编译；
- 整数一律 `i64` 并全程 `wrapping_*` 回绕（溢出不 panic），除法向零截断，
  `i64::MIN / -1` 等角落有专门处理；
- 字符串值按 **UTF-16 码元**计下标与长度（与 C++ / C# 一致）；
- 常量折叠与虚拟机共用同一套算术 helper（`src/common.rs`），保证同一个表达式
  两边给出同一个答案；
- `basic_vm` 的 `step()` 与 `run()` 是两份独立实现，测试锁定两条路径一致。

## 怎么跑测试

```bash
cd rust
cargo test
```

golden 驱动的测试直接读 `../gdscript/test/data/`（相对 `rust/` 的位置，
即仓库根下的 `gdscript/test/data/`），并断言条数：

| 数据文件            | 条数 | 覆盖                                   |
|---------------------|------|----------------------------------------|
| `golden_lex.txt`    | 147  | 词法（TOKS / LEXEMES / ERRN / ERRS）   |
| `golden.txt`        | 201  | 语法形状 + 编译产物（含 FOLD / PRE）   |
| `golden_binarr.txt` | 86   | 二进制数组解析 + 折叠矩阵              |
| `golden_stml.txt`   | 126  | STML 词法 / 语法                       |
| `golden_disasm.txt` | 12   | 反汇编（含 raw 指令流与撞号 warning）  |

另有 `tests/vm.rs` 的自写断言（值语义 / 回绕 / 除零 / 宿主函数 / run≡step）与
解析器嵌套深度上限用例（256，超限只报一条）。

## 怎么跑 demo

```bash
cd rust
cargo run --bin demo01   # quick-start：编译 + 执行（与 Python 版输出逐字节一致）
cargo run --bin demo02   # STML：解析标记文档，切出代码段
cargo run --bin demo03   # 自定义指令：登记 / 编译 / 反汇编
cargo run --bin demo04   # 预导出（preExports）+ STML 的 text_line 起始行
cargo run --bin demo05   # 宿主侧面向对象：Handle 缝 + 手动生命周期
cargo run --bin demo06   # 宿主侧垃圾回收：引用计数级联 + 标记清除
```

## 模块清单

| 文件                    | 内容                                                     |
|-------------------------|----------------------------------------------------------|
| `src/token.rs`          | `TokenType`（0..46）/ `Token`                            |
| `src/lexer.rs`          | 词法器（错误恢复：报错后继续产 token）                   |
| `src/binarr.rs`         | 二进制数组字面量内容解析（超 1 字节静默截断）            |
| `src/ast.rs`            | AST 节点 + 形状串序列化（测试用）                        |
| `src/parser.rs`         | Pratt 语法分析器（嵌套深度上限 256，0 = 不限）           |
| `src/expr_optim.rs`     | 常量折叠（单节点变换，两侧都是字面量才折）               |
| `src/compiler.rs`       | 编译器（作用域 / 变量分配 / 栈容量记账 / preExports）    |
| `src/program.rs`        | `Program`：指令流 + 常量池 + 变量表                      |
| `src/opcode.rs`         | 33 条内置指令 + `CustomOpcodeConfig`                     |
| `src/disasm.rs`         | 反汇编（`disasm` / `disasm_no_custom`）                  |
| `src/stml/`             | STML 三件套：类型、四态词法器、语法器（max_depth 256）   |
| `src/basic_vm.rs`       | 参考执行器（33 条指令 + `set_opcode`，**不是标准**）      |
| `src/common.rs`         | int64 回绕 / 向零除 / `int_pow`；浮点统一入口            |
| `src/utf.rs`            | `fmt_g`（printf %g）/ `esc` / `fmt_bytes`                |
| `src/bin/demo01..04.rs`、`src/bin/demo05/`、`src/bin/demo06/` | 六个 demo                                                |
| `tests/`                | golden 驱动测试 + VM 自写断言                            |

更多上手示例见 [`docs/quick-start.md`](docs/quick-start.md)；解析 STML（demo02）见
[`docs/stml.md`](docs/stml.md)；自定义指令（demo03，含怎么真的执行）见
[`docs/custom-opcode.md`](docs/custom-opcode.md)；预导出（demo04）见
[`../docs/zh-cn/pre-export.md`](../docs/zh-cn/pre-export.md)；宿主侧面向对象（demo05，
含 Rust 内存管理与手动生命周期的关系）见
[`docs/object-oriented.md`](docs/object-oriented.md)；宿主侧垃圾回收（demo06，
含 `&mut State` 独占借用下的快照根扫描）见 [`docs/gc.md`](docs/gc.md)。
