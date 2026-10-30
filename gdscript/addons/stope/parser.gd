class_name StopeParser
# 语法分析器 —— 逐行端口 cpp/stope/parser.hpp（C++ 为权威实现，2026-10-18 重写）。
#
# 行为契约见 docs/zh-cn/parser-test-plan.md，与 C++ 的偏差登记在该文档 §7（GD-P-xx）。
# 几条容易踩错、且两边必须一致的约定：
#   1. 错误恢复：**分隔符缺失时只报错、不推进**，把后续 token 留给下一条语句重新解析。
#      （参考实现在这几处会吞 token，C++ 有意偏离，见 cpp/docs/parser-test-plan.md §2.2）
#      例外（有意保留旧语义）：parse_let_stmt / parse_return_stmt 的兜底分支仍会推进。
#   2. 不变量：parse_expr() 之后必有一次 next_token()。删错误分支里的推进时别连带删它。
#   3. 顶层孤立 "}" 要报错【并跳过】继续解析；块内的 "}" 由外层消费，不报错。
#   4. 常量折叠挂在 parse_unary_op_expr / parse_binary_op_expr 的构造末尾，
#      **不要**改成把 parse_expr 包一层 —— 那样每层递归多一个栈帧，会把深括号用例打崩。
#   5. 节点取的是 token 的 parsed 而非 literal：字符串要转义后的值、标识符要拼好的 ':'。
#      只有 BinArr 取 literal（词法阶段不做任何转义）。
const TokenType = StopeLexer.Token.Type

