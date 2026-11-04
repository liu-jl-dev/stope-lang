# Stope Rust 版快速上手

## 安装

只需 Rust 工具链（1.91.0 已验证），**无任何第三方依赖**（`Cargo.toml` 没有
`[dependencies]`，`cargo build` 可完全离线完成）：

```bash
cd rust
cargo build            # 编译库 + 四个 demo
cargo test             # 跑全部测试（golden 数据直接读 ../gdscript/test/data/）
```

## 最小示例（已验证可跑）

### 1. 编译 + 执行一段 Stope 源码

```rust
use std::rc::Rc;
use stope::{Api, Compiler, Parser, Prog, Program, Result as StopeResult, State, Value};

let src = "let a = 40; return a + 2;";

// 1) 词法 + 语法：Parser 内部持有词法器，词法错误在 parser.lexer().errors 里
let mut parser = Parser::new(src, None); // 第二参是 CustomOpcodeConfig
let mut tree = Prog::default();
parser.parse_program(&mut tree);

// 2) 编译：AST -> Program
let mut compiler = Compiler::new(None);
let mut program = Program::new();
assert!(compiler.compile(&tree, &mut program, &[]) == StopeResult::Success);

// 3) 执行（内置基础虚拟机，不属于标准）
let mut state = State::new();
state.reset(Rc::new(Api::new()), Rc::new(program), None);
state.run();
assert!(matches!(state.returns[0], Value::Int(42))); // Int(42)
```

错误不抛异常：`parser.errors` / `parser.lexer().errors` / `compiler.errors`
各自积累文案（`line N: ...`）；编译失败时 `program` 已被清空。

### 2. 解析一份 STML 文档

```rust
use stope::stml::Element;
use stope::stml_lexer::Lexer as StmlLexer;
use stope::stml_parser::{Parser as StmlParser, StateFuncOpt};

// <sto> 内容按 Stope 代码扫、<nev> 按 Nevext、<p> 按纯文本，其余是子元素
let doc = "<doc><p>hello world</p><sto>return 1;</sto></doc>";
let mut lexer = StmlLexer::new(doc);
let mut root = Element::new();
let mut sp = StmlParser::new(&mut lexer);
assert!(sp.parse(&mut root, StateFuncOpt::Default) == StopeResult::Success);

assert_eq!(root.tag, "doc");
assert_eq!(root.children[0].tag, "p");
assert_eq!(root.children[0].text, "hello world");
assert_eq!(root.children[1].text, "return 1;"); // 原样切出的 Stope 源码
```

注意：STML 的文本元素内不允许子标签（`<p>hello <b>x</b></p>` 里的 `<b>`
会被当纯文本吃掉，随后 `</b>` 触发 tag name mismatch —— 语言设计如此）。

宿主可以用 `StateFuncOpt::Custom(Box::new(f))` 自定义「哪个标签的内容怎么扫」，
用 `lexer.set_line(...)` 把从 STML 切出的代码段的起始行号对齐文档（demo04）。

### 3. 看一眼字节码

```rust
let text = stope::disasm_no_custom(&program);
assert!(text.contains("PushInt"));
```

含自定义指令时用 `stope::disasm(&program, Some(&config))`。

## 整数语义备忘

- 整数是 `i64`，**溢出回绕**（`2 ^ 64 == 0`、`-i64::MIN == i64::MIN`）；
- 除法向零截断，`i64::MIN idiv -1` 回绕成 `i64::MIN`、`i64::MIN % -1 == 0`；
- 除零只在两侧都是整数时报错，任一侧是浮点走 IEEE（`1.0 / 0` 得 inf）；
- 字符串下标 / 长度按 **UTF-16 码元**（emoji 占两个码元）。

## 下一步

- 四个完整示例：`cargo run --bin demo01` … `demo04`（见 `../README.md`）；
- 语义细节以 C++ 为权威：`../cpp/src/`；各测试计划见 `../docs/zh-cn/`。
