# Rust 版 STML 上手

STML 是 Stope 的标记语言：**树**由 `stml::parser::Parser` 管（标签名、属性、嵌套、结束标签
是否配对），**内容怎么切**由宿主管 —— 就是传给 `parse()` 的那个回调。

完整可运行版本是 [`src/bin/demo02.rs`](../src/bin/demo02.rs)，本文逐段讲它。
STML 的**语义权威**在 [`cpp/docs/stml.md`](../../cpp/docs/stml.md)（12 条语法注意事项都在那），
本文只讲「Rust 侧怎么上手 + 本实现与另外几套的差异」。

## 1. 先跑起来：`demo02` 的四段

```bash
cargo run --bin demo02
```

```
[1] 根元素 <stml>，属性 package="MyPkg"
[2] 它的直接子元素：
  config
  func
  class
[3] <class> 的子元素：
  property(自闭合)
  property(自闭合)
  method(自闭合)
[4] <func> 里的 Stope 代码段：
let a = 1;
  return a + argc;
```

- `[1]` 属性是 `BTreeMap<String, String>`：`root.attrs["package"]`，没有就得到 `None`
  （`attrs.get("package")`）。
- `[3]` `self_closing` 是布尔值 —— `/>` 这种写法不产生子元素，也不会去等结束标签。
- `[4]` 代码段是**原样**的一整段 `String`：换行是真换行、缩进保留，只有尾部空白被词法裁掉。
  拿到 `text` 之后交给 `stope::Lexer` 就能编译它 —— 但**这一步不是必须的**，
  STML 不关心你的代码写得对不对（demo 就到此为止）。

## 2. 第一步：写一个回调

回调类型是 `StateFunc = Fn(&str, &BTreeMap<String, String>) -> LexerState`，在**读完开始
标签、还没进内容**的那一刻被调用一次，它的返回值决定后面怎么扫这个元素的内容：

| 返回 | 含义 |
| --- | --- |
| `LexerState::Xml` | 内容是**子元素列表**（普通标签） |
| `LexerState::Text` | 内容是**一整段普通文本**（`<p>`） |
| `LexerState::Nevext` | 内容是 **Nevext 代码**（`<config>`） |
| `LexerState::Stope` | 内容是 **Stope 代码**（带 `stope` 属性的元素） |

```rust
fn content_kind(tag: &str, attrs: &BTreeMap<String, String>) -> LexerState {
    if tag == "config" {
        return LexerState::Nevext;
    }
    if attrs.contains_key("stope") {
        return LexerState::Stope;
    }
    LexerState::Xml
}
```

三点：

- **按标签名 / 属性判断，不要按层级**。回调拿不到「我是谁的儿子」，只有 `tag` 与 `attrs`。
- 回调经 `StateFuncOpt` 包好再传：`StateFuncOpt::Custom(Box::new(content_kind))`；
  `StateFuncOpt::None` 是「一律 `Xml`」；`StateFuncOpt::Default` 是默认约定（见下）。
- 回调**每次进元素都会调一次**，不要在里面积累状态。

现成的默认回调用固定约定：`<sto>` → Stope、`<nev>` → Nevext、`<p>` → Text，其余 Xml ——
传 `StateFuncOpt::Default` 即可（这也是 `Parser::new` 不给回调时的默认值；
`StateFuncOpt::None` 才是「一律 Xml」）。

## 3. 第二步：解析

```rust
use stope::common::Result as StopeResult;
use stope::stml::lexer::Lexer;
use stope::stml::parser::{Parser, StateFuncOpt};
use stope::stml::{Element, LexerState};

let mut lexer = Lexer::new(doc);
let mut root = Element::new();
let ok = {
    let mut parser = Parser::new(&mut lexer); // ⚠ lexer 被 parser 可变借用
    let rc = parser.parse(&mut root, StateFuncOpt::Custom(Box::new(content_kind)));
    if rc != StopeResult::Success {
        let mut errs = parser.lexer().errors.clone(); // 词法错误经 parser.lexer() 拿
        errs.extend(parser.errors.clone());           // 语法错误在 parser.errors
        eprintln!("{}", errs.join("\n"));
    }
    rc == StopeResult::Success
};
if !ok {
    std::process::exit(1);
}
```

