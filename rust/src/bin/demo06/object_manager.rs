//! object_manager.rs：obj:* 域的全部行为（对应 C++ 的 ObjectManager.*）。
//!
//! 与 demo 5 的差异：没有 bind_cache / live 表 / obj:delete——描述符每次
//! bind 新建（Rc 回收不可达者），对象生命期归 gc 分配器。
//! 三个开口入口先 safe_point()：安全点根同步，先于一切 del_ref。
//! runtime 用 `RefCell<Option<Rc<Runtime>>>` 延迟注入：描述符/绑定在装配期
//! 就要创建（Runtime 还没冻结），析构与诊断在冻结后才需要它。

use std::cell::RefCell;
use std::rc::Rc;

use stope::{State, Value};

use crate::gc::GcAllocator;
use crate::object::{desc_handle, desc_of, obj_of, Desc, MemberKind, ObjRef};
use crate::runtime::Runtime;

pub struct ObjectManager {
    pub runtime: RefCell<Option<Rc<Runtime>>>, // 冻结后由 main 注入
    pub alloc: GcAllocator,
}

impl ObjectManager {
    pub fn new() -> Self {
        ObjectManager {
            runtime: RefCell::new(None),
            alloc: GcAllocator::new(),
        }
    }

    pub fn set_runtime(&self, rt: Rc<Runtime>) {
        *self.runtime.borrow_mut() = Some(rt);
    }

    fn rt(&self) -> Rc<Runtime> {
        self.runtime.borrow().as_ref().unwrap().clone()
    }

    // new_object new 业务对象。返回 None = 顶到 max_nodes（调用方 s.error）。
    pub fn new_object(&self, cls_id: usize, roots: &[ObjRef]) -> Option<Value> {
        let obj_handle = self.alloc.new_object(roots)?;
        let obj = obj_of(&obj_handle).unwrap();
        obj.borrow_mut().class_id = cls_id;
        let n = self.rt().classes[cls_id].properties.len();
        obj.borrow_mut().fields = vec![Value::Null; n];
        Some(obj_handle)
    }

    // 描述符：每次新建，不去重——demo 5 的 bind_cache / 驱逐在 demo 6 里
    // 全部消失，计数归零的描述符由 Rc 当场回收。
    pub fn new_member_desc(&self, member_id: i32) -> Value {
        desc_handle(Desc::Member { member_id, obj: None })
    }

    pub fn new_ctor_desc(&self, cls_id: usize, ctor_idx: usize) -> Value {
        desc_handle(Desc::Ctor { cls_id, ctor_idx })
    }

    // bind 绑定描述符：每次新建。Obj 是普通 Handle——描述符不持有对象
    // （Rc 管不到 gc 对象），「正在执行方法」的对象由 Runtime.pinned 保活。
    pub fn bind(&self, member_id: i32, obj_handle: &Value) -> Value {
        desc_handle(Desc::Member {
            member_id,
            obj: Some(obj_handle.clone()),
        })
    }

    // safe_point 三个开口的公共前奏：安全点——先同步根集合，再做本次操作。
    // 当前 State 由开口参数直接扫描（Rust 的 &mut State 不经 RefCell，没有
    // 借用冲突）；外层 State 的可达性由快照栈 + pinned 覆盖（见 runtime.rs）。
    // 「引用计数归零 -> 立即级联释放」的可靠性由这条顺序保证。
    pub fn safe_point(&self, s: &State) {
        let roots = self.rt().gather_roots_with(Some(s));
        self.alloc.sync_roots(&roots);
    }

    // at obj:<名>[p] -> 绑定描述符。
    pub fn at(&self, s: &mut State, handle: &Value, key: &Value) -> Value {
        self.safe_point(s);
        let d = match desc_of(handle) {
            Some(d) => d,
            None => {
                s.error("no implement for container type. ");
                return Value::Null;
            }
        };
        match d {
            Desc::Ctor { .. } => {
                s.error("no implement for container type. "); // 构造描述符不可 At
                Value::Null
            }
            Desc::Member { member_id, .. } => {
                if obj_of(key).is_some() {
                    self.bind(member_id, key)
                } else {
                    s.error("not an object. ");
                    Value::Null
                }
            }
        }
    }

