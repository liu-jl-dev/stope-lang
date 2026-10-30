class_name StopeBasicVM

const Opcode = StopeOpcode.Opcode

# 变量槽位的**左值**标记。只有 PushId 会造它，也只有 Assign 会读它。
#
# 编译器契约（见 compiler.gd 开头）：PushId 只出现在两处 —— 「有赋值的 let」左侧、
# 「Assign 左端是裸标识符」；其余读变量一律 PushValue（压**值**）。
# 所以执行器**不做任何防御性解引用**：运算指令从栈上拿到的必定是值，拿到 Identifier
# 就说明编译器产物错了，该让它当场暴露，而不是悄悄替换成变量内容。
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

	# 真值判定，逐行照 C++ 的 API::truely：
	#   null / 整数 0 / 浮点 0.0 / 空字符串 / 空二进制数组 → 假；其余 → 真。
	# 别偷懒写 `if v:` —— Godot 的隐式真值恰好与这里一致，但那是巧合（比如空
	# `Callable` 也假），把规则写出来才不会被引擎版本或类型扩展带跑。
	func _truely(v) -> bool:
		if typeof(v) == TYPE_NIL: return false
		if v is bool: return v
		if v is int: return v != 0
		if v is float: return v != 0.0
		if v is String: return not v.is_empty()
		if v is PackedByteArray: return not v.is_empty()
		return true	# Callable（宿主函数）等

	func _error(msg:String, print_inst_name:bool=true):
		var inst := '' if not print_inst_name else str(' ', _inst_name(program.opcodes[i]))
		errors.append(str(i, inst, ': ', msg))

	# 错误串里的指令名。内置指令取枚举名；>= 33 的自定义编号在枚举里没有位置，
	# 按 debug.gd 的惯例印成 `Custom<N>`（那里没传 config 时也是这么印的）。
	# ⚠ 这里**必须**兜住越界：早期直接写 `Opcode.keys()[raw]`，自定义指令一报错
	# 就变成 `Out of bounds get index` —— 错误没记下来，run() 还会返回 true。
	func _inst_name(raw:int) -> String:
		var keys := Opcode.keys()
		if raw >= 0 and raw < keys.size(): return keys[raw]
		return str('Custom', raw) if raw > Opcode.Return else str('Op#', raw)


