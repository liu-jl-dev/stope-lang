class_name StopeTestParser
# 语法分析测试。契约见 docs/zh-cn/parser-test-plan.md。
#
# 两组期望值，都是 C++ 侧探针 dump 出来的：
#   1. test/data/golden.txt（195 条）的 SHAPE / LINES / PERR / LEXERR / PERRS / LEXERRS
#      —— 走完整 Lexer + Parser，比对 AST 形状、语句行号、两侧错误列表。
#   2. test/data/golden_binarr.txt（86 条）
#      —— BA 组直接打二进制数组解析器，FB / FU 组直接打常量折叠矩阵。

const GOLDEN := 'res://test/data/golden.txt'
const GOLDEN_BINARR := 'res://test/data/golden_binarr.txt'

static func run(rep:StopeTestUtil.Report) -> void:
	_run_source_cases(rep)
	_run_binarr_cases(rep)
	_run_depth_cases(rep)

# ---------------- 1. 源码 -> AST ----------------
static func _run_source_cases(rep:StopeTestUtil.Report) -> void:
	var cases := StopeTestUtil.read_golden(GOLDEN)
	if cases.is_empty():
		rep.add_fail(str('  FAIL 语法：读不到 ', GOLDEN))
		return
	for c in cases:
		var id:String = c.get('ID', '')
		var src := StopeTestUtil.unesc(c.get('SRC', ''))
		var fold:bool = c.get('FOLD', '0') == '1'
		var got := _one(src, fold)
		for k in ['SHAPE', 'LINES', 'PERR', 'LEXERR', 'PERRS', 'LEXERRS']:
			rep.check(id, k, c.get(k, ''), got[k])

static func _one(src:String, fold:bool) -> Dictionary:
	var lx := StopeLexer.Lexer.new(src)
	var cfg := StopeTestUtil.custom_config()
	var ps := StopeParser.Parser.new(lx, cfg)
	ps.const_folding = fold
	var prog := StopeAst.Prog.new()
	ps.parse_program(prog)
	var line_parts:Array[String] = []
	for st in prog.stmts: line_parts.append(str(st.line))
	return {
		'SHAPE': StopeTestUtil.esc_(StopeAst.shape_prog(prog)),
		'LINES': ",".join(line_parts),
		'PERR': str(ps.errors.size()),
		'LEXERR': str(lx.errors.size()),
		'PERRS': StopeTestUtil.join_esc(ps.errors, StopeTestUtil.esc_),
		'LEXERRS': StopeTestUtil.join_esc(lx.errors, StopeTestUtil.esc_),
	}

# ---------------- 2. 二进制数组 / 常量折叠 ----------------
# 记录格式：
#   BA\t输入\tok|err\t[字节]
#   FB\t运算符\t是否折叠\t结果       （二元折叠）
#   FU\t运算符\t是否折叠\t结果       （一元折叠）
static func _run_binarr_cases(rep:StopeTestUtil.Report) -> void:
	var golden := StopeTestUtil.read_lines(GOLDEN_BINARR)
	if golden.is_empty():
		rep.add_fail(str('  FAIL 语法：读不到 ', GOLDEN_BINARR))
		return
	var got := _dump_binarr()
	if len(got) != len(golden):
		rep.add_fail(str('  FAIL 语法：golden_binarr 期望 ', len(golden),
			' 行，实际产出 ', len(got), ' 行'))
		return
	for i in range(len(golden)):
		rep.check_line('BA/FB/FU #' + str(i + 1), golden[i], got[i])

