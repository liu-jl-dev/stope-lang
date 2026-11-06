# runtime.py：静态结构 + 调用 + 入口绑定（对应 C++ 的 Runtime.*）。

from stope import Handle, Result, State

from api import DemoApi
from classes import ClassInfo
from object_model import Object
from object_manager import ObjectManager


class Runtime:
    def __init__(self):
        self.host_funcs = []
        self.host_func_map = {}      # 名 -> host_funcs 序号
        self.member_name_map = {}    # 成员名 -> 成员 id（跨类共享同名 id）
        self.class_map = {}          # 类名 -> 类 id（export_binds 按类名找构造器）
        self.functions = []
        self.classes = []
        self.obj_mgr = ObjectManager(self)
        self.api = DemoApi(self.obj_mgr)
        # gc 根扫描的范围 = 显式帧栈 frames（入口帧 + 压住的方法帧）+
        # live_states（只装 <delete> 析构的同步旁路 State，见 invoke_method）。
        self.frames = []     # Frame 字典：{state, method, self_obj, wants_return}
        self.live_states = []
        self.had_errors = False  # 任一帧出错置位（错误已打印，供入口返回码用）
        # 正在执行方法的对象（Python 版的「保活」机制）：C++ demo 6 靠绑定
        # 描述符的字段引用撑住 self，Python 的描述符不参与 gc，改由这个列表
        # 强引用——push_method_frame 压入、弹帧收尾弹出；invoke_method 同样。
        self.pinned = []
        # gc 根扫描：分配器不认识 State，由 Runtime 供给。只有「Handle 载荷
        # 是 Object」才算引用；描述符由引擎管，不算。
        self.obj_mgr.alloc.gather_roots = self.gather_roots
        # 析构回调：对象被回收前跑 <delete>。
        self.obj_mgr.alloc.on_free = self.obj_mgr.run_destructor

    def gather_roots(self):
        out = []

        def scan(s):
            for arr in (s.variables, s.stack, s.returns):
                for v in arr:
                    if isinstance(v, Handle) and isinstance(v.data, Object):
                        out.append(v.data)

        for f in self.frames:
            scan(f["state"])
        for s in self.live_states:
            scan(s)
        for o in self.pinned:
            out.append(o)
        return out

    def track_state(self, s):
        self.live_states.append(s)

    def untrack_state(self, s):
        # 从后往前找：调用栈是 LIFO，最后一个匹配就是要拆的那个。
        for i in range(len(self.live_states) - 1, -1, -1):
            if self.live_states[i] is s:
                self.live_states.pop(i)
                return

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

    # 装配入口函数并压帧：宿主函数、构造器描述符、obj:* 成员描述符绑进导出
    # 槽位。demo 6 没有 obj:delete——生命期归 gc 管，<delete> 是回收时自动
    # 跑的析构。
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
        # 方法体里的 <类名>:<构造名> / obj:<名> 描述符：装配期已预算好
        # (槽位, Handle)，逐个拷进槽位。
        for slot, handle in m.export_binds:
            state.variables[slot] = handle
        # self:<方法名> 槽位绑 self 的绑定方法描述符——每次新建（不去重）。
        for slot, member_id in m.self_method_binds:
            state.variables[slot] = self.obj_mgr.bind(member_id, Handle(obj))

    # 压入方法帧，不执行——run_steps 自然切到栈顶帧。调用方（call 开口的
    # 发起方）停在 Call 的下一条；开口返回的占位 None 会被 op_call 压到调用
    # 方栈顶，弹帧收尾时用真正的返回值覆盖。self 进 pinned 保活。
    def push_method_frame(self, m, obj, args, wants_return):
        state = State()
        self._setup_method_state(m, obj, args, state)
        self.frames.append({"state": state, "method": m, "self_obj": obj,
                            "wants_return": wants_return})
        self.pinned.append(obj)

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

    # 帧收尾：错误打印、self: 槽位写回字段（走 set_field：引用计数照常维护）、
    # 返回值回填调用方栈顶（op_call 已把占位 None 压到那里，覆盖即可）。
    def _finish_frame(self, f):
        s = f["state"]
        for e in s.errors:
            print("  vm: " + e)
            self.had_errors = True
        if f["method"] is None:
            return  # 入口帧：没有 self_props / 返回值
        self.pinned.pop()  # 与 push_method_frame 配对
        # 返回前把 self: 槽位写回字段——self_props 只含方法体实际引用的属性。
        for slot, field_idx in f["method"].self_props:
            self.obj_mgr.alloc.set_field(f["self_obj"], field_idx, s.variables[slot])
        # 回填调用方栈顶（wants_return 帧）。构造器帧返回的是新对象本身，不走这里。
        if f["wants_return"] and self.frames and s.returns:
            caller = self.frames[-1]["state"]
            caller.stack[-1] = s.returns[0]

    # 同步执行整个方法（<delete> 析构路径）：装配 + run + 收尾。析构在级联
    # 释放 / sweep 的中间被调用，跑完后调用方还要清字段——不能让出执行权。
    # 析构里再调方法也走这条路：压帧没人跑（此刻正停在 step 中间）。
    def invoke_method(self, m, obj, args):
        state = State()
        self._setup_method_state(m, obj, args, state)
        self.pinned.append(obj)
        self.track_state(state)
        state.run()
        self.untrack_state(state)
        self.pinned.pop()
        for e in state.errors:
            print("  vm: " + e)
            self.had_errors = True
        for slot, field_idx in m.self_props:
            self.obj_mgr.alloc.set_field(obj, field_idx, state.variables[slot])
        return state.returns[0] if state.returns else None

    # 装配入口函数：宿主函数、构造器描述符、obj:* 成员描述符绑进导出槽位。
    # demo 6 没有 obj:delete——生命期归 gc 管，<delete> 是回收时自动跑的析构。
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
                    continue  # 构造器不占 obj: 名
                self._bind_export(state, entry, "obj:" + m.name,
                                  self.obj_mgr.new_member_desc(self.new_member_id(m.name)))

    def _bind_export(self, state, entry, nm, handle):
        slot = entry.program.exports.get(nm)
        if slot is not None:
            state.variables[slot] = handle