| 约定 | 内容 |
| --- | --- |
| 错误分两处 | 词法错误与语法错误**不合并**。`parse()` 只看前者是否为空的**间接**结果 —— 返回码只反映语法错误。⚠ `Parser::new(&mut lexer)` 之后 lexer 被**可变借用**，读词法错误要走 `parser.lexer()`（demo02 的块作用域就是为了在借用结束前把错误取完） |
| 返回值 | `StopeResult::Success` / `StopeResult::Error` |
| `root` 是容器 | 调用前是 `Element::new()`（line = -1），`parse()` 往里填 |
| 只解析一个根 | STML 文档就是一个根元素（demo 里的 `<stml>`），根后面还有内容不会报错，但也不会被解析 |
| 嵌套深度 | 元素嵌套默认最多 **256 层**（根算第 1 层），`parser.max_depth = 0` 表示不限。超限报 1 条 `nesting too deep (max 256). ` 并中止，剩余输入忽略、**不级联** |

## 4. 第三步：读树

`Element` 只有 7 个字段，别指望更多：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `line` | `i32` | 开始标签所在行（从 1 起） |
| `text_line` | `i32` | 内容首行的物理行号（不是标签行）；无内容时 -1 |
| `tag` | `String` | 标签名 |
| `attrs` | `BTreeMap<String, String>` | 属性；**无值属性的值是空串**。`BTreeMap` 按名字序遍历 |
| `self_closing` | `bool` | 是不是 `/>` |
| `children` | `Vec<Element>` | 子元素 |
| `text` | `String` | 元素内文本 / 代码段。与 `children` **互斥** |

`text_line` 是**内容**的第一行：词法器切内容前跳过了前导空白（含换行），所以
`<sto>\nlet a = 1;</sto>` 里 `line` 是 1、`text_line` 是 2。把切出来的代码段交给
`stope::Lexer` 时调 `lexer.set_line(e.text_line)`，报错行号才和原文档对得上。

```rust
fn child<'a>(ele: &'a Element, tag: &str) -> Option<&'a Element> {
    ele.children.iter().find(|c| c.tag == tag)
}

let func_ele = child(&root, "func").unwrap();
println!("{}", func_ele.text);                    // 代码段原样
println!("{:?}", func_ele.attrs.keys().collect::<Vec<_>>()); // 属性名（BTreeMap：名字序）
```

`text` 与 `children` 互斥，是因为**元素内文本只有一段**：`<p>a<span/>b</p>` 里的 `b` 不会
被拼到 `a` 后面 —— 按 STML 的规则，有文本就不能有子元素，写了就是宿主自己的问题
（词法器会把 `<span/>` 整段当文本吃掉，见 `cpp/docs/stml.md` 的 B-2）。

## 5. 属性

```rust
root.attrs["package"]             // "MyPkg"（Index，不存在会 panic）
root.attrs.get("missing")         // None —— 不存在走 get
root.attrs.contains_key("stope")  // 有值为空串的属性也要用 contains_key 判
```

| 规则 | 说明 |
| --- | --- |
| 可以无值 | `<a flag>` 等价于 `flag=""`。判「有没有这个属性」用 `contains_key`，判「值是不是空」用 `attrs["flag"] == ""` |
| 顺序 | `BTreeMap` 按名字序 —— 与 C++ 的 `std::map` **同序**（Go 是保序切片、Lua/GD/JS/Py 是插入序，Rust 反而最接近 C++） |
| 同名属性 | 保留**先出现的**那个（对齐 C++ 的 `std::map::emplace`），后一个被静默丢弃 |
| 值不转义 | 属性串里的 `\"` **不会**被当成转义 —— 第一个引号就是结束引号（TD-9） |

## 6. 本实现与另外几套的差异

| 项 | C++ | Rust | 影响 |
| --- | --- | --- | --- |
| `attrs` 容器 | `std::map`（名字序） | `BTreeMap`（名字序） | 两者同序，golden 形状串逐字节一致 |
| 回调的传法 | 函数指针 / lambda | `StateFuncOpt::Custom(Box::new(f))`（boxed `Fn`） | `None` = 一律 Xml、`Default` = 默认约定，别混 |
| 词法错误的取法 | 直接拿 lexer | **经 `parser.lexer()`**（lexer 被 parser 借用中） | demo02 的块作用域写法照抄即可 |
| 非 BMP 字符（如 emoji） | 按 **UTF-16 码元**，一个字符两个 `?` | lexeme 是源码子串原样保留（UTF-8 字节）；golden 比较经 `esc16` 折算成 UTF-16 码元 | 输出与 C++ 一致 |
| `lexeme` 所有权 | `string_view` 借用输入 | `String` / `&str` 复制 | 宿主不用管生命周期 |
| `TokenType` 名字 | `EndOfFile` | `Eof` | 与 GD / JS / C# / Py / Go 一致 |

