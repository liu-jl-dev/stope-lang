class_name StopeTestUtil
# 测试基础设施。三组测试（词法 / 语法 / 编译器）共用。
#
# 【期望值从哪来】test/data/*.txt 是**机器生成**的：由 cpp/tools/golden*.cpp
# 在 C++ 侧跑同一批用例 dump 出来（C++ 是权威实现）。这里的测试不做任何手推期望值，
# 只负责让 GDScript 侧产出同格式文本，再逐字段比对。
# 重跑方式见 gdscript/docs/testing.md。

# dump_program 里用的两个别名（原来是 StopeProgram 文件顶部的常量，随函数一起搬来）
const Opcode = StopeOpcode.Opcode
const CustomOpcode = StopeOpcode.CustomOpcode

# ============================== 结果汇总 ==============================
class Report:
	var total:int = 0
	var failed:int = 0
	var lines:Array[String] = []

	# 一条字段级断言
	func check(id:String, field:String, exp:String, got:String) -> bool:
		total += 1
		if exp == got: return true
		failed += 1
		lines.append(str('  FAIL ', id, '  字段 ', field, '\n    exp= ', exp, '\n    got= ', got))
		return false
	# 整行比对（golden_binarr.txt 那种没有 ID 的记录）
	func check_line(id:String, exp:String, got:String) -> bool:
		return check(id, '(整行)', exp, got)
	# 读不到数据文件这类「整组没跑」的失败
	func add_fail(msg:String) -> void:
		failed += 1
		lines.append(msg)
	func add_total(n:int = 1) -> void: total += n
	func summary() -> String:
		return str('  断言 ', total, ' 条，失败 ', failed, ' 条')

# ============================== 转义 ==============================
# 与 C++ 探针 golden.cpp 的 E_ 同一套规则：\\ \n \r \t，保证一条记录一行。
static func esc_(s:String) -> String:
	var o := ''
	for i in range(len(s)):
		var ch := s[i]
		if ch == '\\': o += '\\\\'
		elif ch == '\n': o += '\\n'
		elif ch == '\r': o += '\\r'
		elif ch == '\t': o += '\\t'
		else: o += ch
	return o

# golden_lex.cpp 的 E_ 比 golden.cpp 多转义两个竖向空白
static func esc_lex(s:String) -> String:
	var o := ''
	for i in range(len(s)):
		var ch := s[i]
		if ch == '\\': o += '\\\\'
		elif ch == '\n': o += '\\n'
		elif ch == '\r': o += '\\r'
		elif ch == '\t': o += '\\t'
		elif ch == '\v': o += '\\v'
		elif ch == '\f': o += '\\f'
		else: o += ch
	return o

# 与 C++ 的 Stope::Test::escUtf8 完全一致：\ " \n \r \t 转义，非 ASCII 一律变 '?'
# （形状串与 lexeme 比对用，两侧必须同一套规则）
static func esc_shape(s:String) -> String:
	var o := ''
	for i in range(len(s)):
		var ch := s[i]
		if ch == '\\': o += '\\\\'
		elif ch == '"': o += '\\"'
		elif ch == '\n': o += '\\n'
		elif ch == '\r': o += '\\r'
		elif ch == '\t': o += '\\t'
		elif ord(ch) < 128: o += ch
		else: o += '?'
	return o

# E_ 的逆：把记录里的转义还原成源文本，喂给 Lexer
static func unesc(s:String) -> String:
	var o := ''
	var i := 0
	while i < len(s):
		if s[i] == '\\' and i + 1 < len(s):
			var c := s[i + 1]
			if c == '\\': o += '\\'
			elif c == 'n': o += '\n'
			elif c == 'r': o += '\r'
			elif c == 't': o += '\t'
			elif c == 'v': o += '\v'
			elif c == 'f': o += '\f'
			else:
				o += s[i]
				i += 1
				continue
			i += 2
		else:
			o += s[i]
			i += 1
	return o

static func join_esc(errs:Array, esc_fn:Callable) -> String:
	var parts:Array[String] = []
	for e in errs: parts.append(esc_fn.call(str(e)))
	return "|".join(parts)

# ============================== 读取数据文件 ==============================
# 每条记录一行，字段间用 \t 分隔，形如 ID=xx\tSRC=xx\t...
static func read_golden(path:String) -> Array[Dictionary]:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error(str('打不开数据文件: ', path, ' —— 请先确认 gdscript/test/data/ 存在'))
		return []
	var out:Array[Dictionary] = []
	for raw in f.get_as_text().split('\n'):
		if raw == '' or raw.begins_with('#'): continue
		# C++ 探针在 Windows 上重定向出来是 CRLF，最后一个字段会粘上 \r
		if raw.ends_with('\r'): raw = raw.substr(0, len(raw) - 1)
		var fields := {}
		for part in raw.split('\t'):
			var p := part.find('=')
			if p < 0: continue
			fields[part.substr(0, p)] = part.substr(p + 1)
		out.append(fields)
	return out

