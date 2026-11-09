class_name StopeCompiler
# 编译器：把 AST 编译成 Program（指令流 + 常量池 + 变量表）。
# 逐行端口 cpp/stope/compiler.hpp（C++ 为权威实现，2026-10-18 重写）。
#
# 【指令流的形状】Program.opcodes 是 int 数组，指令与操作数混在同一个序列里。
# 带操作数的指令：
#   PushInt / PushFloat / PushString / PushBinArr / PushValue / PushId
#                                              —— 常量池或变量表的索引
#   Call / At                                             —— 参数个数
#   If / GoTo                                             —— 跳转目标（opcodes 下标）
#   Return                                                —— 返回值个数
#   custom                                                —— 变长参数时多一个参数个数
# 其余指令无操作数（见 StopeOpcode.has_a_param）。
#
# 【PushValue 与 PushId 的分工】PushId 压的是槽位引用（左值），只有两处产生：
#   「有赋值的 let」左侧、Assign 左端是裸标识符时。其余读变量一律 PushValue（压值）。
#   所以执行器【不需要】在运算指令里做解引用兜底 —— 那样只会掩盖编译器的产物错误。
#
# 【遍历骨架】继承 StopeAstVisitor.ASTVisitor（对齐 C++：ASTVisitor + visitMap），
# 语义动作全在 on_visit_xxx 里。基类的默认实现只是「按源码顺序递归子节点」，
# 这里凡是需要发指令的一律整段重写（不再 down 到 super），其余靠基类递归。
# cur_line 由基类的 visit() 维护，没有专属行号的错误就用它。

const TokenType = StopeLexer.Token.Type
const Opcode = StopeOpcode.Opcode

