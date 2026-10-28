class_name StopeAst

# AST 节点定义 —— 与 cpp/stope/ast.hpp 逐项对齐（2026-10-18 重写）。
#
# 命名约定：C++ 的 camelCase 字段名在 GD 侧改成 snake_case，一一对应，便于逐行对照：
#     leftExpr -> left_expr      rightExpr -> right_expr      keyExpr  -> key_expr
#     keyExprs -> key_exprs      firstProg -> first_prog      elseProg -> else_prog
#     cond     -> cond           prog      -> prog            callee   -> callee
#     opcodeName -> opcode_name  hasAssign -> has_assign
#
# 三个静态函数 shape_expr / shape_stmt / shape_prog 是【测试用】序列化，
# 严格照抄 cpp/test/test_common.hpp 的同名函数。跨实现比较格式见
# docs/zh-cn/parser-test-plan.md §2；两组 x 交叉比对的全部用例应由 gdscript/test 驱动。
#
# 浮点有一条坑：C++ 用 printf("%g")，GDScript 的 % 运算符不支持 %g，
# 也没有科学计数法格式化。fmt_g() 手工复刻了 %g（精度 6）的全部决策，
# 包含「舍入进位后指数 +1」的情形，详见函数上方注释。

const TokenType = StopeLexer.Token.Type

# 与 AST::NodeType 同序同值，共 28 项
enum NodeType {
	Node, Prog, Stmt, Expr,
	ExprStmt, LetStmt, ReturnStmt, ExportStmt, BlockStmt, IfStmt, WhileStmt, AssignStmt,
	BreakStmt, ContinueStmt,
	NullExpr, BoolExpr, IntExpr, FloatExpr, BinArrExpr, StringExpr, IdentExpr,
	ArgcExpr, ArgsExpr, UnaryOpExpr, BinaryOpExpr, CallExpr, AtExpr, CustomOpcodeExpr
}

# 9 级优先级；与 cpp/stope/common.hpp 的 OpPrecedence 一致
enum Precedence {
	Lowest,
	Or,			#  or  ||
	And,		#  and  &&
	Equals,		#  ==  !=
	LessGreater,#  <  <=  >  >=
	AddSub,		#  +  -
	MulDiv,		#  *  /  idiv  %
	Pow,		#  ^
	Prefix,		#  -  not  !
	Paren		#  ()（含调用）  []
}

const binop_prec_map:Dictionary = {
	TokenType.Or: Precedence.Or,
	TokenType.And: Precedence.And,
	TokenType.EQ: Precedence.Equals,
	TokenType.NE: Precedence.Equals,
	TokenType.LT: Precedence.LessGreater,
	TokenType.LE: Precedence.LessGreater,
	TokenType.GT: Precedence.LessGreater,
	TokenType.GE: Precedence.LessGreater,
	TokenType.Add: Precedence.AddSub,
	TokenType.Sub: Precedence.AddSub,
	TokenType.Mul: Precedence.MulDiv,
	TokenType.Div: Precedence.MulDiv,
	TokenType.IDiv: Precedence.MulDiv,
	TokenType.Mod: Precedence.MulDiv,
	TokenType.Pow: Precedence.Pow,
	# 调用 ()、取元素 [] 也是二元形式，优先级最高
	TokenType.LParen: Precedence.Paren,
	TokenType.LBrack: Precedence.Paren,
}

# 运算符的显示文本（错误信息 / 调试用；节点里的 op 存的是 TokenType，不是这个字符串）
const binop_literal_map:Dictionary = {
	TokenType.Or: '||',
	TokenType.And: '&&',
	TokenType.EQ: '==',
	TokenType.NE: '!=',
	TokenType.LT: '<',
	TokenType.LE: '<=',
	TokenType.GT: '>',
	TokenType.GE: '>=',
	TokenType.Add: '+',
	TokenType.Sub: '-',
	TokenType.Mul: '*',
	TokenType.Div: '/',
	TokenType.IDiv: 'idiv',
	TokenType.Mod: '%',
	TokenType.Pow: '^',
}

