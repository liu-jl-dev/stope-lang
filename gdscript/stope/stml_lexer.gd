class_name STMLLexer

class Result:
	var err:int
	var value
	const Ok := 0
	const Err := 1

enum State {
	Xml, Nevext, Stope
}

class Lexer:
	var state:int
	var src:String
	var line:int = 1
	var errors:Array[String]
	func _init(source:String="") -> void:
		src = source
	func next_token() -> STML.Token:
		var token := STML.Token.new()
		skip_xml_ws(); token.line = line
		if state == State.Xml:
			if len(src) <= 0: token.set_(STML.Token.Type.Eof, '<EOF>')
			elif test('</'): token.set_(STML.Token.Type.CLAngle, '</'); src = src.substr(2)
			elif test('/>'): token.set_(STML.Token.Type.CRAngle, '/>'); src = src.substr(2)
			elif src[0] == '<': token.set_(STML.Token.Type.LAngle, '<'); src = src.substr(1)
			elif src[0] == '>': token.set_(STML.Token.Type.RAngle, '>'); src = src.substr(1)
			elif src[0] == '=': token.set_(STML.Token.Type.EQ, '='); src = src.substr(1)
			elif src[0] == "'" or src[0] == '"':
				var res:Result = scan_str(src[0])
				if res.err: token.set_(STML.Token.Type.Invalid, '')
				else: token.set_(STML.Token.Type.Str, res.value)
			elif is_word_begin(src[0]): token.set_(STML.Token.Type.Word, scan_word()) # scan_word 中进行了 src = src.substr( )
			else: token.set_(STML.Token.Type.Text, scan_text())
		elif state == State.Nevext:
			token.set_(STML.Token.Type.NevSrc, scan_nevext())
		elif state == State.Stope:
			token.set_(STML.Token.Type.StoSrc, scan_stope())
		else: error(str('unexpected lexer state ',state,'. ')); src = src.substr(1)
		return token
	
	func scan_str(quote:String) -> Result:
		var res := Result.new()
		var end:int = 1
		while true:
			#print(end,'  ',src.substr(1, end-1))
			if end >= len(src): error('unclosed string. '); res.err = Result.Err; break
			if src[end] == quote: break
			end += 1
		res.value = src.substr(1, end-1); src = src.substr(end + 1)
		return res
	func scan_word() -> String:
		var end:int = 1
		while end < len(src):
			if not is_word_char(src[end]): break
			end += 1
		var s:String = src.substr(0, end); src = src.substr(end)
		return s
	func scan_text() -> String:
		var end:int = 1 # 外层保证，src[0] 不可能是 <
		while end < len(src):
			if src[end] == '<': break # 不只是 </ ，还可能是子元素 <
			end += 1
		var s:String = src.substr(0, end); src = src.substr(end)
		return s
	func scan_nevext() -> String:
		var code:String = src
		while len(src) > 0:
			if test('</'): break
			elif src[0] == '\n': line += 1; src = src.substr(1)
			elif src[0] == "'" or src[0] == '"': skip_src_str(src[0])
			elif test('//'): skip_src_singline_comment()
			elif test('/*'): skip_src_multline_comment()
			else: src = src.substr(1)
		return code.substr(0, len(code) - len(src))
	func scan_stope() -> String:
		return scan_nevext()
	func skip_src_singline_comment():
		src = src.substr(2)
		var newline_idx:int = src.find('\n')
		if newline_idx < 0: src = src.substr(len(src))
		else: src = src.substr(newline_idx + 1); line += 1
	func skip_src_multline_comment():
		while len(src) > 0:
			if test('*/'): src = src.substr(2); break
			elif src[0] == '\n': src = src.substr(1); line += 1
			else: src = src.substr(1)
	func skip_src_str(quote:String):
		var begin_line:int = line
		while true:
			if len(src) <= 0: error2(begin_line, 'unclosed string. '); break
			if src[0] == quote: src = src.substr(1); break
			elif src[0] == '\\':
				if len(src) >= 2 and src[1] == '\n': line += 1
				src = src.substr(2)
			else: src = src.substr(1)
	
	func skip_xml_ws():
		while len(src) > 0:
			if src[0] == '\n': line = line + 1; src = src.substr(1)
			elif src[0] in white_chars: src = src.substr(1)
			else: break
	func skip_xml_comment():
		src = src.substr(3)
		while len(src) > 0:
			if test('-->'): src = src.substr(3); break
			if src[0] == '\n': line = line + 1
			src = src.substr(1)
	
	#func test(s:String, offset:int=0) -> bool:
		#var c := src.substr(offset)
		#if len(c) < len(s): return false
		#return c.substr(0, len(s)) == s
	func test(s:String) -> bool:
		if len(src) < len(s): return false
		return src.substr(0, len(s)) == s
	func error(msg:String):
		errors.append(str('line ',line,': ',msg))
	func error2(line_:int, msg:String):
		errors.append(str('line ',line_,': ',msg))
	
	const white_chars:Dictionary = {
		' ':0,'\t':0,'\v':0,'\f':0,'\r':0,'\n':0,
	}
	static func is_alpha(ch:String) -> bool:
		var c := ord(ch)
		return (c >= ord('a') and c <= ord('z')) or (c >= ord("A") and c <= ord("Z"))
	static func is_digit(ch:String) -> bool:
		var c := ord(ch)
		return c >= ord('0') and c <= ord('9')
	static func is_word_begin(ch:String) -> bool:
		return (is_alpha(ch) or ch == '_' or ch == ':')
	static func is_word_char(ch:String) -> bool:
		return is_word_begin(ch) or is_digit(ch)




























