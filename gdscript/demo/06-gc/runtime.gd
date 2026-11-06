# runtime.gd：静态结构 + 调用 + 入口绑定（对应 cpp/demo/06-gc/ 的 Runtime.*）。
# 脚本自身即 Runtime 类。

extends Object
# 继承 Object（手动管理）：Runtime ⇄ ObjectManager 互指，若都继承
# RefCounted 就构成环引用——Godot 没有循环回收，Runtime 作为根由 demo
# 显式 free()。

const Classes := preload("res://demo/06-gc/classes.gd")
const Objects := preload("res://demo/06-gc/objects.gd")
const ObjectManagerScript := preload("res://demo/06-gc/object_manager.gd")
const DemoApiScript := preload("res://demo/06-gc/demo_api.gd")

var host_funcs:Array[Callable] = []
var host_func_map:Dictionary = {}	# 名 -> host_funcs 序号
var member_name_map:Dictionary = {}	# 成员名 -> 成员 id（跨类共享同名 id）
var functions:Array = []	# Classes.FunctionInfo
var classes:Array = []	# Classes.ClassInfo
var class_map:Dictionary = {}	# 类名 -> 类 id（export_binds 按类名找构造器）
var obj_mgr	# ObjectManagerScript 实例
var api	# DemoApiScript 实例
# gc 根扫描的范围 = 显式帧栈 frames（入口帧 + 压住的方法帧）+ live_states
# （只装 <delete> 析构的同步旁路 State，见 invoke_method）。
var frames:Array = []	# Frame 字典：{state, method, self_obj, wants_return}
var live_states:Array = []
var had_errors := false	# 任一帧出错置位（错误已打印，供入口返回码用）
# 正在执行方法的对象（GD 版的「保活」机制）：C++ demo 6 靠绑定描述符的
# 字段引用撑住 self，GD 的描述符不参与 gc，改由这个数组强引用——
# push_method_frame 压入、弹帧收尾弹出；invoke_method（同步旁路）同样。
var pinned:Array = []

func _init() -> void:
	obj_mgr = ObjectManagerScript.new()
	obj_mgr.runtime = self
	api = DemoApiScript.new(obj_mgr)
	# gc 根扫描：分配器不认识 State，由 Runtime 供给。只有「Handle 载荷是
	# MyObject」才算引用；描述符（RefCounted）由引擎计数管，不算。
	obj_mgr.alloc.gather_roots = gather_roots
	# 析构回调：对象被回收前跑 <delete>。
	obj_mgr.alloc.on_free = obj_mgr.run_destructor

func track_state(s:StopeBasicVM.State) -> void:
	live_states.append(s)

func untrack_state(s:StopeBasicVM.State) -> void:
	live_states.erase(s)

# 根扫描：帧栈 + 同步旁路 State 的 variables/stack/returns + pinned。
func gather_roots(out:Array) -> void:
	for f in frames:
		_scan_state(f.state, out)
	for s in live_states:
		_scan_state(s, out)
	for o in pinned:
		out.append(o)

func _scan_state(s:StopeBasicVM.State, out:Array) -> void:
	for v in s.variables:
		if v is StopeBasicVM.Handle and v.data is Objects.MyObject:
			out.append(v.data)
	for v in s.stack:
		if v is StopeBasicVM.Handle and v.data is Objects.MyObject:
			out.append(v.data)
	for v in s.returns:
		if v is StopeBasicVM.Handle and v.data is Objects.MyObject:
			out.append(v.data)

func new_member_id(nm:String) -> int:
	if member_name_map.has(nm):
		return member_name_map[nm]
	var id := member_name_map.size()
	member_name_map[nm] = id
	return id

func new_class():
	var c = Classes.ClassInfo.new()
	c.id = classes.size()
	classes.append(c)
	return c

func find_function(nm:String):
	for f in functions:
		if f.name == nm:
			return f
	return null

func add_host_function(nm:String, fn:Callable) -> void:
	host_func_map[nm] = host_funcs.size()
	host_funcs.append(fn)

# ---------- 显式帧栈：把 State 显式放在一个栈里，驱动循环只跑栈顶帧 ----------
# 调用栈从 GDScript 递归栈搬进 frames 成员：方法调用压帧、返回弹帧，调用方
# 在栈里压住等返回值。换来 run_steps(max_steps)「每帧限步」与 run_all()
# 「一口气跑完」两种驱动，随时可切。

# 装配入口函数并压帧：宿主函数、构造器描述符、obj:* 成员描述符绑进导出槽位。
# demo 6 没有 obj:delete——生命期归 gc 管，<delete> 是回收时自动跑的析构。
func push_entry_frame(entry, vm_args = null) -> void:
	var state := StopeBasicVM.State.new()
	state.set_api(api)
	state.set_program(entry.program)
	if vm_args != null:
		state.set_arguments(vm_args)
	state.variables.resize(entry.program.variable_num)
	entry.initialize_state(state, [])
	bind_entry(state, entry)
	frames.append({'state': state, 'method': null, 'self_obj': null,
		'wants_return': false})

