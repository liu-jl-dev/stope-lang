//! Demo 02：STML —— 解析一份标记文档，把里面的代码段原样切出来。
//!
//! STML 是「两半」：树的形状由 `stml::parser` 管；「某个元素的内容怎么切」由宿主的
//! 回调决定。只解析，不编译也不执行。
//!
//! 运行：cargo run --bin demo02

use std::collections::BTreeMap;
use stope::common::Result as StopeResult;
use stope::stml::{Element, LexerState, lexer::Lexer, parser::{Parser, StateFuncOpt}};

const DOC: &str = "
<stml package=\"MyPkg\">

<config>
  windowTitle \"demo\";
  windowSize 1280, 720
</config>
<func name=\"myFunc\" stope>
  let a = 1;
  return a + argc;
</func>
<class name=\"Person\">
  <property name=\"name\" />
  <property name=\"age\" />
  <method name=\"greet\" />
</class>

</stml>
";

/// 宿主回调：读完开始标签、还没进内容时调用一次，返回值决定这段内容怎么扫。
fn content_kind(tag: &str, attrs: &BTreeMap<String, String>) -> LexerState {
    if tag == "config" {
        return LexerState::Nevext; // 一段 Nevext 代码，整段原样保留
    }
    if attrs.contains_key("stope") {
        return LexerState::Stope; // 一段 Stope 代码
    }
    LexerState::Xml // 默认：内容是子元素列表
}

/// 按名字找子元素 —— 别写死下标，空行和注释都会让它变。
fn child<'a>(ele: &'a Element, tag: &str) -> Option<&'a Element> {
    ele.children.iter().find(|c| c.tag == tag)
}

fn main() {
    let mut lexer = Lexer::new(DOC);
    let mut root = Element::new();
    let ok = {
        let mut parser = Parser::new(&mut lexer);
        let rc = parser.parse(&mut root, StateFuncOpt::Custom(Box::new(content_kind)));
        if rc != StopeResult::Success {
            let mut errs = parser.lexer().errors.clone();
            errs.extend(parser.errors.clone());
            eprintln!("{}", errs.join("\n"));
        }
        rc == StopeResult::Success
    };
    if !ok {
        std::process::exit(1);
    }

    println!(
        "[1] 根元素 <{}>，属性 package=\"{}\"",
        root.tag, root.attrs["package"]
    );
    println!("[2] 它的直接子元素：");
    for c in &root.children {
        println!("  {}", c.tag);
    }

    println!("[3] <class> 的子元素：");
    for c in &child(&root, "class").unwrap().children {
        println!("  {}{}", c.tag, if c.self_closing { "(自闭合)" } else { "" });
    }

    // 代码段是原样的一整段：换行是真的换行、缩进保留（只有尾部空白被词法裁掉）。
    // 拿到它交给 stope::Lexer 就能编译执行（见 demo01）—— STML 不管代码写得对不对。
    println!("[4] <func> 里的 Stope 代码段：");
    println!("{}", child(&root, "func").unwrap().text);
}
