//! classes.rs：类 / 方法 / 函数的静态结构与槽位装配
//! （对应 C++ 的 Class.* / Function.*）。与 demo 5 的差异：MethodInfo 多一个
//! export_binds。

use std::collections::{BTreeMap, HashMap};
use std::rc::Rc;

use stope::{Program, State, Value};

use crate::object::{MemberRef, ObjRef};

pub struct MethodInfo {
    pub name: String,
    pub params: Vec<String>,
    pub program: Rc<Program>,
    // 装配期预计算的整数索引：运行中不做任何按名查找。
    pub self_props: Vec<(usize, usize)>,      // (槽位下标, 字段下标)
    pub host_binds: Vec<(usize, usize)>,      // (槽位下标, 宿主函数序号)
    pub self_method_binds: Vec<(usize, i32)>, // (槽位下标, 成员 id)
    // 方法体里的 <类名>:<构造名> / obj:<名> 描述符：(槽位下标, Handle)。
    // 方法有独立的 program，这些名字是它自己的隐式导出——每个 State 都要
    // 各自绑。描述符被本列表引用着，引用计数保证存活。
    pub export_binds: Vec<(usize, Value)>,
    pub param_slots: Vec<usize>, // params[i] -> 变量槽位下标
}

impl MethodInfo {
    pub fn initialize_state(&self, state: &mut State, self_obj: &ObjRef, args: &[Value]) {
        for (slot, field_idx) in &self.self_props {
            state.variables[*slot] = self_obj.borrow().fields[*field_idx].clone(); // 字段 -> 槽位
        }
        for (k, slot) in self.param_slots.iter().enumerate() {
            // 缺参静默：缺的槽位是 Null（已知局限，见 docs §10）
            state.variables[*slot] = args.get(k).cloned().unwrap_or(Value::Null);
        }
    }
}

pub struct FunctionInfo {
    pub name: String,
    pub params: Vec<String>,
    pub program: Rc<Program>,
    pub host_binds: Vec<(usize, usize)>,
    pub param_slots: Vec<usize>,
}

pub struct ClassInfo {
    pub id: usize,
    pub name: String,
    pub properties: Vec<String>,
    pub methods: Vec<MethodInfo>,
    pub member_by_id: HashMap<i32, MemberRef>,    // 唯一的查找表
    pub constructor_map: BTreeMap<String, usize>, // <new 名> -> methods 下标
    pub deconstructor_id: i32,
}
