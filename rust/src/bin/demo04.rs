//! Demo 04：预导出（preExports）—— 宿主先把形参塞进作用域，再编译函数体。
//!
//! 场景：STML 文档里定义函数，参数表写在标签属性上（`params="a b"`），函数体是
//! Stope 源码。编译函数体时把 params 里的名字当 preExports 传进去，它们就先占好
//! 槽位、进 `Program.exports`；宿主在 `run()` 之前把实参写进这些槽位。
//!
//! 运行：cargo run --bin demo04

use std::collections::BTreeMap;
use std::rc::Rc;
use stope::common::Result as StopeResult;
use stope::stml::{Element, LexerState};
use stope::stml_lexer::Lexer as StmlLexer;
use stope::stml_parser::{Parser as StmlParser, StateFuncOpt};
use stope::{Api, Compiler, Lexer, Parser, Prog, Program, State, Value};

const DOC: &str = "
<stml>
<func name=\"add\" params=\"a b\" stope>
    return a + b;
</func>
</stml>
";

/// 带 stope 属性的元素，内容按 Stope 代码扫；切出来的 text 就是原样源码。
fn content_kind(_tag: &str, attrs: &BTreeMap<String, String>) -> LexerState {
    if attrs.contains_key("stope") {
        LexerState::Stope
    } else {
        LexerState::Xml
    }
}

/// 按名字找子元素。
fn child<'a>(ele: &'a Element, tag: &str) -> Option<&'a Element> {
    ele.children.iter().find(|c| c.tag == tag)
}

/// 编译一段源码，pre_exports 原样交给 Compiler。失败时打印错误并返回 false。
///
/// start_line 是 src 首行的物理行号 —— 从 STML 切出来的代码段不是从 1 开始，设给
/// lexer 之后报错行号才和文档对得上（这里直接从 fn.text_line 取）。
fn compile_src(src: &str, start_line: i32, pre_exports: &[&str], out: &mut Program) -> bool {
    let mut lexer = Lexer::new(src);
    lexer.set_line(start_line);
    let mut parser = Parser::with_lexer(lexer, None);
    let mut tree = Prog::default();
    parser.parse_program(&mut tree);
    for e in parser.lexer().errors.clone() {
        println!("  lexer: {}", e);
    }
    for e in parser.errors.clone() {
        println!("  parser: {}", e);
    }

    let mut compiler = Compiler::new(None);
    let rc = compiler.compile(&tree, out, pre_exports);
    for e in compiler.errors.clone() {
        println!("  compiler: {}", e);
    }
    rc == StopeResult::Success && parser.lexer().errors.is_empty() && parser.errors.is_empty()
}

fn main() {
    // ---------------- 1. 从 STML 里取出函数定义 ----------------
    let mut lexer = StmlLexer::new(DOC);
    let mut root = Element::new();
    let ok = {
        let mut parser = StmlParser::new(&mut lexer);
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

    let func = child(&root, "func").unwrap();
    let name = func.attrs["name"].clone();
    let params: Vec<String> = func.attrs["params"].split_whitespace().map(String::from).collect();
    println!(
        "[1] 从 <func> 取出：{}({})",
        name,
        params.join(", ")
    );

    // ---------------- 2. 用参数表当 preExports 编译 ----------------
    // 形参先占槽位（a=0、b=1），函数体里的 a、b 于是解析到文件作用域 ——
    // 反汇编里是 PushValue(0) / PushValue(1)。
    let params_ref: Vec<&str> = params.iter().map(String::as_str).collect();
    let mut program = Program::new();
    println!("\n[2] 编译函数体（preExports = 形参表）：");
    if !compile_src(&func.text, func.text_line, &params_ref, &mut program) {
        std::process::exit(1);
    }
    print!("{}", stope::disasm(&program, None));
    println!();
    println!(
        "  exports: {}",
        program
            .exports
            .iter()
            .map(|(k, v)| format!("{}={}", k, v))
            .collect::<Vec<_>>()
            .join(" ")
    );

    // ---------------- 3. 塞实参、运行 ----------------
    // 编译期就知道槽位，所以 run() 之前就能把值写进去 —— 这才是预导出的用处。
    let program = Rc::new(program);
    let mut state = State::new();
    state.set_api(Rc::new(Api::new()));
    state.set_program(program.clone());
    let a_slot = *program.exports.get("a").unwrap() as usize;
    let b_slot = *program.exports.get("b").unwrap() as usize;
    state.variables[a_slot] = Value::Int(3);
    state.variables[b_slot] = Value::Int(4);

    state.run();
    println!("\n[3] add(3, 4) = {}", match &state.returns[0] {
        Value::Int(i) => i.to_string(),
        other => format!("{:?}", other),
    });

    // ---------------- 4. 陷阱：预导出的名字不能再声明 ----------------
    // 名字已经进了文件作用域，源码里再 export 同名、或顶层 let 同名，都是 duplicate。
    println!("\n[4] 函数体里又写 export a;：");
    compile_src("export a; return a;", 1, &params_ref, &mut Program::new());
}