# ================================ 格式化小工具 ================================
# 与 test_common.hpp 的 escUtf8 对齐：只转义 \\ " \n \r \t，非 ASCII 打成 '?'
static func esc(s:String) -> String:
	var o := ''
	for i in range(s.length()):
		var ch := s[i]
		if ch == '\\': o += '\\\\'
		elif ch == '"': o += '\\"'
		elif ch == '\n': o += '\\n'
		elif ch == '\r': o += '\\r'
		elif ch == '\t': o += '\\t'
		elif ord(ch) < 128: o += ch
		else: o += '?'
	return o

# BinArr 的字节二分十六进制，小写两位，逗号分隔：BinArr[04,01]
static func fmt_bytes(ba:PackedByteArray) -> String:
	var parts:Array[String] = []
	for b in ba: parts.append("%02x" % b)
	return ",".join(parts)

# 复刻 C 的 printf("%g")（默认精度 6）。GDScript 的 % 运算符不支持 %g，
# String.num() 也没有科学计数法分支，所以这里自己实现，供 shape 与 Program 序列化共用。
#
# %g 的决策：先取十进制指数 X（使 10^X <= |v| < 10^(X+1)）；
#   X < -4 或 X >= 6  -> 科学计数法，尾数 5 位小数
#   否则              -> 定点表示，5 - X 位小数
# 两种情形都要去掉尾部的 0 与孤立的小数点。
# 舍入可能让尾数进位到 10（如 9.9999999 -> 10.00000），此时 X 要 +1 再重新决策，
# 否则 999999.9 会打印成 "1e+06" 而另一个实现打印 "100000"（已按 glibc 行为校正）。
#
# 精度边界（已实测）：浮点发生器 dump 3166 个样本（10 的各次幂、0/1/1.5/边界值、
# 1500 组随机尾数×随机二的幂、60 个次正规数）与 Python 的 "%g" 逐位对照，
# 3127 条完全一致；剩下 39 条【全部】落在次正规区间（|v| < 2.2e-308）。
# 原因是 pow(10.0, x) 在这个区间本身只剩个位数有效比特，a / pow(10.0, x) 无法保住
# 6 位有效数字。Stope 的正常词法产物（如 1e-320）会落到这一档，
# 因此通用测试计划里【不】把次正规数纳入比对，选测试用例时要避开。
const G_PRECISION := 6
static func fmt_g(v:float) -> String:
	if is_nan(v): return "nan"
	if is_inf(v): return "inf" if v > 0.0 else "-inf"
	if v == 0.0: return "-0" if (1.0 / v) < 0.0 else "0"
	var sign := "-" if v < 0.0 else ""
	var a := absf(v)
	var x:int = int(floor(log(a) / log(10.0)))
	var guard := 40		# 校正最多迭代这么多次，防止 pow 精度把循环卡死
	while guard > 0 and pow(10.0, x) > a: x -= 1; guard -= 1
	while guard > 0 and pow(10.0, x + 1) <= a: x += 1; guard -= 1
	var mant := String.num(a / pow(10.0, x), G_PRECISION - 1)
	if mant.begins_with("10"):	# 舍入进位
		x += 1
		mant = "1." + "0".repeat(G_PRECISION - 1)
	if x < -4 or x >= G_PRECISION:
		return str(sign, strip_zeros(mant), "e", ("+" if x >= 0 else "-"), "%02d" % absi(x))
	return sign + strip_zeros(String.num(a, G_PRECISION - 1 - x))

# 去掉小数尾部多余的 0，以及随之孤立的小数点：1.50000 -> 1.5   15.0000 -> 15
static func strip_zeros(s:String) -> String:
	if s.find('.') < 0: return s
	while s.ends_with('0'): s = s.substr(0, s.length() - 1)
	if s.ends_with('.'): s = s.substr(0, s.length() - 1)
	return s

static func node_type_name(t:int) -> String:
	return NodeType.keys()[t] if t >= 0 and t < NodeType.size() else str("?", t)

static func indent(level:int) -> String: return "  ".repeat(level)
static func _e(e) -> String: return e.to_str() if e else "<null>"
static func op_text(op:int) -> String:
	if op == TokenType.Sub: return '-'
	if op == TokenType.Not: return '!'
	return str(TokenType.keys()[op], '(')

