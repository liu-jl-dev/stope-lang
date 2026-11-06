# demo_api.gd：三个开口薄转发到 ObjectManager
# （对应 cpp/demo/06-gc/ 的 API.*）。
#
# GDScript 方法天然动态派发：继承 StopeBasicVM.Api 覆写三个方法即可生效。

extends StopeBasicVM.Api

var obj_mgr	# object_manager.gd 的 ObjectManager（跨文件不写静态类型）

func _init(mgr) -> void:
	obj_mgr = mgr

func handle_at(s:StopeBasicVM.State, handle, key) -> Variant:
	return obj_mgr.at(s, handle, key)

func handle_assign(s:StopeBasicVM.State, handle, value) -> void:
	obj_mgr.assign(s, handle, value)

func handle_call(s:StopeBasicVM.State, handle, args:Array) -> Variant:
	return obj_mgr.call_member(s, handle, args)
