extends Node

# 统一入口：addons/stope 不注册全局类，preload 门面后按 Stope.模块 访问
const Stope = preload("res://addons/stope/stope.gd")

# Demo 05: 宿主侧的面向对象 —— 对应 cpp/demo/05-object/。
#
# 多文件拆分与 C++ 参考实现同构（demo/05-object/ 目录）：
#   objects.gd（对象模型）、classes.gd（类/方法/函数）、object_manager.gd
#   （obj:* 域行为）、runtime.gd（装配与调用）、doc_visitor.gd（STML -> 类与
#   函数）、demo_api.gd（Handle 三开口转发）；本文件只留文档、装配与入口。
#   设计推导见 cpp/docs/object-oriented.md，GDScript 侧差异见
#   docs/object-oriented.md。
#
# 语法（与 cpp demo 逐字一致）：
#   Person:New("Tom", 18)     构造（<Class>:<构造名> 绑定构造描述符）
#   obj:name[p] = "James"     写属性（At 绑定 + Assign 写穿）
#   obj:Introduce[p]()        调方法
#   self:Greet()              方法体内调同对象方法（self 绑定描述符）
#   obj:delete(p)             手动删除：先跑 <delete>，再 free
#
# ★ GDScript 侧的内存管理（与 C++ demo 的差异，详见 docs/object-oriented.md）：
#   · Godot 没有 GC，只有引用计数（RefCounted）+ 手动管理（Object.free）——
#     官方口径见 GDScript 基础教程 Memory management 一节；
#   · MyObject 继承 Object：与 C++ 的 new/delete 完全对应，obj:delete
#     里 free()，析构时机确定；
#   · 描述符继承 RefCounted：引用计数替我们记账——缓存驱逐后无人引用即释放，
#     不需要 C++ 的 freeDescs 复用池；bindCache 用 Dictionary 按实例哈希，
#     驱逐是 O(1) 整组摘除。

const RuntimeScript := preload("res://demo/05-object/runtime.gd")
const DocVisitorScript := preload("res://demo/05-object/doc_visitor.gd")

const DOC := """
<stml>

<class name="Person">
  <property name="name" />
  <property name="age" />
  <method name="Greet">
    println("i am ", self:name, ", ", self:age, " years old.");
  </method>
  <method name="Age">
    return self:age;
  </method>
  <method name="Introduce">
    // self:<方法名>() 调用同对象的另一个方法，无需 [对象]：self 绑定
    println("-- introducing --");
    self:Greet();
    println("age via self:Age() = ", self:Age());
  </method>
  <new name="New" params="name age">
    self:name = name;
    self:age = age;
  </new>
  <delete>
    // 析构函数，可以用来清理宿主的非托管资源等
    println("[Person] deleted!");
  </delete>
</class>

<func name="main">
  let p = Person:New("Tom", 18);
  obj:name[p] = "James";
  obj:Introduce[p]();
  obj:delete(p);
</func>

</stml>
"""

# ==================== 入口 ====================

class NoArgs extends "res://addons/stope/basic_vm.gd".Arguments:
	func at(_s:Stope.BasicVM.State, _k) -> Variant:
		return null
	func num() -> int:
		return 0

func _ready() -> void:
	demo()
	get_tree().quit()

func demo() -> void:
	var runtime = RuntimeScript.new()
	runtime.obj_mgr.max_objects = 4096	# 存活对象上限：忘了 obj:delete 顶到上限时构造器直接报错
	runtime.add_host_function('println', host_println)

	# ---------- 1. STML 解析：代码段标签按 Stope 代码扫 ----------
	var lexer := Stope.STMLLexer.Lexer.new(DOC)
	var parser := Stope.STMLParser.Parser.new(lexer)
	var root := Stope.STML.Element.new()
	if parser.parse(root, _state_func) != Stope.Result.Success:
		for e in parser.errors: print(e)
		return

	# ---------- 2. 访问文档：构建类、编译函数 ----------
	var visitor = DocVisitorScript.new()
	if not visitor.visit_doc(root, runtime):
		return
	var main_func = runtime.find_function('main')
	if main_func == null:
		print('no main function')
		return

	# ---------- 3. 装配入口帧：绑定归 Runtime.push_entry_frame ----------
	runtime.push_entry_frame(main_func, NoArgs.new())

	# ---------- 4. 运行：两种驱动，随时可切 + 清理诊断 ----------
	# 限步：run_steps(20) 每帧最多 20 条指令，帧间就是宿主的逻辑帧；方法
	#   调用压帧、返回弹帧，预算跨调用共享——单步调试就把 20 改成 1。
	# 直接：run_all() 一口气跑到帧栈清空。demo 先限步 1 帧，再直接跑完。
	var slices := 0
	while slices < 1 and runtime.run_steps(20):
		slices += 1
	runtime.run_all()
	print('-- ', slices, ' stepped slice(s), 20 steps each, then RunAll --')
	runtime.obj_mgr.report_live()	# 忘了 obj:delete 的对象在这里现形
	runtime.free()	# Runtime 是 Object：显式释放，否则 ObjectDB 报泄漏

# 宿主函数：与 C++ demo 一致——只格式化 int / float / String，其余忽略。
func host_println(args:Array):
	var parts:PackedStringArray = []
	for a in args:
		if a is String:
			parts.append(a)
		elif a is float and a == floor(a) and abs(a) < 1e15:
			parts.append(str(int(a)))
		elif a is int or a is float:
			parts.append(str(a))
	print(''.join(parts))
	return null

# 带 stope 属性的元素，内容按 Stope 代码扫；其余按子元素列表（Xml）解析。
static func _state_func(tag:String, _attrs:Dictionary) -> int:
	return Stope.STMLLexer.State.Stope if tag in ['method', 'new', 'delete', 'func'] \
		else Stope.STMLLexer.State.Xml