# ================================ 基类 ================================
class Node_:
	var line:int = -1
	var node_type:int = NodeType.Node
	func _init(line_:int = -1) -> void:
		line = line_

class Stmt extends Node_:
	func _init(line_:int = -1) -> void:
		node_type = NodeType.Stmt; line = line_
	func to_str(_level:int = 0) -> String: return ";\n"

class Expr extends Node_:
	func _init(line_:int = -1) -> void:
		node_type = NodeType.Expr; line = line_
	func to_str(_level:int = 0) -> String: return "()"

# ================================ prog ================================
# prog : stmt*
class Prog extends Node_:
	var stmts:Array[Stmt] = []
	func _init(line_:int = -1) -> void:
		node_type = NodeType.Prog; line = line_
	func to_str(level:int = 0) -> String:
		var s := ''
		for st in stmts: s += st.to_str(level)
		return s

# ================================ 语句 ================================
# expr_stmt : expr ";"
class ExprStmt extends Stmt:
	var expr:Expr = null
	func _init(line_:int = -1) -> void:
		node_type = NodeType.ExprStmt; line = line_
	func to_str(level:int = 0) -> String:
		return StopeAst.indent(level) + StopeAst._e(expr) + ";\n"

# let_stmt : "let" ident ( ("," ident)* | ("=" expr) )? ";"
class LetStmt extends Stmt:
	var has_assign:bool = false
	var idents:Array[String] = []
	var expr:Expr = null
	func _init(line_:int = -1) -> void:
		node_type = NodeType.LetStmt; line = line_
	func ident_num() -> int: return idents.size()
	func to_str(level:int = 0) -> String:
		var s := StopeAst.indent(level) + "let"
		if has_assign:
			s += str(' ', idents[0] if idents.size() > 0 else '?', ' = ', StopeAst._e(expr))
		else:
			for id in idents: s += str(' ', id, ',')
			if idents.size() > 0: s = s.substr(0, s.length() - 1)
		return s + ";\n"

# return_stmt : "return" ( expr ( "," expr )* )? ";"
class ReturnStmt extends Stmt:
	var exprs:Array[Expr] = []
	func _init(line_:int = -1) -> void:
		node_type = NodeType.ReturnStmt; line = line_
	func expr_num() -> int: return exprs.size()
	func to_str(level:int = 0) -> String:
		var s := StopeAst.indent(level) + "return"
		for e in exprs: s += str(' ', StopeAst._e(e), ',')
		if exprs.size() > 0: s = s.substr(0, s.length() - 1)
		return s + ";\n"

# export_stmt : "export" ident ( "," ident )* ";"
class ExportStmt extends Stmt:
	var idents:Array[String] = []
	func _init(line_:int = -1) -> void:
		node_type = NodeType.ExportStmt; line = line_
	func ident_num() -> int: return idents.size()
	func to_str(level:int = 0) -> String:
		var s := StopeAst.indent(level) + "export"
		for id in idents: s += str(' ', id, ',')
		if idents.size() > 0: s = s.substr(0, s.length() - 1)
		return s + ";\n"

# block_stmt : "{" prog "}"
class BlockStmt extends Stmt:
	# C++ 侧 Prog 是【值】成员（cpp/stope/ast.hpp），永远存在；错误路径上它不是 null，
	# 而是一个空 Prog，形状串输出 Block{} 而不是 Block{null}。GD 侧是引用类型，
	# 所以必须在构造时就建好实例 —— 只有 IfStmt.else_prog 例外，它对应 C++ 的
	# std::optional<Prog>，null 表示「没有 else 分支」。
	var prog:Prog = StopeAst.Prog.new()
	func _init(line_:int = -1) -> void:
		node_type = NodeType.BlockStmt; line = line_
	func to_str(level:int = 0) -> String:
		return str(StopeAst.indent(level), '{\n', prog.to_str(level + 1), StopeAst.indent(level), '}\n')

