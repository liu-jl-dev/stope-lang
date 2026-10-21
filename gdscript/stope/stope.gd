class_name Stope

enum Inst {
	Assign, PushNull, PushFalse, PushTrue, PushInt,
	PushFloat, PushString, PushBinArr, PushId, Call,
	At, Pop, Minus, Not, Pow, Mul,
	Div, IDiv, Mod, Add, Sub,
	EQ, NE, LT, LE, GT,
	GE, If, GoTo, GetArg, ArgNum,
	Return,
} # 共 32 个

class CustomInst:
	var name:String
	var code:int
	var variable_arg:bool
	var arg_num:int
	func _init(name_:String, code_:int, var_arg:bool, arg_n:int=-1) -> void:
		name = name_; code = code_; variable_arg = var_arg; arg_num = arg_n

# 该指令是否带一个操作数。分档与 golden 探针 / VM 的步进规则完全一致。
# 注意 CD 于此：cpp 侧没有这个函数，是 opcode 与否由 emit 处决定；
# 这里是供序列化（dump_program）与反汇编器使用的一个等价判定。
static func has_a_param(inst:int) -> bool:
	if inst <= Inst.PushTrue: return false	# 0..3
	if inst <= Inst.At: return true			# 4..10  常量/变量索引、参数个数
	if inst <= Inst.GE: return false		# 11..26
	if inst <= Inst.GoTo: return true		# 27..28 If / GoTo 的跳转目标
	if inst <= Inst.ArgNum: return false	# 29..30
	return true								# 31 Return 的返回值个数

# 程序 = 指令流 + 常量池 + 变量表。字段名取 cpp/stope/program.hpp 的 snake_case 形式。
class Program:
	var opcodes:Array[int]
	var variable_num:int # 变量数量
	var exports:Dictionary[String,int] # 导出的变量的索引
	var int_consts:Array#[int]
	var float_consts:Array#[float]
	var string_consts:Array#[String]
	var bin_arr_consts:Array#[PackedByteArray]
	var max_return_num:int # return 语句最大返回值数量
	var required_stack_size:int
	func to_map() -> Dictionary:
		return {
			'c': opcodes, 'i': int_consts, 'f': float_consts, 's': string_consts,
			'ba': bin_arr_consts, 'vn': variable_num, 'e': exports,
			'sc': required_stack_size, 'mr': max_return_num
		}
	func  to_json_string() -> String:
		return JSON.stringify(to_map(), '', false)

# 序列化成「通用测试计划」约定的一行文本（见 docs/zh-cn/compiler-test-plan.md §2.3）：
#   code[PushId(0) PushInt(0) Assign] vars=1 stack=2 maxRet=0
#   ints=[1] floats=[] strs=[] binarrs=[] exports=[a:0,b:1]
# cis 是自定义指令表（名字 -> Stope.CustomInst），用来判断 >31 的 opcode 是否变长。
static func dump_program(p:Program, cis:Dictionary = {}) -> String:
	var s := 'code['
	var i := 0
	while i < len(p.opcodes):
		if i > 0: s += ' '
		var op:int = p.opcodes[i]; i += 1
		var has_param:bool
		if op > Inst.Return:
			s += str('Inst(', op, ')')
			has_param = false
			for k in cis.keys():
				var ci:Stope.CustomInst = cis[k]
				if ci.code == op:
					has_param = ci.variable_arg
					break
		else:
			has_param = has_a_param(op)
			s += Inst.keys()[op]
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

class Identifier:
	var index:int
	func _init(index_:int): index = index_

@abstract class Link:
	@abstract func call_(argc:int, stack:Array)
	@abstract func at(argc:int, stack:Array)

@abstract class Arguments:
	@abstract func at(index_or_key)
	@abstract func num() -> int

class State:
	var api:Api
	var program:Program
	var link:Link
	var args:Arguments
	var returns:Array

	var i:int
	var variables:Array
	var stack:Array

	var errors:Array[String]
	#func _init(program:Program) -> void:
		#reset(program)
	func reset(api_:Api, prog:Program, link_:Link, args_:Arguments):
		api = api_
		program = prog
		link = link_
		args = args_
		returns = []
		i = 0
		variables = []; variables.resize(program.variable_num)
		stack = []
		errors = []
	func set_args(args_:Arguments): args = args_
	func step():
		pass
	func run() -> bool: # 没错误时返回 true，否则 false
		while i < len(program.opcodes):
			api.op_map[program.opcodes[i]].call(self)
			if len(errors) > 0: return false
			i += 1
		return true

	func _get_value_in_stack(idx:int):
		if stack[idx] is Identifier:
			return variables[stack[idx].index]
		return stack[idx]
	func _replace_and_get_value_in_stack(idx:int):
		if stack[idx] is Identifier:
			stack[idx] = variables[stack[idx].index]
			return stack[idx]
		return stack[idx]
	func _replace_id_in_stack(idx:int):
		if stack[idx] is Identifier:
			stack[idx] = variables[stack[idx].index]
	func _pop_and_get_value():
		var v = stack.pop_back()
		if v is Identifier: return variables[v.index]
		return v

	func _error(msg:String, print_inst_name:bool=true):
		errors.append(str(i,
			str(' ',Inst.keys()[program.opcodes[i]]) if print_inst_name else '',': ',msg))



