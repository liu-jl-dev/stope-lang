class_name StopeTestVM
# 执行器测试。StopeBasicVM 是**参考实现**，不是标准（见 docs/zh-cn/vm-guide.md）。
#
# 这组没有 C++ golden 数据，原因两条：
#   1. VM 不在三项标准里，两侧错误文案格式本就不同 —— GD 是 "3 Add: msg"
#      （带指令名），C++ 是 "3: msg"，逐字节比没意义；
#   2. 要锁的是「本实现内部自洽」，不是「和 C++ 一模一样」。
# 所以断言比的是同一程序走两条驱动路径（run 一次跑完 / step 逐条）的结果必须
# 相同：返回值、错误列表、停机时的指令指针。step 是手写单步调试的入口，两条
# 路径分头实现（为了热循环不套一层函数调用），这里就是防止它们漂开的那道锁。

const SRC_LINEAR := 'let a = 1; let b = 2; let c = a + b; return c;'
const SRC_LOOP := 'let i = 0; while i < 3 { i = i + 1; } return i;'
const SRC_ERR := 'let x; let a = 1 + x; return a;' # x 未赋值 = null，Add 运行期报错

class NoArgs extends StopeBasicVM.Arguments:
	# 这组用例都不用 args/argc；真被取到就报错，立刻暴露「用例写错了」
	func at(state:StopeBasicVM.State, index_or_key) -> Variant:
		state.error('args not provided in this test. ')
		return null
	func num() -> int: return 0

# V-05 用：一条主动报错的自定义指令
class HostBoom:
	func boom(s:StopeBasicVM.State) -> void:
		s.error('boom. ')

static func run(rep:StopeTestUtil.Report) -> void:
	# 顺序执行的程序：步数恰好等于指令条数（不含操作数），顺手锁住 step 的计数
	_paths(rep, 'V-01', SRC_LINEAR, true)
	# 带回边（If / GoTo 会改 i）：只比两条路径是否一致，步数不可预知
	_paths(rep, 'V-02', SRC_LOOP, false)
	# 运行期出错：两条路径停在同一条指令上，错误文本相同
	_paths(rep, 'V-03', SRC_ERR, false)
	# 宿主取参失败也要能回报（Arguments.at 有 state 参数了）
	_get_arg_error(rep)
	# 自定义指令里报错：错误串拼指令名时不能越界
	_custom_opcode_error(rep)
	# 下面是「值语义」这一层：布尔没有独立类型、整数回绕、序列运算、真值、除零
	_value_semantics(rep)

# 宿主侧的错误通道：`Arguments.at(state, key)` 里 state.error(...) 之后 VM 必须停，
# 错误进同一个 errors，且定位到 GetArg 那条指令。以前 at 拿不到 state，宿主只能
# push_error 到 Godot 控制台，VM 当成功继续跑。
static func _get_arg_error(rep:StopeTestUtil.Report) -> void:
	var prog := _build('return args[0];')
	if prog == null:
		rep.add_fail('  FAIL V-04  编译失败')
		return
	var s := _new_state(prog)
	rep.check('V-04', 'run 返回', 'false', str(s.run()))
	rep.check('V-04', '错误条数', '1', str(s.errors.size()))
	rep.check('V-04', '错误全文',
		str(s.i, ' GetArg: args not provided in this test. '), _join(s.errors))

