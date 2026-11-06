# objects.gd：对象模型 —— gc 管理的业务对象 + 引擎管理的描述符
# （对应 cpp/demo/06-gc/ 的 Object.*）。
#
# 与 demo 5 的差异：MyObject 头上多了 gc 字段（侵入式循环双向链表 + 引用
# 计数 + 标记），生命期归 gc；描述符仍是 RefCounted——引擎引用计数替我们
# 记账，不需要 C++ demo 6 的 Pin（C++ 侧描述符进 gc 链、装配期 Pin 住，
# 这里引擎机制等价替代）。gc 字段语义见 gc.gd 的头注释。

# 业务对象：继承 Object（gc 决定何时 free()）。
class MyObject extends Object:
	var class_id:int = -1
	var fields:Array = []	# 下标对齐 Classes.ClassInfo.properties
	# ---- gc 头 ----
	var gc_prev:Variant = null	# 循环双向链表（哨兵是 GcAnchor）
	var gc_next:Variant = null
	var ref_count:int = 0	# 字段引用（精确）+ 根引用（安全点同步）
	var mark:int = 0		# 0 未标记 / 1 已标记
	var dead:bool = false	# 已摘链待删：级联与 sweep 的回收名单重叠时防双重释放

# 链表哨兵：不占对象编号，与 MyObject 一样有 gc_prev / gc_next（鸭子类型）。
class GcAnchor extends RefCounted:
	var gc_prev:Variant = null
	var gc_next:Variant = null

class MemberRef extends RefCounted:
	var kind:int = 0	# MemberKind（见 doc_visitor.gd）
	var index:int = -1	# 进 properties 或 methods

# 描述符（RefCounted：引擎引用计数管理，不进 gc 链）。绑定描述符的 obj
# 是普通 Handle——不持有对象：gc 只认「State 可达 + 字段引用 + 正在执行
# 方法」的对象，见 runtime.gd 的 pinned。
class MemberDesc extends RefCounted:
	var member_id:int = -1
	var obj:Variant = null	# StopeBasicVM.Handle，null = 未绑定

class CtorDesc extends RefCounted:
	var cls_id:int = -1
	var ctor_idx:int = -1