class Compiler extends StopeASTVisitor.ASTVisitor:
	var prog:StopeProgram.Program			# 正在写入的 Program，不拥有
	var custom_opcodes:StopeOpcode.CustomOpcodeConfig	# 可空，只读（不拥有）
	var errors:Array[String] = []

	var var_alloc:VariableAllocator
	var stack_size_mgr:StackSizeManager
	var scope_stack:Array[Scope] = []

	# 全局声明序号：declare_local 与 declare_exported（非隐式导出）时递增。
	# defer 的「冻结名字绑定」靠它判定：载荷解析到的本地名字若序号晚于 defer
	# 语句处的基线，视为不可见——不被捕获，按隐式导出宿主变量处理（OQ-8）。
	# 隐式导出记 -1 豁免。
	var decl_counter:int = 0
	# defer 载荷编译期状态：当前生效的声明序号基线（< 0 = 不在载荷里）与
	# 载荷编译期报错（duplicate export）的归责行号（defer 语句行）。
	var defer_order_floor:int = -1
	var defer_err_line:int = -1
	# 死代码消除：每条语句 visitor 维护的终止标志；进入语句前由语句序列循环清零。
	var stmt_terminates:bool = false
	# 最内层 while 的循环体里是否有本层 break（死循环判定用）；按 while 配对保存恢复。
	var saw_break:bool = false

	func _init(custom:StopeOpcode.CustomOpcodeConfig = null) -> void:
		custom_opcodes = custom

	# 与 C++ 的 Compiler::Reset 一致：清错误、换自定义指令表。
	func reset(custom:StopeOpcode.CustomOpcodeConfig = null) -> void:
		errors = []
		custom_opcodes = custom

	# ---------------- 对外接口 ----------------
	# 编译 ast，结果直接写进 out。有错误时返回 StopeResult.Error 并把 out 复原为空 ——
	# 半成品 Program 跑不了，留着反而误导。
	# pre_exports：遍历 AST 之前先导出的标识符（宿主注入的全局）。每个名字按给定顺序
	# 占一个「永不回收」的槽位，所以源码里所有变量的编号整体后移；名字进了文件作用域，
	# 源码里再 export 同名、或顶层 let 同名，都会报 duplicate —— 预导出的变量只能赋值。
	# 空名字与重名都是编译错误（行号记 0：这些名字不来自源码）。
	func compile(ast:StopeAst.Prog, out:StopeProgram.Program,
			pre_exports:Array = []) -> int:
		_reset(out)
		_export_pre_exports(pre_exports)
		visit(ast)
		# 顶层 defer：程序尾结算。程序以终止语句（return / 死循环等）结尾时
		# 这里不可达（return 出口已在 on_visit_return_stmt 结算过），再拼就是
		# Return 之后的死代码——跳过；自然结束（fall-through）才需要这份结算。
		if not stmt_terminates: _splice_defers(_file_scope())
		_file_scope().defers.clear()	# 最终结算：途中出口（return）已各拼过副本
		if not errors.is_empty():
			_clear_output()
			return StopeResult.Error
		out.variable_num = var_alloc.num()
		out.required_stack_size = stack_size_mgr.max_size
		return StopeResult.Success

	# ---------------- 遍历骨架 ----------------
	# visit() / visit_map 都在基类 StopeAstVisitor.ASTVisitor 里，这里只重写钩子。
	func _reset(out:StopeProgram.Program) -> void:
		errors = []
		var_alloc = VariableAllocator.new()
		stack_size_mgr = StackSizeManager.new()
		scope_stack = []
		decl_counter = 0
		defer_order_floor = -1
		defer_err_line = -1
		stmt_terminates = false
		saw_break = false
		cur_line = -1
		prog = out
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
	func _find_ident_host(name:String) -> BlockScope:
		for i in range(len(scope_stack) - 1, -1, -1):
			var s:Scope = scope_stack[i]
			if s is BlockScope and (name in s.id_map): return s
		return null
	# 冻结名字绑定：defer 载荷里找名字宿主时用（floor = defer 登记时的声明序号基线）。
	# 最内层载荷根以内（栈中更靠内）不过滤；以外跳过「声明序号 >= floor」的本地名
	# （defer 之后才声明 / 遮蔽的）。与 cpp/src/compiler.cpp 的 findIdentHostFrozen 一致。
	func _find_ident_host_frozen(name:String, floor:int) -> BlockScope:
		# 最内层载荷根：它以内是载荷自己的内部作用域，名字解析不过滤
		var payload_idx:int = -1
		for i in range(len(scope_stack) - 1, -1, -1):
			var s:Scope = scope_stack[i]
			if s is BlockScope and s.is_defer_payload:
				payload_idx = i
				break
		for i in range(len(scope_stack) - 1, -1, -1):
			var s:Scope = scope_stack[i]
			if not (s is BlockScope): continue
			if not (name in s.id_map): continue
			if i < payload_idx:	# 登记 scope 一侧：跳过 defer 之后才声明的（遮蔽）
				# 基线 = 登记时的 decl_counter（= 下一个待分配序号），所以
				# 「order >= 基线」⟺ 在 defer 之后声明。隐式导出记 -1，豁免。
				if s.id_order.has(name):
					var o:int = s.id_order[name]
					if o >= 0 and o >= floor: continue
			return s
		return null
	# defer 载荷编译期的名字解析：冻结规则优先。未命中 → 不再查 now、不再报
	# declared after（OQ-8，2026-11-08 定夺：后文声明的本地名不被捕获，按隐式
	# 导出宿主变量处理，同未声明名字的路径）。FileScope 已有同名（后文顶层
	# let / export 声明的文件级变量）时无法再建同名宿主变量，报重复——行号归
	# defer 语句（冲突在 defer 绑定符号时就已注定；若 defer 先于顶层声明结算，
	# 则由后文 declare_local 报 duplicate declaration，两处报错互斥）。返回
	# FileScope：编译已失败，避免连锁隐式导出。都空 → 返回 null，调用方走
	# 隐式导出路径（新建宿主变量）。与 cpp/src/compiler.cpp 的 resolveAtSplice 一致。
	func _resolve_at_splice(name:String) -> BlockScope:
		var frozen:BlockScope = _find_ident_host_frozen(name, defer_order_floor)
		if frozen != null: return frozen
		var fs:FileScope = _file_scope()
		if name in fs.id_map:
			error(defer_err_line, str('duplicate export of "', name, '". '))
			return fs	# 编译已失败；返回宿主避免连锁隐式导出
		return null
	func _file_scope() -> FileScope: return scope_stack.front()

	# ---------------- 语句 ----------------
	# 语句序列（顶层 Prog / 块体 / if 分支 / while 体共用）：终止语句（return /
	# break / continue / 死循环）之后的语句在语言语义下执行不到——不再发射，也
	# 不登记它们的 defer（死代码消除）。序列的终止性 = 最后一条已发射语句。
	func on_visit_prog(p:StopeAst.Prog) -> void:
		var terminated := false
		for s in p.stmts:
			if terminated: break
			stmt_terminates = false	# 每条语句先清零；终止语句的 visitor 置 true
			visit(s)
			terminated = stmt_terminates
		stmt_terminates = terminated
	func on_visit_expr_stmt(s:StopeAst.ExprStmt) -> void:
		visit(s.expr)
		_emit_op(Opcode.Pop); stack_size_mgr.dec()
	func on_visit_let_stmt(s:StopeAst.LetStmt) -> void:
		var bs:BlockScope = _top_block_scope()
		if bs == null: return
		if s.has_assign:	# let a = expr; —— 只有一个标识符
			if s.idents.is_empty(): return
			var name:String = s.idents[0]
			if name in bs.id_map:
				error(s.line, str("duplicate declaration of '", name, "'. "))
				return
			# 不要 visit 标识符本身（那会生成 PushValue 取值），这里是要绑定到新变量
			var idx:int = var_alloc.new_var()
			_declare_local(bs, name, idx)
			_emit_op(Opcode.PushId); _emit_index(idx); stack_size_mgr.inc()
			visit(s.expr)
			_emit_op(Opcode.Assign); stack_size_mgr.dec(2)
		else:
			for nm in s.idents:
				if nm in bs.id_map:
					error(s.line, str("duplicate declaration of '", nm, "'. "))
					continue
				_declare_local(bs, nm, var_alloc.new_var())
	func on_visit_return_stmt(s:StopeAst.ReturnStmt) -> void:
		# defer 边界：return 的终点是整个程序，在载荷内必然越界，一律报错。
		for sc in scope_stack:
			if sc is BlockScope and sc.is_defer_payload:
				error(s.line, '"return" cannot be used in a defer statement. ')
				return
		# 顺序：先结算，再求返回值，最后 Return（结算 → PushValue → Return）。
		# 结算先于退出动作，与块退出一致——defer 可以影响返回值。
		for i in range(len(scope_stack) - 1, -1, -1):
			var sc:Scope = scope_stack[i]
			if sc is BlockScope: _splice_defers(sc)
		for e in s.exprs: visit(e)
		_emit_op(Opcode.Return); _emit_index(len(s.exprs))
		prog.max_return_num = maxi(prog.max_return_num, len(s.exprs))
		stmt_terminates = true
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
		# 块尾结算：本 scope 的 defer 在这里执行（LIFO）。块体以终止语句结尾时
		# 这里不可达（return 出口已结算、break/continue 出口就地结算过）——
		# 跳过，避免拼出不可达的副本。
		if not stmt_terminates: _splice_defers(bs)
		bs.defers.clear()	# 最终结算：途中出口（break/return）已各拼过副本
		_pop_scope()
		for idx in bs.id_map.values(): var_alloc.free_var(int(idx))	# 回收局部变量索引
	# OQ-2：条件是否为「解析期折叠后的字面量常量」（Null/Bool/Int/Float/String/
	# BinArr 六种）。truthy（expr_optim）是真值表的单一实现，这里只补常量判断。
	# 与 cpp/src/compiler.cpp 的 constCondTruth 一致（GDScript 无出参，拆成判断 +
	# truthy 两步调用）。
	func _is_const_cond(e) -> bool:
		return StopeExprOptim.is_const(StopeExprOptim.kind_of(e))

	func on_visit_if_stmt(s:StopeAst.IfStmt) -> void:
		if s.cond == null: return
		# OQ-2（2026-11-09 落地）：字面量条件折叠。条件是常量字面量时按真值表
		# 静态判定——常量真只发该分支（零条件、零跳转指令），常量假整支消除
		# （体不访问，其中的 defer 不登记，与死代码消除一致）；链上遇到非常量
		# 条件才走普通发射路径。常量真的分支体是链的最后一段发射——体走完
		# 就到链尾，不需要出口 GoTo。
		var goto_end_indices:Array[int] = []
		var pending_false:int = -1	# 上一个「条件为假」占位（-1 = 无）
		var all_bodies_terminate := true
		var any_body_emitted := false
		var fallthrough_resolved := false	# 「一路为假」的落空路径被 else / 常量真接住
		var chain_ended := false			# 常量真之后整条链不可达
		var branch_term:bool = false

		if _is_const_cond(s.cond):
			if StopeExprOptim.truthy(s.cond):	# 常量真：整条链只剩这一个分支体
				_visit_body_as_block(s.first_prog)
				all_bodies_terminate = all_bodies_terminate and stmt_terminates
				any_body_emitted = true
				fallthrough_resolved = true
				chain_ended = true
			# 常量假：跳过，看 elifs / else
		else:	# 非常量：普通发射
			visit(s.cond)
			_emit_op(Opcode.If); stack_size_mgr.dec()
			pending_false = _emit_placeholder()	# 条件为假时跳到这里
			_visit_body_as_block(s.first_prog)
			branch_term = stmt_terminates
			all_bodies_terminate = all_bodies_terminate and branch_term
			any_body_emitted = true
			if not branch_term:	# 分支走完会落到这里，需要跳出整个 if；终止则死代码
				_emit_op(Opcode.GoTo)
				goto_end_indices.append(_emit_placeholder())
		for ei in s.elifs:
			if chain_ended or ei.cond == null: continue
			if _is_const_cond(ei.cond):
				if StopeExprOptim.truthy(ei.cond):
					# 常量真：之前的假路径在这里进体，链到此为止
					if pending_false >= 0:
						_patch_index(pending_false, _code_size())
						pending_false = -1
					_visit_body_as_block(ei.prog)
					all_bodies_terminate = all_bodies_terminate and stmt_terminates
					any_body_emitted = true
					fallthrough_resolved = true
					chain_ended = true	# 其后的 elif / else 不可达
				# 常量假：跳过该分支（pending_false 留给下一个真分支 / else 回填）
				continue
			if pending_false >= 0:	# 假路径从上一个占位跳到本分支条件处
				_patch_index(pending_false, _code_size())
				pending_false = -1
			visit(ei.cond)
			_emit_op(Opcode.If); stack_size_mgr.dec()
			pending_false = _emit_placeholder()
			_visit_body_as_block(ei.prog)
			branch_term = stmt_terminates
			all_bodies_terminate = all_bodies_terminate and branch_term
			any_body_emitted = true
			if not branch_term:
				_emit_op(Opcode.GoTo)
				goto_end_indices.append(_emit_placeholder())
		if not chain_ended and s.else_prog != null:
			if pending_false >= 0:
				_patch_index(pending_false, _code_size())
				pending_false = -1
			_visit_body_as_block(s.else_prog)
			all_bodies_terminate = all_bodies_terminate and stmt_terminates
			any_body_emitted = true
			fallthrough_resolved = true
		if pending_false >= 0:	# 链以非常量条件结尾且无 else：假路径跳到链尾
			_patch_index(pending_false, _code_size())
		for pos in goto_end_indices: _patch_index(pos, _code_size())
		# if 语句的终止性：所有可达分支体终止，且「一路为假」的落空路径被
		# else / 常量真接住——否则那条路径直接落到 if 之后，不算终止。
		stmt_terminates = any_body_emitted and all_bodies_terminate and fallthrough_resolved
	func on_visit_while_stmt(s:StopeAst.WhileStmt) -> void:
		# OQ-2：常量条件折叠——常量真折叠为无条件循环（其后语句按真死循环
		# 消除），常量假整环消除（体不访问，其中的 defer 不登记）。
		var truth := false
		var cond_const := false
		if s.cond != null:
			cond_const = _is_const_cond(s.cond)
			if cond_const: truth = StopeExprOptim.truthy(s.cond)
		var eliminate:bool = cond_const and not truth

		var ws:WhileScope = _push_while_scope()
		ws.start_index = _code_size()	# continue 回到这里
		var case_goto_end_pos:int = -1
		if s.cond != null and not cond_const:	# 非常量条件才发射判断
			visit(s.cond)
			_emit_op(Opcode.If); stack_size_mgr.dec()
			case_goto_end_pos = _emit_placeholder()
		if eliminate:	# 常量假：体永不执行，整环消除（break/continue 无可达）
			stmt_terminates = false
			_pop_scope()
			return
		# saw_break 按 while 配对保存/恢复：嵌套循环里的 break 只算最内层的
		var saved_saw_break:bool = saw_break
		saw_break = false
		_visit_body_as_block(s.prog)
		var body_term:bool = stmt_terminates
		var body_saw_break:bool = saw_break
		saw_break = saved_saw_break
		if not body_term:	# 体终止（return/break/continue 收尾）则回跳是死代码
			_emit_op(Opcode.GoTo); _emit_index(ws.start_index)
		for pos in ws.break_indices: _patch_index(pos, _code_size())
		# [纠正 4] 条件可省。无条件（含折叠为真的常量条件）时必须跳过回填，
		# 否则会把第 0 条指令改成跳转目标。
		if case_goto_end_pos >= 0: _patch_index(case_goto_end_pos, _code_size())
		# while 的终止性：无条件（含折叠为真的常量条件，OQ-2）且体不含本层
		# break 的真死循环才永不退出。
		stmt_terminates = (s.cond == null or (cond_const and truth)) and not body_saw_break
		_pop_scope()
	func on_visit_assign_stmt(s:StopeAst.AssignStmt) -> void:
		if s.left_expr.node_type == StopeAst.NodeType.IdentExpr:
			# 赋值左端的裸标识符要压【槽位】而不是值，否则 Assign 无处可存。
			# 这条与 on_visit_ident_expr 的 PushValue 是一对：只有这里和
			# 「有赋值的 let」会产生 PushId。
			var e:StopeAst.IdentExpr = s.left_expr
			var idx:int = _ident_slot(e.ident)
			_emit_op(Opcode.PushId); _emit_index(idx); stack_size_mgr.inc()
		else:
			# 可能是使用者设计的数组元素引用、对象成员引用等。压入值。
			visit(s.left_expr)
		visit(s.right_expr)
		_emit_op(Opcode.Assign); stack_size_mgr.dec(2)
	func on_visit_break_stmt(s:StopeAst.BreakStmt) -> void:
		# 找最内层 WhileScope。途中先撞到 defer 载荷边界 = 目标循环在载荷外：
		# 载荷在退出点才执行，break 从收尾代码里跳回主流程是灾难语义，禁。
		var wi:int = -1
		for i in range(len(scope_stack) - 1, -1, -1):
			var sc:Scope = scope_stack[i]
			if sc is WhileScope:
				wi = i
				break
			if sc is BlockScope and sc.is_defer_payload:
				error(s.line, '"break" cannot cross a defer statement. ')
				return
		if wi < 0:
			error(s.line, 'cannot use "break" outside of a loop. ')
			return
		# 结算 break 越过的所有块：从最内层到循环体块（不含 WhileScope 本身、
		# 不含循环外的任何 scope）。运行时 break 直接跳循环尾，这些块的正常
		# 块尾拼接不会执行到，必须在跳转前就地结算。
		for i in range(len(scope_stack) - 1, wi, -1):
			if scope_stack[i] is BlockScope: _splice_defers(scope_stack[i])
		_emit_op(Opcode.GoTo)
		scope_stack[wi].break_indices.append(_emit_placeholder())
		saw_break = true	# 告知最内层 while：本层有 break（死循环判定用）
		stmt_terminates = true
	func on_visit_continue_stmt(s:StopeAst.ContinueStmt) -> void:
		# 同 break：continue 也退出循环体块，体块的 defer 必须先结算。
		var wi:int = -1
		for i in range(len(scope_stack) - 1, -1, -1):
			var sc:Scope = scope_stack[i]
			if sc is WhileScope:
				wi = i
				break
			if sc is BlockScope and sc.is_defer_payload:
				error(s.line, '"continue" cannot cross a defer statement. ')
				return
		if wi < 0:
			error(s.line, 'cannot use "continue" outside of a loop. ')
			return
		for i in range(len(scope_stack) - 1, wi, -1):
			if scope_stack[i] is BlockScope: _splice_defers(scope_stack[i])
		_emit_op(Opcode.GoTo); _emit_index(scope_stack[wi].start_index)
		stmt_terminates = true
	# defer：纯编译期登记，defer 语句位置零指令。载荷在退出点才编译（每个退出点
	# 各编译一次——If/GoTo 操作数是绝对下标，编译一次再拷贝会破坏跳转目标）。
	func on_visit_defer_stmt(s:StopeAst.DeferStmt) -> void:
		var bs:BlockScope = _top_block_scope()
		if bs == null: return	# 不可能：FileScope 常驻栈底
		var d := Deferred.new()
		d.stmt = s.stmt
		d.line = s.line
		d.order_baseline = decl_counter
		bs.defers.append(d)

	# ---------------- defer 拼接 ----------------
	# 对 bs 的 defers 逆序逐条编译载荷（LIFO）。⚠ 不清空 bs.defers：一个块可以
	# 有多个运行期出口（break / continue / return 各一处 + 块尾），每个出口都
	# 要拼一份自己的副本；只有块尾 / 程序尾的「最终结算」由调用方在拼接后清空。
	# 开头先检查：defers 为空或已有错误就直接返回（错误去重：载荷在每个退出点
	# 重编译，报一次就够）；载荷循环内报错即停，不再拼后续。
	func _splice_defers(bs:BlockScope) -> void:
		if bs.defers.is_empty() or not errors.is_empty(): return
		for k in range(len(bs.defers) - 1, -1, -1):
			if not errors.is_empty(): return
			var d:Deferred = bs.defers[k]
			var saved_floor:int = defer_order_floor
			var saved_line:int = defer_err_line
			defer_order_floor = d.order_baseline
			defer_err_line = d.line
			# 载荷包一层隐式作用域并打标记：break/continue/return 的越界检查
			# 靠它识别「从收尾代码里跳回主流程」。
			var ps:BlockScope = _push_block_scope()
			ps.is_defer_payload = true
			visit(d.stmt)
			# 载荷 scope 自己的 defers（直接嵌套 defer defer X 落在这里）：
			# 触发点 = 载荷 scope 结束 = 同一退出点，就地拼接。
			_splice_defers(ps)
			_pop_scope()
			for idx in ps.id_map.values(): var_alloc.free_var(int(idx))
			defer_order_floor = saved_floor
			defer_err_line = saved_line

	# ---------------- 表达式 ----------------
	# NullExpr / ArgcExpr 没有子节点，但签名保持一致以便统一 call(n)
	func on_visit_null_expr(_n=null) -> void:
		_emit_op(Opcode.PushNull); stack_size_mgr.inc()
	func on_visit_bool_expr(e:StopeAst.BoolExpr) -> void:
		_emit_op(Opcode.PushTrue if e.value else Opcode.PushFalse)
		stack_size_mgr.inc()
	func on_visit_int_expr(e:StopeAst.IntExpr) -> void:
		_emit_op(Opcode.PushInt); _emit_index(_const_index(prog.int_consts, e.value))
		stack_size_mgr.inc()
	func on_visit_float_expr(e:StopeAst.FloatExpr) -> void:
		_emit_op(Opcode.PushFloat); _emit_index(_const_index(prog.float_consts, e.value))
		stack_size_mgr.inc()
	func on_visit_string_expr(e:StopeAst.StringExpr) -> void:
		_emit_op(Opcode.PushString)
		_emit_index(_const_index(prog.string_consts, e.value))
		stack_size_mgr.inc()
	func on_visit_bin_arr_expr(e:StopeAst.BinArrExpr) -> void:	# 旧版没有这个类型
		_emit_op(Opcode.PushBinArr)
		_emit_index(_const_index(prog.bin_arr_consts, e.value))
		stack_size_mgr.inc()
	func on_visit_ident_expr(e:StopeAst.IdentExpr) -> void:
		var idx:int = _ident_slot(e.ident)
		_emit_op(Opcode.PushValue)	# 压的是变量的【值】；要槽位请用 PushId
		_emit_index(idx)
		stack_size_mgr.inc()
	func on_visit_argc_expr(_n=null) -> void:
		_emit_op(Opcode.ArgNum); stack_size_mgr.inc()
	func on_visit_args_expr(e:StopeAst.ArgsExpr) -> void:
		visit(e.key_expr)
		_emit_op(Opcode.GetArg)	# 弹下标、压结果，栈大小不变
	func on_visit_unary_op_expr(e:StopeAst.UnaryOpExpr) -> void:
		visit(e.expr)
		if e.op == TokenType.Not: _emit_op(Opcode.Not)
		elif e.op == TokenType.Sub: _emit_op(Opcode.Minus)
		# 一元指令：弹 1 压 1，栈大小不变
	func on_visit_binary_op_expr(e:StopeAst.BinaryOpExpr) -> void:
		if e.op == TokenType.Or:
			on_visit_or_expr(e); return
		if e.op == TokenType.And:
			on_visit_and_expr(e); return
		visit(e.left_expr); visit(e.right_expr)
		_emit_op(_binary_opcode(e.op))
		stack_size_mgr.dec()	# 弹 2 压 1
	# 短路或：任一侧为真就 PushTrue，两条路径都在栈上留下恰好 1 个结果。
	# [纠正 2] 这里对 PushTrue / PushFalse 记账，且末尾不 dec。
	func on_visit_or_expr(e:StopeAst.BinaryOpExpr) -> void:
		visit(e.left_expr)
		_emit_op(Opcode.If); stack_size_mgr.dec()
		var first_if_pos:int = _emit_placeholder()
		var depth_at_if_target:int = stack_size_mgr.size	# If 已弹掉条件 = 汇合点深度
		_emit_op(Opcode.PushTrue); stack_size_mgr.inc()
		_emit_op(Opcode.GoTo); var goto_end1:int = _emit_placeholder()
		_patch_index(first_if_pos, _code_size())
		stack_size_mgr.converge(depth_at_if_target)	# 后面接的是「左侧为假」这条路径

		visit(e.right_expr)
		_emit_op(Opcode.If); stack_size_mgr.dec()
		var second_if_pos:int = _emit_placeholder()
		depth_at_if_target = stack_size_mgr.size
		_emit_op(Opcode.PushTrue); stack_size_mgr.inc()
		_emit_op(Opcode.GoTo); var goto_end2:int = _emit_placeholder()
		_patch_index(second_if_pos, _code_size())
		stack_size_mgr.converge(depth_at_if_target)

		_emit_op(Opcode.PushFalse)	# 两侧都不成立
		stack_size_mgr.inc()
		_patch_index(goto_end1, _code_size())
		_patch_index(goto_end2, _code_size())
	func on_visit_and_expr(e:StopeAst.BinaryOpExpr) -> void:
		visit(e.left_expr)
		_emit_op(Opcode.If); stack_size_mgr.dec()
		var first_if_pos:int = _emit_placeholder()
		visit(e.right_expr)
		_emit_op(Opcode.If); stack_size_mgr.dec()
		var second_if_pos:int = _emit_placeholder()
		var depth_at_if_target:int = stack_size_mgr.size		# 两侧都为真才落到这里
		_emit_op(Opcode.PushTrue); stack_size_mgr.inc()
		_emit_op(Opcode.GoTo); var goto_end:int = _emit_placeholder()
		_patch_index(first_if_pos, _code_size())
		_patch_index(second_if_pos, _code_size())
		stack_size_mgr.converge(depth_at_if_target)
		_emit_op(Opcode.PushFalse); stack_size_mgr.inc()
		_patch_index(goto_end, _code_size())
	func on_visit_call_expr(e:StopeAst.CallExpr) -> void:
		visit(e.callee)
		for a in e.args: visit(a)
		_emit_op(Opcode.Call); _emit_index(len(e.args))
		stack_size_mgr.dec(len(e.args))		# callee + args 换成 1 个返回值
	func on_visit_at_expr(e:StopeAst.AtExpr) -> void:
		visit(e.container)
		for k in e.key_exprs: visit(k)
		_emit_op(Opcode.At); _emit_index(len(e.key_exprs))
		stack_size_mgr.dec(len(e.key_exprs))
	func on_visit_custom_opcode_expr(e:StopeAst.CustomOpcodeExpr) -> void:
		if custom_opcodes == null or not custom_opcodes.opcodes.has(e.opcode_name):
			error(e.line, str('undefined custom opcode "', e.opcode_name, '". '))
			return
		var info:StopeOpcode.CustomOpcode = custom_opcodes.opcodes[e.opcode_name]
		var is_var_arg:bool = info.arg_num < 0	# 与 C++ 的 isVarArg 同一判据
		if not is_var_arg and info.arg_num != len(e.args):
			error(e.line, str('custom opcode "', e.opcode_name, '" expected ', info.arg_num,
				' args, but got ', len(e.args), '. '))
		for a in e.args: visit(a)
		_emit_op(info.opcode)
		if is_var_arg: _emit_index(len(e.args))
		# [纠正 3] 自定义指令没有 callee 入栈，结果仍占 1 格 ⇒ dec(参数个数 - 1)
		stack_size_mgr.dec(len(e.args) - 1)

	# ---------------- 小工具 ----------------
	# 标识符 -> 变量槽位索引。没声明过就当作外部变量，登记到文件作用域
	# （名字非空正是 Program.exports 的判据）。PushValue / PushId 共用这一处查找，
	# 否则两边容易一边登记一边漏。
	# defer 载荷编译期（defer_order_floor >= 0）走冻结名字绑定规则。
	func _ident_slot(name:String) -> int:
		var host:BlockScope = _resolve_at_splice(name) if defer_order_floor >= 0 \
				else _find_ident_host(name)
		if host != null: return host.id_map[name]
		_declare_exported(name, var_alloc.new_unique_var(name), true)
		return _file_scope().id_map[name]
	# 登记一个会进 Program.exports 的变量。索引来自 new_unique_var（不回收）。
	# 隐式导出（从未声明的宿主变量）记 -1：豁免 defer 冻结绑定检查。
	func _declare_exported(name:String, idx:int, implicit_export:bool = false) -> void:
		var fs:FileScope = _file_scope()
		fs.id_map[name] = idx
		fs.id_order[name] = -1 if implicit_export else decl_counter
		if not implicit_export: decl_counter += 1
		prog.exports[name] = idx
	# 登记一个局部变量：id_map 之外再记声明序号（defer 冻结绑定用）。
	func _declare_local(bs:BlockScope, name:String, idx:int) -> void:
		bs.id_map[name] = idx
		bs.id_order[name] = decl_counter
		decl_counter += 1
	# 预导出：必须在 _reset() 之后调用（reset 会重建 var_alloc、清空 out.exports）。
	# 走 new_unique_var，并且先于源码里任何变量分配 —— 这一步定了整个程序的槽位编号。
	func _export_pre_exports(names:Array) -> void:
		var fs:FileScope = _file_scope()
		for n in names:
			var name := String(n)
			# 行号记 0：这些名字不来自源码，硬套 cur_line（此刻是 -1）只会误导
			if name.is_empty():
				error(0, 'empty name in pre-exports. ')
				continue
			if name in fs.id_map:
				error(0, str('duplicate export of "', name, '". '))
				continue
			_declare_exported(name, var_alloc.new_unique_var(name))
	# 块 / if 分支 / 循环体在 AST 里都是裸 Prog（没有 BlockStmt 包着），
	# 这里补一层 BlockScope，让内部 let 的变量在离开时被回收。
	# 块尾结算（if 分支 / 循环体同普通块）：体以终止语句结尾时这里不可达，
	# 跳过——出口结算（return / break / continue）已就地拼过副本。
	func _visit_body_as_block(p:StopeAst.Prog) -> void:
		var bs:BlockScope = _push_block_scope()
		visit(p)
		if not stmt_terminates: _splice_defers(bs)
		bs.defers.clear()	# 最终结算
		_pop_scope()
		for idx in bs.id_map.values(): var_alloc.free_var(int(idx))
	# 二元运算符 -> 指令。注意二元 `-` 是 Sub 而不是 Minus（[纠正 1]）
	static func _binary_opcode(op:int) -> int:
		var T := TokenType
		if op == T.EQ: return Opcode.EQ
		if op == T.NE: return Opcode.NE
		if op == T.LT: return Opcode.LT
		if op == T.LE: return Opcode.LE
		if op == T.GT: return Opcode.GT
		if op == T.GE: return Opcode.GE
		if op == T.Add: return Opcode.Add
		if op == T.Sub: return Opcode.Sub
		if op == T.Mul: return Opcode.Mul
		if op == T.Div: return Opcode.Div
		if op == T.IDiv: return Opcode.IDiv
		if op == T.Mod: return Opcode.Mod
		if op == T.Pow: return Opcode.Pow
		return Opcode.Pop	# 到不了：parser 只会用上面这些 op 构造 BinaryOpExpr