class Api:
	# 下标 = 指令编号，稠密数组。默认 33 项，只有内置指令；要跑自定义编号必须
	# 自己 `op_map.resize(N+1)` 并把 0…N 每格都填成有效 Callable。
	var op_map:Array[Callable] = [
		self._assign, self._push_null, self._push_false, self._push_true, self._push_int,
		self._push_float, self._push_string, self._push_bin_arr, self._push_value, self._push_id,
		self._call, self._at, self._pop, self._minus, self._not,
		self._pow, self._mul, self._div, self._idiv, self._mod,
		self._add, self._sub, self._eq, self._ne, self._lt,
		self._le, self._gt, self._ge, self._if, self._goto,
		self._get_arg, self._arg_num, self._return,
	]

	# ---------------- 小工具（全部对应 C++ API 里的私有 static） ----------------

	static func _is_num(v) -> bool: return v is int or v is float
	static func _is_seq(v) -> bool: return v is String or v is PackedByteArray
	static func _num(v) -> float: return float(v)

	# 算术公共前置检查（C++ checkArith）：null 不参与算术，两侧都必须是数字。
	func _check_arith(s:State, op:String, a, b) -> bool:
		if typeof(a) == TYPE_NIL or typeof(b) == TYPE_NIL:
			s._error(str('"', op, '" cannot operate on null. ')); return false
		if not _is_num(a) or not _is_num(b):
			s._error(str('"', op, '" can only operate on integer or float. ')); return false
		return true

	# 整数除以 0 要报错（C++ checkIntZero）：只有**两侧都是整数**才走整数路径，
	# 任一侧是浮点就走 IEEE（`1.0 / 0` 得 inf，不报错）。GDScript 的 `1 / 0`
	# 是引擎级报错并中止整个脚本，不是「返回 inf」，所以必须提前拦。
	func _check_int_zero(s:State, op:String, a, b) -> bool:
		if a is int and b is int and b == 0:
			s._error(str('"', op, '" division by zero. ')); return false
		return true

	# 整数除法 / 取模：都向零取整、余数符号跟被除数（GDScript 的 `/` `%` 正是如此）。
	# `INT64_MIN / -1` 与 `% -1` 在 GDScript 里会**静默中止整个脚本**（连报错都没有），
	# 所以这两个角落单独兜住 —— C++ 那边用无符号运算躲，理由相同。
	static func _int_div(a:int, b:int) -> int:
		if b == -1: return ~a + 1	# 溢出回绕成 INT64_MIN 本身
		return a / b

	static func _int_mod(a:int, b:int) -> int:
		if b == -1: return 0
		return a % b

	# 整数快速幂，exp >= 0，溢出回绕不检查 —— 与 C++ intPow 一致。
	# ⚠ 不能用 GDScript 的 `a ** b`：它在 int 底数下会先算 double 再转回 int，
	# `2 ^ 64` 得到 INT64_MIN（double 溢出转 int），而按 64 位回绕应当是 0。
	static func _int_pow(base:int, exp:int) -> int:
		var result := 1
		var b := base
		var e := exp
		while e > 0:
			if e & 1: result = result * b
			e >>= 1
			if e > 0: b = b * b
		return result

	# 二元运算收尾（C++ storeBinary）：弹出右操作数，结果写回左操作数的位置。
	static func _store(s:State, result) -> void:
		s.stack.pop_back()
		s.stack[s.stack.size() - 1] = result

	# ---------------- 变量与常量 ----------------

	func _assign(s:State):
		if s.stack.size() < 2: s._error('stack underflow. '); return
		var id = s.stack[-2]
		if not (id is Identifier):
			# 唯一合法的左值形态就是裸标识符（`a = 1`）。`a[0] = 1` 这类还没有语法。
			s._error('no implement for value type. '); return
		s.variables[id.index] = s.stack[-1]
		s.stack.resize(s.stack.size() - 2)

	func _push_null(s:State): s.stack.push_back(null)

	# 布尔**没有**独立的值类型：`true` / `false` 就是整数 1 / 0（照 C++ opPushTrue）。
	# 所以 `return true;` 得到的是 1，`1 == true` 成立，`true + 1` 是 2。
	func _push_false(s:State): s.stack.push_back(0)
	func _push_true(s:State): s.stack.push_back(1)

	func _push_int(s:State):
		s.i += 1; var idx:int = s.program.opcodes[s.i]
		s.stack.append(s.program.int_consts[idx])
	func _push_float(s:State):
		s.i += 1; var idx:int = s.program.opcodes[s.i]
		s.stack.append(s.program.float_consts[idx])
	func _push_string(s:State):
		s.i += 1; var idx:int = s.program.opcodes[s.i]
		s.stack.append(s.program.string_consts[idx])
	func _push_bin_arr(s:State):
		s.i += 1; var idx:int = s.program.opcodes[s.i]
		s.stack.append(s.program.bin_arr_consts[idx])

	# 压变量的【值】。读变量只有这一条路 —— 拿到的一定是值，不需要再解引用。
	func _push_value(s:State):
		s.i += 1; var idx:int = s.program.opcodes[s.i]
		s.stack.append(s.variables[idx])

	# 压槽位引用（左值）。只有 Assign 认它。
	func _push_id(s:State):
		s.i += 1; var idx:int = s.program.opcodes[s.i]
		s.stack.append(Identifier.new(idx))

	# ---------------- 调用与索引 ----------------

	func _call(s:State):
		s.i += 1; var argc:int = s.program.opcodes[s.i]
		var callee = s.stack[-argc-1]	# 宿主函数就是栈上的一个值
		if not (callee is Callable):
			s._error('"Call" can only call a function. '); return
		var argv:Array = []
		for k in range(argc): argv.append(s.stack[-argc+k])
		var result = callee.call(argv)	# 参数整包传入，由宿主自己拆（对齐 C++ 的 args span）
		s.stack.resize(s.stack.size() - argc - 1)
		# 宿主可能返回 bool；Stope 没有布尔值类型，统一归一成整数（与 PushTrue 一致）
		if result is bool: result = 1 if result else 0
		s.stack.push_back(result)

	func _at(s:State):
		s.i += 1; var key_num:int = s.program.opcodes[s.i]
		if key_num != 1: s._error('no implement for key num != 1. '); return
		var container = s.stack[-2]
		var key = s.stack[-1]
		if not (key is int): s._error('index must be integer. '); return
		var result
		if container is PackedByteArray:	# '...' 二进制串
			if key < 0 or key >= container.size(): s._error('index out of range. '); return
			result = container[key]
		elif container is String:
			if key < 0 or key >= container.length(): s._error('index out of range. '); return
			result = container.unicode_at(key)	# 与 C++ 一致：取的是码元，不是单字符子串
		else: s._error('no implement for container type. '); return
		s.stack.resize(s.stack.size() - key_num - 1)
		s.stack.push_back(result)

	func _pop(s:State): s.stack.pop_back()

	# ---------------- 一元 ----------------

	func _minus(s:State):
		var v = s.stack[-1]
		if v is int:
			s.stack[-1] = ~v + 1	# 等价于 -v，但 `-INT64_MIN` 不会把脚本打崩
		elif v is float:
			s.stack[-1] = -v
		else: s._error('"Minus" can only operate on integer or float. ')

	# `!x` 只接受 null / 整数 / 浮点（与 C++ opNot 一致）；字符串与二进制数组
	# 在这里报错 —— 想在 `if` 里判空请直接写 `if s {}`（条件走 _truely，支持空串）。
	func _not(s:State):
		var v = s.stack[-1]
		if typeof(v) == TYPE_NIL: s.stack[-1] = 1
		elif v is bool: s.stack[-1] = 0 if v else 1
		elif v is int: s.stack[-1] = 1 if v == 0 else 0
		elif v is float: s.stack[-1] = 1 if v == 0.0 else 0
		else: s._error('"Not" can only operate on integer or float. ')

	# ---------------- 二元算术 ----------------

	func _pow(s:State):
		var b = s.stack[-1]; var a = s.stack[-2]
		if not _check_arith(s, 'Pow', a, b): return
		# 两个整数且指数 >= 0 → 整数结果（回绕）；负指数 `2 ^ -1` → Float(0.5)。
		# 与常量折叠的 Pow 分支一致。
		if a is int and b is int and b >= 0: _store(s, _int_pow(a, b))
		else: _store(s, pow(_num(a), _num(b)))

	func _mul(s:State):
		var b = s.stack[-1]; var a = s.stack[-2]
		if typeof(a) == TYPE_NIL or typeof(b) == TYPE_NIL:
			s._error('"Mul" cannot operate on null. '); return
		if _is_num(a) and _is_num(b):
			# 整数乘法溢出就回绕（GDScript 的 `*` 正是如此），不检查
			_store(s, a * b if (a is int and b is int) else _num(a) * _num(b))
		elif (_is_seq(a) and b is int) or (a is int and _is_seq(b)):
			# 序列重复：`2 * "ab"` 与 `"ab" * 2` 都要成立 —— 取序列那一侧
			var seq = a if _is_seq(a) else b
			var times:int = b if _is_seq(a) else a
			if times < 0:
				s._error('"Mul" cannot repeat a sequence by a negative number. '); return
			if times == 0:
				_store(s, '' if seq is String else PackedByteArray())
			elif seq is String:
				_store(s, seq.repeat(times))
			else:
				var out := PackedByteArray()
				for _k in range(times): out.append_array(seq)
				_store(s, out)
		else:
			s._error('"Mul" can only operate on numbers, or repeat a string / bin array by an integer. ')

	func _div(s:State):
		var b = s.stack[-1]; var a = s.stack[-2]
		if not _check_arith(s, 'Div', a, b) or not _check_int_zero(s, 'Div', a, b): return
		if a is int and b is int:
			# 除不尽 → 浮点数（`7 / 2` 是 3.5）；整除要用 idiv。与常量折叠规则一致。
			if _int_mod(a, b) == 0: _store(s, _int_div(a, b))
			else: _store(s, float(a) / float(b))
		else:
			_store(s, _num(a) / _num(b))

	func _idiv(s:State):
		var b = s.stack[-1]; var a = s.stack[-2]
		if not _check_arith(s, 'IDiv', a, b) or not _check_int_zero(s, 'IDiv', a, b): return
		if a is int and b is int:
			_store(s, _int_div(a, b))	# 向零取整
		else:
			# 含浮点：仍按数值整除（向零取整），但**结果保持浮点**，不收窄成 int
			_store(s, float(int(_num(a) / _num(b))))

	func _mod(s:State):
		var b = s.stack[-1]; var a = s.stack[-2]
		if not _check_arith(s, 'Mod', a, b) or not _check_int_zero(s, 'Mod', a, b): return
		if a is int and b is int: _store(s, _int_mod(a, b))	# 余数符号跟被除数
		else: _store(s, fmod(_num(a), _num(b)))

	func _add(s:State):
		var b = s.stack[-1]; var a = s.stack[-2]
		# null 不是加法单位元，也不与任何值做算术 —— 一律报错
		if typeof(a) == TYPE_NIL or typeof(b) == TYPE_NIL:
			s._error('"Add" cannot operate on null. '); return
		if a is int:
			if b is int: _store(s, a + b)	# 回绕，不检查溢出
			elif b is float: _store(s, float(a) + b)
			else: s._error('integer can only add integer or float. ')
		elif a is float:
			if _is_num(b): _store(s, a + _num(b))
			else: s._error('float can only add integer or float. ')
		elif a is String and b is String: _store(s, a + b)
		elif a is PackedByteArray and b is PackedByteArray: _store(s, a + b)
		else: s._error('"Add" can only operate on numbers, strings or bin arrays. ')

	func _sub(s:State):
		var b = s.stack[-1]; var a = s.stack[-2]
		if not _check_arith(s, 'Sub', a, b): return
		if a is int:
			if b is int: _store(s, a - b)	# 回绕，不检查溢出
			elif b is float: _store(s, float(a) - b)
			else: s._error('integer can only subtract integer or float. ')
		elif a is float:
			if _is_num(b): _store(s, a - _num(b))
			else: s._error('float can only subtract integer or float. ')
		else: s._error('"Sub" can only operate on integer or float. ')

	# ---------------- 比较（结果一律是整数 1 / 0） ----------------

	# 相等判定，照 C++ 的 equals：**同类型按类型比，整数与浮点互通，其余一律不等**。
	# ⚠ 不能直接写 `a == b`：Godot 在类型不匹配时会抛引擎错误（比如 String vs int
	# 的 `"1" == 1`），而且那一句 `_store` 根本不会执行 —— 栈没动、errors 也没记，
	# run() 照样往下跑，最后得到一个**看起来正常其实错**的返回值。
	static func _equals(a, b) -> bool:
		if typeof(a) == TYPE_NIL or typeof(b) == TYPE_NIL:
			return typeof(a) == TYPE_NIL and typeof(b) == TYPE_NIL
		if a is int and b is int: return a == b
		if a is int and b is float: return float(a) == b
		if a is float and b is int: return a == float(b)
		if a is float and b is float: return a == b
		if a is String and b is String: return a == b
		if a is PackedByteArray and b is PackedByteArray: return a == b	# 按内容
		if a is Callable and b is Callable: return a == b
		return false

	func _eq(s:State): _store(s, 1 if _equals(s.stack[-2], s.stack[-1]) else 0)
	func _ne(s:State): _store(s, 1 if not _equals(s.stack[-2], s.stack[-1]) else 0)

	func _lt(s:State):
		var b = s.stack[-1]; var a = s.stack[-2]
		if _is_num(a) and _is_num(b): _store(s, 1 if a < b else 0)
		else: s._error('only on integer or float can be compared. ')
	func _le(s:State):
		var b = s.stack[-1]; var a = s.stack[-2]
		if _is_num(a) and _is_num(b): _store(s, 1 if a <= b else 0)
		else: s._error('only on integer or float can be compared. ')
	func _gt(s:State):
		var b = s.stack[-1]; var a = s.stack[-2]
		if _is_num(a) and _is_num(b): _store(s, 1 if a > b else 0)
		else: s._error('only on integer or float can be compared. ')
	func _ge(s:State):
		var b = s.stack[-1]; var a = s.stack[-2]
		if _is_num(a) and _is_num(b): _store(s, 1 if a >= b else 0)
		else: s._error('only on integer or float can be compared. ')

	# ---------------- 控制流 ----------------

	func _if(s:State):
		var yes := s._truely(s.stack.pop_back())	# 条件用完即弹，不再留在栈上
		s.i += 1	# 跳过操作数；条件成立时 run 的 i += 1 正好落到下一句
		if not yes: s.i = s.program.opcodes[s.i] - 1
	func _goto(s:State): s.i = s.program.opcodes[s.i+1] - 1

	# ---------------- 宿主接口 ----------------

	func _get_arg(s:State):
		if s.args == null: s._error('no args. '); return
		# 先弹 key 再取参：实参表可能拿 key 做准备，顺序写死免得依赖求值顺序
		var key = s.stack.pop_back()
		var v = s.args.at(s, key)
		if v is bool: v = 1 if v else 0	# 实参表也可能返回 bool，同样归一成整数
		s.stack.push_back(v)
	func _arg_num(s:State):
		if s.args == null: s._error('no args. '); return
		s.stack.push_back(s.args.num())

	func _return(s:State):
		var n:int = s.program.opcodes[s.i + 1]
		var top := s.stack.size()
		for k in range(top - n, top): s.returns.append(s.stack[k])
		s.i = s.program.opcodes.size()
