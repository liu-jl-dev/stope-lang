# runtime.gd：静态结构 + 调用 + 入口绑定（对应 cpp/demo/05-object/ 的 Runtime.*）。
# 脚本自身即 Runtime 类。

extends Object
# 继承 Object（手动管理）：Runtime ⇄ ObjectManager 互指，若都继承
# RefCounted 就构成环引用——Godot 没有循环回收（官方口径见入口文件头），
# 整个运行时图会在退出时报 ObjectDB leak。Runtime 作为根由 demo 显式
# free()；ObjectManager 持有的 runtime 引用因此不构成计数环。

const Classes := preload("res://demo/05-object/classes.gd")
const ObjectManagerScript := preload("res://demo/05-object/object_manager.gd")
const DemoApiScript := preload("res://demo/05-object/demo_api.gd")

var host_funcs:Array[Callable] = []
var host_func_map:Dictionary = {}	# 名 -> host_funcs 序号
var member_name_map:Dictionary = {}	# 成员名 -> 成员 id（跨类共享同名 id）
var functions:Array = []	# Classes.FunctionInfo
var classes:Array = []	# Classes.ClassInfo
var obj_mgr	# ObjectManagerScript 实例
var api	# DemoApiScript 实例

func _init() -> void:
	obj_mgr = ObjectManagerScript.new()
	obj_mgr.runtime = self
	api = DemoApiScript.new(obj_mgr)

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

# 方法/函数调用：每层调用一个临时 State，随返回销毁 —— 嵌套调用就是
# GDScript 的递归栈。Runtime 不保存调用栈（demo 6 做根扫描时才需要）。
func invoke_method(m, obj, args:Array) -> Variant:
	var state := StopeBasicVM.State.new()
	state.set_api(api)
	state.set_program(m.program)
	m.initialize_state(state, obj, args)
	for b in m.host_binds:
		state.variables[b[0]] = host_funcs[b[1]]
	# self:<方法名> 槽位绑 self 的绑定方法描述符——创建即绑定 self，
	# self:Greet() 无需 [对象]；去重缓存保证递归调用不重复分配。
	for b in m.self_method_binds:
		state.variables[b[0]] = obj_mgr.bind(b[1], StopeBasicVM.Handle.new(obj))
	state.run()
	for e in state.errors:
		print('  vm: ', e)
	# 返回前把 self: 槽位写回字段（只写实际引用的那几个）。
	for p in m.self_props:
		obj.fields[p[1]] = state.variables[p[0]]
	return state.returns[0] if not state.returns.is_empty() else null

# 装配入口函数：宿主函数、构造器描述符、obj:* 成员描述符绑进导出槽位。
# 按名只发生在这里（装配期），state.run() 期间零按名查找。
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
				continue	# <delete> 走 obj:delete；构造器不占 obj: 名
			_bind_export(state, entry, 'obj:' + m.name,
				obj_mgr.new_member_desc(new_member_id(m.name)))
		if cls.deconstructor_id >= 0:
			_bind_export(state, entry, 'obj:delete',
				obj_mgr.new_member_desc(new_member_id('delete')))

func _bind_export(state:StopeBasicVM.State, entry, nm:String,
		handle:StopeBasicVM.Handle) -> void:
	if not entry.program.exports.has(nm):
		return
	state.variables[entry.program.exports[nm]] = handle