# 自定义指令（编号 >= 33）里报错：`_error` 拼指令名时**不能越界**。
# `Opcode.keys()` 只有 33 项，早期直接 `Opcode.keys()[opcode]` 下标取 —— 自定义指令
# 一报错就变成引擎级 `Out of bounds get index`，错误一句都没记下来，而 errors 既然
# 为空，run() 还会返回 true（假装成功）。修复后按 debug.gd 的惯例印成 `Custom<N>`。
static func _custom_opcode_error(rep:StopeTestUtil.Report) -> void:
	var first := StopeOpcode.FIRST_CUSTOM_OPCODE
	var cfg := StopeOpcode.CustomOpcodeConfig.new()
	cfg.add_custom_opcode('my:boom', first, 0)
	var prog := _build_with('my:boom();', cfg)
	if prog == null:
		rep.add_fail('  FAIL V-05  编译失败')
		return

	var host := HostBoom.new()
	var api := StopeBasicVM.Api.new()
	# 分派表是稠密 Array，下标即编号 ⇒ 长度必须 >= 编号 + 1
	api.op_map.resize(first + 1)
	api.op_map[first] = host.boom

	var s := StopeBasicVM.State.new()
	s.reset(api, prog, NoArgs.new())
	rep.check('V-05', 'run 返回', 'false', str(s.run()))
	rep.check('V-05', '错误条数', '1', str(s.errors.size()))
	rep.check('V-05', '错误全文', str('0 Custom', first, ': boom. '), _join(s.errors))

static func _paths(rep:StopeTestUtil.Report, id:String, src:String, check_steps:bool) -> void:
	var prog := _build(src)
	if prog == null:
		rep.add_fail(str('  FAIL ', id, '  编译失败：', src))
		return

	var a := _new_state(prog)
	var ok_a := a.run()

	var b := _new_state(prog)
	var steps := 0
	while b.step(): steps += 1

	# run 的返回值就是「errors 为空」，两路都得守住这条
	rep.check(id, 'run 返回值↔errors', 'true', str(ok_a == a.errors.is_empty()))
	if check_steps:
		rep.check(id, 'step 步数', str(_inst_count(prog)), str(steps))
	rep.check(id, 'returns', _fmt(a.returns), _fmt(b.returns))
	rep.check(id, '停机时 i', str(a.i), str(b.i))
	rep.check(id, 'errors 条数', str(a.errors.size()), str(b.errors.size()))
	rep.check(id, 'errors 文本', _join(a.errors), _join(b.errors))

	# 停机后再驱动一次：不执行指令、不追加错误（结束态与错误态都应如此）
	var err_before := b.errors.size()
	var i_before := b.i
	rep.check(id, '停机后 step', 'false', str(b.step()))
	rep.check(id, '停机后 i 不变', str(i_before), str(b.i))
	rep.check(id, '停机后 errors 不变', str(err_before), str(b.errors.size()))

# 指令条数（不含操作数）：顺序执行时 step 应当正好走这么多条
static func _inst_count(prog:StopeProgram.Program) -> int:
	var n := 0
	var k := 0
	var ops := prog.opcodes
	while k < ops.size():
		var op:int = ops[k]
		n += 1
		k += 1
		# > Return 的是自定义指令，本组用例不涉及
		if op <= StopeOpcode.Opcode.Return and StopeOpcode.has_a_param(op): k += 1
	return n

static func _build(src:String) -> StopeProgram.Program:
	return _build_with(src, null)

# cfg 同时交给 Parser 与 Compiler（少给一处，自定义指令就会被当成普通函数调用）
static func _build_with(src:String, cfg:StopeOpcode.CustomOpcodeConfig) -> StopeProgram.Program:
	var lx := StopeLexer.Lexer.new(src)
	var ps := StopeParser.Parser.new(lx, cfg)
	var ast := StopeAst.Prog.new()
	ps.parse_program(ast)
	if not ps.errors.is_empty(): return null
	var c := StopeCompiler.Compiler.new(cfg)
	var out := StopeProgram.Program.new()
	if c.compile(ast, out) != StopeResult.Success: return null
	return out

static func _new_state(prog:StopeProgram.Program) -> StopeBasicVM.State:
	var s := StopeBasicVM.State.new()
	s.reset(StopeBasicVM.Api.new(), prog, NoArgs.new())
	return s

static func _fmt(values:Array) -> String:
	var parts:Array[String] = []
	for v in values: parts.append(str(v))
	return '[' + ','.join(parts) + ']'

