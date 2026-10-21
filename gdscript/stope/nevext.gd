class_name Nevext # 默认继承 RefCounted

# 行为基准：cpp/nevext 下的 C++ 实现。
enum TokenType {
	Unexpected, EndOfFile, RawStr, QuotedStr, Sep,
}

class Token: # 默认继承 RefCounted
	var type:TokenType
	var line:int
	var literal:String   # 未展开转义的原始内容（QuotedStr 会包含 \n 这类转义序列）

class Result:
	var err:int = OK
	var val
	const OK = 0
	const Err = 1

const white_chars = { # in 关键字为从 key 中寻找
	' ':null,',':null,'\t':null,'\v':null,'\r':null,'\n':null,'\f':null,
}
# raw 串的额外终止字符，必须与 C++ 版 Lexer::rawStrEndChars 逐项一致。
const raw_str_end_chars = {
	';':null,'"':null,"'":null,
}

''' 词法分析 '''
class Lexer:
	var escape_func:Callable = Nevext.defalt_escape  # 由 Parser 调用，只作用于 QuotedStr
	var code:String
	var line:int = 1
	var errors:Array[String] = []      # 与 C++ 的 Lexer::errors 对应
	func _init(code_:String="") -> void:
		reset(code_)
	func reset(code_:String):
		self.code = code_; line = 1; errors = []
	func next_token() -> Token:
		var token:Token = Token.new()
		_skip_ws(); token.line = line
		if len(code) <= 0:
			token.type = TokenType.EndOfFile
			token.literal = '<EOF>'
		elif code[0] == ';':
			token.type = TokenType.Sep
			token.literal = ';'
			code = code.substr(1)
		elif code[0] == '"' or code[0] == "'":
			var res:Result = _scan_quote_string(code[0])
			if res.err:
				token.type = TokenType.Unexpected
				token.literal = '< unclosed string >'
				_push_error('unclosed string literal. ')
			else:
				token.type = TokenType.QuotedStr
				token.literal = res.val
		else:
			var res:Result = _scan_raw_string()
			if res.err: # 一个字符都没读到；与 C++ 一致，报 Unexpected 并吞掉一个字符
				token.type = TokenType.Unexpected
				code = code.substr(1)
			else:
				token.type = TokenType.RawStr
				token.literal = res.val
		return token
	func _scan_quote_string(quote_char:String) -> Result:
		var res := Result.new()
		code = code.substr(1)        # 跳过开头的引号
		var strlen:int = 0
		while true:
			if strlen >= len(code):  # 字符串未结束
				res.err = Result.Err
				break
			var c:String = code[strlen]
			if c == '\\':            # 转义作用于任意字符，包括 '\\' 自身
				strlen += 1
				if strlen >= len(code):
					res.err = Result.Err
					break
				if code[strlen] == '\n': line += 1  # 被转义的换行也要推进物理行号
				strlen += 1
				continue
			if c == quote_char: break
			if c == '\n': line += 1  # 引号串可以跨行
			strlen += 1
		res.val = code.substr(0, strlen)
		if res.err == Result.OK:
			code = code.substr(strlen + 1)  # 跳过闭合引号
		# 出错时不吞掉剩余输入，与 C++ 一致：后续 token 仍可继续读出
		return res
	func _scan_raw_string() -> Result:
		var res := Result.new()
		var strlen:int = 0
		while strlen < len(code):
			var c:String = code[strlen]
			if Nevext.white_chars.has(c) or Nevext.raw_str_end_chars.has(c): break
			if c == '/' and strlen + 1 < len(code) and (code[strlen + 1] == '/' or code[strlen + 1] == '*'): break
			strlen += 1
		if strlen <= 0:
			res.err = Result.Err
			return res
		res.val = code.substr(0, strlen)
		code = code.substr(strlen)
		return res
	func _skip_ws():
		while len(code) > 0:
			if Nevext.white_chars.has(code[0]):
				if code[0] == '\n': line += 1
				code = code.substr(1)
			elif _test('//'):
				var nl := code.find('\n')
				if nl < 0: code = ''
				else:
					code = code.substr(nl + 1)
					line += 1
			elif _test('/*'): _skip_multiline_comment()
			else:
				break
	func _skip_multiline_comment():
		code = code.substr(2)
		while len(code) > 0:
			if _test('*/'): code = code.substr(2); break
			if code[0] == '\n': line += 1
			code = code.substr(1)
			# 未闭合的多行注释不是错误，一直延伸到输入结束（语法规定）
	func _test(form:String, offset:int=0) -> bool:
		var c := code.substr(offset)
		if len(c) < len(form): return false
		return c.substr(0, len(form)) == form
	func _push_error(msg:String) -> void:
		errors.append('line ' + str(line) + ': ' + msg)


