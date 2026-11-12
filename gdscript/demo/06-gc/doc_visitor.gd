# doc_visitor.gd：STML 文档 -> 类与函数，含编译、索引预算与 self 链接
# （对应 cpp/demo/06-gc/ 的 DocVisitor.*）。脚本自身即 DocVisitor 类。
#
# 与 demo 5 的差异：<delete> 只设 deconstructor（不注册 obj:delete 成员）；
# link 阶段多一步 export_binds 预算（方法体里的 <类名>:<构造名> / obj:<名>）。

extends RefCounted

# 统一入口：addons/stope 不注册全局类，preload 门面后按 Stope.模块 访问
const Stope = preload("res://addons/stope/stope.gd")

const Classes := preload("res://demo/06-gc/classes.gd")
const Objects := preload("res://demo/06-gc/objects.gd")

var failed := false

# GDScript 没有异常（C++ 版用 throw 上传装配期失败）：失败沿返回值上传。
func visit_doc(root:Stope.STML.Element, rt) -> bool:
	for e in root.children:
		if e.tag == 'class':
			visit_class(e, rt)
		elif e.tag == 'func':
			visit_func(e, rt)
	return link_self_calls(rt)

func visit_class(e:Stope.STML.Element, rt) -> void:
	var cls = rt.new_class()
	cls.name = e.attrs['name']
	rt.class_map[cls.name] = cls.id	# 命名后再登记：new_class 时 name 还是空
	for c in e.children:
		if c.tag == 'property':
			var prop_name := String(c.attrs['name'])
			cls.member_by_id[rt.new_member_id(prop_name)] = \
				_ref(MemberKind.PROP, cls.properties.size())
			cls.properties.append(prop_name)
		elif c.tag == 'method':
			var idx = cls.methods.size()
			visit_method(c, rt, cls)
			if not cls.methods[-1].name.is_empty():
				cls.member_by_id[rt.new_member_id(cls.methods[-1].name)] = \
					_ref(MemberKind.METHOD, idx)
		elif c.tag == 'new':
			var idx2 = cls.methods.size()
			cls.constructor_map[String(c.attrs['name'])] = idx2
			visit_method(c, rt, cls)
		elif c.tag == 'delete' and cls.deconstructor_id == -1:
			var idx3 = cls.methods.size()
			cls.deconstructor_id = idx3
			visit_method(c, rt, cls)
			# demo 6：<delete> 是 gc 回收时自动跑的析构函数，不注册
			# obj:delete 成员——没有手动删除入口，成员 id 也不为它分配。

# 成员种类（对应 C++ 的 kMemberProp / kMemberMethod）。
enum MemberKind { PROP, METHOD }

func visit_method(e:Stope.STML.Element, rt, cls) -> void:
	var m = Classes.MethodInfo.new()
	m.name = String(e.attrs.get('name', ''))
	if e.attrs.has('params'):
		for p in String(e.attrs['params']).split(' ', false):
			m.params.append(p)
	# pre_exports = 形参（属性不进：self:<属性> 走隐式导出，链接遍配对）。
	m.program = _compile(e.text, e.text_line, m.params)
	if m.program == null:
		m.name = '@failed@'	# 标记失败，link 阶段统一报
		return
	# 装配期预计算整数索引：宿主函数 -> (槽位, 序号)；形参 -> 槽位。
	for nm: String in rt.host_func_map:
		if m.program.exports.has(nm):
			m.host_binds.append([m.program.exports[nm], rt.host_func_map[nm]])
	for p in m.params:
		m.param_slots.append(m.program.exports[p])
	cls.methods.append(m)

