//! object_manager.rs：obj:* 域的全部行为（对应 C++ 的 ObjectManager.*）。

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use stope::{State, Value};

use crate::classes::ClassInfo;
use crate::object::{desc_handle, desc_of, handle_of, obj_key, obj_of, Desc, MemberKind, Object, ObjRef};
use crate::runtime::Runtime;

pub struct ObjectManager {
    pub runtime: Rc<Runtime>,   // 冻结后的只读运行时（类表/函数表/宿主函数表）
    pub live: RefCell<Vec<ObjRef>>, // delete 后移除
    // 去重缓存：对象裸指针 -> (成员 id -> 绑定描述符)。绑定描述符只存这两样且
    // 创建后不可变，同一绑定永远等价；delete 时整组驱逐，计数归零即回收。
    pub bind_cache: RefCell<HashMap<*const RefCell<Object>, HashMap<i32, Value>>>,
}

impl ObjectManager {
    pub fn new(runtime: Rc<Runtime>) -> Self {
        ObjectManager {
            runtime,
            live: RefCell::new(Vec::new()),
            bind_cache: RefCell::new(HashMap::new()),
        }
    }

    pub fn new_object(&self, cls_id: usize) -> Value {
        let obj = ObjRef::new(RefCell::new(Object {
            class_id: cls_id,
            fields: vec![Value::Null; self.runtime.classes[cls_id].properties.len()],
            deleted: false,
        }));
        self.live.borrow_mut().push(obj.clone());
        handle_of(&obj)
    }

    pub fn new_member_desc(&self, member_id: i32) -> Value {
        desc_handle(Desc::Member { member_id, obj: None })
    }

    pub fn new_ctor_desc(&self, cls_id: usize, ctor_idx: usize) -> Value {
        desc_handle(Desc::Ctor { cls_id, ctor_idx })
    }

    // 绑定（创建即去重）。C++ 版还有 freeDescs 复用池；这里不需要 —— 驱逐后
    // 计数归零的描述符由 Rc 当场回收，池的存在意义被语言机制替掉了。
    pub fn bind(&self, member_id: i32, obj_handle: &Value) -> Value {
        let obj = obj_of(obj_handle).expect("bind: not an object");
        let key = obj_key(&obj);
        let mut cache = self.bind_cache.borrow_mut();
        let by_member = cache.entry(key).or_default();
        if let Some(hit) = by_member.get(&member_id) {
            return hit.clone(); // 命中：复用
        }
        let d = desc_handle(Desc::Member {
            member_id,
            obj: Some(obj_handle.clone()),
        });
        by_member.insert(member_id, d.clone());
        d
    }

