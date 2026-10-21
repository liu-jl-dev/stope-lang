class_name STMLParser

class Parser:
	var lexer:STMLLexer.Lexer
	var cur_token:STML.Token
	var errors:Array[String]
	func _init(lex:STMLLexer.Lexer) -> void:
		lexer = lex
		next_token()
	func next_token() -> STML.Token:
		cur_token = lexer.next_token()
		return cur_token
	func parse_element() -> STML.Element:
		if cur_token.type != STML.Token.Type.LAngle:
			error(str('expected "<" for an element, but got ',STML.Token.type_name(cur_token.type),'. '))
			next_token(); return STML.Element.new()
		var ele:STML.Element = parse_start_tag() # 当前 cur_token 是 > 或 />，为了检查是否为 nev、sto
		if ele.self_closing: # 没有子元素、文本，直接返回
			next_token() # 跳过 />
			return ele
		
		if ele.tag == 'nev':
			lexer.state = STMLLexer.State.Nevext
			next_token() # 此时进入文本
			ele.text = cur_token.lexeme; ele.text_begin_line = cur_token.line
			lexer.state = STMLLexer.State.Xml # 还原状态
			next_token() # 应当为 </
		elif ele.tag == 'sto':
			if 'asm' in ele.attrs: lexer.state = STMLLexer.State.Nevext
			else: lexer.state = STMLLexer.State.Stope
			next_token()
			ele.text = cur_token.lexeme; ele.text_begin_line = cur_token.line
			lexer.state = STMLLexer.State.Xml
			next_token() # 应当为 </
		else: # 普通 xml 节点
			next_token() # 越过 >
			while true:
				if cur_token.type == STML.Token.Type.LAngle: # 新的子元素
					ele.children.append(parse_element()) # 子元素解析的 parse_end_tag() 最后有 next_token()
				elif cur_token.type == STML.Token.Type.Str:  # 标签内文本
					if ele.text == '': ele.text_begin_line = cur_token.line; ele.text = cur_token.lexeme
					else: ele.text = str(ele.text,'\n',cur_token.lexeme)
					next_token()
				elif cur_token.type == STML.Token.Type.CLAngle: # 标签结束
					break
				else: error(str('unexpected token type ',STML.Token.type_name(cur_token.type)))
		
		if cur_token.type != STML.Token.Type.CLAngle: # 标签结束
			error(str('expected "</" to finish an element, but got ',STML.Token.type_name(cur_token.type),'. '))
			next_token()
		else:
			var end_tag_name:String = parse_end_tag() # 最后有 next_token()
			if end_tag_name != ele.tag:
				error(str('element began with tag name "',ele.tag,'", but ended with "',end_tag_name,'". '))
		return ele
	func parse_start_tag() -> STML.Element:
		var ele := STML.Element.new(); ele.line = cur_token.line
		if next_token().type != STML.Token.Type.Word:
			error(str('expected a word for tag name, but got ',STML.Token.type_name(cur_token.type),'. '))
			return ele
		ele.tag = cur_token.lexeme; next_token() # 到达第一个 attr 或 > 或 />
		while cur_token.type == STML.Token.Type.Word:
			var attr_name:String = cur_token.lexeme
			next_token()
			if cur_token.type == STML.Token.Type.EQ: # attribute 有值
				if next_token().type != STML.Token.Type.Str: # 已跳过 =
					error(str('expected a string for attribute value, but got ',STML.Token.type_name(cur_token.type),'. '))
					ele.attrs[attr_name] = ''
				else:
					ele.attrs[attr_name] = cur_token.lexeme; next_token()
			elif cur_token.type == STML.Token.Type.Word:
				ele.attrs[attr_name] = ''
			else: ele.attrs[attr_name] = ''; break
		if cur_token.type == STML.Token.Type.RAngle: ele.self_closing = false
		elif cur_token.type == STML.Token.Type.CRAngle: ele.self_closing = true
		else: error(str('expected ">" or "/>" at end of a start tag, but got ',
			STML.Token.type_name(cur_token.type),'. '))
		#next_token() # 不能跳过最后的 > 或 />，因为要先检查标签是否为 nev、sto
		return ele
	func parse_end_tag() -> String:
		if next_token().type != STML.Token.Type.Word:
			error(str('expected a word in end tag, but got ',STML.Token.type_name(cur_token.type),'. '))
			next_token(); return ''
		var tag_name:String = cur_token.lexeme; 
		if next_token().type != STML.Token.Type.RAngle:
			error(str('expected ">" to close an end tag, but got ',STML.Token.type_name(cur_token.type),'. '))
		next_token(); return tag_name
	
	func error(msg:String):
		errors.append(str('line ',cur_token.line,': ',msg))




























