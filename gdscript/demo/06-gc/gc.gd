# gc.gd：对象分配器（对应 cpp/demo/06-gc/ 的 ObjectAllocator）。
#
# 引用计数的口径（demo 6 最需要想清楚的地方，与 C++ 版逐字对应）：
#   * VM 对 Handle 的复制不通知宿主（Clear2/Copy 对 Handle 是无操作——缝的
#     设计），所以「栈/变量里此刻有哪些 Handle」只能靠扫描得知。
#   * refCount = 字段引用（set_field 精确维护）+ 根引用（sync_roots 同步）。
#   * 安全点 = 每个 obj:* 开口入口 + Collect 入口：扫描全部在册 State 的
#     variables/stack/returns，Handle 一律算根，diff 出增减。**先加后删**——
#     删除触发的级联发生在刚扫描完、根集合新鲜的瞬间，此时计数归零必然
#     意味着 VM 侧再无 Handle，「立即级联释放」才可靠。
# GD 差异：没有 String/BinArr 引用计数（引擎管），SetField 不需要 Clear2；
# free() 是引擎调用，延迟删除用 trash 数组 + flush_trash()——理由与 C++ 相同
# （级联与 sweep 的回收名单重叠时，名单里的指针要保到用完为止）。

extends RefCounted

# 统一入口：addons/stope 不注册全局类，preload 门面后按 Stope.模块 访问
const Stope = preload("res://addons/stope/stope.gd")

const Objects := preload("res://demo/06-gc/objects.gd")

var anchor = Objects.GcAnchor.new()	# 哨兵：anchor.gc_next = 第一个对象
var root_set:Dictionary = {}		# 当前认定的根对象集合（obj -> true）
var alive_count:int = 0		# 链上真实对象数（触发器用）
var gc_trigger:int = 64		# 存活数到阈值，分配前先 Collect
var max_nodes:int = 0		# gc 节点上限（GD 侧只计业务对象，描述符由引擎管）；
				# 顶到上限先 Collect 仍放不下则分配失败。0 = 不限
var collecting:bool = false	# Collect 重入守卫
var last_freed:int = 0		# 上次 Collect 释放数（诊断用）
var trash:Array = []		# 已摘链待 free：安全点末尾统一冲刷

# 安全点根扫描：宿主注册——枚举全部在册 State 的 variables/stack/returns
# 与正在执行方法的对象，把 MyObject 塞进参数。分配器不认识 State。
var gather_roots:Callable = Callable()
# 回收前回调：跑 <delete>（析构）。析构体可以读写自己的字段、调方法。
var on_free:Callable = Callable()

func _init() -> void:
	anchor.gc_next = anchor
	anchor.gc_prev = anchor

# 新对象挂到链尾。返回 null = 顶到 max_nodes（开口里 s.error 报错）。
func new_object() -> Variant:
	if not collecting and max_nodes != 0 and alive_count >= max_nodes:
		collect()	# 顶到上限：先回收再判断——gc 还有机会救
	if max_nodes != 0 and alive_count >= max_nodes:
		return null
	var obj = Objects.MyObject.new()
	obj.gc_next = anchor
	obj.gc_prev = anchor.gc_prev
	anchor.gc_prev.gc_next = obj
	anchor.gc_prev = obj
	alive_count += 1
	return obj

# 宿主长期持有（GD 侧目前没有 C++ 的 Pin 场景：描述符由引擎引用计数管），
# 字段留空以便将来扩展。

# ==================== 安全点：根同步 ====================

# 先加后删的原因：删除可能级联释放。假设先删后加——根集合里过期的引用
# 被摘除时，那个对象可能「恰好刚被本轮扫描发现在另一个 State 里」，先删
# 会把它连同还活着的引用一起级联释放，后加就是把悬空指针登记成根。
func sync_roots() -> void:
	if not gather_roots.is_valid() or collecting:
		return	# 收集期间跳过重扫：根集合保持 Collect 入口时的新鲜度
	var found:Array = []
	gather_roots.call(found)

	# 先加：本轮新发现的根 +1（同一对象在多个槽位出现只记一次根）。
	for o in found:
		if o.dead:
			continue	# 防御：死对象不可达，不该出现在扫描结果里
		if not root_set.has(o):
			root_set[o] = true
			o.ref_count += 1
	# 后删：上一轮的根这轮没再出现 -> -1，归零立即级联。释放只摘链不 free
	# （进 trash），本轮名单里的指针始终有效，dead 标志挡住重复处理。
	var stale:Array = []
	for o in root_set:
		if not found.has(o):
			stale.append(o)
	for o in stale:
		root_set.erase(o)	# 无论死活都摘出根集合
		if o.dead:
			continue	# 同轮级联已收走
		o.ref_count -= 1
		if o.ref_count < 1:
			free_now(o)	# 刚确认：VM 侧再无 Handle，立即级联释放
	flush_trash()

# ==================== 引用计数 ====================

# 只有 Handle 且载荷是 MyObject 才是对象引用；描述符（RefCounted）由引擎管。
func _obj_of(v:Variant) -> Variant:
	if v is Stope.BasicVM.Handle and v.data is Objects.MyObject:
		return v.data
	return null