    // assign obj:<属性>[p] = v -> 写字段（走 set_field：旧值减引用可级联）。
    pub fn assign(&self, s: &mut State, handle: &Value, value: &Value) {
        self.safe_point(s);
        let d = match desc_of(handle) {
            Some(d) => d,
            None => {
                s.error("not assignable. ");
                return;
            }
        };
        let (member_id, obj_handle) = match d {
            Desc::Member { member_id, obj } => (member_id, obj),
            Desc::Ctor { .. } => {
                s.error("not assignable. ");
                return;
            }
        };
        let obj = match obj_handle.and_then(|h| obj_of(&h)) {
            Some(o) => o,
            None => {
                s.error("not assignable. ");
                return;
            }
        };
        if obj.borrow().dead {
            s.error("use after gc. "); // 死对象不可达才判死，正常程序到不了这里
            return;
        }
        let class_id = obj.borrow().class_id;
        let cls = &self.rt().classes[class_id]; // 第一层
        let r = match cls.member_by_id.get(&member_id) {
            Some(r) if r.kind == MemberKind::Prop => r,
            _ => {
                s.error("not assignable. "); // 该类没有这个属性 / 方法不可赋值
                return;
            }
        };
        let idx = r.index; // 第二层：MemberRef.index 即字段下标
        self.alloc.set_field(&obj, idx, value);
    }

    // call_member obj:<名>[p](...) -> 调方法；<Class>:<New>(...) -> 构造。
    // demo 6 没有 obj:delete(p)：生命期归 gc 管。
    pub fn call_member(&self, s: &mut State, handle: &Value, args: &[Value]) -> Value {
        self.safe_point(s);
        let d = match desc_of(handle) {
            Some(d) => d,
            None => {
                s.error("\"Call\" can only call a function. ");
                return Value::Null;
            }
        };
        match d {
            Desc::Ctor { cls_id, ctor_idx } => {
                let caller_roots = self.rt().gather_roots_with(Some(s));
                let obj_handle = match self.new_object(cls_id, &caller_roots) {
                    Some(h) => h,
                    None => {
                        s.error("too many gc nodes. "); // 顶到 max_nodes：正常错误通道
                        return Value::Null;
                    }
                };
                let obj = obj_of(&obj_handle).unwrap();
                let rt = self.rt();
                let m = &rt.classes[cls_id].methods[ctor_idx];
                if rt.in_sync_run.get() {
                    // 析构同步旁路里的构造：压帧没人跑（驱动循环停在 Step
                    // 中间），走同步路径一口气跑完。
                    rt.invoke_method_with_roots(self, m, &obj, args, &caller_roots);
                } else {
                    // 构造器压帧：返回值是新对象本身（不走「弹帧回填」通道）。
                    rt.stage_method_frame(self, m, &obj, args, caller_roots, false);
                }
                obj_handle
            }
            Desc::Member { member_id, obj } => {
                let obj_handle = match obj {
                    Some(h) => h,
                    None => {
                        s.error("method not bound. "); // demo 6 只支持 obj:<名>[p]() 形式
                        return Value::Null;
                    }
                };
                let bound_obj = match obj_of(&obj_handle) {
                    Some(o) => o,
                    None => {
                        s.error("use after gc. ");
                        return Value::Null;
                    }
                };
                if bound_obj.borrow().dead {
                    s.error("use after gc. ");
                    return Value::Null;
                }
                let class_id = bound_obj.borrow().class_id;
                let rt = self.rt();
                let cls = &rt.classes[class_id]; // 第一层
                let r = match cls.member_by_id.get(&member_id) {
                    Some(r) => r,
                    None => {
                        s.error("no method. "); // 该类没有这个方法（属性不可调）
                        return Value::Null;
                    }
                };
                if r.kind != MemberKind::Method {
                    s.error("\"Call\" can only call a function. "); // 属性不可调
                    return Value::Null;
                }
                let m = &cls.methods[r.index];
                if rt.in_sync_run.get() {
                    // 析构同步旁路里的方法调用：同上，走同步路径。
                    return rt.invoke_method_with_roots(self, m, &bound_obj, args, &[]);
                }
                // 方法调用压帧：返回占位 Null——op_call 把它压到调用方栈顶，
                // 方法帧弹栈时（finish_top_frame）再回填真正的返回值。
                let caller_roots = self.rt().gather_roots_with(Some(s));
                rt.stage_method_frame(self, m, &bound_obj, args, caller_roots, true);
                Value::Null
            }
        }
    }

    // run_destructor gc 回收前回调（alloc.on_free）：跑 <delete>。字段还完整
    // 可读。此时没有「当前 State」（回收发生在安全点路径上），根以快照与
    // pinned 为准。
    pub fn run_destructor(&self, obj: &ObjRef) {
        let rt = self.rt();
        let cls_id = obj.borrow().class_id;
        let deid = rt.classes[cls_id].deconstructor_id;
        if deid >= 0 {
            let m = &rt.classes[cls_id].methods[deid as usize];
            rt.invoke_method_with_roots(self, m, obj, &[], &[]);
        }
    }

    pub fn report_live(&self) {
        self.alloc.report_alive();
        if self.alloc.root_count() == 0 {
            println!("[gc] no roots: everything reachable has been freed");
        } else {
            println!(
                "[gc] roots keep {} object(s) alive - frame stack not empty (freed by dispose_all)",
                self.alloc.root_count()
            );
        }
    }
}
