class_name StopeBasicVM

const Opcode = StopeOpcode.Opcode

class Identifier:
	var index:int
	func _init(index_:int): index = index_

@abstract class Arguments:
	# 取第 index_or_key 个实参。取不到**自己报错**：state.error(...) + 返回 null ——
	# 与 C++ 的 at(State&, const Value&, Value& out) -> Result 等价（错误进同一个
	# errors，VM 立刻停）。以前这里没有 state，宿主只能 push_error 到 Godot 控制台，
	# VM 那边当成功继续跑。
	@abstract func at(state:State, index_or_key) -> Variant
	@abstract func num() -> int

class State:
	var api:Api
	var program:StopeProgram.Program
	var args:Arguments
	var returns:Array

	var i:int
	var variables:Array
	var stack:Array

	var errors:Array[String]
	#func _init(program:Program) -> void:
		#reset(program)
	func reset(api_:Api, prog:StopeProgram.Program, args_:Arguments):
		api = api_
		program = prog
		args = args_
		returns = []
		i = 0
		variables = []; variables.resize(program.variable_num)
		stack = []
		errors = []
	func set_args(args_:Arguments): args = args_

	# 宿主的报错入口（对应 C++ 的 State::Error）。i 已经指着出错的那条指令，
	# 所以错误串带上指令名：`"3 Add: msg"`（C++ 是 `"3: msg"`，格式不同但位置同）。
	func error(msg:String) -> void: _error(msg)

	# 执行**一条**指令。true = 这条执行完了且没出错，可以接着 step。
	# 返回 false 有两种情况，靠 errors 区分：
	#   · errors 非空 —— 出错了，i 停在出错的那条指令上；
	#   · errors 为空   —— 指令流已经走完（i 越过末尾）。
	# 所以 `while s.step(): pass` 与 `s.run()` 等价，连走的条数都一样。
	#
	# 出错后再 step 不执行任何指令（不会把同一条错指令跑第二遍、把错误刷两遍）。
	#
	# 与 run 是**两份独立实现**，不互相调用：热循环里每条指令多一次 step()
	# 调用 + 返回值判断，在 GDScript 里是实打实的开销，而 run 是执行路径上唯一
	# 的性能敏感处。代价是两处循环体要保持同步 —— 改步进规则（错误检查、i 推进）
	# 必须同时改这两个函数。
	func step() -> bool:
		if not errors.is_empty(): return false
		var ops := program.opcodes
		if i >= ops.size(): return false
		api.op_map[ops[i]].call(self)
		if not errors.is_empty(): return false
		i += 1
		return true

	func run() -> bool: # 没错误时返回 true，否则 false
		# ops / n 提到循环外：opcodes 在执行中不会变长（Return 只是把 i 拨到末尾）。
		var ops := program.opcodes
		var n := ops.size()
		while i < n:
			api.op_map[ops[i]].call(self)
			if not errors.is_empty(): return false
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
			str(' ',Opcode.keys()[program.opcodes[i]]) if print_inst_name else '',': ',msg))