# ====================================================================
class Scope:
	var type:String = 'scope'	# 'file' / 'block' / 'while'

# 名字作用域：标识符 -> 变量总表中的索引
class BlockScope extends Scope:
	var id_map:Dictionary[String,int]
	# 名字 -> 声明序号（decl_counter 的全局值，跨 scope 可比）。defer 的
	# 「冻结名字绑定」靠它判定：载荷解析到的本地名字若序号晚于 defer 语句处
	# 的基线，视为不可见——不被捕获，按隐式导出宿主变量处理（OQ-8）。
	# 隐式导出记 -1 豁免。
	var id_order:Dictionary[String,int]
	# defer 语句在本 scope 的登记：载荷（所有权留在 AST）、defer 行号、登记时
	# 的声明序号基线。退出点（块尾 / break / continue / return）由编译器逆序
	# 拼接——运行时没有 defer 栈，顺序在编译期物化。
	var defers:Array[Deferred] = []
	# 该 scope 是否为 defer 载荷的隐式作用域：break / continue / return
	# 不得跨越它（break/continue 的目标循环在载荷外 → 报错；return 在
	# 载荷内一律报错）。
	var is_defer_payload:bool = false
	func _init() -> void: type = 'block'; id_map = {}; id_order = {}

# defer 登记条目（对照 C++ BlockScope::Deferred）
class Deferred:
	var stmt:StopeAst.Stmt = null
	var line:int = 0
	var order_baseline:int = 0

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
