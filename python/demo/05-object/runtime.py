# runtime.py：静态结构 + 调用 + 入口绑定（对应 C++ 的 Runtime.*）。

from stope import Handle, State

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

    # 方法调用：每层调用一个临时 State，随返回销毁 —— 嵌套调用就是 Python 的
    # 递归栈。Runtime 不保存调用栈（demo 6 做根扫描时才需要）。
    def invoke_method(self, m, obj, args):
        state = State()
        state.set_api(self.api)
        state.set_program(m.program)
        m.initialize_state(state, obj, args)
        for slot, host_idx in m.host_binds:
            state.variables[slot] = self.host_funcs[host_idx]
        # self:<方法名> 槽位绑 self 的绑定方法描述符——创建即绑定 self，
        # self:Greet() 无需 [对象]；去重缓存保证递归调用不重复分配。
        for slot, member_id in m.self_method_binds:
            state.variables[slot] = self.obj_mgr.bind(member_id, Handle(obj))
        state.run()
        for e in state.errors:
            print("  vm: " + e)
        # 返回前把 self: 槽位写回字段（只写实际引用的那几个）。
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
