# runtime.py：静态结构 + 调用 + 入口绑定（对应 C++ 的 Runtime.*）。

from stope import Handle, Result, State

from api import DemoApi
from classes import ClassInfo
from object_manager import ObjectManager


class Runtime:
    def __init__(self):
        self.host_funcs = []
        self.host_func_map = {}      # 名 -> host_funcs 序号
        self.member_name_map = {}    # 成员名 -> 成员 id（跨类共享同名 id）
        self.functions = []
        self.classes = []
        self.obj_mgr = ObjectManager(self)
        self.api = DemoApi(self.obj_mgr)
        self.frames = []         # 显式帧栈：{state, method, self_obj, wants_return}
        self.had_errors = False  # 任一帧出错置位（错误已打印，供入口返回码用）

    def new_member_id(self, nm):
        if nm in self.member_name_map:
            return self.member_name_map[nm]
        mid = len(self.member_name_map)
        self.member_name_map[nm] = mid
        return mid

    def new_class(self):
        c = ClassInfo()
        c.id = len(self.classes)
        self.classes.append(c)
        return c

    def find_function(self, nm):
        return next((f for f in self.functions if f.name == nm), None)

    def add_host_function(self, nm, fn):
        self.host_func_map[nm] = len(self.host_funcs)
        self.host_funcs.append(fn)

    # ---------- 显式帧栈：把 State 显式放在一个栈里，驱动循环只跑栈顶帧 ----------
    # 调用栈从 Python 调用栈搬进 frames 成员：方法调用压帧、返回弹帧，调用方
    # 在栈里压住等返回值。换来 run_steps(max_steps)「每帧限步」与 run_all()
    # 「一口气跑完」两种驱动，随时可切。
    # __init__ 里有：self.frames = []、self.had_errors = False。

    # 装配入口函数并压帧：宿主函数、构造器描述符、obj:* 成员描述符绑进导出
    # 槽位。按名只发生在这里（装配期），执行期间零按名查找。
    def push_entry_frame(self, entry, vm_args=None):
        state = State()
        state.set_api(self.api)
        state.set_program(entry.program)
        if vm_args is not None:
            state.set_arguments(vm_args)
        state.variables.extend([None] * (entry.program.variable_num - len(state.variables)))
        entry.initialize_state(state, [])
        self.bind_entry(state, entry)
        self.frames.append({"state": state, "method": None, "self_obj": None,
                            "wants_return": False})

    # 装配方法 State（push_method_frame / invoke_method 共用）。
    def _setup_method_state(self, m, obj, args, state):
        state.set_api(self.api)
        state.set_program(m.program)
        m.initialize_state(state, obj, args)
        for slot, host_idx in m.host_binds:
            state.variables[slot] = self.host_funcs[host_idx]
        # self:<方法名> 槽位绑 self 的绑定方法描述符——创建即绑定 self，
        # self:Greet() 无需 [对象]；去重缓存保证递归调用不重复分配。
        for slot, member_id in m.self_method_binds:
            state.variables[slot] = self.obj_mgr.bind(member_id, Handle(obj))

    # 压入方法帧，不执行——run_steps 自然切到栈顶帧。调用方（call 开口的
    # 发起方）停在 Call 的下一条；开口返回的占位 None 会被 op_call 压到调用
    # 方栈顶，弹帧收尾时用真正的返回值覆盖。
    def push_method_frame(self, m, obj, args, wants_return):
        state = State()
        self._setup_method_state(m, obj, args, state)
        self.frames.append({"state": state, "method": m, "self_obj": obj,
                            "wants_return": wants_return})

    # 每帧限步驱动：只跑栈顶帧，至多 max_steps 条指令；帧弹栈（Return / 指令
    # 流走完 / 出错中止当前函数）不消耗步数。返回 False = 帧栈已空。
    def run_steps(self, max_steps):
        while max_steps > 0 and self.frames:
            s = self.frames[-1]["state"]
            if s.i >= len(s.program.opcodes):
                self.finish_top_frame()  # Return 已把返回值备好；弹栈不消耗步数
                continue
            if s.step() != Result.Success:
                self.finish_top_frame()  # 运行期错误：只中止当前函数，调用方继续
                continue
            max_steps -= 1
        return bool(self.frames)

    # 直接执行：一口气跑到帧栈清空。与 run_steps 随时可切。
    def run_all(self):
        while self.run_steps(1 << 30):
            pass

    # 摘出栈顶帧并收尾。
    def finish_top_frame(self):
        f = self.frames.pop()
        self._finish_frame(f)

    # 帧收尾：错误打印、self: 槽位写回字段、返回值回填调用方栈顶（op_call
    # 已把占位 None 压到那里，覆盖即可）。
    def _finish_frame(self, f):
        s = f["state"]
        for e in s.errors:
            print("  vm: " + e)
            self.had_errors = True
        if f["method"] is None:
            return  # 入口帧：没有 self_props / 返回值
        # 返回前把 self: 槽位写回字段——self_props 只含方法体实际引用的属性。
        for slot, field_idx in f["method"].self_props:
            f["self_obj"].fields[field_idx] = s.variables[slot]
        # 回填调用方栈顶（wants_return 帧）。构造器帧返回的是新对象本身，不走这里。
        if f["wants_return"] and self.frames and s.returns:
            caller = self.frames[-1]["state"]
            caller.stack[-1] = s.returns[0]

    # 同步执行整个方法（obj:delete 的析构路径）：装配 + run + 收尾。Delete
    # 的清理序列中间不能让出执行权——析构跑完后还要驱逐描述符、delete 对象。
    # 析构里再调方法也走这条路：压帧没人跑（此刻正停在 step 中间）。
    def invoke_method(self, m, obj, args):
        state = State()
        self._setup_method_state(m, obj, args, state)
        state.run()
        for e in state.errors:
            print("  vm: " + e)
            self.had_errors = True
        for slot, field_idx in m.self_props:
            obj.fields[field_idx] = state.variables[slot]
        return state.returns[0] if state.returns else None

    # 装配入口函数：宿主函数、构造器描述符、obj:* 成员描述符绑进导出槽位。
    # 按名只发生在这里（装配期），state.run() 期间零按名查找。
    def bind_entry(self, state, entry):
        for slot, host_idx in entry.host_binds:
            state.variables[slot] = self.host_funcs[host_idx]
        for cls in self.classes:
            for nm, ctor_idx in cls.constructor_map.items():
                self._bind_export(state, entry, f"{cls.name}:{nm}",
                                  self.obj_mgr.new_ctor_desc(cls.id, ctor_idx))
            for prop in cls.properties:
                self._bind_export(state, entry, "obj:" + prop,
                                  self.obj_mgr.new_member_desc(self.new_member_id(prop)))
            for m in cls.methods:
                if m.name == "" or m.name in cls.constructor_map:
                    continue  # <delete> 走 obj:delete；构造器不占 obj: 名
                self._bind_export(state, entry, "obj:" + m.name,
                                  self.obj_mgr.new_member_desc(self.new_member_id(m.name)))
            if cls.deconstructor_id >= 0:
                self._bind_export(state, entry, "obj:delete",
                                  self.obj_mgr.new_member_desc(self.new_member_id("delete")))

    def _bind_export(self, state, entry, nm, handle):
        slot = entry.program.exports.get(nm)
        if slot is not None:
            state.variables[slot] = handle