    // obj:<名>[p] -> 绑定描述符（属性引用与绑定方法都从这里出发）。
    pub fn at(&self, s: &mut State, handle: &Value, key: &Value) -> Value {
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
            Desc::Member { member_id, .. } => match obj_of(key) {
                Some(_) => self.bind(member_id, key),
                None => {
                    s.error("not an object. ");
                    Value::Null
                }
            },
        }
    }

    // obj:<属性>[p] = v -> 写字段。两层整数查询：对象自己的 class_id 选类，
    // member_by_id 查 MemberRef——同名成员在各类里落在不同位置也各归各。
    pub fn assign(&self, s: &mut State, handle: &Value, value: &Value) {
        let d = match desc_of(handle) {
            Some(d) => d,
            None => {
                s.error("not assignable. ");
                return;
            }
        };
        let (member_id, obj_handle) = match d {
            Desc::Member { member_id, obj } => (member_id, obj.clone()),
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
        if obj.borrow().deleted {
            s.error("use after free. "); // Rust 无悬空指针：删除标记替代 UB
            return;
        }
        let class_id = obj.borrow().class_id;
        let cls = &self.runtime.classes[class_id]; // 第一层
        let r = match cls.member_by_id.get(&member_id) {
            Some(r) if r.kind == MemberKind::Prop => r,
            _ => {
                s.error("not assignable. "); // 该类没有这个成员 / 方法不可赋值
                return;
            }
        };
        let idx = r.index; // 第二层：MemberRef.index 即字段下标
        obj.borrow_mut().fields[idx] = value.clone();
    }

    // obj:<名>[p](...) -> 调方法；obj:<名>(...) 直接调（delete 走这里，对象在
    // 实参里）；<Class>:<New>(...) -> 构造。
    pub fn call_member(&self, s: &mut State, handle: &Value, args: &[Value]) -> Value {
        let d = match desc_of(handle) {
            Some(d) => d,
            None => {
                s.error("\"Call\" can only call a function. ");
                return Value::Null;
            }
        };
        match d {
            Desc::Ctor { cls_id, ctor_idx } => {
                let obj_handle = self.new_object(cls_id);
                let obj = obj_of(&obj_handle).unwrap();
                let m = &self.runtime.classes[cls_id].methods[ctor_idx];
                self.runtime.invoke_method(self, m, &obj, args);
                obj_handle
            }
            Desc::Member { member_id, obj } => {
                // kind 由 member_by_id 查表揭晓；类来自绑定对象或实参对象。
                let mut obj_handle = obj.clone();
                if obj_handle.is_none() {
                    if let Some(first) = args.first() {
                        if obj_of(first).is_some() {
                            obj_handle = Some(first.clone()); // obj:delete(p) 实参形式
                        }
                    }
                    if obj_handle.is_none() {
                        if !args.is_empty() {
                            s.error("not an object. "); // 实参不是对象
                        } else {
                            s.error("method not bound. "); // obj:<方法> 未带 [对象]
                        }
                        return Value::Null;
                    }
                }
                let bound_obj = obj_of(obj_handle.as_ref().unwrap()).unwrap();
                if bound_obj.borrow().deleted {
                    s.error("use after free. ");
                    return Value::Null;
                }
                let member_id = member_id;
                let class_id = bound_obj.borrow().class_id;
                let cls: &ClassInfo = &self.runtime.classes[class_id]; // 第一层
                let r = match cls.member_by_id.get(&member_id) {
                    Some(r) => r,
                    None => {
                        s.error("no method. "); // 该类没有这个成员
                        return Value::Null;
                    }
                };
                match r.kind {
                    MemberKind::Delete => {
                        self.delete(s, &bound_obj); // 绑定形式与实参形式在此收敛
                        Value::Null
                    }
                    MemberKind::Prop => {
                        s.error("\"Call\" can only call a function. "); // 属性不可调
                        Value::Null
                    }
                    MemberKind::Method => {
                        let m = &cls.methods[r.index];
                        self.runtime.invoke_method(self, m, &bound_obj, args)
                    }
                }
            }
        }
    }

    // 跑 <delete>（可读写字段）-> 驱逐绑定描述符 -> 删除标记。双重 delete 拦下。
    pub fn delete(&self, s: &mut State, obj: &ObjRef) {
        let pos = self
            .live
            .borrow()
            .iter()
            .position(|o| obj_key(o) == obj_key(obj));
        match pos {
            Some(i) => {
                self.live.borrow_mut().remove(i);
            }
            None => {
                s.error("double delete. ");
                return;
            }
        }
        let cls_id = obj.borrow().class_id;
        let deid = self.runtime.classes[cls_id].deconstructor_id;
        if deid >= 0 {
            let m = &self.runtime.classes[cls_id].methods[deid as usize];
            self.runtime.invoke_method(self, m, obj, &[]);
        }
        self.bind_cache.borrow_mut().remove(&obj_key(obj)); // 整组驱逐；计数归零即回收
        obj.borrow_mut().deleted = true; // 内存回收交给 Rc；之后使用即 use after free
    }

    pub fn report_live(&self) {
        let live = self.live.borrow();
        if live.is_empty() {
            println!("[objects] all freed");
        } else {
            let parts: Vec<String> = live
                .iter()
                .map(|o| format!("(class {})", o.borrow().class_id))
                .collect();
            println!("[objects] {} alive: {}", live.len(), parts.join(" "));
        }
        let cached: usize = self.bind_cache.borrow().values().map(|m| m.len()).sum();
        // 差异：C++ 打 allocated/pooled 两个数（复用池）；这里只有缓存里仍被
        // 引用的绑定描述符，池被 Rc 替代了。
        println!("[bind-cache] {} entries", cached);
    }
}
