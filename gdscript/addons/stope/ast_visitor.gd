class_name StopeASTVisitor
# 遍历骨架 —— 逐项对齐 cpp/include/stope/ast_visitor.hpp（+.cpp 里的分发表）。
#
# 用法：继承 ASTVisitor，按需重写 on_visit_xxx。默认实现一律「按源码顺序递归子节点」，
# 子类重写后若要继续下钻，调 super.on_visit_xxx(...) 即可。
#
# 与 C++ 的唯一差别在分发表：C++ 的 visitMap 存的是 `void(*)(ASTVisitor&, Node*)`
# 分发函数（负责把 Node* 强转成具体类型再交给钩子）；GD 的节点本来就是对象，
# 不需要强转，所以表里存的是**方法名字符串**，visit() 用 call() 派发 —— call()
# 同样会走到子类的重写版本。
#
# 表要能被测试看见：漏一项不会报错、只会静默跳过整类节点（Node / Stmt / Expr
# 三个裸基类本来就没有表项，它们在错误恢复路径上出现，visit() 直接跳过）。

const NodeType = StopeAst.NodeType

class ASTVisitor:
	# 当前正在访问的节点行号，由 visit() 顺带更新。基类自己不用，留给要报诊断的
	# 子类（Compiler 那些没有专属行号的错误就取它）。
	var cur_line:int = -1

	# NodeType -> 方法名，等价于 C++ 的 ASTVisitor::visitMap
	const visit_map:Dictionary = {
		NodeType.Prog: 'on_visit_prog',

		NodeType.ExprStmt: 'on_visit_expr_stmt',
		NodeType.LetStmt: 'on_visit_let_stmt',
		NodeType.ReturnStmt: 'on_visit_return_stmt',
		NodeType.ExportStmt: 'on_visit_export_stmt',
		NodeType.BlockStmt: 'on_visit_block_stmt',
		NodeType.IfStmt: 'on_visit_if_stmt',
		NodeType.WhileStmt: 'on_visit_while_stmt',
		NodeType.AssignStmt: 'on_visit_assign_stmt',
		NodeType.BreakStmt: 'on_visit_break_stmt',
		NodeType.ContinueStmt: 'on_visit_continue_stmt',

		NodeType.NullExpr: 'on_visit_null_expr',
		NodeType.BoolExpr: 'on_visit_bool_expr',
		NodeType.IntExpr: 'on_visit_int_expr',
		NodeType.FloatExpr: 'on_visit_float_expr',
		NodeType.BinArrExpr: 'on_visit_bin_arr_expr',
		NodeType.StringExpr: 'on_visit_string_expr',
		NodeType.IdentExpr: 'on_visit_ident_expr',
		NodeType.ArgcExpr: 'on_visit_argc_expr',
		NodeType.ArgsExpr: 'on_visit_args_expr',
		NodeType.UnaryOpExpr: 'on_visit_unary_op_expr',
		NodeType.BinaryOpExpr: 'on_visit_binary_op_expr',
		NodeType.CallExpr: 'on_visit_call_expr',
		NodeType.AtExpr: 'on_visit_at_expr',
		NodeType.CustomOpcodeExpr: 'on_visit_custom_opcode_expr',
	}

	func visit(n) -> void:
		if n == null: return
		cur_line = n.line
		var fn = visit_map.get(n.node_type)
		if fn != null: call(fn, n)

	# ==================== 子类要重写的钩子 ====================
	# 只有 NullExpr / ArgcExpr 没有子节点，它们的参数写成可选的 `_n`，这样 visit()
	# 能对所有钩子统一 call(fn, n)，不必为「无参钩子」单开一条分支。

	func on_visit_prog(p:StopeAst.Prog) -> void:
		for s in p.stmts: visit(s)

	# ---------------- 语句 ----------------
	func on_visit_expr_stmt(s:StopeAst.ExprStmt) -> void:
		visit(s.expr)
	# 只走初值：idents 是名字（String 列表），不是 Expr
	func on_visit_let_stmt(s:StopeAst.LetStmt) -> void:
		if s.has_assign: visit(s.expr)
	func on_visit_return_stmt(s:StopeAst.ReturnStmt) -> void:
		for e in s.exprs: visit(e)
	func on_visit_export_stmt(_s:StopeAst.ExportStmt) -> void:
		pass
	# 块里嵌的是裸 Prog，递归回 Prog 的表项即可，不必 dispatch 两遍
	func on_visit_block_stmt(s:StopeAst.BlockStmt) -> void:
		visit(s.prog)
	# 顺序：条件 → 首分支 → 每个 elif（条件 → 块）→ else 块
	func on_visit_if_stmt(s:StopeAst.IfStmt) -> void:
		visit(s.cond)
		visit(s.first_prog)
		for ei in s.elifs:
			visit(ei.cond)
			visit(ei.prog)
		if s.else_prog != null: visit(s.else_prog)
	func on_visit_while_stmt(s:StopeAst.WhileStmt) -> void:
		visit(s.cond)	# 条件可省（while { }），visit(null) 自己会返回
		visit(s.prog)
	func on_visit_assign_stmt(s:StopeAst.AssignStmt) -> void:
		visit(s.left_expr)
		visit(s.right_expr)
	func on_visit_break_stmt(_s:StopeAst.BreakStmt) -> void:
		pass
	func on_visit_continue_stmt(_s:StopeAst.ContinueStmt) -> void:
		pass

	# ---------------- 表达式 ----------------
	# 叶子：没有子节点
	func on_visit_null_expr(_n = null) -> void: pass
	func on_visit_bool_expr(_e:StopeAst.BoolExpr) -> void: pass
	func on_visit_int_expr(_e:StopeAst.IntExpr) -> void: pass
	func on_visit_float_expr(_e:StopeAst.FloatExpr) -> void: pass
	func on_visit_bin_arr_expr(_e:StopeAst.BinArrExpr) -> void: pass
	func on_visit_string_expr(_e:StopeAst.StringExpr) -> void: pass
	func on_visit_ident_expr(_e:StopeAst.IdentExpr) -> void: pass
	func on_visit_argc_expr(_n = null) -> void: pass
	func on_visit_args_expr(e:StopeAst.ArgsExpr) -> void:
		visit(e.key_expr)	# args[] 的下标缺失时为 null
	func on_visit_unary_op_expr(e:StopeAst.UnaryOpExpr) -> void:
		visit(e.expr)
	func on_visit_binary_op_expr(e:StopeAst.BinaryOpExpr) -> void:
		if e.op == StopeLexer.Token.Type.Or:
			on_visit_or_expr(e)
			return
		if e.op == StopeLexer.Token.Type.And:
			on_visit_and_expr(e)
			return
		visit(e.left_expr)
		visit(e.right_expr)
	# 短路语义的钩子：默认实现与上面的普通路径等价，需要特判的后端（编译器）自行重写
	func on_visit_or_expr(e:StopeAst.BinaryOpExpr) -> void:
		visit(e.left_expr)
		visit(e.right_expr)
	func on_visit_and_expr(e:StopeAst.BinaryOpExpr) -> void:
		visit(e.left_expr)
		visit(e.right_expr)
	func on_visit_call_expr(e:StopeAst.CallExpr) -> void:
		visit(e.callee)
		for a in e.args: visit(a)
	func on_visit_at_expr(e:StopeAst.AtExpr) -> void:
		visit(e.container)
		for k in e.key_exprs: visit(k)
	func on_visit_custom_opcode_expr(e:StopeAst.CustomOpcodeExpr) -> void:
		for a in e.args: visit(a)
