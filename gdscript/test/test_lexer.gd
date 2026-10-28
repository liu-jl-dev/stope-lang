class_name StopeTestLexer
# 词法分析测试。契约见 docs/zh-cn/lexer-test-plan.md。
#
# 期望值全部来自 C++ 侧探针 dump 的 test/data/golden_lex.txt（147 条），
# 逐个字段比对 TOKS / LEXEMES / ERRN / ERRS。

const GOLDEN := 'res://test/data/golden_lex.txt'

static func run(rep:StopeTestUtil.Report) -> void:
	var cases := StopeTestUtil.read_golden(GOLDEN)
	if cases.is_empty():
		rep.add_fail(str('  FAIL 词法：读不到 ', GOLDEN))
		return
	for c in cases:
		var id:String = c.get('ID', '')
		var src := StopeTestUtil.unesc(c.get('SRC', ''))
		var got := _one(src)
		for k in ['TOKS', 'LEXEMES', 'ERRN', 'ERRS']:
			rep.check(id, k, c.get(k, ''), got[k])

static func _one(src:String) -> Dictionary:
	var T := StopeLexer.Token.Type
	var lx := StopeLexer.Lexer.new(src)
	var cfg := StopeTestUtil.custom_config()
	var toks := ''
	var lexemes := ''
	for i in range(10000):
		var t := lx.next_token(cfg)
		if i > 0: toks += ' '
		toks += str(StopeLexer.Token.type_name(t.type), '(', t.line, ')')
		if t.parsed != '': toks += str('[', StopeTestUtil.esc_lex(t.parsed), ']')
		if t.type == T.Integer: toks += str('=', t.int_value)
		elif t.type == T.Float: toks += str('=', StopeAst.fmt_g(t.float_value))
		# lexeme 只比对「双方实现都提供」的类型：数字 / 字符串 / 二进制数组。
		# 标识符与标点的 lexeme 属实现自定，计划里不断言。
		if t.type == T.Integer or t.type == T.Float or t.type == T.String or t.type == T.BinArr:
			if lexemes != '': lexemes += ','
			lexemes += str(i, ':', StopeTestUtil.esc_lex(t.literal))
		if t.type == T.Eof: break
	return {
		'TOKS': toks,
		'LEXEMES': lexemes,
		'ERRN': str(lx.errors.size()),
		'ERRS': StopeTestUtil.join_esc(lx.errors, StopeTestUtil.esc_lex),
	}
