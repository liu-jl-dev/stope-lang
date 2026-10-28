class_name StopeDebug

# Program 反汇编（调试用）。与 cpp/include/stope/debug.hpp 的 `Disasm` /
# `DisasmNoCustom` **一一对应，连名字都一样**（唯一差别是语言命名惯例）：
# 编号列、名字列宽、变量表、常量池、自定义指令表、warning 的顺序与文案都照抄，
# 便于两侧对同一份产物逐行 diff。
#
# 这是**库 API 里唯一的文本呈现入口**。单行比对格式不在这里，也不在库里的任何
# 地方 —— 它在 test/test_util.gd 的 `dump_program`，与 C++ 侧把它关在
# tools/golden.cpp 私有的 `dumpLine` 里，是同一个分工。
#
# config 可空：产物里没有自定义指令就传 null。**有**自定义指令时必须传注册时
# 用的那一份，否则名字无从得知，而且变长指令后面那个「参数个数」会被当成下一条
# 指令 —— 两者只差一个 int，整段会错位。

const Opcode = StopeOpcode.Opcode
const FIRST_CUSTOM := StopeOpcode.FIRST_CUSTOM_OPCODE

# 名字列的最小宽度 = 内置名里最长的两个（PushString / PushBinArr，都 10 个字符）。
const MIN_NAME_WIDTH := 10

# 内置指令是否带一个操作数。真正的判定只有一份：StopeOpcode.has_a_param，
# 这里是对应 C++ `OpcodeHasArg` 的同名入口（自定义指令不走这里）。
static func opcode_has_arg(op:int) -> bool:
	return StopeOpcode.has_a_param(op)

# 自定义指令只有在**变长**参数时带操作数 —— 那个操作数是本次调用的参数个数；
# 定长指令的参数个数在注册时就定死了，产物里不再重复写。对应 C++ 的
# `CustomOpcodeHasArg`。
static func custom_opcode_has_arg(raw:int, config:StopeOpcode.CustomOpcodeConfig) -> bool:
	if config == null: return false
	for k in config.opcodes:
		var info:StopeOpcode.CustomOpcode = config.opcodes[k]
		if info.opcode == raw and info.arg_num < 0: return true
	return false

static func disasm_no_custom(prog:StopeProgram.Program) -> String:
	return disasm(prog, null)

static func disasm(prog:StopeProgram.Program,
		config:StopeOpcode.CustomOpcodeConfig = null) -> String:
	# ---------- 编号 -> 名字 的反查表 ----------
	var names:= {}	# int -> String，只装合法编号（>= 33 且不与他人撞号）
	var infos:= {}	# int -> StopeOpcode.CustomOpcode，同上
	var warnings:Array[String] = []
	var name_width := MIN_NAME_WIDTH

	if config != null:
		# C++ 的 config.opcodes 是 std::map（按键字典序），GD 的 Dictionary 是插入序。
		# 先排序再遍历，撞号 / 重号的「谁赢」与警告文案才能和 C++ 一致。
		var keys:Array[String] = []
		for k in config.opcodes: keys.append(k)
		keys.sort()
		for name in keys:
			var info:StopeOpcode.CustomOpcode = config.opcodes[name]
			if info.opcode < FIRST_CUSTOM:
				# 用了内置编号：反汇编只能按内置指令解码，这个名字彻底丢失
				var what := '(not an opcode)'
				if info.opcode >= 0 and info.opcode < Opcode.size():
					what = Opcode.keys()[info.opcode]
				warnings.append(str('custom opcode "', name, '" uses #', info.opcode,
					', which collides with ', what, '; builtin decoding wins.'))
				continue
			if names.has(info.opcode):
				warnings.append(str('custom opcodes "', names[info.opcode], '" and "', name,
					'" share #', info.opcode, '; the former wins.'))
				continue
			names[info.opcode] = name
			infos[info.opcode] = info
			name_width = max(name_width, name.length())

	# ---------- 指令流 ----------
	var s := ''
	var unknown:Array[int] = []	# 不认识的编号，最后统一提示（升序，同 std::set）
	var n := prog.opcodes.size()
	var i := 0
	while i < n:
		var raw:int = prog.opcodes[i]
		var op_name := ''
		var has_arg := false
		if raw >= 0 and raw < Opcode.size():
			op_name = Opcode.keys()[raw]
			has_arg = StopeOpcode.has_a_param(raw)
		elif names.has(raw):
			op_name = names[raw]
			has_arg = infos[raw].arg_num < 0	# 变长才带「参数个数」
		else:
			# 编号不认识就只能印数字。**绝不能猜有没有操作数**，否则会把下一条
			# 指令当成操作数吃掉、后面整段错位。
			op_name = str('Custom', raw) if raw > Opcode.Return else str('Op#', raw)
			if not unknown.has(raw): unknown.append(raw)
		s += _pad_right(str('[', i, ']'), 8)
		s += _pad_right(op_name, name_width)
		s += ' '
		if has_arg:
			if i + 1 < n:
				i += 1
				s += str(prog.opcodes[i])
			else:
				s += '<missing operand>'
				warnings.append(str('opcode at [', i,
					'] expects an operand but the stream ends there.'))
		s += '\n'
		i += 1

	# ---------- 自定义指令表 ----------
	if not names.is_empty():
		s += 'custom opcodes:\n'
		var ids:Array[int] = []
		for id in names: ids.append(id)
		ids.sort()
		for id in ids:
			var info:StopeOpcode.CustomOpcode = infos[id]
			s += str('  ', _pad_right(names[id], name_width), ' -> ', id)
			if info.arg_num < 0: s += ' (vararg)'
			else: s += str(' (', info.arg_num, ' args)')
			s += '\n'

	# ---------- 变量表与常量池 ----------
	# 槽位 -> 名字：只有 exports 里的变量有名字，其余留空串（与 C++ 一致）
	s += 'variables:\n'
	var vars:Array[String] = []
	vars.resize(prog.variable_num)
	for name in prog.exports: vars[prog.exports[name]] = name
	s += '  '
	for k in range(vars.size()):
		s += str('"', vars[k], '"')
		if k < vars.size() - 1: s += ' '
	s += '\nint consts:\n'
	for v in prog.int_consts: s += str('  ', v)
	s += '\nfloat consts:\n'
	for v in prog.float_consts: s += str('  ', StopeAst.fmt_g(v))
	s += '\nstring consts:\n'
	for v in prog.string_consts: s += str('  "', v, '"\n')
	s += 'binary array consts:\n'
	for v in prog.bin_arr_consts: s += str('  ', v.size(), ' bytes\n')
	s += str('max return num: ', prog.max_return_num, '\n')
	s += str('required stack size: ', prog.required_stack_size, '\n')

	unknown.sort()
	for raw in unknown:
		if raw > Opcode.Return:
			# 文案与 C++ 的 Disasm 逐字一致（两边同名，不用翻译）
			warnings.append(str('opcode #', raw, ' is not a builtin; pass the ',
				'CustomOpcodeConfig to Disasm() to decode it.'))
		else:
			warnings.append(str('opcode #', raw,
				' is not a valid instruction (unpatched placeholder?).'))
	for w in warnings: s += str('warning: ', w, '\n')
	return s

static func _pad_right(s:String, width:int) -> String:
	if s.length() >= width: return s
	return s + ' '.repeat(width - s.length())