class IfStmtElif extends Node_:
	var cond:Expr = null
	var prog:Prog = StopeAst.Prog.new()

# if_stmt : "if" expr "{" prog "}" ( "elif" expr "{" prog "}" )* ( "else" "{" prog "}" )?
class IfStmt extends Stmt:
	var cond:Expr = null
	var first_prog:Prog = StopeAst.Prog.new()
	var elifs:Array[IfStmtElif] = []
	var else_prog:Prog = null	# 没有 else 分支时为 null（对应 C++ 的 std::optional）
	func _init(line_:int = -1) -> void:
		node_type = NodeType.IfStmt; line = line_
	func has_else() -> bool: return else_prog != null
	func to_str(level:int = 0) -> String:
		var o := str(StopeAst.indent(level), 'if ', StopeAst._e(cond), ' ',
				first_prog.to_str(level))
		for ei in elifs:
			o += str(StopeAst.indent(level), 'elif ', StopeAst._e(ei.cond), ' ',
					ei.prog.to_str(level))
		if has_else():
			o += str(StopeAst.indent(level), 'else ', else_prog.to_str(level))
		return o

# while_stmt : "while" expr? "{" prog "}"   —— cond 为 null 表示无条件循环
class WhileStmt extends Stmt:
	var cond:Expr = null
	var prog:Prog = StopeAst.Prog.new()
	func _init(line_:int = -1) -> void:
		node_type = NodeType.WhileStmt; line = line_
	func to_str(level:int = 0) -> String:
		return str(StopeAst.indent(level), 'while ', StopeAst._e(cond), ' ',
				prog.to_str(level))

# assign_stmt : expr "=" expr ";"
class AssignStmt extends Stmt:
	var left_expr:Expr = null
	var right_expr:Expr = null
	func _init(line_:int = -1) -> void:
		node_type = NodeType.AssignStmt; line = line_
	func to_str(level:int = 0) -> String:
		return str(StopeAst.indent(level), StopeAst._e(left_expr), ' = ', StopeAst._e(right_expr), ";\n")

class BreakStmt extends Stmt:
	func _init(line_:int = -1) -> void:
		node_type = NodeType.BreakStmt; line = line_
	func to_str(level:int = 0) -> String: return StopeAst.indent(level) + "break;\n"

class ContinueStmt extends Stmt:
	func _init(line_:int = -1) -> void:
		node_type = NodeType.ContinueStmt; line = line_
	func to_str(level:int = 0) -> String: return StopeAst.indent(level) + "continue;\n"

# ================================ 表达式 ================================
class NullExpr extends Expr:
	func _init(line_:int = -1) -> void:
		node_type = NodeType.NullExpr; line = line_
	func to_str(_level:int = 0) -> String: return 'null'

class BoolExpr extends Expr:
	var value:bool = false
	func _init(line_:int = -1, v:bool = false) -> void:
		node_type = NodeType.BoolExpr; line = line_; value = v
	func to_str(_level:int = 0) -> String: return str(value)

class IntExpr extends Expr:
	var value:int = 0
	func _init(line_:int = -1, v:int = 0) -> void:
		node_type = NodeType.IntExpr; line = line_; value = v
	func to_str(_level:int = 0) -> String: return str(value)

class FloatExpr extends Expr:
	var value:float = 0.0
	func _init(line_:int = -1, v:float = 0.0) -> void:
		node_type = NodeType.FloatExpr; line = line_; value = v
	func to_str(_level:int = 0) -> String: return StopeAst.fmt_g(value)

class BinArrExpr extends Expr:
	var value:PackedByteArray = PackedByteArray()
	func _init(line_:int = -1, v:PackedByteArray = PackedByteArray()) -> void:
		node_type = NodeType.BinArrExpr; line = line_; value = v
	func to_str(_level:int = 0) -> String: return str("'", StopeAst.fmt_bytes(value), "'")

class StringExpr extends Expr:
	var value:String = ''
	func _init(line_:int = -1, v:String = '') -> void:
		node_type = NodeType.StringExpr; line = line_; value = v
	func to_str(_level:int = 0) -> String: return str('"', value, '"')

