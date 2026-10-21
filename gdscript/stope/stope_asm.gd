class_name StopeAsm

class Result:
	var err:int
	var val
	const OK = 0
	const Err = 1

class Compiler:
	var _custom_insts:Dictionary[String,Stope.CustomInst] = {}
	var _nevext_code:Array[Nevext.Statement]
	var _nev_cmd:Nevext.Statement
	var _scope_tree:Scope
	var _scope_stack:Array[Scope] # 防止使用 scope 指向上级的弱引用
	var _code:Array[int] # 生成的代码，指令部分
	var _errors:Array[String]
	var _warnings:Array[String]
	var _infos:Array[String]
	var _var_alloc:VariableAllocator
	var _int_consts:ConstantManager
	var _float_consts:ConstantManager
	var _str_consts:ConstantManager
	var _stack_size_mgr:StackSizeManager
	var _max_return_num:int
	func _init(nevext_code:Array[Nevext.Statement]=[]) -> void:
		reset(nevext_code)
	func reset(nevext_code:Array[Nevext.Statement]):
		_nevext_code = nevext_code
		_scope_tree = FileScope.new()
		_scope_stack = [_scope_tree]
		_code = []; _errors = []; _warnings = []; _infos = []
		_var_alloc = VariableAllocator.new()
		_int_consts = ConstantManager.new()
		_float_consts = ConstantManager.new()
		_str_consts = ConstantManager.new()
		_stack_size_mgr = StackSizeManager.new()
		_max_return_num = 0
	func set_custom_insts(cis:Array[Stope.CustomInst]) -> Array[String]:
		var errs:Array[String] = []
		for ci in cis:
			if ci.name in _on_visit:
				errs.append(str("inst \"",ci.name,"\": is a duplicate of a build-in inst. "))
				continue
			if ci.code <= Stope.Inst.Return:
				errs.append(str("inst \"",ci.name,"\": custom inst code must be greater than ",
					Stope.Inst.Return,". "))
				continue
			if (not ci.variable_arg) and ci.arg_num < 0:
				errs.append(str("inst \"",ci.name,"\": arg num must not be less than 0. "))
				continue
			_custom_insts[ci.name] = ci
		return errs
	func compile() -> Result:
		var o:Result = Result.new()
		_scope_tree.begin_line = 1; _scope_tree.end_line = _nevext_code[-1].line
		for nev_cmd:Nevext.Statement in _nevext_code:
			_nev_cmd = nev_cmd;
			if len(nev_cmd.strings) <= 0:
				_error('empty statement. ')
			elif nev_cmd.strings[0] in _on_visit:
				_on_visit[nev_cmd.strings[0]].call()
			elif nev_cmd.strings[0] in _custom_insts: _parse_custom_inst()
			else: _error(str('undefined command: ',nev_cmd.strings[0],'. '))
			if len(_errors) > 0:
				o.err = Result.Err
				break
		var p:Stope.Program = Stope.Program.new()
		p.opcodes = _code; p.int_consts = _int_consts._data; p.float_consts = _float_consts._data
		p.string_consts = _str_consts._data; p.variable_num = len(_var_alloc._vars)
		p.required_stack_size = _stack_size_mgr.max_size()
		p.max_return_num = _max_return_num
		for i in range(len(_var_alloc._vars)):
			if _var_alloc._vars[i] != '': p.exports[_var_alloc._vars[i]] = i
		o.val = p; return o
	
	func _parse_custom_inst():
		var inst_name:String = _nev_cmd.strings[0]
		var inst_info:Stope.CustomInst = _custom_insts[inst_name]
		if inst_info.variable_arg:
			if len(_nev_cmd.strings) != 2:
				_error(str("custom command \"",inst_name,"\" expected one integer for argument count. "))
				return
			var arg_n_literal:String = _nev_cmd.strings[1]
			if not arg_n_literal.is_valid_int():
				_error(str("custom command \"",inst_name,"\" param must be an integer. "))
				return
			var arg_n:int = arg_n_literal.to_int()
			_code.append(inst_info.code); _code.append(arg_n)
			for i in range(arg_n): # 弹出所有参数
				var res:String = _stack_size_mgr.dec()
				if res: _error(res); return
			_stack_size_mgr.inc() # 压入返回值
		else:              # 固定参数个数
			_check_param_num_eq(0)
			if not _check_stack_size_ge(inst_info.arg_num): return
			_code.append(inst_info.code)
			for i in range(inst_info.arg_num): _stack_size_mgr.dec()
			_stack_size_mgr.inc()
	
	var _on_visit:Dictionary[String,Callable] = { # 遇到 Nevext 语句的回调函数
		'assign': self._on_visit_assign, '=':self._on_visit_assign,
		'null': self._on_visit_null,
		'false': self._on_visit_false,
		'true': self._on_visit_true,
		'int': self._on_visit_int, 'i': self._on_visit_int,
		'float': self._on_visit_float, 'f': self._on_visit_float,
		'str': self._on_visit_str, 's': self._on_visit_str,
		'val': self._on_visit_val, 'v': self._on_visit_val,
		'id': self._on_visit_id,
		'call': self._on_visit_call,
		
		'at':self._on_visit_at,
		'pop': self._on_visit_pop,
		'minus': self._on_visit_minus,
		'not': self._on_visit_not, '!': self._on_visit_not,
		'pow': self._on_visit_pow, '^': self._on_visit_pow,
		'mul': self._on_visit_mul, '*': self._on_visit_mul,
		'div': self._on_visit_div, '/': self._on_visit_div,
		'idiv': self._on_visit_idiv,
		'mod': self._on_visit_mod, '%': self._on_visit_mod,
		'add': self._on_visit_add, '+': self._on_visit_add,
		
		'sub': self._on_visit_sub, '-': self._on_visit_sub,
		'eq': self._on_visit_eq, '==': self._on_visit_eq,
		'ne': self._on_visit_ne, '!=': self._on_visit_ne,
		'lt': self._on_visit_lt, '<': self._on_visit_lt,
		'le': self._on_visit_le, '<=': self._on_visit_le,
		'gt': self._on_visit_gt, '>': self._on_visit_gt,
		'ge': self._on_visit_ge, '>=': self._on_visit_ge,
		'if': self._on_visit_if,
		'else': self._on_visit_else,
		'elif': self._on_visit_elif,
		
		'end_if': self._on_visit_end_if, 'endif': self._on_visit_end_if,
		'begin_block': self._on_visit_begin_block, 'begin': self._on_visit_begin_block,
		'end_block': self._on_visit_end_block, 'end': self._on_visit_end_block,
		'begin_loop': self._on_visit_begin_loop,
		'end_loop': self._on_visit_end_loop,
		'continue': self._on_visit_continue,
		'break': self._on_visit_break,
		'arg': self._on_visit_arg,
		'argc': self._on_visit_argc,
		'return': self._on_visit_return,
		
		'let': self._on_visit_let,
		'export': self._on_visit_export,
	} # 共 42 个
	
	func _on_visit_assign():
		_check_param_num_eq(0); if not _check_stack_size_ge(2): return
		_code.append(Stope.Inst.Assign); _stack_size_mgr.dec(); _stack_size_mgr.dec()
	func _on_visit_null(): _visit_primitive_value(Stope.Inst.PushNull)
	func _on_visit_false(): _visit_primitive_value(Stope.Inst.PushFalse)
	func _on_visit_true(): _visit_primitive_value(Stope.Inst.PushTrue)
	func _visit_primitive_value(inst:int): # 原始值
		_check_param_num_eq(0); _stack_size_mgr.inc()
		_code.append(inst)
	func _on_visit_int():
		_check_param_num_ge(1)
		for i in range(1, len(_nev_cmd.strings)):
			var literal:String = _nev_cmd.strings[i]
			if not literal.is_valid_int():
				_error(str("command 'int': '",literal,"' is not a valid integer. "))
				break
			_code.append(Stope.Inst.PushInt)
			_code.append(_int_consts.get_index(literal.to_int()))
			_stack_size_mgr.inc()
	func _on_visit_float():
		_check_param_num_ge(1)
		for i in range(1, len(_nev_cmd.strings)):
			var literal:String = _nev_cmd.strings[i]
			if not literal.is_valid_float():
				_error(str("command 'float': '",literal,"' is not a valid float. "))
				break
			_code.append(Stope.Inst.PushFloat)
			_code.append(_float_consts.get_index(literal.to_float()))
			_stack_size_mgr.inc()
	func _on_visit_str():
		_check_param_num_ge(1)
		for i in range(1, len(_nev_cmd.strings)):
			var literal:String = _nev_cmd.strings[i]
			_code.append(Stope.Inst.PushString); _code.append(_str_consts.get_index(literal))
			_stack_size_mgr.inc()
	func _on_visit_val():
		_check_param_num_ge(1)
		for i in range(1, len(_nev_cmd.strings)):
			var literal:String = _nev_cmd.strings[i]
			if literal.is_valid_int():
				_code.append(Stope.Inst.PushInt); _code.append(_int_consts.get_index(literal.to_int()))
			elif literal.is_valid_float():
				_code.append(Stope.Inst.PushFloat); _code.append(_float_consts.get_index(literal.to_float()))
			else:
				_code.append(Stope.Inst.PushString); _code.append(_str_consts.get_index(literal))
			_stack_size_mgr.inc()
	func _on_visit_id():
		_check_param_num_ge(1)
		for i in range(1, len(_nev_cmd.strings)):
			var literal:String = _nev_cmd.strings[i]
			_code.append(Stope.Inst.PushId); _code.append(_get_id_index(literal))
			_stack_size_mgr.inc() # 压 1 个 id
	func _get_id_index(id:String):
		var found:bool = false; var index:int
		var scope_i:int = len(_scope_stack)
		while scope_i > 0:
			scope_i -= 1
			var scope:Scope = _scope_stack[scope_i]
			if id in scope.id_map:
				index = scope.id_map[id]
				found = true; break
		if not found: # 类似 export 处理
			index = _var_alloc.new_unique_var(id)
			_scope_tree.id_map[id] = index
		return index
	func _on_visit_call():
		_visit_call_like('call', Stope.Inst.Call)
	func _on_visit_at():
		_visit_call_like('at', Stope.Inst.At)
	func _visit_call_like(name:String, inst:int): # 要求写明参数数量
		if len(_nev_cmd.strings) != 2:
			_error(str("'",name,"' requires 1 param, but got ",
				len(_nev_cmd.strings)-1,'. ')); return
		var n_lit:String = _nev_cmd.strings[1]
		if not n_lit.is_valid_int():
			_error(str("command '",name,"': ',",n_lit,"' is not a valid integer. ")); return
		var n:int = n_lit.to_int()
		if n < 0: _error(str("command '",name,"': arg num must be 0 or a positive integer. ")); return
		if n+1 > _stack_size_mgr.size(): # 1 个函数引用加 n 个参数
			_error(str("command '",name,"': object and arg num ",n+1,
				" is greater than stack size ",_stack_size_mgr.size(),". ")); return
		_code.append(inst); _code.append(n)
		for i in range(n): _stack_size_mgr.dec() # 弹出所有参数和函数引用，压入返回值。共减少 n 个。
	func _on_visit_pop():
		_check_param_num_eq(0)
		_code.append(Stope.Inst.Pop); _stack_size_mgr.dec()
	
	func _on_visit_minus(): _visit_unary_operator(Stope.Inst.Minus)
	func _on_visit_not(): _visit_unary_operator(Stope.Inst.Not)
	func _on_visit_pow(): _visit_binary_operator(Stope.Inst.Pow)
	func _on_visit_mul(): _visit_binary_operator(Stope.Inst.Mul)
	func _on_visit_div(): _visit_binary_operator(Stope.Inst.Div)
	func _on_visit_idiv(): _visit_binary_operator(Stope.Inst.IDiv)
	func _on_visit_mod(): _visit_binary_operator(Stope.Inst.Mod)
	func _on_visit_add(): _visit_binary_operator(Stope.Inst.Add)
	func _on_visit_sub(): _visit_binary_operator(Stope.Inst.Sub)
	func _on_visit_eq(): _visit_binary_operator(Stope.Inst.EQ)
	func _on_visit_ne(): _visit_binary_operator(Stope.Inst.NE)
	func _on_visit_lt(): _visit_binary_operator(Stope.Inst.LT)
	func _on_visit_le(): _visit_binary_operator(Stope.Inst.LE)
	func _on_visit_gt(): _visit_binary_operator(Stope.Inst.GT)
	func _on_visit_ge(): _visit_binary_operator(Stope.Inst.GE)
	func _visit_unary_operator(inst:int):
		_check_param_num_eq(0); _check_stack_size_ge(1)
		_code.append(inst) # 一元运算符，不影响栈大小
	func _visit_binary_operator(inst:int):
		_check_param_num_eq(0); _check_stack_size_ge(2)
		_code.append(inst); _stack_size_mgr.dec()

	func _on_visit_arg():
		_check_param_num_eq(0); _check_stack_size_ge(1)
		_code.append(Stope.Inst.GetArg) # 替换栈顶元素，栈大小不变
	func _on_visit_argc():
		_check_param_num_eq(0)
		_code.append(Stope.Inst.ArgNum); _stack_size_mgr.inc()
	func _on_visit_return():
		var n:int; var c:Nevext.Statement = _nev_cmd
		if len(c.strings)!=1 and len(c.strings)!=2: _warnings.append(str('line ',c.line,
			": 'return' command expects 0 or 1 param but got ",len(c.strings)-1,'. '))
		if len(c.strings) == 1: n = 0
		elif c.strings[1].is_valid_int(): n = c.strings[1].to_int()
		else:
			_errors.append(str('line ',c.line,": param 1 of 'return' command must be integer. "))
			return
		_code.append(Stope.Inst.Return); _code.append(n)
		var s := str('line ',c.line,": return variable num: ",n,", stack size: ",
			_stack_size_mgr.size(),'. '); _infos.append(s)
		if n > _stack_size_mgr.size(): _errors.append(s)
		_max_return_num = max(_max_return_num, n)
	
	func _on_visit_if():
		_check_param_num_eq(0)
		var parent:Scope = _scope_stack[-1]
		var sco:IfScope = IfScope.new()
		_code.append(Stope.Inst.If); sco.last_if_index = len(_code); _code.append(0)
		_stack_size_mgr.dec() # 弹出判断的值
		sco.name = str(parent.name,'i',len(parent.children),'/')
		sco.begin_line = _nev_cmd.line
		parent.children.append(sco); _scope_stack.append(sco)
	func _on_visit_elif():
		_check_param_num_eq(0)
		if not _check_scope_type("command 'elif'", Scope.Type.If): return
		var sco:IfScope = _scope_stack[-1]
		_code.append(Stope.Inst.If); sco.last_if_index = len(_code); _code.append(0)
		_stack_size_mgr.dec() # 弹出判断的值
	func _on_visit_else():
		_check_param_num_eq(0)
		if not _check_scope_type("command 'else'", Scope.Type.If): return
		var sco:IfScope = _scope_stack[-1]
		_code.append(Stope.Inst.GoTo); sco.goto_end_indices.append(len(_code)); _code.append(0)
		_code[sco.last_if_index] = len(_code); sco.last_if_index = -1
	func _on_visit_end_if():
		_check_param_num_eq(0)
		if not _check_quit_scope_type(Scope.Type.If): return
		var sco:IfScope = _scope_stack.pop_back()
		for idx in sco.goto_end_indices: _code[idx] = len(_code)
		if sco.last_if_index > 0: _code[sco.last_if_index] = len(_code)
	
	func _on_visit_begin_block():
		_check_param_num_eq(0) # 无参数
		var parent:Scope = _scope_stack[-1]
		var block:BlockScope = BlockScope.new()
		block.name = parent.name + 'b' + str(len(parent.children)) + '/'
		block.begin_line = _nev_cmd.line
		parent.children.append(block)
		_scope_stack.append(block)
	func _on_visit_end_block():
		_check_param_num_eq(0)
		if not _check_quit_scope_type(Scope.Type.Block): return
		var top_sco:Scope = _scope_stack[-1]
		for loc in top_sco.id_map.values(): # 回收作用域中的局部变量
			_var_alloc.free_var(loc)
		top_sco.end_line = _nev_cmd.line
		_scope_stack.pop_back()
		_infos.append(str('line ',_nev_cmd.line,': block scope end with stack size ',
			_stack_size_mgr.size(),'. '))
	
	func _on_visit_begin_loop():
		_check_param_num_eq(0)
		var parent:Scope = _scope_stack[-1]; var loop:LoopScope = LoopScope.new()
		loop.name = parent.name + 'l' + str(len(parent.children)) + '/'
		loop.begin_line = _nev_cmd.line
		parent.children.append(loop); _scope_stack.append(loop)
		loop.begin_index = len(_code); loop.begin_stack_size = _stack_size_mgr.size()
	func _on_visit_end_loop(): # 结束时栈大小必须与开始时相同，否则栈大小无法确定
		_check_param_num_eq(0)
		if not _check_quit_scope_type(Scope.Type.Loop): return
		var loop:LoopScope = _scope_stack.pop_back()
		if _stack_size_mgr.size() != loop.begin_stack_size:
			_error(str('loop start with stack size ',loop.begin_stack_size,
				', but end with ',_stack_size_mgr.size(),'. ')); return
		_code.append(Stope.Inst.GoTo); _code.append(loop.begin_index) # 返回开头
		for idx in loop.break_indices: _code[idx] = len(_code)
	func _on_visit_continue():
		_check_param_num_eq(0)
		var loop:LoopScope = _find_top_loop_scope()
		if loop == null: _not_found_loop_error('continue'); return
		_code.append(Stope.Inst.GoTo); _code.append(loop.begin_index)
	func _on_visit_break():
		_check_param_num_eq(0)
		var loop:LoopScope = _find_top_loop_scope()
		if loop == null: _not_found_loop_error('continue'); return
		_code.append(Stope.Inst.GoTo); loop.break_indices.append(len(_code))
		_code.append(0)
	func _find_top_loop_scope() -> LoopScope:
		var scope_i:int = len(_scope_stack)
		while scope_i > 0:
			scope_i -= 1
			var scope:Scope = _scope_stack[scope_i]
			if scope.type == Scope.Type.Loop: return scope
		return null
	func _not_found_loop_error(name:String):
		_error(str("cannot use '",name,"' outside of a loop. "))
	
	func _on_visit_let():
		_check_param_num_ge(1)
		var top_sco:Scope = _scope_stack[-1]
		for i:int in range(1,len(_nev_cmd.strings)): # 记录标识符、分配存储位置
			var id:String = _nev_cmd.strings[i]
			if id in top_sco.id_map.keys():
				_errors.append(str('line ',_nev_cmd.line,": duplicate declaration of '",id,"'. "))
				break
			top_sco.id_map[id] = _var_alloc.new_var()
	func _on_visit_export():
		_check_param_num_ge(1)
		if len(_scope_stack) != 1:
			_errors.append(str('line ',_nev_cmd.line
				,': export command can only appear in file scope. '))
			return
		for i:int in range(1,len(_nev_cmd.strings)):
			var id:String = _nev_cmd.strings[i]
			if id in _scope_tree.id_map.keys():
				_errors.append(str('line ',_nev_cmd.line,": duplicate declaration of '",id,"'. "))
				break
			_scope_tree.id_map[id] = _var_alloc.new_unique_var(id)
	
	func _error(s:String):
		_errors.append(str('line ',_nev_cmd.line,': ',s))
	func _check_param_num_eq(num:int):
		if len(_nev_cmd.strings)-1 != num:
			_warnings.append(str('line ',_nev_cmd.line,': command ',_nev_cmd.strings[0],
				' expects ',num,' param(s), but got ',len(_nev_cmd.strings)-1,'. '))
	func _check_param_num_ge(num:int):
		if not(len(_nev_cmd.strings)-1 >= num):
			_warnings.append(str('line ',_nev_cmd.line,': command ',_nev_cmd.strings[0],
				' expects not less than ',num,' param(s), but got ',len(_nev_cmd.strings)-1,'. '))
	func _check_stack_size_ge(num:int):
		if _stack_size_mgr.size() < num:
			_error(str("command '",_nev_cmd.strings[0],"' requires stack size not less than ",
				num,', but got ',_stack_size_mgr.size(),'. ')); return false
		return true
	func _check_quit_scope_type(type:int) -> bool:
		if _scope_stack[-1].type != type:
			_errors.append(str('line ',_scope_stack[-1].begin_line,' to ',_nev_cmd.line,
				': ',Scope.Type.keys()[_scope_stack[-1].type],
				' scope end with ',Scope.Type.keys()[type],'. '))
			return false
		return true
	func _check_scope_type(msg:String, type:int) -> bool:
		if _scope_stack[-1].type != type:
			_error(str(msg,' requires scope type ',Scope.Type.keys()[type],', but got ',
				Scope.Type.keys()[_scope_stack[-1].type],'. '))
			return false
		return true
	

