# classes.py：类 / 方法 / 函数的静态结构与槽位装配
# （对应 C++ 的 Class.* / Function.*）。
# 与 demo 5 的差异：MethodInfo 多一个 export_binds。

from stope import State


class MethodInfo:
    def __init__(self):
        self.name = ""
        self.params = []
        self.program = None
        # 装配期预计算的整数索引：运行中不做任何按名查找。
        self.self_props = []         # [槽位下标, 字段下标]
        self.host_binds = []         # [槽位下标, 宿主函数序号]
        self.self_method_binds = []  # [槽位下标, 成员 id]（self:<方法名> 调用）
        # 方法体里的 <类名>:<构造名> / obj:<名> 描述符：[槽位下标, Handle]。
        # 方法有独立的 program，这些名字是它自己的隐式导出——每个 State 都要
        # 各自绑。描述符被本列表引用着，引用计数保证存活。
        self.export_binds = []
        self.param_slots = []        # params[i] -> 变量槽位下标

    def initialize_state(self, state: State, self_obj, args):
        for slot, field_idx in self.self_props:
            state.variables[slot] = self_obj.fields[field_idx]  # 字段 -> 槽位
        for k, slot in enumerate(self.param_slots):
            # 缺参静默：缺的槽位是 None（已知局限，见 docs §10）
            state.variables[slot] = args[k] if k < len(args) else None


class FunctionInfo:
    def __init__(self):
        self.name = ""
        self.params = []
        self.program = None
        self.host_binds = []
        self.param_slots = []

    def initialize_state(self, state: State, args):
        for k, slot in enumerate(self.param_slots):
            state.variables[slot] = args[k] if k < len(args) else None


class ClassInfo:
    def __init__(self):
        self.id = -1
        self.name = ""
        self.properties = []
        self.methods = []
        self.member_by_id = {}       # 成员 id -> MemberRef（唯一的查找表）
        self.constructor_map = {}    # <new 名> -> methods 下标
        self.deconstructor_id = -1