class Parser:
	var lexer:StopeLexer.Lexer
	var custom:StopeOpcode.CustomOpcodeConfig	# 可空：词法器靠它认出自定义指令
	var errors:Array[String] = []
	var const_folding:bool = true	# 表达式常量折叠开关（测试里按用例切换）
	# 嵌套深度上限。depth 由调用链显式传递（每个 parse_xxx 一个形参），不存成员：
	# 哪一层递归、离上限还有多远，看签名就知道。0 = 不限制。
	# 超限时报一条错、置 _aborted，此后不再解析（返回 null）。默认值与 C++ 的
	# Parser::maxDepth 相同，错误文案也逐字相同（两侧测试比对）。
	var max_depth:int = 256
	var _aborted:bool = false

	var cur_token:StopeLexer.Token
	var peek_token:StopeLexer.Token
	var _bin_arr := StopeBinArrParser.new()

	func _init(lexer_:StopeLexer.Lexer, custom_:StopeOpcode.CustomOpcodeConfig = null) -> void:
		reset(lexer_, custom_)
	# 与 C++ 的 Parser::Reset 一致：清错误、重挂词法器、重读两个 token。
	func reset(lexer_:StopeLexer.Lexer, custom_:StopeOpcode.CustomOpcodeConfig = null) -> void:
		errors = []
		_aborted = false
		lexer = lexer_
		custom = custom_
		register_parse_fns()
		# 先读两个 token，cur / peek 才都有值 —— 顺序不能变，
		# 否则输入最开头的自定义指令或首个 token 会被漏掉（对应 PD-3）。
		next_token()
		next_token()

	func register_parse_fns() -> void:
		_prefix_fns[TokenType.Ident] = parse_ident_expr
		_prefix_fns[TokenType.Null] = parse_null_expr
		_prefix_fns[TokenType.False] = parse_bool_expr
		_prefix_fns[TokenType.True] = parse_bool_expr
		_prefix_fns[TokenType.Integer] = parse_int_expr
		_prefix_fns[TokenType.Float] = parse_float_expr
		_prefix_fns[TokenType.String] = parse_string_expr
		_prefix_fns[TokenType.BinArr] = parse_bin_arr_expr
		_prefix_fns[TokenType.Argc] = parse_argc_expr
		_prefix_fns[TokenType.Sub] = parse_unary_op_expr
		_prefix_fns[TokenType.Not] = parse_unary_op_expr
		_prefix_fns[TokenType.LParen] = parse_paren_expr
		_prefix_fns[TokenType.Custom] = parse_custom_opcode_expr
		_prefix_fns[TokenType.Args] = parse_args_expr

		# 与 C++ 的 BinopPrecMap 同一批运算符（含 () 与 [] 之外的全部二元运算符）
		for t in [TokenType.Or, TokenType.And, TokenType.EQ, TokenType.NE,
				TokenType.LT, TokenType.LE, TokenType.GT, TokenType.GE,
				TokenType.Add, TokenType.Sub, TokenType.Mul,
				TokenType.Div, TokenType.IDiv, TokenType.Mod,
				TokenType.Pow]:
			_infix_fns[t] = parse_binary_op_expr
		_infix_fns[TokenType.LParen] = parse_call_expr		# () 函数调用
		_infix_fns[TokenType.LBrack] = parse_at_expr		# [] 取元素

	func parse_program(prog:StopeAst.Prog) -> void: parse_prog(prog, true, 1)

	# ================================ 语句 ================================
	# is_top_level=true 只有 parse_program 用。块/if/while 内部的 prog 都是 false：
	# 它们的 "}" 属于外层语句，必须由外层自己消费。
	func parse_prog(prog:StopeAst.Prog, is_top_level:bool, depth:int) -> void:
		if _aborted: return
		while not _aborted and cur_token.type != TokenType.Eof:
			if cur_token.type == TokenType.RBrace:
				if not is_top_level:
					break	# 块内：正常结束，不跳过，交给外层处理
				error(cur_token.line, 'unexpected "}" at top level. ')
				next_token()
				continue
			if cur_token.type == TokenType.Semi:	# 空语句
				next_token()
				continue
			var stmt:StopeAst.Stmt
			if cur_token.type == TokenType.Let:
				stmt = parse_let_stmt(depth)
			elif cur_token.type == TokenType.Export:
				stmt = parse_export_stmt(depth)
			elif cur_token.type == TokenType.Return:
				stmt = parse_return_stmt(depth)
			elif cur_token.type == TokenType.LBrace:
				stmt = parse_block_stmt(depth)
			elif cur_token.type == TokenType.If:
				stmt = parse_if_stmt(depth)
			elif cur_token.type == TokenType.While:
				stmt = parse_while_stmt(depth)
			elif cur_token.type == TokenType.Break:
				stmt = parse_break_stmt(depth)
			elif cur_token.type == TokenType.Continue:
				stmt = parse_continue_stmt(depth)
			else:	# 表达式语句或赋值语句
				stmt = parse_expr_or_assign_stmt(depth)
			# 超限中止时子函数返回 null：不追加、不再往下解析（否则拿着同一个
			# token 反复调用会死循环）。
			if stmt == null: break
			prog.stmts.append(stmt)

	func parse_let_stmt(depth:int) -> StopeAst.LetStmt:
		var stmt := StopeAst.LetStmt.new(cur_token.line)
		stmt.has_assign = false
		next_token()	# 跳过 let
		if cur_token.type != TokenType.Ident:
			error(cur_token.line, 'expected identifier after "let". ')
			next_token()
			return stmt
		stmt.idents.append(cur_token.parsed)
		next_token()
		if cur_token.type == TokenType.Semi:	# 单个标识符且不赋值
			next_token()
		elif cur_token.type == TokenType.Comma:	# 多个标识符，禁止赋值
			while true:
				if cur_token.type == TokenType.Comma and peek_token.type == TokenType.Ident:
					stmt.idents.append(peek_token.parsed)
					next_token(); next_token()
				elif cur_token.type == TokenType.Semi:
					next_token(); break
				elif cur_token.type == TokenType.Eof or cur_token.type == TokenType.RBrace:
					# 缺 ";"：此处不能再推进。Eof 上推进不会前进会死循环，
					# 推进又会吞掉外层块的 "}" 导致解析错位。
					error(cur_token.line, 'expected ";" in let statement. ')
					break
				else:
					error(cur_token.line, "failed to parse let statement with multiple identifiers. ")
					next_token()
		elif cur_token.type == TokenType.Assign:	# 有赋值
			stmt.has_assign = true
			next_token()
			stmt.expr = parse_expr(StopeAst.Precedence.Lowest, depth)
			next_token()
		else:
			error(cur_token.line, "unexpected token in let statement. ")
			next_token()
		return stmt

	func parse_export_stmt(_depth:int) -> StopeAst.ExportStmt:
		var stmt := StopeAst.ExportStmt.new(cur_token.line)
		next_token()	# 跳过 export
		if cur_token.type != TokenType.Ident:
			error(cur_token.line, 'expected identifier after "export". ')
			next_token()
			return stmt
		stmt.idents.append(cur_token.parsed)
		next_token()
		if cur_token.type == TokenType.Semi:	# 单个标识符
			next_token()
		elif cur_token.type == TokenType.Comma:
			while true:
				if cur_token.type == TokenType.Comma and peek_token.type == TokenType.Ident:
					stmt.idents.append(peek_token.parsed)
					next_token(); next_token()
				elif cur_token.type == TokenType.Semi:
					next_token(); break
				elif cur_token.type == TokenType.Eof or cur_token.type == TokenType.RBrace:
					error(cur_token.line, 'expected ";" in export statement. ')
					break
				else:
					error(cur_token.line, "failed to parse export statement with multiple identifiers. ")
					next_token()
		else:
			error(cur_token.line, "unexpected token in export statement. ")
			next_token()
		return stmt

	# return_stmt : "return" ( expr ( "," expr )* )? ";"
	func parse_return_stmt(depth:int) -> StopeAst.ReturnStmt:
		var stmt := StopeAst.ReturnStmt.new(cur_token.line)
		next_token()	# 跳过 return
		if cur_token.type == TokenType.Semi:	# 无返回值，exprs 为空
			next_token()
			return stmt
		if cur_token.type == TokenType.Eof or cur_token.type == TokenType.RBrace:
			# 缺 ";"：此时不能吞掉 } 或 Eof，否则外层块会解析错位
			error(cur_token.line, 'expected ";" in return statement. ')
			return stmt
		stmt.exprs.append(parse_expr(StopeAst.Precedence.Lowest, depth))	# 第一个表达式
		next_token()	# 到达 , 或 ;
		while true:		# ("," expr)*
			if cur_token.type == TokenType.Semi:
				next_token(); break
			elif cur_token.type == TokenType.Comma:
				next_token()
				stmt.exprs.append(parse_expr(StopeAst.Precedence.Lowest, depth))
				next_token()
			else:
				error(cur_token.line, 'expected ";" or "," in return statement. ')
				next_token(); break
		return stmt

	func parse_block_stmt(depth:int) -> StopeAst.BlockStmt:
		if _aborted: return null	# 已超限：不再解析
		var stmt := StopeAst.BlockStmt.new(cur_token.line)
		next_token()	# 跳过 {
		stmt.prog = StopeAst.Prog.new()
		parse_prog(stmt.prog, false, depth + 1)
		if cur_token.type != TokenType.RBrace:
			error(cur_token.line, 'expected "}" at end of block statement. ')
		next_token()	# 跳过 }
		return stmt

	# if_stmt : "if" expr "{" prog "}" ("elif" expr "{" prog "}")* ("else" "{" prog "}")?
	func parse_if_stmt(depth:int) -> StopeAst.IfStmt:
		if _aborted: return null
		var stmt := StopeAst.IfStmt.new(cur_token.line)
		next_token()	# 跳过 if
		stmt.cond = parse_expr(StopeAst.Precedence.Lowest, depth)
		next_token()	# 到达 {
		if cur_token.type != TokenType.LBrace:
			error(cur_token.line, 'expected "{" in if statement. ')
			return stmt
		next_token()	# 跳过 {
		stmt.first_prog = StopeAst.Prog.new()
		parse_prog(stmt.first_prog, false, depth + 1)
		if cur_token.type != TokenType.RBrace:
			error(cur_token.line, 'expected "}" in if statement. ')
			return stmt
		next_token()	# 跳过 }
		while cur_token.type == TokenType.Elif:	# ("elif" expr "{" prog "}")*
			var ei := StopeAst.IfStmtElif.new(cur_token.line)
			next_token()	# 跳过 elif
			ei.cond = parse_expr(StopeAst.Precedence.Lowest, depth)
			next_token()
			if cur_token.type != TokenType.LBrace:
				error(cur_token.line, 'expected "{" of elif. ')
				return stmt
			next_token()	# 跳过 {
			ei.prog = StopeAst.Prog.new()
			parse_prog(ei.prog, false, depth + 1)
			if cur_token.type != TokenType.RBrace:
				error(cur_token.line, 'expected "}" of elif. ')
				return stmt
			next_token()	# 跳过 }
			stmt.elifs.append(ei)
		if cur_token.type == TokenType.Else:	# ("else" "{" prog "}")?
			next_token()
			if cur_token.type != TokenType.LBrace:
				error(cur_token.line, 'expected "{" after else. ')
				return stmt
			next_token()	# 跳过 {
			stmt.else_prog = StopeAst.Prog.new()
			parse_prog(stmt.else_prog, false, depth + 1)
			if cur_token.type != TokenType.RBrace:
				error(cur_token.line, 'expected "}" in if statement. ')
				return stmt
			next_token()	# 跳过 }
		return stmt

	# while_stmt : "while" expr? "{" prog "}"
	func parse_while_stmt(depth:int) -> StopeAst.WhileStmt:
		if _aborted: return null
		var stmt := StopeAst.WhileStmt.new(cur_token.line)
		next_token()	# 跳过 while
		if cur_token.type != TokenType.LBrace:	# expr?
			stmt.cond = parse_expr(StopeAst.Precedence.Lowest, depth)
			next_token()	# 到达 {
		if cur_token.type != TokenType.LBrace:
			error(cur_token.line, 'expected "{" in while statement. ')
			return stmt
		next_token()	# 跳过 {
		stmt.prog = StopeAst.Prog.new()
		parse_prog(stmt.prog, false, depth + 1)
		if cur_token.type != TokenType.RBrace:
			error(cur_token.line, 'expected "}" at end of while statement. ')
			return stmt
		next_token()
		return stmt

	# break_stmt : "break" ";"
	func parse_break_stmt(_depth:int) -> StopeAst.BreakStmt:
		var stmt := StopeAst.BreakStmt.new(cur_token.line)
		next_token()	# 跳过 break
		if cur_token.type != TokenType.Semi:
			error(cur_token.line, 'expected ";" in break statement. ')
		else:
			next_token()
		return stmt

	# continue_stmt : "continue" ";"
	func parse_continue_stmt(_depth:int) -> StopeAst.ContinueStmt:
		var stmt := StopeAst.ContinueStmt.new(cur_token.line)
		next_token()	# 跳过 continue
		if cur_token.type != TokenType.Semi:
			error(cur_token.line, 'expected ";" in continue statement. ')
		else:
			next_token()
		return stmt

	func parse_expr_or_assign_stmt(depth:int) -> StopeAst.Stmt:
		var left_expr := parse_expr(StopeAst.Precedence.Lowest, depth)
		if left_expr == null: return null	# 超限中止：下面要读 left_expr.line
		next_token()	# 到达 = 或 ;
		if cur_token.type == TokenType.Semi:
			next_token()	# 跳过 ;
			var s := StopeAst.ExprStmt.new(left_expr.line)
			s.expr = left_expr
			return s
		elif cur_token.type == TokenType.Assign:
			next_token()	# 跳过 =
			var a := StopeAst.AssignStmt.new(left_expr.line)
			a.left_expr = left_expr
			a.right_expr = parse_expr(StopeAst.Precedence.Lowest, depth)
			next_token()	# 到达 ;
			if cur_token.type != TokenType.Semi:
				error(cur_token.line, 'expected ";" at end of assign statement. ')
			next_token()
			return a
		else:
			error(cur_token.line, 'expected ";" or "=". ')
			# 不推进：当前 token 不是合法的语句边界，留给下一轮语句解析。
			# 否则会吞掉后续语句（PD-4d：f(1, 2 x; y; 里的 x; 被吞）。
			var s2 := StopeAst.ExprStmt.new(left_expr.line)
			s2.expr = left_expr
			return s2

	# ================================ 表达式主循环 ================================
	func parse_expr(precedence:int, depth:int) -> StopeAst.Expr:
		# 深度检查只在这里和 parse_prog 做 —— 只有这两处会递归。
		if _aborted: return null
		if max_depth > 0 and depth > max_depth:
			_abort_too_deep(cur_token.line)
			return null
		if not _prefix_fns.has(cur_token.type):
			error(cur_token.line, "no prefix parse function for token type. ")
			return StopeAst.Expr.new(cur_token.line)	# 失败路径返回裸节点，形状为 Err(L行号)
		var left_expr:StopeAst.Expr = _prefix_fns[cur_token.type].call(self, depth)
		if left_expr == null: return null	# 子表达式已中止（括号会原样透出）
		while not _aborted and peek_token.type != TokenType.Semi and precedence < peek_precedence():
			if not _infix_fns.has(peek_token.type):
				error(peek_token.line, "no infix parse function for token type. ")
				return left_expr
			next_token()
			left_expr = _infix_fns[cur_token.type].call(self, left_expr, depth)
			if left_expr == null: return null
		return left_expr

	func cur_precedence() -> int:
		return StopeAst.binop_prec_map.get(cur_token.type, StopeAst.Precedence.Lowest)
	func peek_precedence() -> int:
		return StopeAst.binop_prec_map.get(peek_token.type, StopeAst.Precedence.Lowest)

	# 常量折叠的单一入口。挂在 parse_unary_op_expr / parse_binary_op_expr 的构造末尾
	# （见那两处），**不要**改成把 parse_expr 包一层。
	func optimize_in_place(e) -> StopeAst.Expr:
		if not const_folding: return e
		return StopeExprOptim.optimize(e)

	# ================================ 前缀 ================================
	static func parse_ident_expr(p:Parser, _depth:int) -> StopeAst.Expr:
		return StopeAst.IdentExpr.new(p.cur_token.line, p.cur_token.parsed)
	static func parse_null_expr(p:Parser, _depth:int) -> StopeAst.Expr:
		return StopeAst.NullExpr.new(p.cur_token.line)
	static func parse_bool_expr(p:Parser, _depth:int) -> StopeAst.Expr:
		return StopeAst.BoolExpr.new(p.cur_token.line, p.cur_token.type == TokenType.True)
	static func parse_int_expr(p:Parser, _depth:int) -> StopeAst.Expr:
		return StopeAst.IntExpr.new(p.cur_token.line, p.cur_token.int_value)
	static func parse_float_expr(p:Parser, _depth:int) -> StopeAst.Expr:
		return StopeAst.FloatExpr.new(p.cur_token.line, p.cur_token.float_value)
	static func parse_string_expr(p:Parser, _depth:int) -> StopeAst.Expr:
		# 取 parsed：转义已完成（literal 是未转义的原文）
		return StopeAst.StringExpr.new(p.cur_token.line, p.cur_token.parsed)
	static func parse_bin_arr_expr(p:Parser, _depth:int) -> StopeAst.Expr:
		var e := StopeAst.BinArrExpr.new(p.cur_token.line)
		# 取 literal：二进制数组不做转义，解析到一半失败也要保留前半段（报错但继续）
		if not p._bin_arr.parse(p.cur_token.literal, e.value):
			p.error(p.cur_token.line, "invalid binary array. ")
		return e
	static func parse_argc_expr(p:Parser, _depth:int) -> StopeAst.Expr:
		return StopeAst.ArgcExpr.new(p.cur_token.line)

	static func parse_unary_op_expr(p:Parser, depth:int) -> StopeAst.Expr:
		var e := StopeAst.UnaryOpExpr.new(p.cur_token.line)
		e.op = p.cur_token.type
		p.next_token()
		e.expr = p.parse_expr(StopeAst.Precedence.Prefix, depth + 1)
		var out := p.optimize_in_place(e)	# 自底向上：子表达式已折好，这里折自己
		return out

	static func parse_paren_expr(p:Parser, depth:int) -> StopeAst.Expr:
		p.next_token()
		var e := p.parse_expr(StopeAst.Precedence.Lowest, depth + 1)
		p.next_token()
		if p.cur_token.type != TokenType.RParen:
			p.error(p.cur_token.line, 'expected ")". ')
		return e	# 停在 )

	static func parse_custom_opcode_expr(p:Parser, depth:int) -> StopeAst.Expr:
		var e := StopeAst.CustomOpcodeExpr.new(p.cur_token.line)
		e.opcode_name = p.cur_token.parsed
		p.next_token()	# 到达 (
		if p.cur_token.type != TokenType.LParen:
			p.error(p.cur_token.line, 'expected "(" after custom opcode. ')
			p.next_token()
			return e
		p.next_token()
		if p.cur_token.type == TokenType.RParen:
			pass	# 空参数表，cur 停在 )
		else:	# expr ("," expr)*
			e.args.append(p.parse_expr(StopeAst.Precedence.Lowest, depth + 1))
			while p.peek_token.type == TokenType.Comma:
				p.next_token(); p.next_token()
				e.args.append(p.parse_expr(StopeAst.Precedence.Lowest, depth + 1))
			if p.peek_token.type != TokenType.RParen:
				p.error(p.cur_token.line, 'expected ")". ')
			p.next_token()	# 到达 )
		return e

	static func parse_args_expr(p:Parser, depth:int) -> StopeAst.Expr:
		var e := StopeAst.ArgsExpr.new(p.cur_token.line)
		if p.peek_token.type != TokenType.LBrack:
			# 不推进（cur 停在 "args"）：把后续 token 留给下一条语句，避免吞掉（PD-4c）
			p.error(p.peek_token.line, 'expected "[" after "args". ')
			return e
		p.next_token()	# 到达 [
		p.next_token()
		e.key_expr = p.parse_expr(StopeAst.Precedence.Lowest, depth + 1)
		p.next_token()
		if p.cur_token.type != TokenType.RBrack:
			p.error(p.cur_token.line, 'expected "]". ')
		return e

	# ================================ 中缀 ================================
	static func parse_binary_op_expr(p:Parser, left_expr, depth:int) -> StopeAst.Expr:
		if left_expr == null: return null	# 左操作数已中止（正常路径进不来）
		var e := StopeAst.BinaryOpExpr.new(left_expr.line)
		e.left_expr = left_expr
		e.op = p.cur_token.type
		var prec:int = p.cur_precedence()
		# ^ 右结合：优先级 -1 让右侧继续吃同级的 ^（2^3^2 = 2^(3^2)）。
		# 与 C++ 的 parseBinaryOpExpr 一致 —— 那边是 `prec = int(prec) - 1`。
		if e.op == TokenType.Pow: prec -= 1
		p.next_token()
		e.right_expr = p.parse_expr(prec, depth + 1)
		var out := p.optimize_in_place(e)	# 两侧都已折好，折叠只在最深的节点先发生
		return out

	static func parse_call_expr(p:Parser, callee, depth:int) -> StopeAst.Expr:
		if callee == null: return null
		var e := StopeAst.CallExpr.new(callee.line)
		e.callee = callee
		# 外层已保证此处是 (
		if p.peek_token.type != TokenType.RParen:	# expr ("," expr)*
			p.next_token()	# 到达第一个表达式
			e.args.append(p.parse_expr(StopeAst.Precedence.Lowest, depth + 1))
			while p.peek_token.type == TokenType.Comma:	# ("," expr)*
				p.next_token()	# 到达 ","
				p.next_token()	# 到达下一个表达式
				e.args.append(p.parse_expr(StopeAst.Precedence.Lowest, depth + 1))
		if p.peek_token.type == TokenType.RParen:
			p.next_token()	# 跳过 )
		else:	# 缺 ")" 时不推进，避免吞掉后面的 token
			p.error(p.peek_token.line, 'expected ")". ')
		return e

	static func parse_at_expr(p:Parser, container, depth:int) -> StopeAst.Expr:
		if container == null: return null
		var e := StopeAst.AtExpr.new(container.line)
		e.container = container
		if p.peek_token.type != TokenType.RBrack:	# expr ("," expr)*
			p.next_token()	# 到达第一个表达式
			e.key_exprs.append(p.parse_expr(StopeAst.Precedence.Lowest, depth + 1))
			while p.peek_token.type == TokenType.Comma:	# ("," expr)*
				p.next_token()	# 到达 ","
				p.next_token()	# 到达下一个表达式
				e.key_exprs.append(p.parse_expr(StopeAst.Precedence.Lowest, depth + 1))
		if p.peek_token.type == TokenType.RBrack:
			p.next_token()	# 跳过 ]
		else:	# 缺 "]" 时不推进，避免吞掉后面的 token
			p.error(p.peek_token.line, 'expected "]". ')
		return e

	# ---------------- 分发表 ----------------
	# 说明：GDScript 的 const 不能装 Callable，所以不像 C++ 那样写成静态常量表，
	# 而是在构造函数里注册成实例字段。表的内容与 cpp/stope/parser.hpp 的
	# prefixParseFns / infixParseFns 逐项对应。
	var _prefix_fns:Dictionary = {}
	var _infix_fns:Dictionary = {}

	# ================================ 基础设施 ================================
	func next_token() -> void:
		cur_token = peek_token
		peek_token = lexer.next_token(custom)

	func error(line:int, msg:String) -> void:
		# 嵌套超限中止之后的一切错误（缺 "}"、expected ")" 之类）都是连锁反应，
		# 不再记账 —— 否则一个 12000 层的块嵌套能刷出上万条噪音。
		if _aborted: return
		errors.append(str("line ", line, ": ", msg))
	func _abort_too_deep(line:int) -> void:
		error(line, 'nesting too deep (max %d). ' % max_depth)	# 必须在置位之前记账
		_aborted = true
	func has_err() -> bool: return errors.size() > 0
