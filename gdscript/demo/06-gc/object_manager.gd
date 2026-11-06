# object_manager.gd：obj:* 域的全部行为（对应 cpp/demo/06-gc/ 的
# ObjectManager.*）。脚本自身即 ObjectManager 类。
#
# 与 demo 5 的差异：没有 bind_cache / live 表 / obj:delete——描述符每次
# Bind 新建（RefCounted，无人引用由引擎计数回收），对象生命期归 gc。
# 三个开口入口先 safe_point()：安全点根同步，先于一切 del_ref。

extends RefCounted

const Objects := preload("res://demo/06-gc/objects.gd")
const GcScript := preload("res://demo/06-gc/gc.gd")

# 成员种类（对应 C++ 的 kMemberProp / kMemberMethod；demo 6 无 delete）。
enum MemberKind { PROP, METHOD }

var runtime	# runtime.gd 的 Runtime（跨文件不写静态类型：避免 preload 环）
var alloc = GcScript.new()	# gc 分配器（C++ 版住在 ObjectManager 里，同构）

# new 业务对象。返回 null = 顶到 max_nodes（调用方 s.error）。
func new_object(cls_id:int) -> Variant:
	var obj = alloc.new_object()
	if obj == null:
		return null
	obj.class_id = cls_id
	obj.fields.resize(runtime.classes[cls_id].properties.size())
	return StopeBasicVM.Handle.new(obj)

# 描述符（RefCounted）：每次新建，不去重——demo 5 的 bind_cache / 驱逐 /
# 复用池在 demo 6 里全部消失，无人引用的描述符由引擎引用计数当场回收。
func new_member_desc(member_id:int) -> StopeBasicVM.Handle:
	var d = Objects.MemberDesc.new()
	d.member_id = member_id
	return StopeBasicVM.Handle.new(d)

func new_ctor_desc(cls_id:int, ctor_idx:int) -> StopeBasicVM.Handle:
	var d = Objects.CtorDesc.new()
	d.cls_id = cls_id
	d.ctor_idx = ctor_idx
	return StopeBasicVM.Handle.new(d)

# 绑定描述符：每次新建。obj 是普通 Handle——描述符不持有对象（引擎计数
# 管不到 gc 对象），「正在执行方法」的对象由 runtime.pinned 保活。
func bind(member_id:int, obj_handle:StopeBasicVM.Handle) -> StopeBasicVM.Handle:
	var d = Objects.MemberDesc.new()
	d.member_id = member_id
	d.obj = obj_handle
	return StopeBasicVM.Handle.new(d)

# 三个开口的公共前奏：安全点——先同步根集合，再做本次操作。「引用计数
# 归零 -> 立即级联释放」的可靠性由这条顺序保证（见 gc.gd 头注释）。
func safe_point() -> void:
	alloc.sync_roots()

# obj:<名>[p] -> 绑定描述符。
func at(s:StopeBasicVM.State, handle:StopeBasicVM.Handle, key) -> Variant:
	safe_point()
	var d = handle.data
	if not (d is Objects.MemberDesc):
		s.error('no implement for container type. ')
		return null
	if not (key is StopeBasicVM.Handle):
		s.error('not an object. ')
		return null
	return bind(d.member_id, key)

# obj:<属性>[p] = v -> 写字段（走 set_field：旧值减引用可级联，新值加引用）。
func assign(s:StopeBasicVM.State, handle:StopeBasicVM.Handle, value) -> void:
	safe_point()
	var d = handle.data
	if not (d is Objects.MemberDesc) or d.obj == null:
		s.error('not assignable. ')
		return
	var obj = d.obj.data
	var cls = runtime.classes[obj.class_id]	# 第一层
	var ref = cls.member_by_id.get(d.member_id)
	if ref == null or ref.kind != MemberKind.PROP:
		s.error('not assignable. ')	# 该类没有这个属性 / 方法不可赋值
		return
	alloc.set_field(obj, ref.index, value)	# 第二层

# obj:<名>[p](...) -> 调方法；<Class>:<New>(...) -> 构造。
# demo 6 没有 obj:delete(p)：生命期归 gc 管。
func call_member(s:StopeBasicVM.State, handle:StopeBasicVM.Handle,
		args:Array) -> Variant:
	safe_point()
	var d = handle.data
	if d is Objects.CtorDesc:
		var cls = runtime.classes[d.cls_id]
		var obj_handle = new_object(cls.id)
		if obj_handle == null:
			s.error('too many gc nodes. ')	# 顶到 max_nodes：走正常错误通道
			return null
		# 构造器压帧：返回值是新对象本身（不走「弹帧回填」通道）。
		runtime.push_method_frame(cls.methods[d.ctor_idx], obj_handle.data,
			args, false)
		return obj_handle
	if d is Objects.MemberDesc:
		if d.obj == null:
			s.error('method not bound. ')	# demo 6 只支持 obj:<名>[p]() 形式
			return null
		var obj = d.obj.data
		var cls = runtime.classes[obj.class_id]	# 第一层：classId 选类
		var ref = cls.member_by_id.get(d.member_id)
		if ref == null or ref.kind != MemberKind.METHOD:
			s.error('no method. ')	# 该类没有这个方法（属性不可调）
			return null
		# 方法调用压帧：返回占位 null——op_call 把它压到调用方栈顶，
		# 方法帧弹栈时（_finish_frame）再回填真正的返回值。
		runtime.push_method_frame(cls.methods[ref.index], obj, args, true)
		return null
	s.error('"Call" can only call a function. ')
	return null

# gc 回收前回调（alloc.on_free）：跑 <delete>。此时字段还完整可读。
func run_destructor(obj) -> void:
	if obj.class_id < 0:
		return
	var cls = runtime.classes[obj.class_id]
	if cls.deconstructor_id >= 0:
		runtime.invoke_method(cls.methods[cls.deconstructor_id], obj, [])

func report_live() -> void:
	alloc.report_alive()
	if alloc.root_set.is_empty():
		print('[gc] no roots: everything reachable has been freed')
	else:
		print('[gc] roots keep ', alloc.root_set.size(), ' object(s) alive')
