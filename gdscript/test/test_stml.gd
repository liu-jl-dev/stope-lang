class_name StopeTestSTML
# STML 测试。契约见 docs/zh-cn/stml-test-plan.md（§4 的 121 条用例）。
#
# 与其它三组不同，这一组的**用例清单也是数据文件**：
#   data/stml_cases.txt  输入（两侧共用：C++ 探针也读它）
#   data/golden_stml.txt 期望值（由 cpp/tools/golden_stml.cpp 在 C++ 侧 dump）
# 加删用例只改 stml_cases.txt 再重跑探针，别手推期望值。
#
# 每条词法用例比对 4 个字段，每条语法用例比对 6 个字段。

const CASES := 'res://test/data/stml_cases.txt'
const GOLDEN := 'res://test/data/golden_stml.txt'

static func run(rep:StopeTestUtil.Report) -> void:
	var cases := StopeTestUtil.read_golden(CASES)
	var gold := {}
	for g in StopeTestUtil.read_golden(GOLDEN):
		gold[g.get('ID', '')] = g
	if cases.is_empty() or gold.is_empty():
		rep.add_fail(str('  FAIL STML：读不到 ', CASES, ' 或 ', GOLDEN))
		return
	for c in cases:
		var id:String = c.get('ID', '')
		var src := StopeTestUtil.unesc(c.get('SRC', ''))
		var times:int = int(c.get('TIMES', '1'))
		if times > 1:
			var one := src
			src = ''
			for i in range(times): src += one
		var g = gold.get(id)
		if g == null:
			rep.add_fail(str('  FAIL ', id, '：golden 里没有这条，先重跑探针'))
			continue
		if c.get('KIND', 'lex') == 'parse':
			_run_parse(rep, id, src, c.get('SF', 'default'), g)
		else:
			_run_lex(rep, id, src, c.get('ST', 'Xml'), g)
	_check_attrs_copy(rep)

static func _run_lex(rep:StopeTestUtil.Report, id:String, src:String,
		st_name:String, g:Dictionary) -> void:
	var lx := STMLLexer.Lexer.new(src)
	lx.state = _state(st_name)
	var toks := ''
	var lexes := ''
	for i in range(10000): # 与 C++ 的 slexAll 同一道保险丝
		var t := lx.next_token()
		if i > 0: toks += ' '
		toks += str(STML.Token.Type.keys()[t.type], '(', t.line, ')')
		if _has_lexeme(t.type):
			if lexes != '': lexes += ','
			lexes += str(i, ':', StopeTestUtil.esc_shape(t.lexeme))
		if t.type == STML.Token.Type.Eof: break
	rep.check(id, 'TOKS', g.get('TOKS', ''), toks)
	rep.check(id, 'LEXS', g.get('LEXS', ''), lexes)
	rep.check(id, 'ERRN', g.get('ERRN', ''), str(lx.errors.size()))
	rep.check(id, 'ERRS', g.get('ERRS', ''),
		StopeTestUtil.join_esc(lx.errors, StopeTestUtil.esc_shape))

static func _run_parse(rep:StopeTestUtil.Report, id:String, src:String,
		sf_name:String, g:Dictionary) -> void:
	var lx := STMLLexer.Lexer.new(src)
	var parser := STMLParser.Parser.new(lx)
	var root := STML.Element.new()
	var result:int = parser.parse(root, _state_func(sf_name))
	rep.check(id, 'SHAPE', g.get('SHAPE', ''), shape_elem(root))
	rep.check(id, 'RESULT', g.get('RESULT', ''),
		'Success' if result == StopeResult.Success else 'Error')
	rep.check(id, 'ERRN', g.get('ERRN', ''), str(parser.errors.size()))
	rep.check(id, 'ERRS', g.get('ERRS', ''),
		StopeTestUtil.join_esc(parser.errors, StopeTestUtil.esc_shape))
	# B-16：词法错误不并进 parser.errors，两边都要查
	rep.check(id, 'LEXERRN', g.get('LEXERRN', ''), str(lx.errors.size()))
	rep.check(id, 'LEXERRS', g.get('LEXERRS', ''),
		StopeTestUtil.join_esc(lx.errors, StopeTestUtil.esc_shape))

# ============================ 形状串 ============================
# 与 C++ 的 Stope::STML::Test::shapeElem 逐字符一致：
# tag → line → / → 属性（**键的字典序**，不是源码顺序）→ 文本 → 子元素
static func shape_elem(e:STML.Element) -> String:
	var d := str('Elem(', StopeTestUtil.esc_shape(e.tag), ', L', e.line)
	if e.self_closing: d += ', /'
	var keys:Array = e.attrs.keys(); keys.sort()
	for k in keys:
		d += str(', @', StopeTestUtil.esc_shape(k))
		if e.attrs[k] != '': d += str('="', StopeTestUtil.esc_shape(e.attrs[k]), '"')
	if e.text != '': d += str(', T="', StopeTestUtil.esc_shape(e.text), '"')
	if not e.children.is_empty():
		d += ', C=['
		for i in range(e.children.size()):
			if i > 0: d += ' '
			d += shape_elem(e.children[i])
		d += ']'
	return d + ')'

# ============================ 用例里的状态与回调 ============================
static func _state(name:String) -> int:
	if name == 'Text': return STMLLexer.State.Text
	if name == 'Nevext': return STMLLexer.State.Nevext
	if name == 'Stope': return STMLLexer.State.Stope
	return STMLLexer.State.Xml
# 与 C++ 的 defaultStateFunc 一致：<sto> → Stope、<nev> → Nevext、<p> → Text
static func _sf_default(tag:String, _attrs:Dictionary) -> int:
	if tag == 'sto': return STMLLexer.State.Stope
	if tag == 'nev': return STMLLexer.State.Nevext
	if tag == 'p': return STMLLexer.State.Text
	return STMLLexer.State.Xml
static func _sf_text(_tag:String, _attrs:Dictionary) -> int:
	return STMLLexer.State.Text
static func _state_func(sf_name:String) -> Callable:
	if sf_name == 'null': return Callable()
	if sf_name == 'text': return _sf_text
	return _sf_default

static func _has_lexeme(t:int) -> bool:
	var T := STML.Token.Type
	return t == T.Word or t == T.String or t == T.Text or t == T.NevextSrc or t == T.StopeSrc

# ============================ 宿主改不到解析器 ============================
# C++ 的 LexerStateFunc 按值收 std::map，宿主在回调里删/加键影响不到解析结果；
# GDScript 传的是 Dictionary（引用类型），所以 stml_parser 里必须显式 duplicate。
# 这里用同一个输入跑两遍，一遍让回调**故意破坏** attrs，形状串必须一致。
static func _sf_mutate(_tag:String, attrs:Dictionary) -> int:
	attrs['injected'] = 'boom'
	attrs.clear()
	return STMLLexer.State.Xml

static func _check_attrs_copy(rep:StopeTestUtil.Report) -> void:
	const SRC := '<r a="1" b="2"><c d="3"/></r>'
	rep.check('S-COPY', 'attrs 不受宿主影响',
		_parse_shape(SRC, _sf_default), _parse_shape(SRC, _sf_mutate))

static func _parse_shape(src:String, sf:Callable) -> String:
	var parser := STMLParser.Parser.new(STMLLexer.Lexer.new(src))
	var root := STML.Element.new()
	parser.parse(root, sf)
	return str(shape_elem(root), ' errs=', parser.errors.size())