func add_ref(v:Variant) -> void:
	var o = _obj_of(v)
	if o != null and not o.dead:
		o.ref_count += 1

func del_ref(v:Variant) -> void:
	var o = _obj_of(v)
	if o == null or o.dead:
		return
	o.ref_count -= 1
	if o.ref_count < 1:
		free_now(o)	# 归零立即级联释放

# 字段写入：旧引用先减（可能级联释放旧目标——它不在任何 State 里，因为
# 每次开口都先做过根同步），再挂新引用。GD 无 String 引用计数，无需 Clear2。
func set_field(obj, index:int, v:Variant) -> void:
	del_ref(obj.fields[index])
	obj.fields[index] = v
	add_ref(v)

# ==================== 释放（两条路径 + 延迟删除） ====================

# 计数归零路径：字段里的 Handle 引用递减，归零的子对象**级联**释放——
# 一串刚失去最后一丝引用的对象在同一瞬间全部析构。
func free_now(obj) -> void:
	if obj.dead:
		return
	if on_free.is_valid():
		on_free.call(obj)	# <delete> 先跑：此时字段还完整可读
	for v in obj.fields:
		var child = _obj_of(v)
		if child != null and not child.dead:
			child.ref_count -= 1
			if child.ref_count < 1:
				free_now(child)	# 级联
	unlink(obj)
	trash.append(obj)	# 只摘链不 free：调用方的名单里可能还有它

# sweep 路径：字段里的 Handle 引用只减计数**不级联**——真死透的子对象
# 这次没被标记，马上就会在同一个 sweep 里被收走；还活着的（从根可达）
# 计数不会归零。
func free_sweep(obj) -> void:
	if obj.dead:
		return
	if on_free.is_valid():
		on_free.call(obj)
	for v in obj.fields:
		var child = _obj_of(v)
		if child != null and not child.dead and child.ref_count > 0:
			child.ref_count -= 1
	unlink(obj)
	trash.append(obj)

func unlink(obj) -> void:
	obj.gc_prev.gc_next = obj.gc_next
	obj.gc_next.gc_prev = obj.gc_prev
	obj.dead = true
	alive_count -= 1

# 统一冲刷延迟删除。调用点：sync_roots 末尾、collect 末尾——此时所有持有
# 对象引用的局部名单（stale / doomed / found）都已用完，free 绝不悬空。
func flush_trash() -> void:
	for o in trash:
		o.free()
	trash.clear()

# ==================== gc：标记清除 ====================

# 迭代式标记：沿字段里的 Handle 引用铺开，显式栈防深对象图爆 GD 栈。
func mark_from(root) -> void:
	if root.dead or root.mark != 0:
		return
	var work:Array = [root]
	root.mark = 1
	while not work.is_empty():
		var o = work.pop_back()
		for v in o.fields:
			var c = _obj_of(v)
			if c != null and not c.dead and c.mark == 0:
				c.mark = 1
				work.append(c)

func collect() -> void:
	if collecting:
		return	# 析构里新建对象顶到阈值等重入：本次跳过，下个安全点再来
	sync_roots()	# 收集前根集合先刷新到最新（此刻还没置位）

	collecting = true
	last_freed = 0

	# 标记：从全部根出发。
	for root in root_set:
		mark_from(root)

	# 清除：先收集死对象再逐个回收——on_free（析构）可能读写字段，不能
	# 边走链表边摘。级联在本路径不发生（free_sweep 只减计数）：活对象
	# 至少有一条从根来的引用撑着计数。
	var doomed:Array = []
	var h = anchor.gc_next
	while h != anchor:
		if h.mark == 0:
			doomed.append(h)
		h = h.gc_next
	for o in doomed:
		if not o.dead:	# 前面的析构可能已经级联/重入收走了它
			free_sweep(o)
			last_freed += 1

	# 清标记：只走还活着的链。
	h = anchor.gc_next
	while h != anchor:
		h.mark = 0
		h = h.gc_next

	collecting = false
	flush_trash()
	gc_trigger = 64 if alive_count * 2 < 64 else alive_count * 2

# 退出兜底（C++ 的 ~ObjectAllocator）：逐个跑析构、free——否则 ObjectDB
# 报泄漏。GD 没有析构钩子，这一步由入口在退出前显式调用。
func dispose_all() -> void:
	var h = anchor.gc_next
	while h != anchor:
		var nxt = h.gc_next
		if on_free.is_valid():
			on_free.call(h)
		h.free()
		h = nxt
	trash.clear()
	alive_count = 0
	# 断开锚点自环：anchor 是 RefCounted，gc_prev/gc_next 指向自己会构成
	# 引用计数环（rc=2 永不归零），退出时报 ObjectDB leak。链已清空，
	# 这里把两个指针摘掉，让引擎正常回收哨兵。
	anchor.gc_next = null
	anchor.gc_prev = null

# ==================== 诊断 ====================

func report_alive() -> void:
	var objs:int = 0
	var h = anchor.gc_next
	while h != anchor:
		objs += 1
		h = h.gc_next
	print('[gc] alive: ', objs, ' object(s), root set ', root_set.size())
	h = anchor.gc_next
	while h != anchor:
		print('  ', h.get_instance_id(), '  class ', h.class_id,
			'  refCount ', h.ref_count)
		h = h.gc_next
