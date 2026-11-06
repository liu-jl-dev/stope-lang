//! object.rs：对象模型 —— 业务对象、Handle 载荷、描述符（对应 C++ 的 Object.*）。
//!
//! 与 demo 5 的差异：Object 头上多了 gc 字段（侵入式循环双向链表 + 引用计数
//! + 标记），生命期归 demo 的 gc 分配器——判死时跑 <delete>、摘链、清字段，
//! 剩余的 Rc 引用消失后内存由 Rc 回收。gc 字段语义见 gc.rs 的头注释。

use std::cell::RefCell;
use std::rc::Rc;

use stope::Value;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum MemberKind {
    Prop,
    Method,
}

pub fn next_obj_id() -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(1);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

/// 业务对象。gc 决定「何时判死」：<delete> 在判死时运行、时机确定；节点
/// 摘链后不可达，剩余 Rc 引用消失时内存由 Rc 回收——没有 C++ 的
/// delete/trash（对象不会地址复用，悬空指针不存在）。
pub struct Object {
    pub self_id: u64, // 诊断打印用（C++ 打指针；Rust 侧用自增 id 替代）
    pub class_id: usize,
    pub fields: Vec<Value>, // 下标对齐 ClassInfo.properties
    // ---- gc 头 ----
    pub gc_prev: Option<ObjRef>, // 循环双向链表（哨兵是分配器里的 anchor 节点）
    pub gc_next: Option<ObjRef>,
    pub ref_count: isize, // 字段引用（精确）+ 根引用（安全点同步）
    pub mark: bool,       // 0 未标记 / 1 已标记
    pub dead: bool,       // 已摘链判死：级联与 sweep 的回收名单重叠时防重复处理
}

pub type ObjRef = Rc<RefCell<Object>>;

/// Handle 的 Any 载荷：包一层才能从 downcast 里拿回 ObjRef（`Rc<RefCell<T>>`
/// 直接 coerce 进 `Rc<dyn Any>` 的话，下转拿到的是 `RefCell<T>`，Rc 已丢失）。
pub struct ObjHandle(pub ObjRef);

/// 把 ObjRef 装进 Value::Handle；同一性 = ObjHandle 分配的同一性。
pub fn handle_of(obj: &ObjRef) -> Value {
    Value::Handle(Rc::new(ObjHandle(obj.clone())))
}

/// 从 Handle 取回对象（demo 内部约定：Handle 的 Any 就是 ObjHandle）。
pub fn obj_of(handle: &Value) -> Option<ObjRef> {
    if let Value::Handle(any) = handle {
        if let Some(h) = any.downcast_ref::<ObjHandle>() {
            return Some(h.0.clone());
        }
    }
    None
}

/// 对象裸指针（同一性）：根集合的键。
pub fn obj_key(obj: &ObjRef) -> *const RefCell<Object> {
    Rc::as_ptr(obj)
}

/// 描述符：成员（member_id + 绑定对象）或构造器（类 id + 构造器下标）。
/// 描述符由 Rc 管（引用计数），不进 gc 链——不需要 C++ demo 6 的 Pin。
#[derive(Clone)]
pub enum Desc {
    Member { member_id: i32, obj: Option<Value> },
    Ctor { cls_id: usize, ctor_idx: usize },
}

/// 描述符也装成 Handle（Rc<Desc>）。
pub fn desc_handle(d: Desc) -> Value {
    Value::Handle(Rc::new(d))
}

pub fn desc_of(handle: &Value) -> Option<Desc> {
    if let Value::Handle(any) = handle {
        if let Some(d) = any.downcast_ref::<Desc>() {
            return Some(d.clone()); // Desc: Clone；克隆的是描述符，不是对象
        }
    }
    None
}

pub struct MemberRef {
    pub kind: MemberKind,
    pub index: usize, // 进 properties 或 methods
}