class IdentExpr extends Expr:
	var ident:String = ''
	func _init(line_:int = -1, v:String = '') -> void:
		node_type = NodeType.IdentExpr; line = line_; ident = v
	func to_str(_level:int = 0) -> String: return ident

class ArgcExpr extends Expr:
	func _init(line_:int = -1) -> void:
		node_type = NodeType.ArgcExpr; line = line_
	func to_str(_level:int = 0) -> String: return 'argc'

class ArgsExpr extends Expr:
	var key_expr:Expr = null
	func _init(line_:int = -1) -> void:
		node_type = NodeType.ArgsExpr; line = line_
	func to_str(_level:int = 0) -> String: return str('args[', StopeAst._e(key_expr), ']')

class UnaryOpExpr extends Expr:
	var op:int = TokenType.Invalid	# TokenType
	var expr:Expr = null
	func _init(line_:int = -1) -> void:
		node_type = NodeType.UnaryOpExpr; line = line_
	func to_str(_level:int = 0) -> String:
		return str(StopeAst.op_text(op), StopeAst._e(expr))

class BinaryOpExpr extends Expr:
	var left_expr:Expr = null
	var op:int = TokenType.Invalid	# TokenType
	var right_expr:Expr = null
	func _init(line_:int = -1) -> void:
		node_type = NodeType.BinaryOpExpr; line = line_
	func to_str(_level:int = 0) -> String:
		var o:String = binop_literal_map.get(op, '?')
		if o == 'idiv': o = ' idiv '
		else: o = str(' ', o, ' ')
		return str('(', StopeAst._e(left_expr), o, StopeAst._e(right_expr), ')')

class CallExpr extends Expr:
	var callee:Expr = null
	var args:Array[Expr] = []
	func _init(line_:int = -1) -> void:
		node_type = NodeType.CallExpr; line = line_
	func to_str(_level:int = 0) -> String:
		var s := str(StopeAst._e(callee), '(')
		for a in args: s += str(StopeAst._e(a), ',')
		if args.size() > 0: s = s.substr(0, s.length() - 1)
		return str(s, ')')

class AtExpr extends Expr:
	var container:Expr = null
	var key_exprs:Array[Expr] = []
	func _init(line_:int = -1) -> void:
		node_type = NodeType.AtExpr; line = line_
	func to_str(_level:int = 0) -> String:
		var s := str(StopeAst._e(container), '[')
		for a in key_exprs: s += str(StopeAst._e(a), ',')
		if key_exprs.size() > 0: s = s.substr(0, s.length() - 1)
		return str(s, ']')

# custom_opcode_expr : custom "(" ( expr ( "," expr )* )? ")"
class CustomOpcodeExpr extends Expr:
	var opcode_name:String = ''
	var args:Array[Expr] = []
	func _init(line_:int = -1) -> void:
		node_type = NodeType.CustomOpcodeExpr; line = line_
	func to_str(_level:int = 0) -> String:
		var s := str(opcode_name, '(')
		for a in args: s += str(StopeAst._e(a), ',')
		if args.size() > 0: s = s.substr(0, s.length() - 1)
		return str(s, ')')

# ================================ 序列化：测试用 ================================
# 严格照抄 cpp/test/test_common.hpp 的 shapeExpr / shapeStmt / shapeProg。
# 节点写法：
#   Null / Argc / Bool(true) / Int(31) / Float(1.5) / BinArr[04,01] / Str("a\nb") /
#   Ident(a) / Args(null) / Unary(Sub, Int(1)) / Bin(Add, Int(1), Int(2)) /
#   Call(f; Int(1)) / At(a; Int(1)) / Custom(myop; Int(1)) / Err(L-1)
# 语句写法：
#   ExprStmt(..) / Let[a,b]=Int(1) / Return(Int(1), Int(2)) / Export[a] /
#   Block{..} / If(c){..}Elif(c){..}Else{..} / While(c){..} /
#   Assign(l, r) / Break / Continue
# prog：语句按 " ; " 连接，无外层包装；空 prog -> ""

