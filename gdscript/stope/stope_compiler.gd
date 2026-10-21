class_name StopeCompiler
# 编译器：把 AST 编译成 Program（指令流 + 常量池 + 变量表）。
# 逐行端口 cpp/stope/compiler.hpp（C++ 为权威实现，2026-10-18 重写）。
#
# 【指令流的形状】Program.opcodes 是 int 数组，指令与操作数混在同一个序列里。
# 带操作数的指令：
#   PushInt / PushFloat / PushString / PushBinArr / PushId —— 常量池或变量表的索引
#   Call / At                                             —— 参数个数
#   If / GoTo                                             —— 跳转目标（opcodes 下标）
#   Return                                                —— 返回值个数
#   custom                                                —— 变长参数时多一个参数个数
# 其余指令无操作数（见 Stope.has_a_param）。
#
# 【为什么不抽一层 ASTVisitor】C++ 侧把遍历骨架抽到 ast_visitor.hpp 是为了将来写解释器。
# GDScript 侧没有这个需求，且 GD 的虚函数派发写起来笨重，所以这里用一张
# NodeType -> Callable 的字典（等价于 C++ 的 ASTVisitor::visitMap），语义动作直接写在
# 各 visit 函数里，结构与 C++ 的 onVisitXxx 一一对应，便于两边对照。

enum Result { Success, Error, UnknownError, DuplicateWithBuiltinOpcode }

