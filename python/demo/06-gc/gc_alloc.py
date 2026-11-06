# gc_alloc.py：对象分配器（对应 cpp/demo/06-gc/ 的 ObjectAllocator）。
#
# 引用计数的口径（与 C++ 版逐字对应，详见 cpp/docs/gc.md）：
#   * VM 对 Handle 的复制不通知宿主（Clear2/Copy 对 Handle 是无操作——缝的
#     设计），所以「栈/变量里此刻有哪些 Handle」只能靠扫描得知。
#   * ref_count = 字段引用（set_field 精确维护）+ 根引用（sync_roots 同步）。
#   * 安全点 = 每个 obj:* 开口入口 + collect 入口：扫描全部在册 State 的
#     variables/stack/returns，Handle 一律算根，diff 出增减。**先加后删**——
#     删除触发的级联发生在刚扫描完、根集合新鲜的瞬间，此时计数归零必然
#     意味着 VM 侧再无 Handle，「立即级联释放」才可靠。
# Python 差异：没有 String/BinArr 引用计数（引擎管）；「释放」= 摘链 + 判死
# + 清字段，内存交给引用计数/兜环 GC——没有 C++ 的 trash/flush_trash
# （对象不会地址复用，悬空指针不存在）。

from stope import Handle

from object_model import GcAnchor, Object


