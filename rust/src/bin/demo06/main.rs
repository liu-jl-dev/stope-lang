//! Demo 06：宿主侧的垃圾回收 —— 对应 cpp/demo/06-gc/。
//!
//! 多文件拆分与 C++ 参考实现同构：object.rs（gc 节点）、gc.rs（分配器：链表/
//! 计数/同步/标记清除）、object_manager.rs（obj:* 域行为 + 安全点）、
//! runtime.rs（装配与调用 + live_states/pinned）、doc_visitor.rs（STML -> 类
//! 与函数）、api.rs（Handle 三开口转发）；本文件只留文档、装配与入口。
//! 设计推导见 cpp/docs/gc.md，Rust 侧差异见 docs/gc.md。
//!
//! 语法（与 cpp demo 逐字一致）：
//!   Person:New("Tom", 18)     构造（对象生命期归 gc，无 obj:delete）
//!   obj:friend[p] = null      字段覆盖：计数归零 -> 立即级联
//!   （没有 gc 函数：裁决时机在宿主帧循环，main 每 25 帧一次 Collect）
//!
//! ★ Rust 侧的内存管理（与 C++ demo 的差异，详见 docs/gc.md）：
//!   · Rust 没有 GC——所有权 + RAII + Drop；共享所有权走 Rc（引用计数）；
//!   · demo 的 gc 决定「何时判死」：<delete> 在判死时运行、时机确定；节点
//!     摘链后不可达，剩余 Rc 引用消失时内存由 Rc 回收——没有 C++ 的
//!     delete/trash（对象不会地址复用，悬空指针不存在）；
//!   · 描述符交给 Rc：bind 每次新建，计数归零即回收，不需要 Pin；
//!   · 「正在执行方法」的对象由 runtime.pinned 强引用保活（Rust 描述符不
//!     参与 gc，C++ 靠绑定描述符的字段引用，这里是等价物）；
//!   · MaxNodes 只计业务对象（描述符由 Rc 管）；
//!   · 所有权结构：Runtime 装配期结束后冻结为 Rc；ObjectManager 的可变状态
//!     用 RefCell，且借用严格不跨嵌套调用（与 C++ 的「随便改成员」是最大的
//!     工程差异）。
//!
//! 运行：cargo run --bin demo06

use std::collections::BTreeMap;
use std::rc::Rc;

use stope::common::Result as StopeResult;
use stope::stml::{Element, LexerState};
use stope::stml_lexer::Lexer as StmlLexer;
use stope::stml_parser::{Parser as StmlParser, StateFuncOpt};
use stope::{Api, BaseApi, State, Value};

mod api;
mod classes;
mod doc_visitor;
mod gc;
mod object;
mod object_manager;
mod runtime;

use crate::api::DemoApi;
use crate::doc_visitor::DocVisitor;
use crate::gc::GcAllocator;
use crate::object_manager::ObjectManager;
use crate::runtime::Runtime;

const DOC: &str = r#"
<stml>

<class name="Person">
  <property name="name" />
  <property name="age" />
  <property name="friend" />
  <property name="partner" />
  <method name="Greet">
    println("i am ", self:name, ", ", self:age, " years old.");
  </method>
  <method name="Age">
    return self:age;
  </method>
  <method name="Introduce">
    println("-- introducing --");
    self:Greet();
    println("age via self:Age() = ", self:Age());
  </method>
  <method name="BlockGuard">
    // 块内 let 的 guard 对象：块退出不产生任何指令——槽位归还编译器的
    // 复用池，但值还在 variables 里，gc 根扫描每次都扫得到。
    {
      let f = Person:New("block-guard", 1);
    }
    println("-- block exited: nothing freed, nothing printed --");
  </method>
  <method name="Pair">
    // 循环引用：a、b 互指，且只存在于本方法的变量里。方法一返回，两个
    // 变量槽位随栈帧销毁，引用计数停在 1 互相锁定——计数收不走，只能
    // 等标记清除裁决。
    let a = Person:New("cycle.a", 1);
    let b = Person:New("cycle.b", 2);
    obj:partner[a] = b;
    obj:partner[b] = a;
  </method>
  <new name="New" params="name age">
    self:name = name;
    self:age = age;
  </new>
  <delete>
    // 析构函数：gc 回收对象前自动跑，可以打遗言、清理宿主的非托管资源。
    println("[Person] deleted: ", self:name);
  </delete>
</class>

