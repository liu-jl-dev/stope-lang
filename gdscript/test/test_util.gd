class_name StopeTestUtil
# 测试基础设施。三组测试（词法 / 语法 / 编译器）共用。
#
# 【期望值从哪来】test/data/*.txt 是**机器生成**的：由 test/tools/golden*.cpp
# 在 C++ 侧跑同一批用例 dump 出来（C++ 是权威实现）。这里的测试不做任何手推期望值，
# 只负责让 GDScript 侧产出同格式文本，再逐字段比对。
# 重跑方式见 gdscript/docs/testing.md。

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
# 三组测试都用同一张表，与 test/tools/*.cpp 里注册的一致：
#   myop 定长 2 参 -> opcode 100；vop 变长 -> opcode 101
static func custom_insts() -> Array[Stope.CustomInst]:
	return [
		Stope.CustomInst.new('myop', 100, false, 2),
		Stope.CustomInst.new('vop', 101, true, -1),
	]

# 建一个 Program，字段先准备好空容器 —— clear()/append 需要有东西可操作
static func new_program() -> Stope.Program:
	var p := Stope.Program.new()
	p.opcodes = []; p.int_consts = []; p.float_consts = []
	p.string_consts = []; p.bin_arr_consts = []; p.exports = {}
	return p