func visit_func(e:Stope.STML.Element, rt) -> void:
	var f = Classes.FunctionInfo.new()
	f.name = String(e.attrs['name'])
	if e.attrs.has('params'):
		for p in String(e.attrs['params']).split(' ', false):
			f.params.append(p)
	f.program = _compile(e.text, e.text_line, f.params)
	if f.program == null:
		f.name = '@failed@'
		failed = true
		return
	for nm: String in rt.host_func_map:
		if f.program.exports.has(nm):
			f.host_binds.append([f.program.exports[nm], rt.host_func_map[nm]])
	for p in f.params:
		f.param_slots.append(f.program.exports[p])
	rt.functions.append(f)

# 链接 self:<属性> / self:<方法名> / <类名>:<构造名> / obj:<名>，并校验
# self: 前缀的隐式导出全部链接成功。必须在全部类访问完之后跑。
func link_self_calls(rt) -> bool:
	for cls in rt.classes:
		for m in cls.methods:
			if m.name == '@failed@':
				return false
			for fi in range(cls.properties.size()):
				var nm = 'self:' + cls.properties[fi]
				if m.program.exports.has(nm):
					m.self_props.append([m.program.exports[nm], fi])
			for nm2: String in rt.member_name_map:
				if nm2.is_empty():
					continue
				var ref = cls.member_by_id.get(rt.member_name_map[nm2])
				if ref == null or ref.kind != MemberKind.METHOD:
					continue	# 不是本类的方法成员
				var enm := 'self:' + nm2
				if m.program.exports.has(enm):
					m.self_method_binds.append([m.program.exports[enm],
						rt.member_name_map[nm2]])
			# 方法体里的 <类名>:<构造名> / obj:<名>：方法有独立的 program，
			# 这些名字是它自己的隐式导出，每个 State 都要各自绑。描述符是
			# RefCounted、被 export_binds 引用着——引擎计数保证不回收。
			for enm2: String in m.program.exports:
				var colon := enm2.find(':')
				if colon < 0:
					continue
				var head := enm2.substr(0, colon)
				var tail := enm2.substr(colon + 1)
				var handle = null
				if head == 'obj':
					var mid = rt.member_name_map.get(tail)
					if mid == null:
						continue	# 不是任何已注册成员
					handle = rt.obj_mgr.new_member_desc(mid)
				else:
					var cid = rt.class_map.get(head)
					if cid == null:
						continue
					var ctor_idx = rt.classes[cid].constructor_map.get(tail)
					if ctor_idx == null:
						continue
					handle = rt.obj_mgr.new_ctor_desc(cid, ctor_idx)
				if handle != null:
					m.export_binds.append([m.program.exports[enm2], handle])
			for enm3: String in m.program.exports:
				if not enm3.begins_with('self:'):
					continue
				if not _linked(m, enm3):
					push_error('unlinked self member: ' + enm3)
					return false
	return true

func _linked(m, enm:String) -> bool:
	for p in m.self_props:
		if m.program.exports[enm] == p[0]:
			return true
	for b in m.self_method_binds:
		if m.program.exports[enm] == b[0]:
			return true
	return false

func _ref(kind:int, index:int):
	var r = Objects.MemberRef.new()
	r.kind = kind
	r.index = index
	return r

# 编译一份源码：pre_exports = 形参；失败返回 null（GDScript 无异常）。
func _compile(src:String, start_line:int, pre_exports:Array[String]) -> Stope.Program.Program:
	var lexer := Stope.Lexer.Lexer.new(src)
	lexer.line = start_line	# 报错行号对齐原文档
	var parser := Stope.Parser.Parser.new(lexer)
	var tree := Stope.Ast.Prog.new()
	parser.parse_program(tree)
	if not lexer.errors.is_empty() or not parser.errors.is_empty():
		for e in lexer.errors: print('  lexer: ', e)
		for e in parser.errors: print('  parser: ', e)
		return null
	var compiler := Stope.Compiler.Compiler.new()
	var out := Stope.Program.Program.new()
	if compiler.compile(tree, out, pre_exports) != Stope.Result.Success:
		for e in compiler.errors: print('  compiler: ', e)
		return null
	return out