STML 的 12 条语法注意事项（`B-2` / `B-3` / `B-8` / `TD-1` / `TD-8` / `TD-9` …）不再重复，
一律看 [`cpp/docs/stml.md`](../../cpp/docs/stml.md) 与
[`docs/zh-cn/stml-test-plan.md`](../../docs/zh-cn/stml-test-plan.md)。

## 7. 最小骨架（已运行）

```rust
use std::collections::BTreeMap;

use stope::common::Result as StopeResult;
use stope::stml::lexer::Lexer;
use stope::stml::parser::{Parser, StateFuncOpt};
use stope::stml::{Element, LexerState};

fn state_kind(tag: &str, attrs: &BTreeMap<String, String>) -> LexerState {
    if attrs.contains_key("stope") {
        return LexerState::Stope;
    }
    if tag == "p" {
        return LexerState::Text;
    }
    LexerState::Xml
}

fn main() {
    let doc = "
<root>
<p>hello</p>
<code stope>return 1 + 2;</code>
</root>
";
    let mut lexer = Lexer::new(doc);
    let mut root = Element::new();
    let mut parser = Parser::new(&mut lexer);
    let rc = parser.parse(&mut root, StateFuncOpt::Custom(Box::new(state_kind)));
    if rc != StopeResult::Success {
        for e in parser.lexer().errors.iter().chain(parser.errors.iter()) {
            eprintln!("{}", e);
        }
        std::process::exit(1);
    }
    println!("{}", root.tag); // root
    for c in &root.children {
        println!("{} {}", c.tag, c.text); // p hello / code return 1 + 2;
    }
}
```

## 8. 排错表

| 症状 | 原因 / 做法 |
| --- | --- |
| `root.children` 是空的 | 回调返回了 `Xml` 却没写子元素？或者文档只有一个空标签（`<a></a>` 也是空） |
| `root.text` 是空串，但我明明写了文本 | 那个元素的回调返回的是 `Xml`（子元素模式），文本被当成了「不合法的子元素」→ `parser.errors` 里有 `expected "<" or "</". ` |
| `attrs` 里少了属性 | 同名属性只保留第一个；属性名里有 `.` 会被当成非法字符（`Word` 不含 `.`，TD-1） |
| 编译报 `cannot borrow lexer as immutable` 之类 | `Parser::new(&mut lexer)` 之后 lexer 被借用中 —— 词法错误走 `parser.lexer()`，别再直接碰 lexer |
| `root.attrs["x"]` panic | 下标取不存在的属性会 panic；不确定存在就用 `attrs.get("x")` |
| 报 `expected string. ` | 属性写在 `=` 后面没给字符串（`<a id=>`） |
| 报 `expected ">" or "/>" or attribute. ` | 属性位置上出现了不是 `Word` 的东西：`<a @>`、`<a.b>`（`Word` 不含 `.`，TD-1） |
| 报 `expected "<" or "</". ` | 两种情形：① 元素没有结束标签（`<a>` 就到头了）；② 内容按 `Xml` 扫，却遇到了裸文本（`<a>text</a>` 且回调返回 `Xml`） |
| 报 `tag name mismatch. ` | 结束标签与开始标签不一致。STML **没有**「自动闭合」 |
| 报 `unclosed string literal`（**没有**句号） | Xml 属性串没闭合，这一条与代码段那条文案不同（TD-8） |
| 报 `unclosed string literal. `（**有**句号） | `Nevext` / `Stope` 代码段里的引号串没闭合 |
| 代码段里含 `</` 却提前结束了 | 只有**引号串与注释内部**的 `</` 不算结束标签（B-3）；裸的 `</` 一定会结束元素 |
| 文本尾部空格丢了 | 故意的：内容段尾部空白不计入 `lexeme`（B-8） |

## 9. 下一步

- **加自己的指令**：看 [`src/bin/demo03.rs`](../src/bin/demo03.rs) 与
  [`custom-opcode.md`](custom-opcode.md)。
- **把切出来的代码编译了**：看 [`quick-start.md`](quick-start.md)。
- **STML 的语义权威**：[`cpp/docs/stml.md`](../../cpp/docs/stml.md)。