class Api:
	var op_map:Array[Callable] = [
		self._assign, self._push_null, self._push_false, self._push_true, self._push_int,
		self._push_float, self._push_string, self._push_bin_arr, self._push_value, self._push_id,
		self._call, self._at, self._pop, self._minus, self._not,
		self._pow, self._mul, self._div, self._idiv, self._mod,
		self._add, self._sub, self._eq, self._ne, self._lt,
		self._le, self._gt, self._ge, self._if, self._goto,
		self._get_arg, self._arg_num, self._return,
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
	func _push_value(s:State):
		s.i += 1; var idx:int = s.program.opcodes[s.i]
		s.stack.append(s.variables[idx])	# 压【值】；要槽位引用请用 PushId
	func _push_id(s:State):
		s.i += 1; var idx:int = s.program.opcodes[s.i]
		s.stack.append(Identifier.new(idx)) # 不能是值，否则无法 Assign。
	func _call(s:State):
		s.i += 1; var argc:int = s.program.opcodes[s.i]
		for i in range(-1-argc, 0): s._replace_id_in_stack(i) # 将 id 替换为值。包括函数和参数。
		var callee = s.stack[-argc-1] # 宿主函数就是栈上的一个值，对应 C++ 的 HostFunction
		var result = null
		if callee is Callable:
			var argv:Array = []
			for k in range(argc): argv.append(s.stack[-argc+k])
			result = callee.call(argv)	# 参数整包入栈，由宿主自己拆（对齐 C++ 的 args span）
		else: s._error(str('"Call" can only call a function. '))
		s.stack = s.stack.slice(0, -argc-1)
		s.stack.push_back(result)
	func _at(s:State):
		s.i += 1; var key_num:int = s.program.opcodes[s.i]
		for i in range(-1-key_num, 0): s._replace_id_in_stack(i)
		if key_num != 1: s._error(str('no implement for key num != 1. ')); return
		var container = s._get_value_in_stack(-2)
		var key = s._get_value_in_stack(-1)
		if not (key is int): s._error(str('index must be integer. ')); return
		var result
		if container is PackedByteArray:	# '...' 二进制串
			if key < 0 or key >= len(container): s._error(str('index out of range. ')); return
			result = container[key]
		elif container is String:
			if key < 0 or key >= len(container): s._error(str('index out of range. ')); return
			result = container.unicode_at(key)	# 与 C++ 一致：取的是码元，不是单字符子串
		else: s._error(str('no implement for container type. ')); return
		s.stack = s.stack.slice(0, -key_num-1)
		s.stack.push_back(result)

	func _pop(s:State): s.stack.pop_back()
	func _minus(s:State):
		var val = s._pop_and_get_value()
		if val is int or val is float: s.stack.push_back(-val)
		else: s._error("'Minus' can only numbers. ")
	func _not(s:State):
		var v = s._pop_and_get_value()
		s.stack.push_back(not v) # Godot 中，所有类型都可以 not
	func _pow(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		if (a is int or a is float) and (b is int or b is float): s.stack.push_back(a ** b)
		else: s._error(str("'Pow' can only operate numbers. "))
	func _mul(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		if (a is int or a is float) and (b is int or b is float): s.stack.push_back(a * b)
		else: s._error(str("'Mul' can only operate numbers. "))

	func _div(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		if (a is int) and (b is int):
			if a % b == 0: s.stack.push_back(a / b)
			else: s.stack.push_back(float(a) / float(b))
		elif (a is int or a is float) and (b is int or b is float):
			s.stack.push_back(a / float(b))
		else: s._error(str("'Div' can only operate numbers. "))
	func _idiv(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		if (a is int or a is float) and (b is int or b is float):
			s.stack.push_back(int(a / b))
		else: s._error(str("'IDiv' can only operate numbers. "))
	func _mod(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		if (a is int or a is float) and (b is int or b is float):
			if (a is int) and (b is int): s.stack.push_back(a % b)
			else: s.stack.push_back(fmod(a, b))
		else: s._error(str("'Mod' can only operate numbers. "))
	func _add(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		if ((a is int or a is float) and (b is int or b is float)) or (a is String and b is String):
			s.stack.push_back(a + b)
		else: s._error(str("'Add' can only operate numbers or strings. "))
	func _sub(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		if (a is int or a is float) and (b is int or b is float): s.stack.push_back(a - b)
		else: s._error(str("'Sub' can only operate numbers. "))

	func _eq(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		s.stack.push_back(a == b)
	func _ne(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		s.stack.push_back(a != b)
	func _lt(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		if (a is int or a is float) and (b is int or b is float): s.stack.push_back(a < b)
		else: s._error(str("'LT' can only operate numbers. "))
	func _le(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		if (a is int or a is float) and (b is int or b is float): s.stack.push_back(a <= b)
		else: s._error(str("'LE' can only operate numbers. "))
	func _gt(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		if (a is int or a is float) and (b is int or b is float): s.stack.push_back(a > b)
		else: s._error(str("'GT' can only operate numbers. "))

	func _ge(s:State):
		var b = s._pop_and_get_value(); var a = s._pop_and_get_value()
		if (a is int or a is float) and (b is int or b is float): s.stack.push_back(a >= b)
		else: s._error(str("'GE' can only operate numbers. "))
	func _if(s:State):
		if not s._pop_and_get_value(): s.i = s.program.opcodes[s.i + 1] - 1
		else: s.i += 1 # 后面还会再 +1
	func _goto(s:State): s.i = s.program.opcodes[s.i+1] - 1
	func _get_arg(s:State):
		# 先弹 key 再取参：实参表可能拿 key 做准备，顺序写死免得依赖求值顺序
		var key = s._pop_and_get_value()
		s.stack.push_back(s.args.at(s, key))
	func _arg_num(s:State): s.stack.push_back(s.args.num())

	func _return(s:State):
		var n:int = s.program.opcodes[s.i + 1]
		for i in range(-n,0): s.returns.append(s._get_value_in_stack(i))
		s.i = len(s.program.opcodes)