static func null_escape(s:String) -> Result:
	var res := Result.new(); res.val = s
	return res

const escape_map = {
	"'":"'",'"':'"','\\':'\\',
	'b':'\b','f':'\f','n':'\n',
	'r':'\r','t':'\t','v':'\v',
}
static func defalt_escape(s:String) -> Result:
	var res:Result = Result.new(); res.val = ''
	while len(s) > 0:
		var pos := s.find('\\')
		if pos < 0: # 没有 \
			res.val += s
			break
		res.val += s.substr(0, pos); s = s.substr(pos)
		if len(s) < 2 or not (s[1] in escape_map.keys()):
			res.err = Result.Err
			break
		res.val += escape_map[s[1]]
		s = s.substr(2)   # s 已重新以 '\' 开头，固定推进 2
	return res


''' 语法分析 '''
class Statement:
	var line:int
	var strings:Array[String]
	func _to_string() -> String:
		return '(Statement line:'+str(line)+' '+str(strings)+')'
class ParseResult:
	var err:int
	var val:Array[Statement]
class Parser:
	var lexer:Lexer
	var errors:Array[String]
	var _token:Token
	var _failed:bool = false      # 本次解析是否出错
	func _init(lexer_:Lexer=null) -> void:
		reset(lexer_)
	func reset(lexer_:Lexer):
		lexer = lexer_
		errors = []
	func parse_prog(pause_when_error:bool=true) -> ParseResult:
		var res := ParseResult.new(); res.val = []
		_failed = false
		while true:
			_token = lexer.next_token()
			if _token.type == TokenType.EndOfFile: break
			elif _token.type == TokenType.Sep: # 空语句
				pass
			elif _token.type == TokenType.Unexpected:
				_unexpected_token_error()
				_failed = true
			elif _token.type == TokenType.RawStr or _token.type == TokenType.QuotedStr:
				var stmt := Statement.new()
				stmt.line = _token.line
				stmt.strings = [_to_literal(_token)]
				_scan_rest_of_statement(stmt)
				res.val.append(stmt)
			else:
				_undefined_tokentype_err()
				_failed = true
			if pause_when_error and len(errors) > 0: break
		res.err = Result.Err if _failed else Result.OK
		return res
	func _scan_rest_of_statement(stmt:Statement) -> void:
		while true:
			_token = lexer.next_token()
			if _token.type == TokenType.EndOfFile: break # 允许最后一个语句没有分号结尾
			elif _token.type == TokenType.Unexpected:
				_unexpected_token_error(); _failed = true; break
			elif _token.type == TokenType.RawStr or _token.type == TokenType.QuotedStr:
				stmt.strings.append(_to_literal(_token))
			elif _token.type == TokenType.Sep: break
			else:
				_undefined_tokentype_err(); _failed = true; break
	# 只有 QuotedStr 才展开转义。失败时与 C++ 的 Parser::escape 一致：
	# 保留失败点之前已展开的部分，而不是丢成空串。
	func _to_literal(tok:Token) -> String:
		if tok.type != TokenType.QuotedStr: return tok.literal
		var esc:Result = lexer.escape_func.call(tok.literal)
		if esc.err:
			errors.append('line ' + str(tok.line) + ': invalid escape character. ')
			_failed = true
		return esc.val
	func _undefined_tokentype_err():
		errors.append('exception: line '+str(_token.line)
			+': undefined token type '+ str(_token.type))
		_failed = true
	func _unexpected_token_error():
		errors.append('line '+str(_token.line)+': unexpected token. ')
