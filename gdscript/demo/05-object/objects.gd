# objects.gd：对象模型 —— 业务对象与描述符（对应 cpp/demo/05-object/ 的 Object.*）。
# 本文件是内类的容器，自身不实例化；跨文件经 preload 常量访问，如
# `const Objects = preload("res://demo/05-object/objects.gd")` 后
# `Objects.MyObject.new()`。

# 业务对象：继承 Object（手动管理，free() 释放），与 C++ 的 new/delete 对应。
# 继承 RefCounted 的话计数归零自动释放，但那样 free() 会被引擎拒绝，
# 「obj:delete 的析构时机」就不再由文档程序员决定了。

# 统一入口：addons/stope 不注册全局类，preload 门面后按 Stope.模块 访问
const Stope = preload("res://addons/stope/stope.gd")
class MyObject extends Object:
	var class_id:int = -1
	var fields:Array = []	# 下标对齐 Classes.ClassInfo.properties

class MemberRef extends RefCounted:
	var kind:int = 0	# MemberKind（见入口文件）
	var index:int = -1	# 进 properties 或 methods

# 成员描述符：member_id + obj（绑定后才有，Handle）。
class MemberDesc extends RefCounted:
	var member_id:int = -1
	var obj:Variant = null	# Stope.BasicVM.Handle，null = 未绑定

class CtorDesc extends RefCounted:
	var cls_id:int = -1
	var ctor_idx:int = -1