class Api:
	var op_map:Array[Callable] = [
		self._assign, self._push_null, self._push_false, self._push_true, self._push_int,
		self._push_float, self._push_string, self._push_bin_arr, self._push_id, self._call, self._at,
		self._pop, self._minus, self._not, self._pow, self._mul,
		self._div, self._idiv, self._mod, self._add, self._sub,
		self._eq, self._ne, self._lt, self._le, self._gt,
		self._ge, self._if, self._goto, self._get_arg, self._arg_num,
		self._return,
	]
	func _assign(s:State):
		if s.stack[-2] is Identifier:
			var value = s._pop_and_get_value()
			var id:Identifier = s.stack.pop_back()
			s.variables[id.index] = value
		else: s._error(str('no implement. '))
	func _push_null(s:State): s.stack.push_back(null)
	func _push_false(s:State): s.stack.push_back(false)
	func _push_true(s:State): s.stack.push_back(true)
	func _push_int(s:State):
		s.i += 1; var idx:int = s.program.opcodes[s.i]
		s.stack.append(s.program.int_consts[idx])

	func _push_float(s:State):
		s.i += 1; var idx:int = s.program.opcodes[s.i]
		s.stack.append(s.program.float_consts[idx])
	func _push_string(s:State):
		s.i += 1; var idx:int = s.program.opcodes[s.i]
		s.stack.append(s.program.string_consts[idx])
	func _push_bin_arr(s:State): # C++ 侧新增的指令，参考实现里没有
		s.i += 1; var idx:int = s.program.opcodes[s.i]
		s.stack.append(s.program.bin_arr_consts[idx])
	func _push_id(s:State):
		s.i += 1; var idx:int = s.program.opcodes[s.i]
		s.stack.append(Identifier.new(idx)) # 不能是值，否则无法 Assign。
	func _call(s:State):
		s.i += 1; var argc:int = s.program.opcodes[s.i]
		for i in range(-1-argc, 0): s._replace_id_in_stack(i) # 将 id 替换为值。包括函数和参数。
		var result = s.link.call_(argc, s.stack) # Link 中处理参数等
		s.stack = s.stack.slice(0, -argc-1)
		s.stack.push_back(result)
	func _at(s:State):
		s.i += 1; var argc:int = s.program.opcodes[s.i]
		for i in range(-1-argc, 0): s._replace_id_in_stack(i)
		var result = s.link.at(argc, s.stack) # Link 中处理参数等
		s.stack = s.stack.slice(0, -argc-1)
		s.stack.push_back(result)

	func _pop(s:State): s.stack.pop_back()
	func _minus(s:State):
		var val = s._pop_and_get_value()
		if val is int or val is float: s.stack.push_back(-val)
		else: s.error("'Minus' can only numbers. ")
	func _not(s:State):
		var v = s._pop_and_get_value()
		s.stack.push_back(not v) # Godot 中，所有类型都可以 not
	func _pow(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		if (a is int or a is float) and (b is int or b is float): s.stack.push_back(a ** b)
		else: s.error(str("'Pow' can only operate numbers. "))
	func _mul(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		if (a is int or a is float) and (b is int or b is float): s.stack.push_back(a * b)
		else: s.error(str("'Mul' can only operate numbers. "))

	func _div(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		if (a is int) and (b is int):
			if a % b == 0: s.stack.push_back(a / b)
			else: s.stack.push_back(float(a) / float(b))
		elif (a is int or a is float) and (b is int or b is float):
			s.stack.push_back(a / float(b))
		else: s.error(str("'Div' can only operate numbers. "))
	func _idiv(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		if (a is int or a is float) and (b is int or b is float):
			s.stack.push_back(int(a / b))
		else: s.error(str("'IDiv' can only operate numbers. "))
	func _mod(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		if (a is int or a is float) and (b is int or b is float):
			if (a is int) and (b is int): s.stack.push_back(a % b)
			else: s.stack.push_back(fmod(a, b))
		else: s.error(str("'Mod' can only operate numbers. "))
	func _add(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		if ((a is int or a is float) and (b is int or b is float)) or (a is String and b is String):
			s.stack.push_back(a + b)
		else: s.error(str("'Add' can only operate numbers or strings. "))
	func _sub(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		if (a is int or a is float) and (b is int or b is float): s.stack.push_back(a - b)
		else: s.error(str("'Sub' can only operate numbers. "))

	func _eq(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		s.stack.push_back(a == b)
	func _ne(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		s.stack.push_back(a != b)
	func _lt(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		if (a is int or a is float) and (b is int or b is float): s.stack.push_back(a < b)
		else: s.error(str("'LT' can only operate numbers. "))
	func _le(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		if (a is int or a is float) and (b is int or b is float): s.stack.push_back(a <= b)
		else: s.error(str("'LE' can only operate numbers. "))
	func _gt(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		if (a is int or a is float) and (b is int or b is float): s.stack.push_back(a > b)
		else: s.error(str("'GT' can only operate numbers. "))

	func _ge(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		if (a is int or a is float) and (b is int or b is float): s.stack.push_back(a >= b)
		else: s.error(str("'GE' can only operate numbers. "))
	func _if(s:State):
		if not s._pop_and_get_value(): s.i = s.program.opcodes[s.i + 1] - 1
		else: s.i += 1 # 后面还会再 +1
	func _goto(s:State): s.i = s.program.opcodes[s.i+1] - 1
	func _get_arg(s:State): s.stack.push_back(s.args.at(s._pop_and_get_value()))
	func _arg_num(s:State): s.stack.push_back(s.args.num())

	func _return(s:State):
		var n:int = s.program.opcodes[s.i + 1]
		for i in range(-n,0): s.returns.append(s._get_value_in_stack(i))
		s.i = len(s.program.opcodes)
