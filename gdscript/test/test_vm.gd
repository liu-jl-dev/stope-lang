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

static func run(rep:StopeTestUtil.Report) -> void:
	# 顺序执行的程序：步数恰好等于指令条数（不含操作数），顺手锁住 step 的计数
	_paths(rep, 'V-01', SRC_LINEAR, true)
	# 带回边（If / GoTo 会改 i）：只比两条路径是否一致，步数不可预知
	_paths(rep, 'V-02', SRC_LOOP, false)
	# 运行期出错：两条路径停在同一条指令上，错误文本相同
	_paths(rep, 'V-03', SRC_ERR, false)
	# 宿主取参失败也要能回报（Arguments.at 有 state 参数了）
	_get_arg_error(rep)

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
	var lx := StopeLexer.Lexer.new(src)
	var ps := StopeParser.Parser.new(lx)
	var ast := StopeAst.Prog.new()
	ps.parse_program(ast)
	if not ps.errors.is_empty(): return null
	var c := StopeCompiler.Compiler.new()
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
