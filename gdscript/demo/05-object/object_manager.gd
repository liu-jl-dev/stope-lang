# object_manager.gd：obj:* 域的全部行为（对应 cpp/demo/05-object/ 的
# ObjectManager.*）。脚本自身即 ObjectManager 类。

extends RefCounted

const Objects := preload("res://demo/05-object/objects.gd")

# 成员种类（对应 C++ 的 kMemberProp / kMemberMethod / kMemberDelete）。
enum MemberKind { PROP, METHOD, DELETE }

var runtime	# runtime.gd 的 Runtime（跨文件不写静态类型：避免 preload 环）
var live:Array = []	# MyObject，手动管理：delete 后移除
var max_objects := 0	# 存活对象上限（live 表大小）；0 = 不限（对齐 maxDepth 约定）
# 去重缓存：对象 -> (成员 id -> 绑定描述符)。绑定描述符只存这两样且创建后
# 不可变，同一绑定永远等价；delete 时整组驱逐（Dictionary 按实例哈希，
# O(1)），驱逐后无人引用的描述符由引用计数立即回收。
var bind_cache:Dictionary = {}

func new_object(cls_id:int) -> StopeBasicVM.Handle:
	var obj = Objects.MyObject.new()
	obj.class_id = cls_id
	obj.fields.resize(runtime.classes[cls_id].properties.size())
	live.append(obj)
	return StopeBasicVM.Handle.new(obj)

func new_member_desc(member_id:int) -> StopeBasicVM.Handle:
	var d = Objects.MemberDesc.new()
	d.member_id = member_id
	return StopeBasicVM.Handle.new(d)

func new_ctor_desc(cls_id:int, ctor_idx:int) -> StopeBasicVM.Handle:
	var d = Objects.CtorDesc.new()
	d.cls_id = cls_id
	d.ctor_idx = ctor_idx
	return StopeBasicVM.Handle.new(d)

# 绑定（创建即去重）。C++ 版还有 freeDescs 复用池；这里不需要 —— 驱逐后
# 无人引用的描述符由引用计数当场回收，池的存在意义被语言机制替掉了。
func bind(member_id:int, obj_handle:StopeBasicVM.Handle) -> StopeBasicVM.Handle:
	var obj = obj_handle.data
	var by_member = bind_cache.get(obj)	# 缺键得 null；typed 标注会被 null 赋值打崩
	if by_member == null:
		by_member = {}
		bind_cache[obj] = by_member
	var hit = by_member.get(member_id)
	if hit != null:
		return StopeBasicVM.Handle.new(hit)	# 命中：复用
	var d = Objects.MemberDesc.new()
	d.member_id = member_id
	d.obj = obj_handle
	by_member[member_id] = d
	return StopeBasicVM.Handle.new(d)

# obj:<名>[p] -> 绑定描述符（属性引用与绑定方法都从这里出发）。
func at(s:StopeBasicVM.State, handle:StopeBasicVM.Handle, key) -> Variant:
	var d = handle.data
	if not (d is Objects.MemberDesc):
		s.error('no implement for container type. ')
		return null
	if not (key is StopeBasicVM.Handle):
		s.error('not an object. ')
		return null
	return bind(d.member_id, key)

# obj:<属性>[p] = v -> 写字段。两层整数查询：对象自己的 classId 选类，
# member_by_id 查 MemberRef——同名成员在各类里落在不同位置也各归各。
func assign(s:StopeBasicVM.State, handle:StopeBasicVM.Handle, value) -> void:
	var d = handle.data
	if not (d is Objects.MemberDesc) or d.obj == null:
		s.error('not assignable. ')
		return
	var obj = d.obj.data
	var cls = runtime.classes[obj.class_id]	# 第一层
	var ref = cls.member_by_id.get(d.member_id)
	if ref == null or ref.kind != MemberKind.PROP:
		s.error('not assignable. ')	# 该类没有这个成员 / 方法不可赋值
		return
	obj.fields[ref.index] = value	# 第二层：MemberRef.index 即字段下标

# obj:<名>[p](...) -> 调方法；obj:<名>(...) 直接调（delete 走这里，对象在
# 实参里）；<Class>:<New>(...) -> 构造。
func call_member(s:StopeBasicVM.State, handle:StopeBasicVM.Handle,
		args:Array) -> Variant:
	var d = handle.data
	if d is Objects.CtorDesc:
		var cls = runtime.classes[d.cls_id]
		if max_objects != 0 and live.size() >= max_objects:
			s.error('too many objects. ')	# 手动管理：上限内也不自动回收，必须 obj:delete
			return null
		var obj_handle := new_object(cls.id)
		# 构造器压帧：返回值是新对象本身（不走「弹帧回填」通道）。
		runtime.push_method_frame(cls.methods[d.ctor_idx], obj_handle.data,
			args, false)
		return obj_handle
	if d is Objects.MemberDesc:
		# kind 由 member_by_id 查表揭晓；类来自绑定对象或实参对象。
		var obj_handle = d.obj
		if obj_handle == null:
			if not args.is_empty() and args[0] is StopeBasicVM.Handle:
				obj_handle = args[0]	# obj:delete(p) 实参形式
			else:
				if not args.is_empty():
					s.error('not an object. ')	# obj:<名>(实参)，但实参不是对象
				else:
					s.error('method not bound. ')	# obj:<方法> 未带 [对象]
				return null
		var obj = obj_handle.data
		var cls = runtime.classes[obj.class_id]	# 第一层
		var ref = cls.member_by_id.get(d.member_id)
		if ref == null:
			s.error('no method. ')	# 该类没有这个成员
			return null
		if ref.kind == MemberKind.DELETE:
			delete(s, obj)	# 绑定形式与实参形式在此收敛
			return null
		if ref.kind != MemberKind.METHOD:
			s.error('"Call" can only call a function. ')	# 属性不可调
			return null
		# 方法调用压帧：返回占位 null——op_call 把它压到调用方栈顶，
		# 方法帧弹栈时（_finish_frame）再回填真正的返回值。
		runtime.push_method_frame(cls.methods[ref.index], obj, args, true)
		return null
	s.error('"Call" can only call a function. ')
	return null

# 跑 <delete>（可读写字段）-> 驱逐绑定描述符 -> free。双重 delete 拦下。
func delete(s:StopeBasicVM.State, obj) -> void:
	if not live.has(obj):	# Array.erase 返回 void，先 has 再删
		s.error('double delete. ')
		return
	live.erase(obj)
	var cls = runtime.classes[obj.class_id]
	if cls.deconstructor_id >= 0:
		runtime.invoke_method(cls.methods[cls.deconstructor_id], obj, [])
	bind_cache.erase(obj)	# 整组驱逐；无人引用的描述符由引用计数回收
	obj.free()

func report_live() -> void:
	if live.is_empty():
		print('[objects] all freed')
	else:
		var parts:PackedStringArray = []
		for o in live:
			parts.append('(class ' + str(o.class_id) + ')')
		print('[objects] ', live.size(), ' alive: ', ' '.join(parts))
	var cached := 0
	for by_member in bind_cache.values():
		cached += by_member.size()
	# 差异：C++ 打 allocated/pooled 两个数（复用池）；这里只有缓存里
	# 还被引用的绑定描述符，池被引用计数替代了。
	print('[bind-cache] ', cached, ' entries')
