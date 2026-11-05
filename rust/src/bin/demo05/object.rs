//! object.rs：对象模型 —— 业务对象、Handle 载荷、描述符（对应 C++ 的 Object.*）。

use std::cell::RefCell;
use std::rc::Rc;

use stope::Value;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum MemberKind {
    Prop,
    Method,
    Delete,
}

/// 业务对象。Rust 无 GC：装在 `Rc<RefCell<_>>` 里共享，最后引用消失时 Drop
/// 确定性地运行；deleted 标记 + 使用检测模拟手动管理的纪律。
pub struct Object {
    pub class_id: usize,
    pub fields: Vec<Value>, // 下标对齐 ClassInfo.properties
    pub deleted: bool,
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

/// 对象裸指针（同一性）：缓存键。
pub fn obj_key(obj: &ObjRef) -> *const RefCell<Object> {
    Rc::as_ptr(obj)
}

/// 描述符：成员（member_id + 绑定对象）或构造器（类 id + 构造器下标）。
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
