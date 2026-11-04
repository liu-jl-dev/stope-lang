class_name STMLParser

# STML 语法器。契约见 docs/zh-cn/stml-test-plan.md §2.6~§2.8，
# 权威实现是 cpp/src/stml_parser.cpp（本文件逐分支照抄它）。
#
# STML 比 XML 严格，三条容易写错：
#   1. 属性可以没有值 —— `<a flag>` ≡ `flag = ""`，所以属性循环**不能**在开头
#      无条件 next_token()，每个分支自己负责推进（否则无值属性会多吞一个 token）；
#   2. 子元素与元素内文本**互斥**，文本只有一段、不拼接；
#   3. 每个错误分支都**提前 return**，不在同一处级联（B-14）。

class Parser:
	var lexer:STMLLexer.Lexer
	var state_func:Callable
	var token:STML.Token
	var errors:Array[String]
	# 嵌套深度上限（根元素算第 1 层），0 = 不限。与 parser.gd 的 max_depth 同语义；
	# STML 每层至少要 <a></a> 7 字节，正常文档到不了 256，兜底的是畸形输入。
	var max_depth:int = 256
	var _aborted:bool = false
	func _init(lex:STMLLexer.Lexer) -> void:
		lexer = lex

	# 顶层只解析**一个**元素（B-15），根之后的剩余输入被忽略。
	# state_func(tag, attrs) -> STMLLexer.State：由宿主决定某个标签的内容该按
	# 哪种状态扫；传空 Callable() 等价于 C++ 的 nullptr，一律 Xml（子元素模式）。
	# 返回值是 StopeResult.Success / StopeResult.Error（与 C++ 共用同一份 Result）。
	func parse(root:STML.Element, state_func_:Callable) -> int:
		state_func = state_func_
		_aborted = false
		next_token()
		parse_element(root, 1) # 根元素算第 1 层
		return StopeResult.Success if errors.is_empty() else StopeResult.Error

	func parse_element(e:STML.Element, depth:int) -> void:
		var T := STML.Token.Type
		# 深度检查：唯一递归点在子元素分支，检查放入口即可。_aborted 之后逐层
		# 提前 return，不再消费任何 token —— 与 parser.gd「中止但不逐层传染」
		# 同款，25 万层畸形输入只报一条错。
		if _aborted: return
		if max_depth > 0 and depth > max_depth:
			abort_too_deep()
			return
		# 进入元素一律先回到 Xml：自闭合分支与出错提前返回的路径都走不到
		# state_func，留着上一次的 Text/Nevext/Stope 会污染后续 token
		lexer.state = STMLLexer.State.Xml
		e.line = token.line
		if token.type != T.LAngle:
			error('expected "<". '); return
		next_token()
		if token.type != T.Word:
			error('expected tag name. '); return
		e.tag = token.lexeme
		next_token() # 第一个属性名，或 > 或 />
		while true: # (word ("=" string)?)*
			if token.type == T.RAngle: break
			elif token.type == T.CRAngle: e.self_closing = true; return
			elif token.type == T.Word:
				var attr:String = token.lexeme
				next_token()
				if token.type == T.EQ:
					next_token() # 已跳过 =
					if token.type != T.String:
						error('expected string. '); return
					e.attrs[attr] = token.lexeme
					next_token()
				else:
					# 无值属性（B-9）：token 已经是下一个属性名 / > 或 />，不能再推进
					e.attrs[attr] = ''
			else:
				error('expected ">" or "/>" or attribute. '); return
		# 此时 self_closing = false，且停在 ">"
		if state_func.is_valid():
			# attrs 传**副本**：C++ 的 LexerStateFunc 按值收 std::map，宿主改不到
			# 解析器；这里不 duplicate 的话宿主删/加键会改到 e.attrs 本身。
			# 每个元素一次浅拷贝，STML 量级下可忽略。
			lexer.state = int(state_func.call(e.tag, e.attrs.duplicate()))
		else:
			lexer.state = STMLLexer.State.Xml
		if lexer.state == STMLLexer.State.Xml:
			while true:
				next_token()
				if token.type == T.CLAngle: break
				elif token.type == T.LAngle:
					var child := STML.Element.new()
					e.children.append(child)
					parse_element(child, depth + 1)
					if _aborted: return # 超限的那层已报过错，逐层直接返回，不级联
				else:
					error('expected "<" or "</". '); return
		else: # Text / Nevext / Stope：整段内容由 Lexer 一次性给出
			next_token()
			if token.type != T.Text and token.type != T.NevextSrc and token.type != T.StopeSrc:
				error('expected element content. '); return
			e.text = token.lexeme # 只有一段，不拼接（B-11）
			e.text_line = token.line # 词法器已跳过前导空白，这是内容的首行（PL-05）
			next_token() # 停在 CLAngle，与上面 Xml 分支的 break 处汇合
		next_token() # 结束标签名
		if token.type != T.Word:
			error('expected tag name. '); return
		if token.lexeme != e.tag:
			error('tag name mismatch. '); return
		next_token()
		if token.type != T.RAngle:
			error('expected ">". '); return

	func next_token() -> STML.Token:
		token = lexer.next_token()
		return token
	func abort_too_deep() -> void:
		error('nesting too deep (max %d). ' % max_depth) # 必须在置位之前记账
		_aborted = true
	func error(msg:String) -> void:
		# 超限中止之后的错误都是连锁反应，不再记账 —— 与 Stope 的 Parser 同款
		if _aborted: return
		errors.append(str('line ',token.line,': ',msg))
