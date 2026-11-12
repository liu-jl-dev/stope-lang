# demo_api.gd：三个开口薄转发到 ObjectManager
# （对应 cpp/demo/06-gc/ 的 API.*）。
#
# GDScript 方法天然动态派发：继承 Stope.BasicVM.Api 覆写三个方法即可生效。

extends "res://addons/stope/basic_vm.gd".Api

# 统一入口：addons/stope 不注册全局类，preload 门面后按 Stope.模块 访问
const Stope = preload("res://addons/stope/stope.gd")

var obj_mgr	# object_manager.gd 的 ObjectManager（跨文件不写静态类型）

func _init(mgr) -> void:
	obj_mgr = mgr

func handle_at(s:Stope.BasicVM.State, handle, key) -> Variant:
	return obj_mgr.at(s, handle, key)

func handle_assign(s:Stope.BasicVM.State, handle, value) -> void:
	obj_mgr.assign(s, handle, value)

func handle_call(s:Stope.BasicVM.State, handle, args:Array) -> Variant:
	return obj_mgr.call_member(s, handle, args)