class Compiler:
	var prog:Stope.Program			# 正在写入的 Program，不拥有
	var custom_insts:Dictionary[String,Stope.CustomInst] = {}
	var errors:Array[String] = []
	var _fns:Dictionary = {}		# NodeType -> Callable，等价于 C++ 的 visitMap

	var var_alloc:VariableAllocator
	var stack_size_mgr:StackSizeManager
	var scope_stack:Array[Scope] = []
	var cur_line:int = -1			# 由 visit() 更新，没有专属行号的错误用它

	func _init() -> void:
		_register_visit_fns()

	# ---------------- 对外接口 ----------------
	# 编译 ast，结果直接写进 out。有错误时返回 Result.Error 并把 out 复原为空 ——
	# 半成品 Program 跑不了，留着反而误导。
	func compile(ast:StopeAst.Prog, out:Stope.Program,
			cis:Array[Stope.CustomInst] = []) -> int:
		_reset(out, cis)
		visit(ast)
		if not errors.is_empty():
			_clear_output()
			return Result.Error
		out.variable_num = var_alloc.num()
		out.required_stack_size = stack_size_mgr.max_size
		return Result.Success

	func set_custom_insts(cis:Array[Stope.CustomInst]) -> Array[String]:
		var errs:Array[String] = []
		for ci in cis:
			if ci.code <= Stope.Inst.Return:
				errs.append(str("inst \"",ci.name,"\": custom inst code must be greater than ",
					Stope.Inst.Return,". "))
				continue
			if ci.name in StopeToken.key_words:
				errs.append(str("inst \"",ci.name,"\": is a duplicate of keyword \"",ci.name,"\". "))
				continue
			if (not ci.variable_arg) and ci.arg_num < 0:
				errs.append(str("inst \"",ci.name,"\": arg num must not be less than 0. "))
				continue
			custom_insts[ci.name] = ci
		return errs

	# ---------------- 遍历骨架 ----------------
	func visit(n) -> void:
		if n == null: return
		cur_line = n.line
		# Node / Stmt / Expr 三个裸基类没有表项 -> 跳过（只在错误恢复路径上出现）
		if _fns.has(n.node_type): _fns[n.node_type].call(n)

	func _register_visit_fns() -> void:
		var NT := StopeAst.NodeType
		_fns[NT.Prog] = on_visit_prog
		_fns[NT.ExprStmt] = on_visit_expr_stmt
		_fns[NT.LetStmt] = on_visit_let_stmt
		_fns[NT.ReturnStmt] = on_visit_return_stmt
		_fns[NT.ExportStmt] = on_visit_export_stmt
		_fns[NT.BlockStmt] = on_visit_block_stmt
		_fns[NT.IfStmt] = on_visit_if_stmt
		_fns[NT.WhileStmt] = on_visit_while_stmt
		_fns[NT.AssignStmt] = on_visit_assign_stmt
		_fns[NT.BreakStmt] = on_visit_break_stmt
		_fns[NT.ContinueStmt] = on_visit_continue_stmt
		_fns[NT.NullExpr] = on_visit_null_expr
		_fns[NT.BoolExpr] = on_visit_bool_expr
		_fns[NT.IntExpr] = on_visit_int_expr
		_fns[NT.FloatExpr] = on_visit_float_expr
		_fns[NT.BinArrExpr] = on_visit_bin_arr_expr
		_fns[NT.StringExpr] = on_visit_string_expr
		_fns[NT.IdentExpr] = on_visit_ident_expr
		_fns[NT.ArgcExpr] = on_visit_argc_expr
		_fns[NT.ArgsExpr] = on_visit_args_expr
		_fns[NT.UnaryOpExpr] = on_visit_unary_op_expr
		_fns[NT.BinaryOpExpr] = on_visit_binary_op_expr
		_fns[NT.CallExpr] = on_visit_call_expr
		_fns[NT.AtExpr] = on_visit_at_expr
		_fns[NT.CustomOpcodeExpr] = on_visit_custom_opcode_expr

	func _reset(out:Stope.Program, cis:Array[Stope.CustomInst]) -> void:
		errors = []
		var_alloc = VariableAllocator.new()
		stack_size_mgr = StackSizeManager.new()
		scope_stack = []
		cur_line = -1
		prog = out
		set_custom_insts(cis)
		_clear_output()
		var file := FileScope.new()
		scope_stack.append(file)

	func _clear_output() -> void:
		prog.opcodes.clear()
		prog.int_consts.clear()
		prog.float_consts.clear()
		prog.bin_arr_consts.clear()
		prog.string_consts.clear()
		prog.exports.clear()
		prog.variable_num = 0
		prog.max_return_num = 0
		prog.required_stack_size = 0

	# ---------------- 指令输出 ----------------
	func _code_size() -> int: return len(prog.opcodes)
	func _emit_op(op:int) -> void:
		prog.opcodes.append(op)
	# 写一个操作数（索引 / 跳转目标）。超出 int16 要报错，否则回绕出来的跳转目标
	# 会把 VM 带飞。
	func _emit_index(idx:int) -> void:
		if idx < -32768 or idx > 32767:
			error(cur_line, "compile output too large: index exceeds int16. ")
			idx = 0
		prog.opcodes.append(idx)
	func _emit_placeholder() -> int:	# 占位：先写 -1，回填时才知道目标
		prog.opcodes.append(-1)
		return _code_size() - 1
	func _patch_index(pos:int, target:int) -> void:
		if target < -32768 or target > 32767:
			error(cur_line, "compile output too large: jump target exceeds int16. ")
			target = 0
		prog.opcodes[pos] = target

	# 常量入池：相同的值只存一份，返回索引。直接写 Program 里那个池子，
	# 不给编译器再留一份副本（旧版的 ConstantManager 是第三份状态）。
	func _const_index(pool:Array, v) -> int:
		var i:int = pool.find(v)
		if i >= 0: return i
		pool.append(v)
		return len(pool) - 1

	func error(line:int, msg:String) -> void:
		errors.append(str("line ", line, ": ", msg))

	# ---------------- 作用域 ----------------
	func _push_block_scope() -> BlockScope:
		var s := BlockScope.new()
		scope_stack.append(s)
		return s
	func _push_while_scope() -> WhileScope:
		var s := WhileScope.new()
		scope_stack.append(s)
		return s
	func _pop_scope() -> void: scope_stack.pop_back()
	# 由内向外找最近的名字作用域（FileScope 也算，它继承 BlockScope）
	func _top_block_scope() -> BlockScope:
		for i in range(len(scope_stack) - 1, -1, -1):
			var s:Scope = scope_stack[i]
			if s is BlockScope: return s
		return null
	func _top_while_scope() -> WhileScope:
		for i in range(len(scope_stack) - 1, -1, -1):
			var s:Scope = scope_stack[i]
			if s is WhileScope: return s
		return null
	func _find_ident_host(name:String) -> BlockScope:
		for i in range(len(scope_stack) - 1, -1, -1):
			var s:Scope = scope_stack[i]
			if s is BlockScope and (name in s.id_map): return s
		return null
	func _file_scope() -> FileScope: return scope_stack.front()

	# ---------------- 语句 ----------------
	func on_visit_prog(p:StopeAst.Prog) -> void:
		for s in p.stmts: visit(s)
	func on_visit_expr_stmt(s:StopeAst.ExprStmt) -> void:
		visit(s.expr)
		_emit_op(Stope.Inst.Pop); stack_size_mgr.dec()
	func on_visit_let_stmt(s:StopeAst.LetStmt) -> void:
		var bs:BlockScope = _top_block_scope()
		if bs == null: return
		if s.has_assign:	# let a = expr; —— 只有一个标识符
			if s.idents.is_empty(): return
			var name:String = s.idents[0]
			if name in bs.id_map:
				error(s.line, str("duplicate declaration of '", name, "'. "))
				return
			# 不要 visit 标识符本身（那会生成 PushId 取值），这里是要绑定到新变量
			var idx:int = var_alloc.new_var()
			bs.id_map[name] = idx
			_emit_op(Stope.Inst.PushId); _emit_index(idx); stack_size_mgr.inc()
			visit(s.expr)
			_emit_op(Stope.Inst.Assign); stack_size_mgr.dec(2)
		else:
			for nm in s.idents:
				if nm in bs.id_map:
					error(s.line, str("duplicate declaration of '", nm, "'. "))
					continue
				bs.id_map[nm] = var_alloc.new_var()
	func on_visit_return_stmt(s:StopeAst.ReturnStmt) -> void:
		for e in s.exprs: visit(e)
		_emit_op(Stope.Inst.Return); _emit_index(len(s.exprs))
		prog.max_return_num = maxi(prog.max_return_num, len(s.exprs))
		# Return 会让 VM 直接跳到 code 末尾，栈上的返回值不回收
	func on_visit_export_stmt(s:StopeAst.ExportStmt) -> void:
		if len(scope_stack) > 1:
			error(s.line, '"export" can only be used at top scope. ')
		var fs:FileScope = _file_scope()
		for id in s.idents:
			if id in fs.id_map:
				error(s.line, str('duplicate export of "', id, '". '))
				continue
			_declare_exported(id, var_alloc.new_unique_var(id))
	func on_visit_block_stmt(s:StopeAst.BlockStmt) -> void:
		var bs:BlockScope = _push_block_scope()
		visit(s.prog)
		_pop_scope()
		for idx in bs.id_map.values(): var_alloc.free_var(int(idx))	# 回收局部变量索引
	func on_visit_if_stmt(s:StopeAst.IfStmt) -> void:
		if s.cond == null: return
		var goto_end_indices:Array[int] = []
		visit(s.cond)
		_emit_op(Stope.Inst.If); stack_size_mgr.dec()
		var last_if_pos:int = _emit_placeholder()	# 条件为假时跳到这里
		_visit_body_as_block(s.first_prog)
		_emit_op(Stope.Inst.GoTo)					# 分支走完，跳出整个 if
		goto_end_indices.append(_emit_placeholder())
		_patch_index(last_if_pos, _code_size())
		for ei in s.elifs:
			if ei.cond == null: continue
			visit(ei.cond)
			_emit_op(Stope.Inst.If); stack_size_mgr.dec()
			last_if_pos = _emit_placeholder()
			_visit_body_as_block(ei.prog)
			_emit_op(Stope.Inst.GoTo)
			goto_end_indices.append(_emit_placeholder())
			_patch_index(last_if_pos, _code_size())
		if s.else_prog != null: _visit_body_as_block(s.else_prog)
		for pos in goto_end_indices: _patch_index(pos, _code_size())
	func on_visit_while_stmt(s:StopeAst.WhileStmt) -> void:
		var ws:WhileScope = _push_while_scope()
		ws.start_index = _code_size()	# continue 回到这里
		var case_goto_end_pos:int = -1
		if s.cond != null:				# while cond { } —— cond 可省
			visit(s.cond)
			_emit_op(Stope.Inst.If); stack_size_mgr.dec()
			case_goto_end_pos = _emit_placeholder()
		_visit_body_as_block(s.prog)
		_emit_op(Stope.Inst.GoTo); _emit_index(ws.start_index)
		for pos in ws.break_indices: _patch_index(pos, _code_size())
		# [纠正 4] 条件可省。无条件时必须跳过回填，否则会把第 0 条指令改成跳转目标。
		if case_goto_end_pos >= 0: _patch_index(case_goto_end_pos, _code_size())
		_pop_scope()
	func on_visit_assign_stmt(s:StopeAst.AssignStmt) -> void:
		visit(s.left_expr)	# 左值必须是 PushId / At 之类能接赋值的位置
		visit(s.right_expr)
		_emit_op(Stope.Inst.Assign); stack_size_mgr.dec(2)
	func on_visit_break_stmt(s:StopeAst.BreakStmt) -> void:
		var ws:WhileScope = _top_while_scope()
		if ws == null:
			error(s.line, 'cannot use "break" outside of a loop. ')
			return
		_emit_op(Stope.Inst.GoTo)
		ws.break_indices.append(_emit_placeholder())
	func on_visit_continue_stmt(s:StopeAst.ContinueStmt) -> void:
		var ws:WhileScope = _top_while_scope()
		if ws == null:
			error(s.line, 'cannot use "continue" outside of a loop. ')
			return
		_emit_op(Stope.Inst.GoTo); _emit_index(ws.start_index)

	# ---------------- 表达式 ----------------
	# NullExpr / ArgcExpr 没有子节点，但签名保持一致以便统一 call(n)
	func on_visit_null_expr(_n=null) -> void:
		_emit_op(Stope.Inst.PushNull); stack_size_mgr.inc()
	func on_visit_bool_expr(e:StopeAst.BoolExpr) -> void:
		_emit_op(Stope.Inst.PushTrue if e.value else Stope.Inst.PushFalse)
		stack_size_mgr.inc()
	func on_visit_int_expr(e:StopeAst.IntExpr) -> void:
		_emit_op(Stope.Inst.PushInt); _emit_index(_const_index(prog.int_consts, e.value))
		stack_size_mgr.inc()
	func on_visit_float_expr(e:StopeAst.FloatExpr) -> void:
		_emit_op(Stope.Inst.PushFloat); _emit_index(_const_index(prog.float_consts, e.value))
		stack_size_mgr.inc()
	func on_visit_string_expr(e:StopeAst.StringExpr) -> void:
		_emit_op(Stope.Inst.PushString)
		_emit_index(_const_index(prog.string_consts, e.value))
		stack_size_mgr.inc()
	func on_visit_bin_arr_expr(e:StopeAst.BinArrExpr) -> void:	# 旧版没有这个类型
		_emit_op(Stope.Inst.PushBinArr)
		_emit_index(_const_index(prog.bin_arr_consts, e.value))
		stack_size_mgr.inc()
	func on_visit_ident_expr(e:StopeAst.IdentExpr) -> void:
		var host:BlockScope = _find_ident_host(e.ident)
		var idx:int = 0
		if host != null: idx = host.id_map[e.ident]
		else:
			# 未声明就使用：当作外部变量，登记到文件作用域。
			# 名字非空 -> 会出现在 Program.exports 里。
			_declare_exported(e.ident, var_alloc.new_unique_var(e.ident))
			idx = _file_scope().id_map[e.ident]
		_emit_op(Stope.Inst.PushId)	# 压的是变量本身，不是值，否则无法赋值
		_emit_index(idx)
		stack_size_mgr.inc()
	func on_visit_argc_expr(_n=null) -> void:
		_emit_op(Stope.Inst.ArgNum); stack_size_mgr.inc()
	func on_visit_args_expr(e:StopeAst.ArgsExpr) -> void:
		visit(e.key_expr)
		_emit_op(Stope.Inst.GetArg)	# 弹下标、压结果，栈大小不变
	func on_visit_unary_op_expr(e:StopeAst.UnaryOpExpr) -> void:
		visit(e.expr)
		if e.op == StopeToken.Type.Not: _emit_op(Stope.Inst.Not)
		elif e.op == StopeToken.Type.Sub: _emit_op(Stope.Inst.Minus)
		# 一元指令：弹 1 压 1，栈大小不变
	func on_visit_binary_op_expr(e:StopeAst.BinaryOpExpr) -> void:
		if e.op == StopeToken.Type.Or:
			_on_visit_or_expr(e); return
		if e.op == StopeToken.Type.And:
			_on_visit_and_expr(e); return
		visit(e.left_expr); visit(e.right_expr)
		_emit_op(_binary_opcode(e.op))
		stack_size_mgr.dec()	# 弹 2 压 1
	# 短路或：任一侧为真就 PushTrue，两条路径都在栈上留下恰好 1 个结果。
	# [纠正 2] 这里对 PushTrue / PushFalse 记账，且末尾不 dec。
	func _on_visit_or_expr(e:StopeAst.BinaryOpExpr) -> void:
		visit(e.left_expr)
		_emit_op(Stope.Inst.If); stack_size_mgr.dec()
		var first_if_pos:int = _emit_placeholder()
		var depth_at_if_target:int = stack_size_mgr.size	# If 已弹掉条件 = 汇合点深度
		_emit_op(Stope.Inst.PushTrue); stack_size_mgr.inc()
		_emit_op(Stope.Inst.GoTo); var goto_end1:int = _emit_placeholder()
		_patch_index(first_if_pos, _code_size())
		stack_size_mgr.converge(depth_at_if_target)	# 后面接的是「左侧为假」这条路径

		visit(e.right_expr)
		_emit_op(Stope.Inst.If); stack_size_mgr.dec()
		var second_if_pos:int = _emit_placeholder()
		depth_at_if_target = stack_size_mgr.size
		_emit_op(Stope.Inst.PushTrue); stack_size_mgr.inc()
		_emit_op(Stope.Inst.GoTo); var goto_end2:int = _emit_placeholder()
		_patch_index(second_if_pos, _code_size())
		stack_size_mgr.converge(depth_at_if_target)

		_emit_op(Stope.Inst.PushFalse)	# 两侧都不成立
		stack_size_mgr.inc()
		_patch_index(goto_end1, _code_size())
		_patch_index(goto_end2, _code_size())
	func _on_visit_and_expr(e:StopeAst.BinaryOpExpr) -> void:
		visit(e.left_expr)
		_emit_op(Stope.Inst.If); stack_size_mgr.dec()
		var first_if_pos:int = _emit_placeholder()
		visit(e.right_expr)
		_emit_op(Stope.Inst.If); stack_size_mgr.dec()
		var second_if_pos:int = _emit_placeholder()
		var depth_at_if_target:int = stack_size_mgr.size		# 两侧都为真才落到这里
		_emit_op(Stope.Inst.PushTrue); stack_size_mgr.inc()
		_emit_op(Stope.Inst.GoTo); var goto_end:int = _emit_placeholder()
		_patch_index(first_if_pos, _code_size())
		_patch_index(second_if_pos, _code_size())
		stack_size_mgr.converge(depth_at_if_target)
		_emit_op(Stope.Inst.PushFalse); stack_size_mgr.inc()
		_patch_index(goto_end, _code_size())
	func on_visit_call_expr(e:StopeAst.CallExpr) -> void:
		visit(e.callee)
		for a in e.args: visit(a)
		_emit_op(Stope.Inst.Call); _emit_index(len(e.args))
		stack_size_mgr.dec(len(e.args))		# callee + args 换成 1 个返回值
	func on_visit_at_expr(e:StopeAst.AtExpr) -> void:
		visit(e.container)
		for k in e.key_exprs: visit(k)
		_emit_op(Stope.Inst.At); _emit_index(len(e.key_exprs))
		stack_size_mgr.dec(len(e.key_exprs))
	func on_visit_custom_opcode_expr(e:StopeAst.CustomOpcodeExpr) -> void:
		if not (e.opcode_name in custom_insts):
			error(e.line, str('undefined custom instruction "', e.opcode_name, '". '))
			return
		var info:Stope.CustomInst = custom_insts[e.opcode_name]
		if (not info.variable_arg) and info.arg_num != len(e.args):
			error(e.line, str('custom instruction "', info.name, '" expected ', info.arg_num,
				' args, but got ', len(e.args), '. '))
		for a in e.args: visit(a)
		_emit_op(info.code)
		if info.variable_arg: _emit_index(len(e.args))
		# [纠正 3] 自定义指令没有 callee 入栈，结果仍占 1 格 ⇒ dec(参数个数 - 1)
		stack_size_mgr.dec(len(e.args) - 1)

	# ---------------- 小工具 ----------------
	# 登记一个会进 Program.exports 的变量。索引来自 new_unique_var（不回收）。
	func _declare_exported(name:String, idx:int) -> void:
		_file_scope().id_map[name] = idx
		prog.exports[name] = idx
	# 块 / if 分支 / 循环体在 AST 里都是裸 Prog（没有 BlockStmt 包着），
	# 这里补一层 BlockScope，让内部 let 的变量在离开时被回收。
	func _visit_body_as_block(p:StopeAst.Prog) -> void:
		var bs:BlockScope = _push_block_scope()
		visit(p)
		_pop_scope()
		for idx in bs.id_map.values(): var_alloc.free_var(int(idx))
	# 二元运算符 -> 指令。注意二元 `-` 是 Sub 而不是 Minus（[纠正 1]）
	static func _binary_opcode(op:int) -> int:
		var T := StopeToken.Type
		if op == T.EQ: return Stope.Inst.EQ
		if op == T.NE: return Stope.Inst.NE
		if op == T.LT: return Stope.Inst.LT
		if op == T.LE: return Stope.Inst.LE
		if op == T.GT: return Stope.Inst.GT
		if op == T.GE: return Stope.Inst.GE
		if op == T.Add: return Stope.Inst.Add
		if op == T.Sub: return Stope.Inst.Sub
		if op == T.Mul: return Stope.Inst.Mul
		if op == T.Div: return Stope.Inst.Div
		if op == T.IDiv: return Stope.Inst.IDiv
		if op == T.Mod: return Stope.Inst.Mod
		if op == T.Pow: return Stope.Inst.Pow
		return Stope.Inst.Pop	# 到不了：parser 只会用上面这些 op 构造 BinaryOpExpr

