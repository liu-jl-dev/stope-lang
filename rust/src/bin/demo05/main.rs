//! Demo 05：宿主侧的面向对象 —— 对应 cpp/demo/05-object/。
//!
//! 多文件拆分与 C++ 参考实现同构：object.rs（对象模型）、classes.rs（类/方法/
//! 函数）、object_manager.rs（obj:* 域行为）、runtime.rs（装配与调用）、
//! doc_visitor.rs（STML -> 类与函数）、api.rs（Handle 三开口转发）；本文件只留
//! 文档、装配与入口。设计推导见 cpp/docs/object-oriented.md，Rust 侧差异见
//! docs/object-oriented.md。
//!
//! Stope 的值世界里没有对象：类、属性、方法、构造、析构全部长在宿主侧。
//! 语言/编译器零改动，BasicVM 只认 `Value::Handle`（宿主引用）——At 读 /
//! Assign 写 / Call 调三个动作经 `Api` trait 的 handle_at / handle_assign /
//! handle_call 方法转交 ObjectManager。
//!
//! ★ Rust 侧的内存管理（与 C++ demo 的差异，详见 docs/object-oriented.md）：
//!   · Rust **没有 GC**——所有权 + RAII + Drop；共享所有权走 `Rc`（引用计数）；
//!   · 业务对象装在 `Rc<RefCell<Object>>` 里：最后一个 Rc 消失时 Drop
//!     **确定性地**运行（计数是 Rc 的本性）；环引用会泄漏（要打破得用 `Weak`，
//!     与 GDScript 同口径）；
//!   · 但 VM 变量仍持 Handle 时**无法强杀**——没有手动 free。「手动管理」
//!     模拟为：删除标记（deleted）+ 使用检测（用后即报 use after free，而
//!     不是 C++ 的悬空 UB）；
//!   · **析构函数的有效性不受影响**：<delete> 只在显式 obj:delete 时运行，
//!     时机确定；
//!   · 描述符同样交给 Rc：驱逐缓存后计数归零即回收，不需要 C++ 的 freeDescs
//!     复用池；bindCache 用两级 map（对象裸指针 -> map[成员 id]描述符），
//!     驱逐是 O(1) 整组摘除；
//!   · 所有权结构：Runtime 在装配期结束后**冻结为 `Rc`**（类表/函数表只读，
//!     方法递归就是不可变借用栈）；ObjectManager 的可变状态（live 表、
//!     bindCache）用 `RefCell`，且**借用严格不跨嵌套调用**——这与 C++ 的
//!     「随便改成员」是最大的工程差异。
//!
//! 运行：cargo run --bin demo05

use std::collections::BTreeMap;
use std::rc::Rc;

use stope::common::Result as StopeResult;
use stope::stml::{Element, LexerState};
use stope::stml_lexer::Lexer as StmlLexer;
use stope::stml_parser::{Parser as StmlParser, StateFuncOpt};
use stope::{State, Value};

mod api;
mod classes;
mod doc_visitor;
mod object;
mod object_manager;
mod runtime;

use crate::api::DemoApi;
use crate::doc_visitor::DocVisitor;
use crate::object_manager::ObjectManager;
use crate::runtime::Runtime;

const DOC: &str = r#"
<stml>

<class name="Person">
  <property name="name" />
  <property name="age" />
  <method name="Greet">
    println("i am ", self:name, ", ", self:age, " years old.");
  </method>
  <method name="Age">
    return self:age;
  </method>
  <method name="Introduce">
    // self:<方法名>() 调用同对象的另一个方法，无需 [对象]：self 绑定
    println("-- introducing --");
    self:Greet();
    println("age via self:Age() = ", self:Age());
  </method>
  <new name="New" params="name age">
    self:name = name;
    self:age = age;
  </new>
  <delete>
    // 析构函数，可以用来清理宿主的非托管资源等
    println("[Person] deleted!");
  </delete>
</class>

<func name="main">
  let p = Person:New("Tom", 18);
  obj:name[p] = "James";
  obj:Introduce[p]();
  obj:delete(p);
</func>

</stml>
"#;

// 宿主函数：与 C++ demo 一致——只格式化 Integer / Float / String，其余忽略。
// Rust 宿主函数就是栈上的一个值，签名 fn(&mut State, &[Value]) -> Value。
fn host_println(_s: &mut State, argv: &[Value]) -> Value {
    let mut out = String::new();
    for a in argv {
        match a {
            Value::Int(i) => out.push_str(&i.to_string()),
            Value::Float(f) => out.push_str(&fmt_float(*f)),
            Value::Str(u) => {
                if let Some(t) = String::from_utf16(u).ok() {
                    out.push_str(&t);
                }
            }
            _ => {}
        }
    }
    println!("{}", out);
    Value::Null
}

// 浮点按 C++ iostream 默认精度（6 位有效数字）的样子打，读起来对得上
fn fmt_float(v: f64) -> String {
    if v == (v as i64) as f64 && v.abs() < 1e15 {
        format!("{}", v as i64)
    } else {
        format!("{:?}", v)
    }
}

// 带 stope 属性的元素，内容按 Stope 代码扫；其余按子元素列表（Xml）解析。
fn content_kind(tag: &str, _attrs: &BTreeMap<String, String>) -> LexerState {
    if tag == "method" || tag == "new" || tag == "delete" || tag == "func" {
        LexerState::Stope
    } else {
        LexerState::Xml
    }
}

fn main() {
    let mut runtime = Runtime::new();
    runtime.add_host_function(
        "println",
        Rc::new(|s: &mut State, argv: &[Value]| host_println(s, argv)),
    );

    // ---------- 1. STML 解析：代码段标签按 Stope 代码扫 ----------
    let mut lexer = StmlLexer::new(DOC);
    let mut parser = StmlParser::new(&mut lexer);
    let mut root = Element::new();
    if parser.parse(&mut root, StateFuncOpt::Custom(Box::new(content_kind)))
        != StopeResult::Success
    {
        for e in &parser.errors.clone() {
            println!("{}", e);
        }
        std::process::exit(1);
    }

    // ---------- 2. 访问文档：构建类、编译函数 ----------
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let visitor = DocVisitor;
        visitor.visit_doc(&mut root, &mut runtime);
    }));
    if let Err(e) = result {
        if let Some(msg) = e.downcast_ref::<&str>() {
            println!("{}", msg);
        } else if let Some(msg) = e.downcast_ref::<String>() {
            println!("{}", msg);
        }
        std::process::exit(1);
    }
    if runtime.find_function("main").is_none() {
        println!("no main function");
        std::process::exit(1);
    }

    // ---------- 3. 冻结 Runtime，装配主 State：绑定归 bind_entry ----------
    let rt = Rc::new(runtime);
    let obj_mgr = Rc::new(ObjectManager::new(rt.clone()));
    let api: Rc<dyn Api> = Rc::new(DemoApi {
        base: BaseApi::new(),
        obj_mgr: obj_mgr.clone(),
    });
    *rt.api.borrow_mut() = Some(api.clone());

    let mut state = State::new();
    state.set_api(api.clone());
    {
        let entry = rt.find_function("main").unwrap();
        state.set_program(entry.program.clone());
        rt.bind_entry(&obj_mgr, &mut state, entry);
    }

    // ---------- 4. 运行 + 手动清理诊断 ----------
    if state.run() != StopeResult::Success {
        for e in &state.errors {
            println!("  vm: {}", e);
        }
    }
    obj_mgr.report_live(); // 忘了 obj:delete 的对象在这里现形
    if !state.errors.is_empty() {
        std::process::exit(1);
    }
}

use stope::{Api, BaseApi};
