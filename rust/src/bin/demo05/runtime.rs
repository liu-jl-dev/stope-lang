//! runtime.rs：静态结构 + 调用 + 入口绑定（对应 cpp/demo/05-object/ 的 Runtime.*）。
//!
//! 执行模型是**显式帧栈**：`frames` 里每帧一个 State，`run_steps(max)` 只跑
//! 栈顶帧的至多 max 条指令，`run_all()` 一口气跑到帧栈清空，随时可切。方法
//! 调用不再递归——call 开口把新帧放进 `pending` 暂存队列，run_steps 在每条
//! 指令之后搬运到 frames 顶。这样 `frames` 的 RefCell 借用可以跨 step 持有
//! （回调只碰 pending，绝不碰 frames），绕开 `&mut State` 独占借用与回调
//! 重入的冲突。
//!
//! 析构 `<delete>`（obj:delete）走**同步旁路** `invoke_method`：跑完调用方
//! 还要清字段，不能让出执行权。

use std::cell::{Cell, RefCell};
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
    // frames 显式帧栈：入口帧 + 压住的方法帧。run_steps 每次只跑栈顶帧；
    // 方法调用压帧、返回弹帧，调用方在栈里压住等返回值。
    pub frames: RefCell<Vec<Frame>>,
    // pending 待挂帧暂存：call 开口的回调不能借 frames（run_steps 正持着
    // borrow_mut 跑栈顶帧），把新帧先放这里，run_steps 在每条指令之后搬运。
    pub pending: RefCell<Vec<PendingFrame>>,
    pub had_errors: Cell<bool>, // 任一帧出错置位（错误已打印，供入口返回码用）
}

// frame 一个执行帧：一个 State 加「弹栈时怎么收尾」的元数据。method 信息
// 拷贝成收尾所需的最小集（self_props / self_obj / wants_return），避免在
// Frame 里挂对 classes 的借用。
pub struct Frame {
    pub state: State,
    pub self_props: Vec<(usize, usize)>, // (槽位下标, 字段下标)
    pub self_obj: Option<ObjRef>,        // None = 入口帧（main）：不回写不回填
    pub wants_return: bool,              // true = 弹栈时把 returns[0] 回填调用方栈顶
}

// pending_frame 暂存形态与 Frame 相同，state 直接搬走。
pub struct PendingFrame {
    pub state: State,
    pub self_props: Vec<(usize, usize)>,
    pub self_obj: Option<ObjRef>,
    pub wants_return: bool,
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
            frames: RefCell::new(Vec::new()),
            pending: RefCell::new(Vec::new()),
            had_errors: Cell::new(false),
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

    // ---------- 显式帧栈驱动 ----------

    // push_entry_frame 装配入口函数并压帧：宿主函数、构造器描述符、obj:* 成
    // 员描述符绑进导出槽位（bind_entry）。
    pub fn push_entry_frame(&self, obj_mgr: &ObjectManager, entry: &FunctionInfo) {
        let api = self.api.borrow().as_ref().unwrap().clone();
        let mut state = State::new();
        state.set_api(api);
        state.set_program(entry.program.clone());
        self.bind_entry(obj_mgr, &mut state, entry);
        self.frames.borrow_mut().push(Frame {
            state,
            self_props: Vec::new(),
            self_obj: None,
            wants_return: false,
        });
    }

    // setup_method_state 装配方法 State（暂存帧 / 同步旁路共用）。
    pub fn setup_method_state(
        &self,
        obj_mgr: &ObjectManager,
        m: &MethodInfo,
        obj: &ObjRef,
        args: &[Value],
    ) -> State {
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
        state
    }

    // stage_method_frame call 开口的回调侧：不碰 frames，把新帧放进 pending
    //（run_steps 在本条指令结束后搬运）。
    pub fn stage_method_frame(
        &self,
        obj_mgr: &ObjectManager,
        m: &MethodInfo,
        obj: &ObjRef,
        args: &[Value],
        wants_return: bool,
    ) {
        let state = self.setup_method_state(obj_mgr, m, obj, args);
        self.pending.borrow_mut().push(PendingFrame {
            state,
            self_props: m.self_props.clone(),
            self_obj: Some(obj.clone()),
            wants_return,
        });
    }

