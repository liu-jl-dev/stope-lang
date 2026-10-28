class_name StopeLexer

# 17 个关键字
const key_words := {
	'idiv':Token.Type.IDiv,'if':Token.Type.If,'not':Token.Type.Not,'and':Token.Type.And,
	'or':Token.Type.Or,'elif':Token.Type.Elif,'else':Token.Type.Else,'let':Token.Type.Let,
	'return':Token.Type.Return,'while':Token.Type.While,'break':Token.Type.Break,'continue':Token.Type.Continue,
	'null':Token.Type.Null,'false':Token.Type.False,'true':Token.Type.True,'args':Token.Type.Args,
	'argc':Token.Type.Argc,'export':Token.Type.Export}

const I64_MAX := 9223372036854775807
# 浮点上溢 / 下溢的经验阈值：|指数| 超过它时 std::stod 会抛 out_of_range
const DOUBLE_EXP_MAX := 308

class Token:
	enum Type {
		Invalid,	#  无效
		Eof,		#  输入结尾
		Ident,		#  标识符
		Integer,	#  整数字面量
		Float,		#  浮点字面量
		String,		#  "..."  转义之后的文本在 parsed
		BinArr,		#  '...'  二进制数组，词法阶段【不做】转义
		Comma,		#  ,
		Semi,		#  ;
		LParen,		#  (

		RParen,		#  )
		LBrack,		#  [
		RBrack,		#  ]
		LBrace,		#  {
		RBrace,		#  }
		Assign,		#  =
		Add,		#  +
		Sub,		#  -
		Mul,		#  *
		Div,		#  /

		IDiv,		#  idiv
		Mod,		#  %
		Pow,		#  ^
		EQ,			#  ==
		NE,			#  !=
		LT,			#  <
		LE,			#  <=
		GT,			#  >
		GE,			#  >=
		Not,		#  not  !

		And,		#  and  &&
		Or,			#  or  ||
		If,			#  if
		Elif,		#  elif
		Else,		#  else
		Let,		#  let
		Return,		#  return
		While,		#  while
		Break,		#  break
		Continue,	#  continue

		Null,		#  null
		False,		#  false
		True,		#  true
		Args,		#  args
		Argc,		#  argc
		Export,		#  export
		Custom,		#  自定义指令
	} # 共 47 个
	static func type_name(t:int) -> String:
		return Type.keys()[t] if t >= 0 and t < Type.size() else str("?", t)

	var type:int = Type.Invalid
	var line:int = 0
	var literal:String = ''		# 原文切片
	var parsed:String = ''			# 规范形式：数字去 '_'、标识符拼 ':'、字符串转义之后
	var int_value:int = 0			# 仅 Integer
	var float_value:float = 0.0		# 仅 Float
	func invalidate() -> void:
		type = Type.Invalid

