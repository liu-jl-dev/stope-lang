//! api.rs：三个开口薄转发到 ObjectManager（对应 C++ 的 API.*）。

use std::rc::Rc;

use stope::{Api, BaseApi, State, Value};

use crate::object_manager::ObjectManager;

pub struct DemoApi {
    pub base: BaseApi,
    pub obj_mgr: Rc<ObjectManager>,
}

impl Api for DemoApi {
    fn op_map(&self) -> &[stope::basic_vm::OpFunc] {
        &self.base.op_map
    }

    fn handle_at(&self, s: &mut State, handle: &Value, key: &Value) -> Value {
        self.obj_mgr.at(s, handle, key)
    }

    fn handle_assign(&self, s: &mut State, handle: &Value, value: &Value) {
        self.obj_mgr.assign(s, handle, value)
    }

    fn handle_call(&self, s: &mut State, handle: &Value, args: &[Value]) -> Value {
        self.obj_mgr.call_member(s, handle, args)
    }
}