# ====================================================================
class Scope:
	var type:String = 'scope'	# 'file' / 'block' / 'while'

# 名字作用域：标识符 -> 变量总表中的索引
class BlockScope extends Scope:
	var id_map:Dictionary[String,int]
	func _init() -> void: type = 'block'; id_map = {}

# 文件作用域。export 与「未声明就使用的标识符」都落到这里。
class FileScope extends BlockScope:
	func _init() -> void: type = 'file'; id_map = {}

# 循环作用域：不参与名字查找（_find_ident_host 只认 BlockScope）
class WhileScope extends Scope:
	var start_index:int = 0				# continue 跳回这里（循环开头）
	var break_indices:Array[int] = []	# 待回填的 break 跳转目标（code 中的操作数位置）
	func _init() -> void: type = 'while'

# 变量分配器：所有变量统一编号；块结束时索引进入回收堆复用。
# new_unique_var 不参与回收 —— 它给 export 与「未声明就使用的标识符」用，
# 变量名非空正是 Program.exports 的判据。
class VariableAllocator:
	var vars:Array[String] = []
	var recycled:MinHeap = MinHeap.new()
	func num() -> int: return len(vars)
	func new_var(name:String = '') -> int:
		if not recycled.is_empty():
			var idx:int = recycled.pop()
			vars[idx] = name
			return idx
		var i:int = len(vars)
		vars.append(name)
		return i
	func new_unique_var(name:String) -> int:
		var i:int = len(vars)
		vars.append(name)	# 不回收：导出变量必须一直占着一个位置
		return i
	func free_var(idx:int) -> void:
		if recycled.has(idx): return	# 同一索引不重复回收
		recycled.push(idx)

