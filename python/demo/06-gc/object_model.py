# object_model.py：对象模型 —— gc 管理的业务对象 + 引擎管理的描述符
# （对应 cpp/demo/06-gc/ 的 Object.*）。
#
# 与 demo 5 的差异：Object 头上多了 gc 字段（侵入式循环双向链表 + 引用计数
# + 标记），生命期归 gc；描述符仍是普通对象——Python 引用计数/兜环 GC 替
# 我们记账，不需要 C++ demo 6 的 Pin。gc 字段语义见 gc.py 的头注释。

PROP, METHOD = 0, 1  # MemberKind（对应 C++ 的 kMemberProp / kMemberMethod；demo 6 无 delete）


class Object:
    """业务对象。gc 决定「何时判死」：<delete> 在判死时运行、时机确定；
    节点摘链后不可达，内存交给引用计数/兜环 GC——没有 C++ 的 delete/trash
    （对象不会地址复用，悬空指针不存在）。"""

    _next_id = 1  # 诊断打印用（C++ 打指针；Python 用自增 id 替代）

    def __init__(self):
        self.self_id = Object._next_id
        Object._next_id += 1
        self.class_id = -1
        self.fields = []  # 下标对齐 ClassInfo.properties
        # ---- gc 头 ----
        self.gc_prev = None  # 循环双向链表（哨兵是 GcAnchor）
        self.gc_next = None
        self.ref_count = 0   # 字段引用（精确）+ 根引用（安全点同步）
        self.mark = 0        # 0 未标记 / 1 已标记
        self.dead = False    # 已摘链判死：级联与 sweep 的回收名单重叠时防重复处理


class GcAnchor:
    """链表哨兵：不占对象编号，与 Object 一样有 gc_prev / gc_next（鸭子类型）。"""

    def __init__(self):
        self.gc_prev = None
        self.gc_next = None


class MemberRef:
    def __init__(self, kind, index):
        self.kind = kind
        self.index = index  # 进 properties 或 methods


class MemberDesc:
    """描述符（引用计数/兜环 GC 管理，不进 gc 链）。绑定描述符的 obj 是普通
    Handle——不持有对象：gc 只认「State 可达 + 字段引用 + 正在执行方法」。"""

    def __init__(self):
        self.member_id = -1
        self.obj = None  # Handle，None = 未绑定


class CtorDesc:
    def __init__(self, cls_id, ctor_idx):
        self.cls_id = cls_id
        self.ctor_idx = ctor_idx
