extends Node

# Demo 02: STML —— 解析一份内嵌的标记文档，把里面的代码段原样切出来。
# 对应 cpp/demo/02-stml.cpp：**只解析**，不编译也不执行 ——
# 接过 text 之后干什么完全是宿主的事。
#
# STML 是"两半"：树的形状由 STMLParser 管（标签名、属性、嵌套、结束标签是否配对），
# 内容怎么切由宿主管 —— 就是传给 parse() 的那个 state_func 回调，它决定
# 「这个标签的内容是子元素 / 纯文本 / Nevext 代码 / Stope 代码」。
# 这边的 $_state_func 与 C++ demo 里的 lambda 逐条对应。

const DOC := """
<stml package="MyPkg">

<config>
  windowTitle "demo";
  windowSize 1280, 720
</config>
<func name="myFunc" stope>
  let a = 1;
  return a + argc;
</func>
<class name="Person">
  <property name="name" />
  <property name="age" />
  <method name="greet" />
</class>

</stml>
"""

func _ready() -> void:
	demo()
	get_tree().quit()

func demo() -> void:
	var lexer := STMLLexer.Lexer.new(DOC)
	var parser := STMLParser.Parser.new(lexer)
	var root := STML.Element.new()
	if parser.parse(root, _state_func) != StopeResult.Success:
		for e in lexer.errors: print('[lex] ', e)
		for e in parser.errors: print('[parse] ', e)
		return

	print('[1] 根元素 <', root.tag, '>，属性 package="', root.attrs['package'], '"')
	print('[2] 它的直接子元素：')
	for c in root.children: print('  ', c.tag)

	# 按名字找，别像 C++ demo 那样写死下标 —— 下标会随空行/注释变。
	var func_ele := _child_by_tag(root, 'func')
	var class_ele := _child_by_tag(root, 'class')
	print('[3] <class> 的子元素：')
	for c in class_ele.children:
		print('  ', c.tag, '(自闭合)' if c.self_closing else '')

	# 代码段原样切出来：换行是真的换行，缩进也保留（尾部空白已被词法裁掉）。
	# 拿到它交给 StopeLexer 就能编译执行（见 demo_01.gd）—— STML 不管代码写得对不对。
	print('[4] <func> 里的 Stope 代码段：')
	print(func_ele.text)

# 宿主回调：与 C++ demo 的 lexerStateFunc 一一对应。
#   <config>            -> Nevext 代码
#   带 stope 属性的元素  -> Stope 代码
#   其余                -> Xml（按子元素列表解析）
static func _state_func(tag:String, attrs:Dictionary) -> int:
	if tag == 'config': return STMLLexer.State.Nevext
	if 'stope' in attrs: return STMLLexer.State.Stope
	return STMLLexer.State.Xml

static func _child_by_tag(ele:STML.Element, tag:String) -> STML.Element:
	for c in ele.children:
		if c.tag == tag: return c
	return null