@abstract
class Scope:
	var type:int
	var begin_line:int
	var end_line:int
	var name:String
	var id_map:Dictionary[String,int] # id, 总表中的索引
	var children:Array[Scope]
	
	enum Type { File, If, Loop, Block, }

class FileScope extends Scope:
	func _init() -> void:
		type = Scope.Type.File
		name = '/'

class IfScope extends Scope:
	var last_if_index:int
	var goto_end_indices:Array[int] = []
	func _init() -> void:
		type = Scope.Type.If

class LoopScope extends Scope:
	var begin_index:int
	var begin_stack_size:int
	var break_indices:Array[int] = []
	func _init() -> void:
		type = Scope.Type.Loop

class BlockScope extends Scope:
	func _init() -> void:
		type = Scope.Type.Block


class MinHeap:
	var data:Array[int] = [0]
	var count:int = 0
	
	func is_empty() -> bool:
		return count == 0
	func push(v:int):
		data.append(v); count += 1
		_precUp(count)
	func pop() -> int:
		var o = data[1]
		data[1] = data[count]; data.pop_back(); count -= 1
		_precDown(1)
		return o
	func _minChildID(i:int) -> int:
		var l:int = i * 2; var r:int = l + 1
		if r > count: return l
		if data[l] < data[r]: return l
		return r
	func _swap(a:int, b:int):
		var t:int = data[a]; data[a] = data[b]; data[b] = t
	func _precUp(i:int) -> void:
		var now:int = i; var next:int = i / 2
		while next > 0:
			if data[now] < data[next]:
				_swap(now, next)
			now = next; next = next / 2
	func _precDown(i:int):
		while i * 2 < count:
			var c:int = _minChildID(i)
			if data[i] > data[c]:
				_swap(i, c)
			i = c

class VariableAllocator:
	var _vars:Array[String] = []
	var _recycled:MinHeap = MinHeap.new()
	func new_var(name:String='') -> int:
		var idx:int
		if not _recycled.is_empty():
			idx = _recycled.pop(); _vars[idx] = name
			return idx
		idx = len(_vars); _vars.append(name)
		return idx
	func new_unique_var(name:String) -> int:
		var idx:int = len(_vars); _vars.append(name)
		return idx
	func free_var(idx:int):
		_recycled.push(idx)

class ConstantManager:
	var _data:Array
	var _map:Dictionary # 常量值映到 _data 中的索引
	func get_index(val) -> int:
		if val in _map: return _map[val]
		var index:int = len(_data)
		_data.append(val)
		_map[val] = index
		return index

class StackSizeManager:
	var _size:int = 0
	var _max_size:int = 0
	func inc():
		_size += 1; _max_size = maxi(_size, _max_size)
	func dec() -> String:
		_size -= 1
		if _size < 0: return 'stack size less than 0. '
		return ''
	func size() -> int: return _size
	func max_size() -> int: return _max_size