<func name="main">
  let p = Person:New("James", 18);
  obj:Introduce[p]();

  // 1) 引用计数级联：朋友只挂在字段上，覆盖成 null 旧值计数归零，
  //    立即析构（安全点刚同步过根，VM 侧再无 Handle，即时释放是可靠的）。
  obj:friend[p] = Person:New("Jimmy", 1);
  println("-- expect [Person] deleted: Jimmy right above --");
  obj:friend[p] = null;

  // 2) 循环引用：引用计数收不走，脚本侧也没有 gc 函数可调——裁决时机在
  //    宿主手里：驱动循环的帧边界 Collect（见 main），游戏里就是
  //    「每 N 帧收集一次」。
  obj:Pair[p]();
  println("-- expect nothing above: the pair is locked in a cycle --");
  println("-- expect two [Person] deleted above at a frame-boundary collect --");

  // 3) 垃圾 churn：丢弃结果的对象走引用计数路径，在下个安全点被逐个收走；
  //    一路积累的一次性描述符（self 绑定等）由帧边界的标记清除成批收走。
  let i = 0;
  while i < 100 {
    Person:New("garbage", i);
    i = i + 1;
  }
  println("-- expect batches of deleted above: safe-point refcount + frame-boundary sweep --");
</func>

</stml>
"#;

// 宿主函数：与 C++ demo 一致——只格式化 Integer / Float / String，其余忽略。
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
    let obj_mgr = Rc::new(ObjectManager::new());
    runtime.add_host_function(
        "println",
        Rc::new(|s: &mut State, argv: &[Value]| host_println(s, argv)),
    );
    // 注意没有 gc:Collect：宿主本来就能直接调 collect()，注册成 VM 宿主函数
    // 只是让脚本能「主动要求 gc」——去掉之后桥接闭包也跟着删，gc 时机完全
    // 归帧循环（下方 slices % 25 == 0）。

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

    // ---------- 2. 访问文档：构建类、编译函数（obj_mgr 先于冻结创建：
    //              export_binds 预算在装配期就要 new 描述符） ----------
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let visitor = DocVisitor;
        visitor.visit_doc(&mut root, &mut runtime, &obj_mgr);
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
    obj_mgr.set_runtime(rt.clone());
    let alloc: &GcAllocator = &obj_mgr.alloc;
    *alloc.max_nodes.borrow_mut() = 4096; // gc 节点上限（Rust 只计业务对象）；
    // 顶到上限先 collect 仍不够则开口报 too many gc nodes.；0 = 不限
    {
        let obj_mgr2 = obj_mgr.clone();
        *alloc.on_free.borrow_mut() =
            Some(Box::new(move |obj| obj_mgr2.run_destructor(obj)));
    }
    let api: Rc<dyn Api> = Rc::new(DemoApi {
        base: BaseApi::new(),
        obj_mgr: obj_mgr.clone(),
    });
    *rt.api.borrow_mut() = Some(api.clone());

    // ---------- 3.5 装配入口帧：绑定归 push_entry_frame ----------
    let entry = rt.find_function("main").unwrap();
    rt.push_entry_frame(&obj_mgr, entry);

    // ---------- 4. 运行：两种驱动，随时可切 + 帧边界 collect ----------
    // 限步：run_steps(20) 每帧只跑栈顶帧的至多 20 条指令，帧间就是宿主的
    //   逻辑帧；每 25 帧做一次标记清除——gc 时机完全由这个循环决定，脚本侧
    //   无感。单步调试就把 20 改成 1。
    // 直接：run_all() 一口气跑到帧栈清空——没有帧边界，gc 的裁决点只剩
    //   max_nodes 顶满与收尾那次 collect。demo 先限步 25 帧（第一轮帧边界
    //   collect 在这里触发，循环引用被破环），再直接执行跑完剩下的。
    let mut slices = 0;
    while slices < 25 && rt.run_steps(20, &obj_mgr) {
        slices += 1;
        if slices % 25 == 0 {
            let roots = rt.boundary_roots(); // 栈顶帧挂起中，直扫它
            alloc.collect(&roots);
            println!("[gc] frame slice {}: collect freed {}", slices, *alloc.last_freed.borrow());
        }
    }
    rt.run_all(&obj_mgr);
    println!("-- {} stepped slice(s), 20 steps each, then RunAll --", slices);
    alloc.collect(&rt.boundary_roots()); // 入口帧弹出后 p 不可达：最后一次收集
    obj_mgr.report_live(); // 帧栈已空，根集合随最后一步同步清零
    alloc.dispose_all(); // 退出兜底（~ObjectAllocator）：剩余对象逐个跑
    // <delete>——「deleted: James」在这里打印；内存随后由 Rc 回收
    if rt.had_errors.get() {
        std::process::exit(1);
    }
}
