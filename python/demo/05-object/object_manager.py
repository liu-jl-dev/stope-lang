# object_manager.py：obj:* 域的全部行为（对应 C++ 的 ObjectManager.*）。

from stope import Handle

from object_model import DELETE, METHOD, PROP, CtorDesc, MemberDesc, Object


class ObjectManager:
    def __init__(self, runtime):
        self.runtime = runtime
        self.live = []  # Object，delete 后移除
        self.max_objects = 0  # 存活对象上限（live 表大小）；0 = 不限（对齐 maxDepth 约定）
        # 去重缓存：对象 -> (成员 id -> 绑定描述符)。绑定描述符只存这两样且创建后
        # 不可变，同一绑定永远等价；delete 时整组驱逐，不可达的描述符交给回收机制。
        self.bind_cache = {}

    def new_object(self, cls_id):
        obj = Object()
        obj.class_id = cls_id
        obj.fields = [None] * len(self.runtime.classes[cls_id].properties)
        self.live.append(obj)
        return Handle(obj)

    def new_member_desc(self, member_id):
        d = MemberDesc()
        d.member_id = member_id
        return Handle(d)

    def new_ctor_desc(self, cls_id, ctor_idx):
        return Handle(CtorDesc(cls_id, ctor_idx))

    # 绑定（创建即去重）。C++ 版还有 freeDescs 复用池；这里不需要 —— 驱逐后
    # 不可达的描述符由引用计数/兜环回收，池的存在意义被语言机制替掉了。
    def bind(self, member_id, obj_handle):
        obj = obj_handle.data
        by_member = self.bind_cache.setdefault(obj, {})
        hit = by_member.get(member_id)
        if hit is not None:
            return Handle(hit)  # 命中：复用
        d = MemberDesc()
        d.member_id = member_id
        d.obj = obj_handle
        by_member[member_id] = d
        return Handle(d)

    # obj:<名>[p] -> 绑定描述符（属性引用与绑定方法都从这里出发）。
    def at(self, s, handle, key):
        d = handle.data
        if not isinstance(d, MemberDesc):
            s.error("no implement for container type. ")
            return None
        if not isinstance(key, Handle):
            s.error("not an object. ")
            return None
        return self.bind(d.member_id, key)

    # obj:<属性>[p] = v -> 写字段。两层整数查询：对象自己的 class_id 选类，
    # member_by_id 查 MemberRef——同名成员在各类里落在不同位置也各归各。
    def assign(self, s, handle, value):
        d = handle.data
        if not isinstance(d, MemberDesc) or d.obj is None:
            s.error("not assignable. ")
            return
        obj = d.obj.data
        if obj.deleted:
            s.error("use after free. ")  # Python 无悬空指针：删除标记替代 UB
            return
        cls = self.runtime.classes[obj.class_id]  # 第一层
        ref = cls.member_by_id.get(d.member_id)
        if ref is None or ref.kind != PROP:
            s.error("not assignable. ")  # 该类没有这个成员 / 方法不可赋值
            return
        obj.fields[ref.index] = value  # 第二层：MemberRef.index 即字段下标

    # obj:<名>[p](...) -> 调方法；obj:<名>(...) 直接调（delete 走这里，对象在
    # 实参里）；<Class>:<New>(...) -> 构造。
    def call_member(self, s, handle, args):
        d = handle.data
        if isinstance(d, CtorDesc):
            if self.max_objects != 0 and len(self.live) >= self.max_objects:
                s.error("too many objects. ")  # 手动管理：上限内也不自动回收，必须 obj:delete
                return None
            cls = self.runtime.classes[d.cls_id]
            obj_handle = self.new_object(cls.id)
            # 构造器压帧：返回值是新对象本身（不走「弹帧回填」通道）。
            self.runtime.push_method_frame(cls.methods[d.ctor_idx],
                                           obj_handle.data, args, False)
            return obj_handle
        if isinstance(d, MemberDesc):
            # kind 由 member_by_id 查表揭晓；类来自绑定对象或实参对象。
            obj_handle = d.obj
            if obj_handle is None:
                if args and isinstance(args[0], Handle):
                    obj_handle = args[0]  # obj:delete(p) 实参形式
                else:
                    s.error("not an object. " if args else "method not bound. ")
                    return None
            obj = obj_handle.data
            if obj.deleted:
                s.error("use after free. ")
                return None
            cls = self.runtime.classes[obj.class_id]  # 第一层
            ref = cls.member_by_id.get(d.member_id)
            if ref is None:
                s.error("no method. ")  # 该类没有这个成员
                return None
            if ref.kind == DELETE:
                self.delete(s, obj)  # 绑定形式与实参形式在此收敛
                return None
            if ref.kind != METHOD:
                s.error('"Call" can only call a function. ')  # 属性不可调
                return None
            # 方法调用压帧：返回占位 None——op_call 把它压到调用方栈顶，
            # 方法帧弹栈时（_finish_frame）再回填真正的返回值。
            self.runtime.push_method_frame(cls.methods[ref.index], obj, args, True)
            return None
        s.error('"Call" can only call a function. ')
        return None

    # 跑 <delete>（可读写字段）-> 驱逐绑定描述符 -> 删除标记。双重 delete 拦下。
    def delete(self, s, obj):
        if obj not in self.live:
            s.error("double delete. ")
            return
        self.live.remove(obj)
        cls = self.runtime.classes[obj.class_id]
        if cls.deconstructor_id >= 0:
            self.runtime.invoke_method(cls.methods[cls.deconstructor_id], obj, [])
        self.bind_cache.pop(obj, None)  # 整组驱逐；不可达的描述符交给回收机制
        obj.deleted = True  # 内存回收交给引用计数/GC；之后使用即 use after free

    def report_live(self):
        if not self.live:
            print("[objects] all freed")
        else:
            parts = [f"(class {o.class_id})" for o in self.live]
            print(f"[objects] {len(self.live)} alive: {' '.join(parts)}")
        cached = sum(len(v) for v in self.bind_cache.values())
        # 差异：C++ 打 allocated/pooled 两个数（复用池）；这里只有缓存里仍被
        # 引用的绑定描述符，池被回收机制替代了。
        print(f"[bind-cache] {cached} entries")