# 逐行读（golden_binarr.txt：没有 ID= 前缀，按位置分列）
static func read_lines(path:String) -> Array[String]:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error(str('打不开数据文件: ', path))
		return []
	var out:Array[String] = []
	for raw in f.get_as_text().split('\n'):
		if raw == '' or raw.begins_with('#'): continue
		if raw.ends_with('\r'): raw = raw.substr(0, len(raw) - 1)
		out.append(raw)
	return out

# ============================== 自定义指令 ==============================
# 三组测试都用同一张配置，与 cpp/tools/*.cpp 里注册的一致：
#   myop 定长 2 参 -> opcode 100；vop 变长 -> opcode 101
static func custom_config() -> StopeOpcode.CustomOpcodeConfig:
	var cfg := StopeOpcode.CustomOpcodeConfig.new()
	cfg.add_custom_opcode('myop', 100, 2)
	cfg.add_custom_opcode('vop', 101, -1)
	return cfg

# Program 序列化成「通用测试计划」约定的一行文本（docs/zh-cn/compiler-test-plan.md §2.3）。
#
# **只给测试比对用，不属于库 API** —— 人读的反汇编是 StopeDebug.disasm，
# 与 C++ 侧的分工一致（那边单行格式是 tools/golden.cpp 的私有 dumpLine）。
#   code[PushId(0) PushInt(0) Assign] vars=1 stack=2 maxRet=0
#   ints=[1] floats=[] strs=[] binarrs=[] exports=[a:0,b:1]
# cis 是自定义指令表（名字 -> StopeOpcode.CustomOpcode），用来判断 >32 的 opcode 是否变长。
static func dump_program(p:StopeProgram.Program, cis:Dictionary = {}) -> String:
	var s := 'code['
	var i := 0
	while i < len(p.opcodes):
		if i > 0: s += ' '
		var op:int = p.opcodes[i]; i += 1
		var has_param:bool
		if op > Opcode.Return:
			s += str('Opcode(', op, ')')
			has_param = false
			for k in cis.keys():
				var ci:CustomOpcode = cis[k]
				if ci.opcode == op:
					has_param = ci.arg_num < 0	# 与 C++ 的 isVarArg 同一判据
					break
		else:
			has_param = StopeOpcode.has_a_param(op)
			s += Opcode.keys()[op]
		if has_param and i < len(p.opcodes):
			s += str('(', p.opcodes[i], ')')
			i += 1
	s += ']'
	s += str(' vars=', p.variable_num)
	s += str(' stack=', p.required_stack_size)
	s += str(' maxRet=', p.max_return_num)
	s += ' ints=['
	for k in range(len(p.int_consts)):
		if k > 0: s += ','
		s += str(p.int_consts[k])
	s += ']'
	s += ' floats=['
	for k in range(len(p.float_consts)):
		if k > 0: s += ','
		s += StopeAst.fmt_g(p.float_consts[k])
	s += ']'
	s += ' strs=['
	for k in range(len(p.string_consts)):
		if k > 0: s += ','
		s += StopeAst.esc(p.string_consts[k])
	s += ']'
	s += ' binarrs=['
	for k in range(len(p.bin_arr_consts)):
		if k > 0: s += ' '
		s += '['
		var m := 0
		for b in p.bin_arr_consts[k]:
			if m > 0: s += ','
			s += '%02x' % b
			m += 1
		s += ']'
	s += ']'
	s += ' exports=['
	# 【顺序】C++ 侧 Program::exports 是 std::map<u16string,int>，遍历天然按键升序；
	# GDScript 的 Dictionary 是插入序。两边要能逐字节比对，所以这里显式排序。
	# 只影响序列化，VM 与其它地方都不依赖 exports 的遍历顺序。
	var keys:Array[String] = []
	for k in p.exports: keys.append(k)
	keys.sort()
	var first := true
	for k in keys:
		if not first: s += ','
		first = false
		s += str(StopeAst.esc(k), ':', p.exports[k])
	s += ']'
	return s

# 建一个 Program。字段已有默认空容器，这里只是给调用方一个明确的构造入口。
static func new_program() -> StopeProgram.Program:
	return StopeProgram.Program.new()