static func _join(errs:Array) -> String:
	var parts:Array[String] = []
	for e in errs: parts.append(str(e))
	return '|'.join(parts)

# ============================ 值语义（V-06 起） ============================
# 这组锁的是「GD 执行器与 C++ / Node.js 对同一份产物给出同一种答案」。
# 全部用变量而不是字面量：字面量会被常量折叠吃掉，根本走不到执行器。
static func _value_semantics(rep:StopeTestUtil.Report) -> void:
	# 布尔就是整数 1 / 0（C++ opPushTrue 压 Integer，没有 bool 值类型）
	_returns(rep, 'V-06', 'return true;', '[1]')
	_returns(rep, 'V-06b', 'return false;', '[0]')
	_returns(rep, 'V-06c', 'let t = true; let f = false; return t + f + (1 == 1);', '[2]')
	# 比较结果也是整数，不是 bool
	_returns(rep, 'V-06d', 'let a = 1; let b = 2; return a < b;', '[1]')

	# 整数幂：回绕不检查溢出；负指数走浮点
	_returns(rep, 'V-07', 'let a = 2; let b = 64; return a ^ b;', '[0]')
	_returns(rep, 'V-07b', 'let a = 2; return a ^ -1;', '[0.5]')

	# 序列重复：字符串 / 二进制数组 × 整数，两侧都能是序列
	_returns(rep, 'V-08', 'let s = "ab"; return s * 2;', '[abab]')
	_returns(rep, 'V-08b', 'let s = "ab"; return 2 * s;', '[abab]')
	_returns(rep, 'V-08c', "let b = 'd 1 2'; return b * 2;", '[[1, 2, 1, 2]]')
	_err(rep, 'V-08d', 'let s = "ab"; let n = -1; return s * n;',
		'"Mul" cannot repeat a sequence by a negative number. ')

	# 加法：字符串 + 字符串、二进制数组 + 二进制数组
	_returns(rep, 'V-08e', 'let a = "x"; let b = "y"; return a + b;', '[xy]')
	_returns(rep, 'V-08f', "let a = 'd 1'; let b = 'd 2'; return a + b;", '[[1, 2]]')

	# 真值：空串 / 空二进制数组为假（与 C++ truely 一致），不是「非 null 就真」
	_returns(rep, 'V-09', 'let s = ""; if s { return 1; } return 2;', '[2]')
	_returns(rep, 'V-09b', 'let s = "x"; if s { return 1; } return 2;', '[1]')

	# 整数除零：报错，而不是让 GDScript 的 `1 / 0` 把整个脚本打崩
	_err(rep, 'V-10', 'let a = 1; let b = 0; return a / b;', '"Div" division by zero. ')
	_err(rep, 'V-10b', 'let a = 1; let b = 0; return a idiv b;', '"IDiv" division by zero. ')
	_err(rep, 'V-10c', 'let a = 1; let b = 0; return a % b;', '"Mod" division by zero. ')
	# 浮点除零走 IEEE，不报错（`1.0 / 0` 得 inf）
	_returns(rep, 'V-10d', 'let a = 1.0; let b = 0; return a / b;', '[inf]')

	# `!` 只接受 null / 整数 / 浮点；字符串要判空请写 `if s {}`（条件走真值判定）
	_err(rep, 'V-11', 'let s = "abc"; return !s;',
		'"Not" can only operate on integer or float. ')

	# INT64_MIN：取负与 `idiv -1` 回绕，不能把脚本打崩
	_returns(rep, 'V-12', 'let m = 0 - 9223372036854775807 - 1; return -m;',
		'[-9223372036854775808]')
	_returns(rep, 'V-12b', 'let m = 0 - 9223372036854775807 - 1; return m idiv -1;',
		'[-9223372036854775808]')
	_returns(rep, 'V-12c', 'let m = 0 - 9223372036854775807 - 1; return m % -1;', '[0]')

	# idiv：两侧整数得整数，含浮点仍是「向零取整」但**保持浮点**
	_ret_type(rep, 'V-13', 'let a = 7; let b = 2; return a idiv b;', TYPE_INT)
	_ret_type(rep, 'V-13b', 'let a = 7.5; let b = 2; return a idiv b;', TYPE_FLOAT)
	_returns(rep, 'V-13c', 'let a = 7.5; let b = 2; return a idiv b;', '[3.0]')

	# 相等：类型不同一律不等，**不能让 Godot 的 == 抛引擎错误**
	# （`"1" == 1` 在 GDScript 里是 SCRIPT ERROR，而那一句 `_store` 不会执行 ——
	#   栈没动、errors 也没有，run() 照常往下跑，最后得到看似正常的错值）
	_returns(rep, 'V-15', 'let a = "1"; let b = 1; return a == b;', '[0]')
	_returns(rep, 'V-15b', 'let a = null; let b = 0; return a == b;', '[0]')
	_returns(rep, 'V-15c', "let a = 'd 1 2'; let b = 'd 1 2'; return a == b;", '[1]')
	_returns(rep, 'V-15d', "let a = 'd 1'; let b = 'd 2'; return a == b;", '[0]')
	_returns(rep, 'V-15e', 'let a = "ab"; let n = 0; return a * n;', '[]')

	# 宿主函数据返回 bool：归一成整数（Stope 没有布尔值类型）
	_host_bool(rep)