# 只记「相对变化」，最大值最后落到 Program.required_stack_size。
# 记账是**线性**的（按 emit 顺序走一遍），遇到分支就得手动「掰回去」——见 converge()。
class StackSizeManager:
	var size:int = 0
	var max_size:int = 0
	func inc(n:int = 1) -> void:
		size += n
		max_size = maxi(size, max_size)
	func dec(n:int = 1) -> void: size -= n
	# 分支汇合。线性记账只能沿一条路径走，所以某条路径被 GoTo 送走以后，
	# 要把 size 扳回到「从别处跳到这里」时应有的深度，否则 if / 短路运算符
	# 会把容量算成各分支深度之和（实测 `a or b;` 会算成 3）。
	func converge(depth:int) -> void: size = depth

class MinHeap:
	var data:Array[int] = [0]	# 1 起算，方便算父子下标
	var count:int = 0

	func is_empty() -> bool: return count == 0
	func push(v:int) -> void:
		data.append(v); count += 1
		_prec_up(count)
	func pop() -> int:
		var o:int = data[1]
		data[1] = data[count]; data.pop_back(); count -= 1
		_prec_down(1)
		return o
	func has(v:int) -> bool:	# 只看有效区间，跳过下标 0 的哨兵
		return data.slice(1, count + 1).has(v)
	func _min_child_id(i:int) -> int:
		var l:int = i * 2; var r:int = l + 1
		if r > count: return l
		if data[l] < data[r]: return l
		return r
	func _swap(a:int, b:int) -> void:
		var t:int = data[a]; data[a] = data[b]; data[b] = t
	func _prec_up(i:int) -> void:
		var now:int = i; var next:int = i / 2
		while next > 0:
			if data[now] < data[next]: _swap(now, next)
			now = next; next = next / 2
	func _prec_down(i:int) -> void:
		while i * 2 < count:
			var c:int = _min_child_id(i)
			if data[i] > data[c]: _swap(i, c)
			i = c