static func _dump_binarr() -> Array[String]:
	var out:Array[String] = []
	# ---- BA：二进制数组解析 ----
	for t in ['', ' ', 'a', 'ab', 'b 0100 0001', 'b 01000001', 'B 1', 'o 101', 'O 7',
			'd 65', 'd 300', 'D 255 0', 'x 41', 'x ff FF', 'X 0f', '41', '4_1', '_41',
			'01 02', '  01   02  ', 'x zz', 'z', 'b', 'd', 'b 2', 'o 8', '0 1',
			'9999999999999999999999', 'd 2147483647', 'd 2147483648', 'ff']:
		var ba := PackedByteArray()
		var ok := StopeBinArrParser.new().parse(t, ba)
		out.append(str('BA\t', t, '\t', 'ok' if ok else 'err', '\t[',
				StopeAst.fmt_bytes(ba), ']'))

	# ---- FB：二元折叠 ----
	var T := StopeLexer.Token.Type
	out.append(_fb('+', T.Add, _int(1), _int(2)))
	out.append(_fb('-', T.Sub, _int(5), _int(3)))
	out.append(_fb('*', T.Mul, _int(2), _int(3)))
	out.append(_fb('/', T.Div, _int(7), _int(2)))
	out.append(_fb('/', T.Div, _int(6), _int(3)))
	out.append(_fb('/', T.Div, _int(1), _int(0)))
	out.append(_fb('idiv', T.IDiv, _int(7), _int(2)))
	out.append(_fb('%', T.Mod, _int(7), _int(2)))
	out.append(_fb('^', T.Pow, _int(2), _int(10)))
	out.append(_fb('^', T.Pow, _int(2), _int(-1)))
	out.append(_fb('+', T.Add, _float(1.5), _int(1)))
	out.append(_fb('+', T.Add, _int(9223372036854775807), _int(1)))
	out.append(_fb('*', T.Mul, _int(9223372036854775807), _int(2)))
	out.append(_fb('+', T.Add, _bool(true), _bool(true)))
	out.append(_fb('+', T.Add, _str('ab'), _str('cd')))
	out.append(_fb('*', T.Mul, _str('ab'), _int(3)))
	out.append(_fb('*', T.Mul, _int(3), _str('ab')))
	out.append(_fb('*', T.Mul, _str(''), _int(1000000)))
	out.append(_fb('*', T.Mul, _str('ab'), _int(-1)))
	out.append(_fb('*', T.Mul, _float(1.5), _str('ab')))
	out.append(_fb('+', T.Add, _bin([1]), _bin([2])))
	out.append(_fb('*', T.Mul, _bin([1]), _int(3)))
	out.append(_fb('+', T.Add, _null(), _int(5)))
	out.append(_fb('+', T.Add, _int(5), _null()))
	out.append(_fb('+', T.Add, _null(), _null()))
	out.append(_fb('-', T.Sub, _null(), _int(5)))
	out.append(_fb('-', T.Sub, _int(5), _null()))
	out.append(_fb('-', T.Sub, _null(), _null()))
	out.append(_fb('*', T.Mul, _null(), _int(5)))
	out.append(_fb('^', T.Pow, _null(), _int(5)))
	out.append(_fb('==', T.EQ, _null(), _null()))
	out.append(_fb('==', T.EQ, _null(), _int(1)))
	out.append(_fb('!=', T.NE, _null(), _int(1)))
	out.append(_fb('<', T.LT, _null(), _int(1)))
	out.append(_fb('==', T.EQ, _bool(true), _bool(true)))
	out.append(_fb('==', T.EQ, _bool(true), _int(1)))
	out.append(_fb('==', T.EQ, _int(1), _float(1.0)))
	out.append(_fb('==', T.EQ, _str('a'), _str('a')))
	out.append(_fb('<', T.LT, _int(1), _int(2)))
	out.append(_fb('<', T.LT, _bool(true), _int(2)))
	out.append(_fb('<=', T.LE, _float(1.5), _float(1.5)))
	out.append(_fb('>', T.GT, _int(2), _int(1)))
	out.append(_fb('>=', T.GE, _int(2), _int(2)))
	out.append(_fb('and', T.And, _int(1), _int(0)))
	out.append(_fb('or', T.Or, _int(0), _str('a')))

	# ---- FU：一元折叠 ----
	out.append(_fu('-', T.Sub, _bool(true)))
	out.append(_fu('-', T.Sub, _bool(false)))
	out.append(_fu('-', T.Sub, _int(5)))
	out.append(_fu('-', T.Sub, _float(1.5)))
	out.append(_fu('-', T.Sub, _int(-9223372036854775807 - 1)))
	out.append(_fu('!', T.Not, _null()))
	out.append(_fu('!', T.Not, _int(0)))
	out.append(_fu('!', T.Not, _float(0.0)))
	out.append(_fu('!', T.Not, _int(5)))
	out.append(_fu('!', T.Not, _str('')))
	return out