static func _host_bool(rep:StopeTestUtil.Report) -> void:
	var prog := _build('return f();')
	if prog == null:
		rep.add_fail('  FAIL V-14  编译失败')
		return
	var s := _new_state(prog)
	# 未声明就被调用 → 编译器隐式登记进 exports；槽位号由编译器分配，不能写死
	s.variables[prog.exports['f']] = func(_argv): return true
	var ok := s.run()
	rep.check('V-14', 'run 返回', 'true', str(ok))
	rep.check('V-14', 'returns[0] 类型', str(TYPE_INT), str(typeof(s.returns[0])))
	rep.check('V-14', 'returns', '[1]', _fmt(s.returns))

# 跑一段源码，断言返回值（顺带要求没有任何错误）
static func _returns(rep:StopeTestUtil.Report, id:String, src:String, want:String) -> void:
	var s = _state_of(rep, id, src)
	if s == null: return
	rep.check(id, 'returns', want, _fmt(s.returns))
	rep.check(id, 'errors', '', _join(s.errors))

# 跑一段源码，断言**报错**（错误串的「下标 + 指令名」前缀由实现定，只比消息部分）
static func _err(rep:StopeTestUtil.Report, id:String, src:String, want_msg:String) -> void:
	var s = _state_of(rep, id, src)
	if s == null: return
	rep.check(id, '错误条数', '1', str(s.errors.size()))
	rep.check(id, '错误消息', want_msg, _msg_only(s.errors))

static func _ret_type(rep:StopeTestUtil.Report, id:String, src:String, want:int) -> void:
	var s = _state_of(rep, id, src)
	if s == null: return
	rep.check(id, 'errors', '', _join(s.errors))
	rep.check(id, 'returns[0] 类型', str(want), str(typeof(s.returns[0])) if s.returns.size() > 0 else 'none')

static func _state_of(rep:StopeTestUtil.Report, id:String, src:String) -> StopeBasicVM.State:
	var prog := _build(src)
	if prog == null:
		rep.add_fail(str('  FAIL ', id, '  编译失败：', src))
		return null
	var s := _new_state(prog)
	s.run()
	return s

# `"3 Add: msg"` → `msg`：前缀（下标 + 指令名）由实现决定，跨实现只比消息
static func _msg_only(errs:Array) -> String:
	var parts:Array[String] = []
	for e in errs:
		var t := str(e)
		parts.append(t.substr(t.find(': ') + 2))
	return '|'.join(parts)
