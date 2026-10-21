class_name StopeTestCompiler
# 编译器测试。契约见 docs/zh-cn/compiler-test-plan.md。
#
# 期望值来自 C++ 侧探针 dump 的 test/data/golden.txt（195 条）的
# CMP / OUT / CERRS 三个字段，走完整 Lexer -> Parser -> Compiler，
# 比对返回码、Program 序列化串、编译器错误列表。

const GOLDEN := 'res://test/data/golden.txt'

static func run(rep:StopeTestUtil.Report) -> void:
	var cases := StopeTestUtil.read_golden(GOLDEN)
	if cases.is_empty():
		rep.add_fail(str('  FAIL 编译器：读不到 ', GOLDEN))
		return
	for c in cases:
		var id:String = c.get('ID', '')
		var src := StopeTestUtil.unesc(c.get('SRC', ''))
		var fold:bool = c.get('FOLD', '0') == '1'
		var got := _one(src, fold)
		for k in ['CMP', 'OUT', 'CERRS']:
			rep.check(id, k, c.get(k, ''), got[k])

static func _one(src:String, fold:bool) -> Dictionary:
	# 前端：Lexer + Parser
	var lx := StopeToken.Lexer.new(src)
	lx.set_custom_insts(StopeTestUtil.custom_insts())
	var ps := StopeParser.new(lx)
	ps.const_folding = fold
	var ast := StopeAst.Prog.new()
	ps.parse_program(ast)

	# 后端：Compiler
	var cis := StopeTestUtil.custom_insts()
	var c := StopeCompiler.Compiler.new()
	var out := StopeTestUtil.new_program()
	var rc:int = c.compile(ast, out, cis)
	return {
		'CMP': 'OK' if rc == StopeCompiler.Result.Success else 'ERR',
		'OUT': StopeTestUtil.esc_(Stope.dump_program(out, c.custom_insts)),
		'CERRS': StopeTestUtil.join_esc(c.errors, StopeTestUtil.esc_),
	}
