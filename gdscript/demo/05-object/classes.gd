# classes.gd：类 / 方法 / 函数的静态结构与槽位装配
# （对应 cpp/demo/05-object/ 的 Class.* / Function.*）。


# 统一入口：addons/stope 不注册全局类，preload 门面后按 Stope.模块 访问
const Stope = preload("res://addons/stope/stope.gd")
class MethodInfo extends RefCounted:
	var name:String = ''
	var params:Array[String] = []
	var program:Stope.Program.Program
	# 装配期预计算的整数索引：运行中不做任何按名查找。
	var self_props:Array = []	# [槽位下标, 字段下标] —— 只含方法体实际引用的属性
	var host_binds:Array = []	# [槽位下标, 宿主函数序号]
	var self_method_binds:Array = []	# [槽位下标, 成员 id]（self:<方法名> 调用）
	var param_slots:Array[int] = []	# params[i] -> 变量槽位下标

	# self_obj 是 objects.gd 的 MyObject（跨文件不写静态类型，动态分派）。
	func initialize_state(state:Stope.BasicVM.State, self_obj, args:Array) -> void:
		for p in self_props:
			state.variables[p[0]] = self_obj.fields[p[1]]	# 字段 -> 槽位
		for k in range(param_slots.size()):
			# 缺参静默：缺的槽位是 Null（已知局限，见 docs §10）
			state.variables[param_slots[k]] = args[k] if k < args.size() else null

class FunctionInfo extends RefCounted:
	var name:String = ''
	var params:Array[String] = []
	var program:Stope.Program.Program
	var host_binds:Array = []
	var param_slots:Array[int] = []

	func initialize_state(state:Stope.BasicVM.State, args:Array) -> void:
		for k in range(param_slots.size()):
			state.variables[param_slots[k]] = args[k] if k < args.size() else null

class ClassInfo extends RefCounted:
	var id:int = -1
	var name:String = ''
	var properties:Array[String] = []
	var methods:Array[MethodInfo] = []
	var member_by_id:Dictionary = {}	# 成员 id -> MemberRef（唯一的查找表）
	var constructor_map:Dictionary = {}	# <new 名> -> methods 下标
	var deconstructor_id:int = -1