class Lexer:
	var input:String	# **未消费的剩余**原文；每取一个 token 就左移一截
	var line:int = 1
	var errors:Array[String] = []
	func _init(input_:String='') -> void: reset(input_)
	func reset(input_:String) -> void:
		input = input_
		line = 1
		errors = []

	# custom 可省。与 cpp/include/stope/lexer.hpp 一致：配置【不】存在词法器里，
	# 每次取 token 时传进来 —— 换一张表不必重建词法器。
	func next_token(custom:StopeOpcode.CustomOpcodeConfig = null) -> Token:
		var token := Token.new()
		skip_ws(); token.line = line
		if len(input) <= 0:
			token.type = Token.Type.Eof
		elif is_digit(input[0]) or input[0] == '.':
			scan_number(token)
		elif is_ident_begin(input[0]):
			scan_ident(token, custom)
		elif input[0] == '\'':
			scan_bin_arr(token)
		elif input[0] == '"':
			scan_string(token)
		elif input[0] == ',': take(token, Token.Type.Comma, 1)
		elif input[0] == ';': take(token, Token.Type.Semi, 1)
		elif input[0] == '(': take(token, Token.Type.LParen, 1)
		elif input[0] == ')': take(token, Token.Type.RParen, 1)
		elif input[0] == '[': take(token, Token.Type.LBrack, 1)
		elif input[0] == ']': take(token, Token.Type.RBrack, 1)
		elif input[0] == '{': take(token, Token.Type.LBrace, 1)
		elif input[0] == '}': take(token, Token.Type.RBrace, 1)
		elif input[0] == '=':
			if test('=', 1): take(token, Token.Type.EQ, 2)
			else: take(token, Token.Type.Assign, 1)
		elif input[0] == '+': take(token, Token.Type.Add, 1)
		elif input[0] == '-': take(token, Token.Type.Sub, 1)
		elif input[0] == '*': take(token, Token.Type.Mul, 1)
		elif input[0] == '/': take(token, Token.Type.Div, 1)
		elif input[0] == '%': take(token, Token.Type.Mod, 1)
		elif input[0] == '^': take(token, Token.Type.Pow, 1)
		elif input[0] == '!':
			if test('=', 1): take(token, Token.Type.NE, 2)
			else: take(token, Token.Type.Not, 1)
		elif input[0] == '<':
			if test('=', 1): take(token, Token.Type.LE, 2)
			else: take(token, Token.Type.LT, 1)
		elif input[0] == '>':
			if test('=', 1): take(token, Token.Type.GE, 2)
			else: take(token, Token.Type.GT, 1)
		elif test('&&'): take(token, Token.Type.And, 2)
		elif test('||'): take(token, Token.Type.Or, 2)
		else:
			# [通用契约 LEX-P-07] 未知字符必须消费，否则上层循环没有终止条件
			take(token, Token.Type.Invalid, 1)
			error("unknown token. ")
		return token

	# ---------------- 数字 ----------------
	func scan_number(token:Token) -> void:
		if test('0b') or test('0B'): scan_bin_integer(token)
		elif test('0o') or test('0O'): scan_oct_integer(token)
		elif test('0x') or test('0X'): scan_hex_integer(token)
		elif input[0] == '.': scan_dec_start_with_dot(token)
		else: scan_dec_number(token)
		token.parsed = token.literal.replace('_', '') # 去下划线
		get_number_value(token)
	func take_lexeme(token:Token, n:int) -> void:
		token.literal = input.substr(0, n)
		input = input.substr(n)
	func scan_bin_integer(token:Token) -> void:
		token.type = Token.Type.Integer
		var n:int = 2
		while n < len(input) and (input[n] == '_' or input[n] == '0' or input[n] == '1'):
			n += 1
		take_lexeme(token, n)
	func scan_oct_integer(token:Token) -> void:
		token.type = Token.Type.Integer
		var n:int = 2
		while n < len(input) and (input[n] == '_' or (input[n] >= '0' and input[n] <= '7')):
			n += 1
		take_lexeme(token, n)
	func scan_hex_integer(token:Token) -> void:
		token.type = Token.Type.Integer
		var n:int = 2
		while n < len(input) and (input[n] == '_' or is_digit(input[n])
				or (input[n] >= 'a' and input[n] <= 'f')
				or (input[n] >= 'A' and input[n] <= 'F')):
			n += 1
		take_lexeme(token, n)
	func scan_dec_number(token:Token) -> void: # [_0-9]+(.[_0-9]*)?([eE][+-]?[0-9]+)?
		token.type = Token.Type.Integer
		var n:int = 1 # 外层已保证第一个字符是数字
		while n < len(input) and (input[n] == '_' or is_digit(input[n])):
			n += 1
		if n < len(input) and input[n] == '.':
			token.type = Token.Type.Float
			n += 1
			while n < len(input) and (input[n] == '_' or is_digit(input[n])):
				n += 1
		n = scan_exponent(token, n)
		take_lexeme(token, n)
	func scan_dec_start_with_dot(token:Token) -> void: # .[_0-9]+([eE][+-]?[0-9]+)?
		token.type = Token.Type.Float
		var n:int = 1 # 外层已保证第一个字符是 .
		while n < len(input) and (input[n] == '_' or is_digit(input[n])):
			n += 1
		n = scan_exponent(token, n)
		take_lexeme(token, n)
	func scan_exponent(token:Token, n:int) -> int:
		if n < len(input) and (input[n] == 'e' or input[n] == 'E'):
			token.type = Token.Type.Float
			n += 1
			if n < len(input) and (input[n] == '+' or input[n] == '-'):
				n += 1
			while n < len(input) and is_digit(input[n]):
				n += 1
		return n

	# 返回 [base, prefix_len, body]，与 C++ Lexer::numberBase() 同规则
	static func number_base(s:String) -> Array:
		if len(s) >= 2 and s[0] == '0':
			if s[1] == 'b' or s[1] == 'B': return [2, s.substr(2)]
			elif s[1] == 'o' or s[1] == 'O': return [8, s.substr(2)]
			elif s[1] == 'x' or s[1] == 'X': return [16, s.substr(2)]
		return [10, s]

	func get_number_value(token:Token) -> void:
		if token.type == Token.Type.Integer:
			var base_info:Array = number_base(token.parsed)
			var base:int = base_info[0]
			var body:String = base_info[1]
			if len(body) <= 0: # 前缀后没有数字，如 0b / 0x / 0o
				error("invalid integer. "); token.invalidate(); return
			var value:int = 0
			for i in range(len(body)):
				var d:int = digit_of(body[i], base)
				if d < 0: # 该进制不允许的字符 —— 消费不完整
					error("invalid integer. "); token.invalidate(); return
				if value > (I64_MAX - d) / base: # 溢出
					error("invalid integer. "); token.invalidate(); return
				value = value * base + d
			token.int_value = value
		elif token.type == Token.Type.Float:
			var s:String = token.parsed
			if not re_float_form.search(s): # 形态上的消费完整性校验
				error("invalid float. "); token.invalidate(); return
			var m := re_exp_part.search(s)
			if m:
				var e:String = m.get_string(1)
				if not e.is_valid_int(): # 指数位数太多
					error("invalid float. "); token.invalidate(); return
				var exp_num:int = e.to_int()
				if exp_num > DOUBLE_EXP_MAX or exp_num < -DOUBLE_EXP_MAX: # 上溢 / 下溢
					error("invalid float. "); token.invalidate(); return
			var value:float = s.to_float()
			if is_inf(value) or is_nan(value):
				error("invalid float. "); token.invalidate(); return
			token.float_value = value
	static var re_float_form:RegEx = RegEx.create_from_string(
			'^([0-9]+(\\.[0-9]*)?|\\.[0-9]+)([eE][+-]?[0-9]+)?$')
	static var re_exp_part:RegEx = RegEx.create_from_string('[eE]([+-]?[0-9]+)$')
	static func digit_of(ch:String, base:int) -> int:
		if ch >= '0' and ch <= '9':
			var d:int = ord(ch) - ord('0')
			return d if d < base else -1
		elif ch >= 'a' and ch <= 'f':
			var da:int = ord(ch) - ord('a') + 10
			return da if da < base else -1
		elif ch >= 'A' and ch <= 'F':
			var dA:int = ord(ch) - ord('A') + 10
			return dA if dA < base else -1
		return -1

	# ---------------- 字符串 / 二进制数组 ----------------
	func scan_string(token:Token) -> void: # 双引号
		token.type = Token.Type.String
		input = input.substr(1)
		var n:int = 0
		while true:
			if n >= len(input): # 未闭合
				error("unclosed string literal. ")
				token.invalidate(); break
			elif input[n] == '\\':
				n += 1
				if n >= len(input):
					error("unclosed string literal. ")
					token.invalidate(); break
				n += 1
			elif input[n] == '"': break
			else: n += 1
			# 注：与 C++ 一致，跨行字符串【不】累加 line（待定项 D-13）
		token.literal = input.substr(0, n)
		input = input.substr(n)
		if len(input) > 0: input = input.substr(1) # 跳过最后的引号
		if token.type == Token.Type.String: escape_string(token)

	const escape_map := {"'":"'",'"':'"','\\':'\\','b':'\b','f':'\f','n':'\n','r':'\r','t':'\t','v':'\v',}
	# 注：非法转义时与 cpp/stope/lexer.hpp 的 escapeString() 一致 ——
	# 报错后【停止收集】，但 type 仍是 String、parsed 被截断到出错位置。
	# 这条对应词法计划里的待定项 D-14，改之前先看那份文档的说明。
	func escape_string(token:Token) -> void:
		var i:int = 0
		while i < len(token.literal):
			if token.literal[i] == '\\':
				i += 1
				if i >= len(token.literal):
					error("invalid escape character. "); return
				if not (token.literal[i] in escape_map):
					error("invalid escape character. "); return
				token.parsed += escape_map[token.literal[i]]
				i += 1
			else:
				token.parsed += token.literal[i]
				i += 1

	func scan_bin_arr(token:Token) -> void: # 单引号，内容不做任何转义
		token.type = Token.Type.BinArr
		input = input.substr(1)
		var n:int = 0
		while true:
			if n >= len(input):
				error("unclosed binary array. ")
				token.invalidate(); break
			if input[n] == '\'': break
			if input[n] == '\n': line += 1 # 二进制数组跨行累加（与字符串不同）
			n += 1
		token.literal = input.substr(0, n)
		input = input.substr(n)
		if len(input) > 0: input = input.substr(1)

	# ---------------- 标识符 ----------------
	func scan_ident(token:Token, custom:StopeOpcode.CustomOpcodeConfig) -> void: # ^[a-zA-Z_][a-zA-Z0-9_]*(:[a-zA-Z_][a-zA-Z0-9_]*)*
		token.type = Token.Type.Ident
		token.parsed = input.substr(0, 1); input = input.substr(1)
		while len(input) > 0 and is_ident_char(input[0]):
			token.parsed += input.substr(0, 1); input = input.substr(1)
		while len(input) > 0:
			skip_ws()
			if len(input) <= 0 or input[0] != ':': break
			token.parsed += ':'; input = input.substr(1)
			skip_ws()
			if len(input) <= 0 or not is_ident_begin(input[0]):
				error("unclosed identifier. "); token.invalidate(); break
			while len(input) > 0 and is_ident_char(input[0]):
				token.parsed += input.substr(0, 1); input = input.substr(1)
		token.literal = token.parsed
		analyze_ident(token, custom)
	func analyze_ident(token:Token, custom:StopeOpcode.CustomOpcodeConfig) -> void:
		if token.type == Token.Type.Invalid: return
		# 顺序与 C++ 一致：关键字优先，其次才是自定义指令，
		# 所以注册一个叫 if 的指令仍会按关键字处理。
		if token.parsed in key_words: token.type = key_words[token.parsed]
		elif custom != null and custom.opcodes.has(token.parsed): token.type = Token.Type.Custom
		else: token.type = Token.Type.Ident

	# ---------------- 空白与注释 ----------------
	const white_chars:Dictionary = {' ':0,'\t':0,'\v':0,'\f':0,'\r':0}
	func skip_ws() -> void: # 不用正则，因为要数换行
		while true:
			if len(input) <= 0: break
			elif input[0] in white_chars: input = input.substr(1); continue
			elif input[0] == '\n': input = input.substr(1); line += 1; continue
			elif test('//'): skip_line_comment(); continue
			elif test('/*'): skip_multiline_comment(); continue
			else: break
	func skip_line_comment() -> void:
		var p:int = input.find('\n')
		if p < 0: input = ''
		else:
			input = input.substr(p + 1); line += 1
	func skip_multiline_comment() -> void:
		input = input.substr(2)
		while len(input) > 0:
			if test('*/'): input = input.substr(2); return
			if input[0] == '\n': line += 1
			input = input.substr(1)

	# ---------------- 小工具 ----------------
	# 标点 / 运算符：与 cpp/stope/lexer.hpp 一致 —— 只设 type 并推进输入，
	# 不留 literal / parsed（词法计划 §2.2：标点的 lexeme 由实现自定，本文不断言）
	func take(token:Token, type_:int, n:int) -> void:
		token.type = type_
		input = input.substr(n)
	func error(msg:String) -> void:
		errors.append(str("line ", line, ": ", msg))
	func test(s:String, offset:int=0) -> bool:
		var a := input.substr(offset)
		if len(a) < len(s): return false
		return a.substr(0, len(s)) == s
	static func is_digit(ch:String) -> bool:
		return ord(ch) >= ord('0') and ord(ch) <= ord('9')
	static func is_alpha(ch:String) -> bool:
		var c := ord(ch)
		return (c >= ord('a') and c <= ord('z')) or (c >= ord("A") and c <= ord("Z"))
	static func is_ident_begin(ch:String) -> bool:
		return is_alpha(ch) or ch == '_'
	static func is_ident_char(ch:String) -> bool:
		return is_ident_begin(ch) or is_digit(ch)
