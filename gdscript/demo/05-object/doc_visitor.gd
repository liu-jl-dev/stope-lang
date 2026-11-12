# doc_visitor.gd：STML 文档 -> 类与函数，含编译、索引预算与 self 链接
# （对应 cpp/demo/05-object/ 的 DocVisitor.*）。脚本自身即 DocVisitor 类。

extends RefCounted

# 统一入口：addons/stope 不注册全局类，preload 门面后按 Stope.模块 访问
const Stope = preload("res://addons/stope/stope.gd")

const Classes := preload("res://demo/05-object/classes.gd")
const Objects := preload("res://demo/05-object/objects.gd")

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
			cls.member_by_id[rt.new_member_id('delete')] = \
				_ref(MemberKind.DELETE, idx3)

# 成员种类（对应 C++ 的 kMemberProp / kMemberMethod / kMemberDelete）。
enum MemberKind { PROP, METHOD, DELETE }

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

# 链接 self:<属性> 与 self:<方法名>，并校验方法里 self: 前缀的隐式导出
# 全部链接成功（拼写错误装配期拦下）。必须在全部类访问完之后跑：方法可以
# 引用文档里后定义的成员。<func> 里的 self: 有意不校验（见 docs §10）。
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
					continue	# <delete> 无名
				var ref = cls.member_by_id.get(rt.member_name_map[nm2])
				if ref == null or ref.kind != MemberKind.METHOD:
					continue	# 不是本类的方法成员
				var enm := 'self:' + nm2
				if m.program.exports.has(enm):
					m.self_method_binds.append([m.program.exports[enm],
						rt.member_name_map[nm2]])
			for enm: String in m.program.exports:
				if not enm.begins_with('self:'):
					continue
				if not _linked(m, enm):
					push_error('unlinked self member: ' + enm)
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