static func shape_prog(p) -> String:
	if p == null: return "null"
	var d := ''
	for st in p.stmts:
		if d != '': d += ' ; '
		d += shape_stmt(st)
	return d

static func shape_stmt(s) -> String:
	if s == null: return "null"
	var t:int = s.node_type
	if t == NodeType.ExprStmt:
		return "ExprStmt(" + shape_expr(s.expr) + ")"
	elif t == NodeType.LetStmt:
		var d := "Let["
		for i in range(s.idents.size()):
			if i > 0: d += ","
			d += esc(s.idents[i])
		d += "]"
		if s.has_assign: d += "=" + shape_expr(s.expr)
		return d
	elif t == NodeType.ReturnStmt:
		var d := "Return("
		for i in range(s.exprs.size()):
			if i > 0: d += ", "
			d += shape_expr(s.exprs[i])
		return d + ")"
	elif t == NodeType.ExportStmt:
		var d := "Export["
		for i in range(s.idents.size()):
			if i > 0: d += ","
			d += esc(s.idents[i])
		return d + "]"
	elif t == NodeType.BlockStmt:
		return "Block{" + shape_prog(s.prog) + "}"
	elif t == NodeType.IfStmt:
		var d := "If(" + shape_expr(s.cond) + "){" + shape_prog(s.first_prog) + "}"
		for ei in s.elifs:
			d += "Elif(" + shape_expr(ei.cond) + "){" + shape_prog(ei.prog) + "}"
		if s.else_prog != null: d += "Else{" + shape_prog(s.else_prog) + "}"
		return d
	elif t == NodeType.WhileStmt:
		return "While(" + shape_expr(s.cond) + "){" + shape_prog(s.prog) + "}"
	elif t == NodeType.AssignStmt:
		return "Assign(" + shape_expr(s.left_expr) + ", " + shape_expr(s.right_expr) + ")"
	elif t == NodeType.BreakStmt:
		return "Break"
	elif t == NodeType.ContinueStmt:
		return "Continue"
	return "?" + node_type_name(t)

static func shape_expr(e) -> String:
	if e == null: return "null"
	var t:int = e.node_type
	if t == NodeType.Expr:		# 失败路径返回的裸节点（PD-8）：line 恒为 -1
		return str("Err(L", e.line, ")")
	elif t == NodeType.NullExpr:
		return "Null"
	elif t == NodeType.ArgcExpr:
		return "Argc"
	elif t == NodeType.BoolExpr:
		return "Bool(true)" if e.value else "Bool(false)"
	elif t == NodeType.IntExpr:
		return str("Int(", e.value, ")")
	elif t == NodeType.FloatExpr:
		return str("Float(", StopeAst.fmt_g(e.value), ")")
	elif t == NodeType.BinArrExpr:
		return "BinArr[" + StopeAst.fmt_bytes(e.value) + "]"
	elif t == NodeType.StringExpr:
		return 'Str("' + esc(e.value) + '")'
	elif t == NodeType.IdentExpr:
		return "Ident(" + esc(e.ident) + ")"
	elif t == NodeType.ArgsExpr:
		if e.key_expr == null: return "Args(null)"
		return "Args(" + shape_expr(e.key_expr) + ")"
	elif t == NodeType.UnaryOpExpr:
		return str("Unary(", StopeLexer.Token.type_name(e.op), ", ", shape_expr(e.expr), ")")
	elif t == NodeType.BinaryOpExpr:
		return str("Bin(", StopeLexer.Token.type_name(e.op), ", ", shape_expr(e.left_expr),
				", ", shape_expr(e.right_expr), ")")
	elif t == NodeType.CallExpr:
		var d := "Call(" + shape_expr(e.callee)
		for a in e.args: d += "; " + shape_expr(a)
		return d + ")"
	elif t == NodeType.AtExpr:
		var d := "At(" + shape_expr(e.container)
		for k in e.key_exprs: d += "; " + shape_expr(k)
		return d + ")"
	elif t == NodeType.CustomOpcodeExpr:
		var d := "Custom(" + esc(e.opcode_name)
		for a in e.args: d += "; " + shape_expr(a)
		return d + ")"
	return "?" + node_type_name(t)