class GcAllocator:
    def __init__(self):
        self.anchor = GcAnchor()  # 哨兵：anchor.gc_next = 第一个对象
        self.anchor.gc_prev = self.anchor
        self.anchor.gc_next = self.anchor
        self.root_set = set()    # 当前认定的根对象集合
        self.alive_count = 0     # 链上真实对象数（触发器用）
        self.gc_trigger = 64     # 存活数到阈值，分配前先 collect
        self.max_nodes = 0       # gc 节点上限（Python 侧只计业务对象，描述符由
                                 # 引擎管）；顶到上限先 collect 仍放不下则分配
                                 # 失败。0 = 不限
        self.collecting = False  # collect 重入守卫
        self.last_freed = 0      # 上次 collect 释放数（诊断用）
        self.gather_roots = None  # 安全点根扫描：宿主注册（枚举在册 State + pinned）
        self.on_free = None       # 回收前回调：跑 <delete>（析构）

    # 新对象挂到链尾。返回 None = 顶到 max_nodes（开口里 s.error 报错）。
    def new_object(self):
        if not self.collecting and self.max_nodes != 0 and self.alive_count >= self.max_nodes:
            self.collect()  # 顶到上限：先回收再判断——gc 还有机会救
        if self.max_nodes != 0 and self.alive_count >= self.max_nodes:
            return None
        obj = Object()
        obj.gc_next = self.anchor
        obj.gc_prev = self.anchor.gc_prev
        self.anchor.gc_prev.gc_next = obj
        self.anchor.gc_prev = obj
        self.alive_count += 1
        return obj

    # ==================== 安全点：根同步 ====================

    # 先加后删的原因：删除可能级联释放。假设先删后加——根集合里过期的引用
    # 被摘除时，那个对象可能「恰好刚被本轮扫描发现在另一个 State 里」，先删
    # 会把它连同还活着的引用一起级联释放，后加就是把悬空指针登记成根。
    def sync_roots(self):
        if self.gather_roots is None or self.collecting:
            return  # 收集期间跳过重扫：根集合保持 collect 入口时的新鲜度
        found = self.gather_roots()

        # 先加：本轮新发现的根 +1（同一对象在多个槽位出现只记一次根）。
        for o in found:
            if o.dead:
                continue  # 防御：死对象不可达，不该出现在扫描结果里
            if o not in self.root_set:
                self.root_set.add(o)
                o.ref_count += 1
        # 后删：上一轮的根这轮没再出现 -> -1，归零立即级联。
        stale = [o for o in self.root_set if o not in found]
        for o in stale:
            self.root_set.discard(o)  # 无论死活都摘出根集合
            if o.dead:
                continue  # 同轮级联已收走
            o.ref_count -= 1
            if o.ref_count < 1:
                self.free_now(o)  # 刚确认：VM 侧再无 Handle，立即级联释放

    # ==================== 引用计数 ====================

    # 只有 Handle 且载荷是 Object 才是对象引用；描述符由引擎管。
    @staticmethod
    def _obj_of(v):
        if isinstance(v, Handle):
            return v.data if isinstance(v.data, Object) else None
        return None

    def add_ref(self, v):
        o = self._obj_of(v)
        if o is not None and not o.dead:
            o.ref_count += 1

    def del_ref(self, v):
        o = self._obj_of(v)
        if o is None or o.dead:
            return
        o.ref_count -= 1
        if o.ref_count < 1:
            self.free_now(o)  # 归零立即级联释放

    # 字段写入：旧引用先减（可能级联），再挂新引用。Python 无 String 引用计数。
    def set_field(self, obj, index, v):
        self.del_ref(obj.fields[index])
        obj.fields[index] = v
        self.add_ref(v)

    # ==================== 释放（两条路径；Python 无需延迟删除） ====================

    # 计数归零路径：字段里的 Handle 引用递减，归零的子对象**级联**释放。
    def free_now(self, obj):
        if obj.dead:
            return
        if self.on_free is not None:
            self.on_free(obj)  # <delete> 先跑：字段还完整可读
        for v in obj.fields:
            child = self._obj_of(v)
            if child is not None and not child.dead:
                child.ref_count -= 1
                if child.ref_count < 1:
                    self.free_now(child)  # 级联
        obj.fields = []
        self._unlink(obj)

    # sweep 路径：字段引用只减计数**不级联**——真死透的子对象马上就轮到。
    def free_sweep(self, obj):
        if obj.dead:
            return
        if self.on_free is not None:
            self.on_free(obj)
        for v in obj.fields:
            child = self._obj_of(v)
            if child is not None and not child.dead and child.ref_count > 0:
                child.ref_count -= 1
        obj.fields = []
        self._unlink(obj)

    def _unlink(self, obj):
        obj.gc_prev.gc_next = obj.gc_next
        obj.gc_next.gc_prev = obj.gc_prev
        obj.dead = True
        self.alive_count -= 1

    # ==================== gc：标记清除 ====================

    # 迭代式标记：沿字段里的 Handle 引用铺开，显式栈防深对象图爆 Python 栈
    # （sys.setrecursionlimit 管不到显式循环，天然安全）。
    def mark_from(self, root):
        if root.dead or root.mark != 0:
            return
        work = [root]
        root.mark = 1
        while work:
            o = work.pop()
            for v in o.fields:
                c = self._obj_of(v)
                if c is not None and not c.dead and c.mark == 0:
                    c.mark = 1
                    work.append(c)

    def collect(self):
        if self.collecting:
            return  # 析构里新建对象顶到阈值等重入：本次跳过，下个安全点再来
        self.sync_roots()  # 收集前根集合先刷新到最新（此刻还没置位）

        self.collecting = True
        self.last_freed = 0

        # 标记：从全部根出发。
        for root in self.root_set:
            self.mark_from(root)

        # 清除：先收集死对象再逐个回收——on_free（析构）可能读写字段。
        doomed = []
        h = self.anchor.gc_next
        while h is not self.anchor:
            if h.mark == 0:
                doomed.append(h)
            h = h.gc_next
        for o in doomed:
            if not o.dead:  # 前面的析构可能已经级联/重入收走了它
                self.free_sweep(o)
                self.last_freed += 1

        # 清标记：只走还活着的链。
        h = self.anchor.gc_next
        while h is not self.anchor:
            h.mark = 0
            h = h.gc_next

        self.collecting = False
        self.gc_trigger = max(64, self.alive_count * 2)

    # 退出兜底（C++ 的 ~ObjectAllocator）：逐个跑析构、判死——剩余对象（p）
    # 的「deleted: James」在这里打印；内存随后由引擎回收。
    def dispose_all(self):
        h = self.anchor.gc_next
        while h is not self.anchor:
            nxt = h.gc_next
            if self.on_free is not None:
                self.on_free(h)
            self._unlink(h)
            h = nxt

    # ==================== 诊断 ====================

    def report_alive(self):
        objs = 0
        h = self.anchor.gc_next
        while h is not self.anchor:
            objs += 1
            h = h.gc_next
        print(f"[gc] alive: {objs} object(s), root set {len(self.root_set)}")
        h = self.anchor.gc_next
        while h is not self.anchor:
            print(f"  {h.self_id}  class {h.class_id}  refCount {h.ref_count}")
            h = h.gc_next
