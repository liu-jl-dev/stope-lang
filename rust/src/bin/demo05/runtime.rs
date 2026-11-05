//! runtime.rs：静态结构 + 调用 + 入口绑定（对应 C++ 的 Runtime.*）。

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;

use stope::{State, Value};

use crate::classes::{ClassInfo, FunctionInfo, MethodInfo};
use crate::object::ObjRef;
use crate::object_manager::ObjectManager;

pub struct Runtime {
    pub host_funcs: Vec<stope::basic_vm::HostFn>,
    pub host_func_map: BTreeMap<String, usize>, // 名 -> host_funcs 序号
    pub member_name_map: BTreeMap<String, i32>, // 成员名 -> 成员 id（跨类共享同名 id）
    pub member_id_next: i32,
    pub functions: Vec<FunctionInfo>,
    pub classes: Vec<ClassInfo>,
    pub api: RefCell<Option<Rc<dyn Api>>>, // 装配完成后由 main 塞入
}

use stope::Api;

impl Runtime {
    pub fn new() -> Self {
        Runtime {
            host_funcs: Vec::new(),
            host_func_map: BTreeMap::new(),
            member_name_map: BTreeMap::new(),
            member_id_next: 0,
            functions: Vec::new(),
            classes: Vec::new(),
            api: RefCell::new(None),
        }
    }

    pub fn new_member_id(&mut self, nm: &str) -> i32 {
        if let Some(id) = self.member_name_map.get(nm) {
            return *id;
        }
        let id = self.member_id_next;
        self.member_id_next += 1;
        self.member_name_map.insert(nm.to_string(), id);
        id
    }

    pub fn new_class(&mut self) -> usize {
        let id = self.classes.len();
        self.classes.push(ClassInfo {
            id,
            name: String::new(),
            properties: Vec::new(),
            methods: Vec::new(),
            member_by_id: std::collections::HashMap::new(),
            constructor_map: BTreeMap::new(),
            deconstructor_id: -1,
        });
        id
    }

    pub fn find_function(&self, nm: &str) -> Option<&FunctionInfo> {
        self.functions.iter().find(|f| f.name == nm)
    }

    pub fn add_host_function(&mut self, nm: &str, f: stope::basic_vm::HostFn) {
        self.host_func_map.insert(nm.to_string(), self.host_funcs.len());
        self.host_funcs.push(f);
    }

    // 方法调用：每层调用一个临时 State，随返回销毁 —— 嵌套调用就是 Rust 的
    // 递归栈（全部是不可变借用）。Runtime 不保存调用栈（demo 6 做根扫描时才需要）。
    pub fn invoke_method(
        &self,
        obj_mgr: &ObjectManager,
        m: &MethodInfo,
        obj: &ObjRef,
        args: &[Value],
    ) -> Value {
        let api = self.api.borrow().as_ref().unwrap().clone();
        let mut state = State::new();
        state.set_api(api);
        state.set_program(m.program.clone());
        m.initialize_state(&mut state, obj, args);
        for (slot, host_idx) in &m.host_binds {
            state.variables[*slot] = Value::HostFunction(self.host_funcs[*host_idx].clone());
        }
        // self:<方法名> 槽位绑 self 的绑定方法描述符——创建即绑定 self，
        // self:Greet() 无需 [对象]；去重缓存保证递归调用不重复分配。
        for (slot, member_id) in &m.self_method_binds {
            let h = obj_mgr.bind(*member_id, &crate::object::handle_of(obj));
            state.variables[*slot] = h;
        }
        state.run();
        for e in &state.errors {
            println!("  vm: {}", e);
        }
        // 返回前把 self: 槽位写回字段（只写实际引用的那几个）。
        for (slot, field_idx) in &m.self_props {
            obj.borrow_mut().fields[*field_idx] = state.variables[*slot].clone();
        }
        state.returns.first().cloned().unwrap_or(Value::Null)
    }

    // 装配入口函数：宿主函数、构造器描述符、obj:* 成员描述符绑进导出槽位。
    // 按名只发生在这里（装配期），state.run() 期间零按名查找。
    pub fn bind_entry(&self, obj_mgr: &ObjectManager, state: &mut State, entry: &FunctionInfo) {
        for (slot, host_idx) in &entry.host_binds {
            state.variables[*slot] = Value::HostFunction(self.host_funcs[*host_idx].clone());
        }
        for cls in &self.classes {
            for (nm, ctor_idx) in &cls.constructor_map {
                bind_export(
                    state,
                    entry,
                    &format!("{}:{}", cls.name, nm),
                    obj_mgr.new_ctor_desc(cls.id, *ctor_idx),
                );
            }
            for prop in &cls.properties {
                let id = self.member_name_map[prop];
                bind_export(state, entry, &format!("obj:{}", prop), obj_mgr.new_member_desc(id));
            }
            for m in &cls.methods {
                if m.name.is_empty() || cls.constructor_map.contains_key(&m.name) {
                    continue; // <delete> 走 obj:delete；构造器不占 obj: 名
                }
                let id = self.member_name_map[&m.name];
                bind_export(state, entry, &format!("obj:{}", m.name), obj_mgr.new_member_desc(id));
            }
            if cls.deconstructor_id >= 0 {
                let id = self.member_name_map["delete"];
                bind_export(state, entry, "obj:delete", obj_mgr.new_member_desc(id));
            }
        }
    }
}

pub fn bind_export(state: &mut State, entry: &FunctionInfo, nm: &str, handle: Value) {
    match entry.program.exports.get(nm) {
        Some(slot) => state.variables[*slot as usize] = handle,
        None => {}
    }
}