    // drain_pending 把暂存帧搬到帧栈顶（每条指令结束后调用；此刻没有任何
    // frames 借用）。
    fn drain_pending(&self) {
        let pending: Vec<PendingFrame> = std::mem::take(&mut *self.pending.borrow_mut());
        if pending.is_empty() {
            return;
        }
        let mut frames = self.frames.borrow_mut();
        for p in pending {
            frames.push(Frame {
                state: p.state,
                self_props: p.self_props,
                self_obj: p.self_obj,
                wants_return: p.wants_return,
            });
        }
    }

    // run_steps 每帧限步驱动：只跑栈顶帧，至多 max_steps 条指令；帧弹栈
    // （Return / 指令流走完 / 出错中止当前函数）不消耗步数。返回 false =
    // 帧栈已空。frames 的借用跨 step 持有是安全的：回调只碰 pending。
    pub fn run_steps(&self, max_steps: usize) -> bool {
        let mut steps = max_steps;
        while steps > 0 {
            if self.frames.borrow().is_empty() {
                return false;
            }
            enum Action {
                Stepped,
                Finish,
            }
            let action = {
                let mut frames = self.frames.borrow_mut();
                let top = frames.last_mut().unwrap();
                let n = top.state.program.as_ref().unwrap().opcodes.len() as isize;
                if top.state.i >= n {
                    Action::Finish // Return 已把返回值备好；弹栈不消耗步数
                } else if top.state.step() == stope::common::Result::Success {
                    Action::Stepped
                } else {
                    Action::Finish // 运行期错误：只中止当前函数，调用方继续
                }
            };
            match action {
                Action::Stepped => {
                    self.drain_pending();
                    steps -= 1;
                }
                Action::Finish => self.finish_top_frame(),
            }
        }
        !self.frames.borrow().is_empty()
    }

    // run_all 直接执行：一口气跑到帧栈清空。与 run_steps 随时可切。
    pub fn run_all(&self) {
        while self.run_steps(usize::MAX) {}
    }

    // finish_top_frame 摘出栈顶帧并收尾：错误打印、self: 槽位写回字段、返回
    // 值回填调用方栈顶（op_call 已把占位 Null 压到那里，覆盖即可）。此刻没
    // 有任何回调在跑，borrow 自由。
    fn finish_top_frame(&self) {
        let f = self.frames.borrow_mut().pop().unwrap();
        for e in &f.state.errors {
            println!("  vm: {}", e);
            self.had_errors.set(true);
        }
        let obj = match &f.self_obj {
            Some(o) => o,
            None => return, // 入口帧：没有 selfProps / 返回值
        };
        // 返回前把 self: 槽位写回字段——selfProps 只含方法体实际引用的属性。
        for (slot, field_idx) in &f.self_props {
            obj.borrow_mut().fields[*field_idx] = f.state.variables[*slot].clone();
        }
        // 回填调用方栈顶（wantsReturn 帧）。
        if f.wants_return {
            if let Some(v) = f.state.returns.first().cloned() {
                let mut frames = self.frames.borrow_mut();
                if let Some(caller) = frames.last_mut() {
                    *caller.state.stack.last_mut().unwrap() = v;
                }
            }
        }
    }

    // invoke_method 同步执行整个方法（<delete> 析构路径）：装配 + Run + 收尾。
    // 析构走正常错误通道、跑完调用方还要清字段——不能让出执行权。析构里再
    // 调方法也走这条路：压帧没人跑（此刻正停在 Step 中间）。
    pub fn invoke_method(
        &self,
        obj_mgr: &ObjectManager,
        m: &MethodInfo,
        obj: &ObjRef,
        args: &[Value],
    ) -> Value {
        let mut state = self.setup_method_state(obj_mgr, m, obj, args);
        state.run();
        for e in &state.errors {
            println!("  vm: {}", e);
            self.had_errors.set(true);
        }
        // 返回前把 self: 槽位写回字段（只写实际引用的那几个）。
        for (slot, field_idx) in &m.self_props {
            obj.borrow_mut().fields[*field_idx] = state.variables[*slot].clone();
        }
        state.returns.first().cloned().unwrap_or(Value::Null)
    }

    // bind_entry 装配入口函数：宿主函数、构造器描述符、obj:* 成员描述符绑进
    // 导出槽位。按名只发生在这里（装配期），run 期间零按名查找。
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
