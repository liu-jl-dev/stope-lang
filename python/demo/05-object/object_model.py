# object_model.py：对象模型 —— 业务对象与描述符（对应 C++ 的 Object.*）。

PROP, METHOD, DELETE = 0, 1, 2  # MemberKind


class Object:
    """业务对象。Python 无手动释放：deleted 标记 + 使用检测模拟手动管理的纪律。"""

    def __init__(self):
        self.class_id = -1
        self.fields = []  # 下标对齐 ClassInfo.properties
        self.deleted = False


class MemberRef:
    def __init__(self, kind, index):
        self.kind = kind
        self.index = index  # 进 properties 或 methods


class MemberDesc:
    """成员描述符：member_id + obj（绑定后才有，Handle）。"""

    def __init__(self):
        self.member_id = -1
        self.obj = None  # Handle，None = 未绑定


class CtorDesc:
    def __init__(self, cls_id, ctor_idx):
        self.cls_id = cls_id
        self.ctor_idx = ctor_idx
