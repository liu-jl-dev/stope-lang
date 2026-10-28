class_name STMLLexer

# STML 词法器。四态状态机（Xml / Text / Nevext / Stope），契约见
# docs/zh-cn/stml-test-plan.md §2.1~§2.5，权威实现是 cpp/src/stml_lexer.cpp。
#
# 三条最容易写错的规则：
#   1. Text / Nevext / Stope 扫完一段后**必须把 state 交还 Xml**，否则后续
#      next_token() 会产出无限个空 token（C++ 侧由 NextToken 自己收尾）；
#   2. 输入耗尽后**永远**返回 Eof，与当前状态无关；
#   3. 任何异常路径都要**消费字符**，否则调用方的 while 会死循环。

enum State {
	Xml, Text, Nevext, Stope
}

class Lexer:
	var state:int = State.Xml
	var src:String
	var line:int = 1
	var errors:Array[String]
	func _init(source:String="") -> void:
		src = source
	func next_token() -> STML.Token:
		var token := STML.Token.new()
		skip_ws(); token.line = line
		if src.is_empty():
			token.set_(STML.Token.Type.Eof, '')
		elif state == State.Xml:
			if test('</'): token.set_(STML.Token.Type.CLAngle, '</'); src = src.substr(2)
			elif test('/>'): token.set_(STML.Token.Type.CRAngle, '/>'); src = src.substr(2)
			elif src[0] == '<': token.set_(STML.Token.Type.LAngle, '<'); src = src.substr(1)
			elif src[0] == '>': token.set_(STML.Token.Type.RAngle, '>'); src = src.substr(1)
			elif src[0] == '=': token.set_(STML.Token.Type.EQ, '='); src = src.substr(1)
			elif src[0] == "'" or src[0] == '"': scan_string(token)
			elif is_word_begin(src[0]): token.set_(STML.Token.Type.Word, scan_word())
			else:
				error('unexpected character. ')
				token.set_(STML.Token.Type.Invalid, '')
				src = src.substr(1) # 必须消费，否则死循环
		elif state == State.Text:
			token.set_(STML.Token.Type.Text, scan_text()); state = State.Xml
		elif state == State.Nevext:
			token.set_(STML.Token.Type.NevextSrc, scan_nevext()); state = State.Xml
		elif state == State.Stope:
			token.set_(STML.Token.Type.StopeSrc, scan_stope()); state = State.Xml
		else: error(str('unexpected lexer state ',state,'. ')); src = src.substr(1)
		return token

	# ============================ Xml 状态 ============================
	# Xml 属性串：**不转义**（`\"` 里的引号就是结束引号，TD-9）。
	# 未闭合时报错（文案比代码段那条少一个句号，TD-8）并吃掉剩余全部输入。
	func scan_string(token:STML.Token) -> void:
		var T := STML.Token.Type
		token.type = T.String
		var quote:String = src[0]
		src = src.substr(1) # 跳过开头的引号
		var n := 0
		while true:
			if n >= len(src):
				error('unclosed string literal')
				src = ''; token.type = T.Invalid; break
			if src[n] == quote:
				token.lexeme = src.substr(0, n); src = src.substr(n + 1); break
			if src[n] == '\n': line += 1
			n += 1
	func scan_word() -> String:
		var end:int = 1
		while end < len(src):
			if not is_word_char(src[end]): break
			end += 1
		var s:String = src.substr(0, end); src = src.substr(end)
		return s

	# ============================ 内容三态 ============================
	# 三个扫描函数同构：从 src 开头一路吃到 `</` 或输入耗尽，尾部空白不计入
	# lexeme（B-8）。Text 只认 `</`，`<b/>` 会被整段当文本吃掉（B-2）。
	func scan_text() -> String:
		var begin := src
		while not src.is_empty():
			if test('</'): break
			if src[0] == '\n': line += 1
			src = src.substr(1)
		return trim_trailing_ws(begin.substr(0, len(begin) - len(src)))
	# Nevext 代码段：引号串与注释整段跳过，其中的 `</` 不算结束标签（B-3）。
	func scan_nevext() -> String:
		var begin := src
		while not src.is_empty():
			if test('</'): break
			elif src[0] == "'" or src[0] == '"': scan_nevext_str(src[0])
			elif test('//'): skip_singleline_comment()
			elif test('/*'): skip_multiline_comment()
			else:
				if src[0] == '\n': line += 1
				src = src.substr(1)
		return trim_trailing_ws(begin.substr(0, len(begin) - len(src)))
	# Stope 代码段：同 Nevext，只有引号规则不同（单引号是 BinArr，不转义）。
	func scan_stope() -> String:
		var begin := src
		while not src.is_empty():
			if test('</'): break
			elif src[0] == "'" or src[0] == '"': scan_stope_str(src[0])
			elif test('//'): skip_singleline_comment()
			elif test('/*'): skip_multiline_comment()
			else:
				if src[0] == '\n': line += 1
				src = src.substr(1)
		return trim_trailing_ws(begin.substr(0, len(begin) - len(src)))

	# Nevext 的引号串：两种引号**都**转义，且 `\` 后的任意字符都被吃掉。
	func scan_nevext_str(quote:String) -> void:
		var begin_line:int = line
		src = src.substr(1) # 跳过开头的引号
		while true:
			if src.is_empty(): error2(begin_line, 'unclosed string literal. '); return
			var c:String = src[0]; src = src.substr(1)
			if c == '\\':
				if src.is_empty(): error2(begin_line, 'unclosed string literal. '); return
				if src[0] == '\n': line += 1
				src = src.substr(1)
			elif c == quote: return
			elif c == '\n': line += 1
	# Stope 的引号串：双引号是字符串、转义；单引号是 BinArr，**不转义**
	# （与 Stope::Lexer::scanBinArr 一致）。
	func scan_stope_str(quote:String) -> void:
		var escapes:bool = (quote == '"')
		var begin_line:int = line
		src = src.substr(1) # 跳过开头的引号
		while true:
			if src.is_empty(): error2(begin_line, 'unclosed string literal. '); return
			var c:String = src[0]; src = src.substr(1)
			if escapes and c == '\\':
				if src.is_empty(): error2(begin_line, 'unclosed string literal. '); return
				if src[0] == '\n': line += 1
				src = src.substr(1)
			elif c == quote: return
			elif c == '\n': line += 1

	func skip_singleline_comment() -> void:
		src = src.substr(2)
		while not src.is_empty():
			var c:String = src[0]; src = src.substr(1)
			if c == '\n': line += 1; break
	func skip_multiline_comment() -> void:
		src = src.substr(2)
		while not src.is_empty():
			if test('*/'): src = src.substr(2); break
			if src[0] == '\n': line += 1
			src = src.substr(1)

	# ============================ 空白与注释 ============================
	func skip_ws() -> void:
		while not src.is_empty():
			if src[0] in white_chars:
				if src[0] == '\n': line += 1
				src = src.substr(1)
			elif state == State.Xml and test('<!--'):
				# `<!--` 只在 Xml 状态是注释；Nevext / Stope 里的 '<' 是小于号
				skip_xml_comment()
			else: break
	func skip_xml_comment() -> void:
		src = src.substr(4)
		while not src.is_empty():
			if test('-->'): src = src.substr(3); break
			if src[0] == '\n': line += 1
			src = src.substr(1)

	# ============================ 小工具 ============================
	func test(s:String) -> bool:
		if len(src) < len(s): return false
		return src.substr(0, len(s)) == s
	func error(msg:String) -> void:
		errors.append(str('line ',line,': ',msg))
	func error2(line_:int, msg:String) -> void:
		errors.append(str('line ',line_,': ',msg))

	const white_chars:Dictionary = {
		' ':0,'\t':0,'\v':0,'\f':0,'\r':0,'\n':0,
	}
	static func trim_trailing_ws(s:String) -> String:
		var n := len(s)
		while n > 0:
			if not (s[n - 1] in white_chars): break
			n -= 1
		return s.substr(0, n)
	static func is_alpha(ch:String) -> bool:
		var c := ord(ch)
		return (c >= ord('a') and c <= ord('z')) or (c >= ord("A") and c <= ord("Z"))
	static func is_digit(ch:String) -> bool:
		var c := ord(ch)
		return c >= ord('0') and c <= ord('9')
	static func is_word_begin(ch:String) -> bool:
		return (is_alpha(ch) or ch == '_' or ch == ':')
	static func is_word_char(ch:String) -> bool:
		return is_word_begin(ch) or is_digit(ch) or ch == '-'
