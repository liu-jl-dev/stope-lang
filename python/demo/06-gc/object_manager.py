# object_manager.py：obj:* 域的全部行为（对应 C++ 的 ObjectManager.*）。
#
# 与 demo 5 的差异：没有 bind_cache / live 表 / obj:delete——描述符每次
# bind 新建（引用计数回收不可达者），对象生命期归 gc 分配器。
# 三个开口入口先 safe_point()：安全点根同步，先于一切 del_ref。

from stope import Handle

from gc_alloc import GcAllocator
from object_model import METHOD, PROP, CtorDesc, MemberDesc


class ObjectManager:
    def __init__(self, runtime):
        self.runtime = runtime
        self.alloc = GcAllocator()  # gc 分配器（C++ 版住在 ObjectManager 里）

    # new 业务对象。返回 None = 顶到 max_nodes（调用方 s.error）。
    def new_object(self, cls_id):
        obj = self.alloc.new_object()
        if obj is None:
            return None
        obj.class_id = cls_id
        obj.fields = [None] * len(self.runtime.classes[cls_id].properties)
        return Handle(obj)

    # 描述符：每次新建，不去重——demo 5 的 bind_cache / 驱逐在 demo 6 里
    # 全部消失，不可达的描述符由引用计数当场回收。
    def new_member_desc(self, member_id):
        d = MemberDesc()
        d.member_id = member_id
        return Handle(d)

    def new_ctor_desc(self, cls_id, ctor_idx):
        return Handle(CtorDesc(cls_id, ctor_idx))

    # 绑定描述符：每次新建。obj 是普通 Handle——描述符不持有对象（引用计数
    # 管不到 gc 对象），「正在执行方法」的对象由 runtime.pinned 保活。
    def bind(self, member_id, obj_handle):
        d = MemberDesc()
        d.member_id = member_id
        d.obj = obj_handle
        return Handle(d)

    # 三个开口的公共前奏：安全点——先同步根集合，再做本次操作。「引用计数
    # 归零 -> 立即级联释放」的可靠性由这条顺序保证（见 gc.py 头注释）。
    def safe_point(self):
        self.alloc.sync_roots()

    # obj:<名>[p] -> 绑定描述符。
    def at(self, s, handle, key):
        self.safe_point()
        d = handle.data
        if not isinstance(d, MemberDesc):
            s.error("no implement for container type. ")
            return None
        if not isinstance(key, Handle):
            s.error("not an object. ")
            return None
        return self.bind(d.member_id, key)

    # obj:<属性>[p] = v -> 写字段（走 set_field：旧值减引用可级联，新值加引用）。
    def assign(self, s, handle, value):
        self.safe_point()
        d = handle.data
        if not isinstance(d, MemberDesc) or d.obj is None:
            s.error("not assignable. ")
            return
        obj = d.obj.data
        if obj.dead:
            s.error("use after gc. ")  # 死对象不可达才判死，正常程序到不了这里
            return
        cls = self.runtime.classes[obj.class_id]  # 第一层
        ref = cls.member_by_id.get(d.member_id)
        if ref is None or ref.kind != PROP:
            s.error("not assignable. ")  # 该类没有这个属性 / 方法不可赋值
            return
        self.alloc.set_field(obj, ref.index, value)  # 第二层

    # obj:<名>[p](...) -> 调方法；<Class>:<New>(...) -> 构造。
    # demo 6 没有 obj:delete(p)：生命期归 gc 管。
    def call_member(self, s, handle, args):
        self.safe_point()
        d = handle.data
        if isinstance(d, CtorDesc):
            cls = self.runtime.classes[d.cls_id]
            obj_handle = self.new_object(cls.id)
            if obj_handle is None:
                s.error("too many gc nodes. ")  # 顶到 max_nodes：走正常错误通道
                return None
            # 构造器压帧：返回值是新对象本身（不走「弹帧回填」通道）。
            self.runtime.push_method_frame(cls.methods[d.ctor_idx],
                                           obj_handle.data, args, False)
            return obj_handle
        if isinstance(d, MemberDesc):
            if d.obj is None:
                s.error("method not bound. ")  # demo 6 只支持 obj:<名>[p]() 形式
                return None
            obj = d.obj.data
            if obj.dead:
                s.error("use after gc. ")
                return None
            cls = self.runtime.classes[obj.class_id]  # 第一层
            ref = cls.member_by_id.get(d.member_id)
            if ref is None or ref.kind != METHOD:
                s.error("no method. ")  # 该类没有这个方法（属性不可调）
                return None
            # 方法调用压帧：返回占位 None——op_call 把它压到调用方栈顶，
            # 方法帧弹栈时（_finish_frame）再回填真正的返回值。
            self.runtime.push_method_frame(cls.methods[ref.index], obj, args, True)
            return None
        s.error('"Call" can only call a function. ')
        return None

    # gc 回收前回调（alloc.on_free）：跑 <delete>。此时字段还完整可读。
    def run_destructor(self, obj):
        cls = self.runtime.classes[obj.class_id]
        if cls.deconstructor_id >= 0:
            self.runtime.invoke_method(cls.methods[cls.deconstructor_id], obj, [])

    def report_live(self):
        self.alloc.report_alive()
        if not self.alloc.root_set:
            print("[gc] no roots: everything reachable has been freed")
        else:
            print(f"[gc] roots keep {len(self.alloc.root_set)} object(s) alive")