# 装配方法 State（push_method_frame / invoke_method 共用）。
func _setup_method_state(m, obj, args:Array,
		state:StopeBasicVM.State) -> void:
	state.set_api(api)
	state.set_program(m.program)
	m.initialize_state(state, obj, args)
	for b in m.host_binds:
		state.variables[b[0]] = host_funcs[b[1]]
	# 方法体里的 <类名>:<构造名> / obj:<名> 描述符：装配期已预算好
	# (槽位, 描述符 Handle)，逐个拷进槽位。
	for b in m.export_binds:
		state.variables[b[0]] = b[1]
	# self:<方法名> 槽位绑 self 的绑定方法描述符——每次新建（不去重）。
	for b in m.self_method_binds:
		state.variables[b[0]] = obj_mgr.bind(b[1], StopeBasicVM.Handle.new(obj))

# 压入方法帧，不执行——run_steps 自然切到栈顶帧。调用方（call 开口的
# 发起方）停在 Call 的下一条；开口返回的占位 null 会被 op_call 压到调用方
# 栈顶，弹帧收尾时用真正的返回值覆盖。self 进 pinned 保活（帧在栈里，
# self 的绑定描述符扫描不可达，见 gather_roots 注释）。
func push_method_frame(m, obj, args:Array, wants_return:bool) -> void:
	var state := StopeBasicVM.State.new()
	_setup_method_state(m, obj, args, state)
	frames.append({'state': state, 'method': m, 'self_obj': obj,
		'wants_return': wants_return})
	pinned.append(obj)

# 每帧限步驱动：只跑栈顶帧，至多 max_steps 条指令；帧弹栈（Return / 指令流
# 走完 / 出错中止当前函数）不消耗步数。返回 false = 帧栈已空、程序结束。
func run_steps(max_steps:int) -> bool:
	while max_steps > 0 and not frames.is_empty():
		var s:StopeBasicVM.State = frames.back().state
		if s.i >= s.program.opcodes.size():
			finish_top_frame()	# Return 已把返回值备好；弹栈不消耗步数
			continue
		if s.step() != StopeResult.Success:
			finish_top_frame()	# 运行期错误：只中止当前函数，调用方继续
			continue
		max_steps -= 1
	return not frames.is_empty()

# 直接执行：一口气跑到帧栈清空。与 run_steps 随时可切。
func run_all() -> void:
	while run_steps(1 << 30):
		pass

# 摘出栈顶帧并收尾。
func finish_top_frame() -> void:
	var f:Dictionary = frames.pop_back()
	_finish_frame(f)

# 帧收尾：错误打印、self: 槽位写回字段（走 set_field：引用计数照常维护）、
# 返回值回填调用方栈顶（op_call 已把占位 null 压到那里，覆盖即可）。
func _finish_frame(f:Dictionary) -> void:
	var s:StopeBasicVM.State = f.state
	for e in s.errors:
		print('  vm: ', e)
		had_errors = true
	if f.method == null:
		return	# 入口帧：没有 selfProps / 返回值
	pinned.pop_back()	# 与 push_method_frame 配对
	# 返回前把 self: 槽位写回字段——self_props 只含方法体实际引用的属性。
	for p in f.method.self_props:
		obj_mgr.alloc.set_field(f.self_obj, p[1], s.variables[p[0]])
	# 回填调用方栈顶（wants_return 帧）。构造器帧返回的是新对象本身，不走这里。
	if f.wants_return and not frames.is_empty() and not s.returns.is_empty():
		frames.back().state.stack[-1] = s.returns[0]

# 同步执行整个方法（<delete> 析构路径）：装配 + run + 收尾。析构在级联
# 释放 / sweep 的中间被调用，跑完后调用方还要清字段——不能让出执行权。
# 析构里再调方法也走这条路：压帧没人跑（此刻正停在 step 中间）。
func invoke_method(m, obj, args:Array) -> Variant:
	var state := StopeBasicVM.State.new()
	_setup_method_state(m, obj, args, state)
	pinned.append(obj)
	track_state(state)
	state.run()
	untrack_state(state)
	pinned.pop_back()
	for e in state.errors:
		print('  vm: ', e)
		had_errors = true
	for p in m.self_props:
		obj_mgr.alloc.set_field(obj, p[1], state.variables[p[0]])
	return state.returns[0] if not state.returns.is_empty() else null

# 装配入口函数的导出槽位（push_entry_frame 调）：宿主函数、构造器描述符、
# obj:* 成员描述符。按名只发生在这里（装配期），执行期间零按名查找。
func bind_entry(state:StopeBasicVM.State, entry) -> void:
	for b in entry.host_binds:
		state.variables[b[0]] = host_funcs[b[1]]
	for cls in classes:
		for nm: String in cls.constructor_map:
			_bind_export(state, entry, cls.name + ':' + nm,
				obj_mgr.new_ctor_desc(cls.id, cls.constructor_map[nm]))
		for prop in cls.properties:
			_bind_export(state, entry, 'obj:' + prop,
				obj_mgr.new_member_desc(new_member_id(prop)))
		for m in cls.methods:
			if m.name.is_empty() or cls.constructor_map.has(m.name):
				continue	# <delete> 无名不占 obj:；构造器不占 obj: 名
			_bind_export(state, entry, 'obj:' + m.name,
				obj_mgr.new_member_desc(new_member_id(m.name)))

func _bind_export(state:StopeBasicVM.State, entry, nm:String,
		handle:StopeBasicVM.Handle) -> void:
	if not entry.program.exports.has(nm):
		return
	state.variables[entry.program.exports[nm]] = handle