# ---------------- 构造 & 序列化 ----------------
static func _int(v:int) -> StopeAst.Expr: return StopeAst.IntExpr.new(1, v)
static func _float(v:float) -> StopeAst.Expr: return StopeAst.FloatExpr.new(1, v)
static func _bool(v:bool) -> StopeAst.Expr: return StopeAst.BoolExpr.new(1, v)
static func _null() -> StopeAst.Expr: return StopeAst.NullExpr.new(1)
static func _str(v:String) -> StopeAst.Expr: return StopeAst.StringExpr.new(1, v)
static func _bin(arr:Array) -> StopeAst.Expr:
	return StopeAst.BinArrExpr.new(1, PackedByteArray(arr))

static func _fb(name:String, op:int, l:StopeAst.Expr, r:StopeAst.Expr) -> String:
	var e := StopeAst.BinaryOpExpr.new()
	e.op = op; e.left_expr = l; e.right_expr = r
	var o := StopeExprOptim.optimize(e) as StopeAst.Expr
	var folded:int = 0 if o.node_type == StopeAst.NodeType.BinaryOpExpr else 1
	return str('FB\t', name, '\t', folded, '\t', _val(o))

static func _fu(name:String, op:int, v:StopeAst.Expr) -> String:
	var e := StopeAst.UnaryOpExpr.new()
	e.op = op; e.expr = v
	var o := StopeExprOptim.optimize(e) as StopeAst.Expr
	var folded:int = 0 if o.node_type == StopeAst.NodeType.UnaryOpExpr else 1
	return str('FU\t', name, '\t', folded, '\t', _val(o))

# 折叠结果的紧凑写法：与 cpp/tools/golden_binarr.cpp 的 fmtValue 一致
static func _val(e) -> String:
	if e == null: return "null"
	match e.node_type:
		StopeAst.NodeType.NullExpr: return "Null"
		StopeAst.NodeType.BoolExpr: return "true" if e.value else "false"
		StopeAst.NodeType.IntExpr: return str(e.value)
		StopeAst.NodeType.FloatExpr: return StopeAst.fmt_g(e.value)
		StopeAst.NodeType.BinArrExpr: return str('[', StopeAst.fmt_bytes(e.value), ']')
		StopeAst.NodeType.StringExpr: return str('"', e.value, '"')
	return "?"

# ---------------- 3. 嵌套深度上限（PD-DEPTH）----------------
# 期望值不 dump：限额与错误文案是**两侧约定**（C++ Parser::maxDepth 与 GD
# max_depth 同为 256，文案逐字相同），所以这里按约定写死；C++ 侧由
# cpp/test/test_parser_depth.cpp 断言同一组深度。任一侧改了计数口径或文案，
# 两边都会红。
static func _run_depth_cases(rep:StopeTestUtil.Report) -> void:
	_depth_case(rep, 'PD-DEPTH-1', 'paren', 200, false)  # 限额内：照常解析
	_depth_case(rep, 'PD-DEPTH-2', 'paren', 300, true)
	_depth_case(rep, 'PD-DEPTH-3', 'block', 300, true)
	_depth_case(rep, 'PD-DEPTH-4', 'unary', 300, true)   # 没有括号的递归
	_depth_case(rep, 'PD-DEPTH-5', 'at', 300, true)
	_depth_case(rep, 'PD-DEPTH-6', 'paren', 12000, true)  # 曾真的栈溢出

static func _depth_case(rep:StopeTestUtil.Report, id:String, kind:String, n:int,
		deep:bool) -> void:
	var src := ''
	match kind:
		'paren': src = '('.repeat(n) + 'a' + ')'.repeat(n) + ';'
		'block': src = '{'.repeat(n) + 'a;' + '}'.repeat(n)
		'unary': src = '-'.repeat(n) + 'a;'
		'at': src = 'a['.repeat(n) + '0' + ']'.repeat(n) + ';'
	var lx := StopeLexer.Lexer.new(src)
	var ps := StopeParser.Parser.new(lx)
	var prog := StopeAst.Prog.new()
	ps.parse_program(prog)
	rep.check(id, '错误条数', '1' if deep else '0', str(ps.errors.size()))
	if deep:
		rep.check(id, '错误文案', 'line 1: nesting too deep (max 256). ',
			ps.errors[0] if ps.errors.size() > 0 else '（无错误）')
