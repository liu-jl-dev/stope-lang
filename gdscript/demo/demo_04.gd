extends Node

# Demo 04: 预导出（preExports）—— 宿主先把形参塞进作用域，再编译函数体。
# 对应 cpp/demo/04-pre-export.cpp。
#
# 场景：STML 文档里定义函数，参数表写在标签属性上（params="a b"），函数体是
# Stope 源码。编译函数体时把 params 里的名字当 preExports 传进去，它们就先占好
# 槽位、进 Program.exports；宿主在 run() 之前把实参写进这些槽位，函数体里的 a、b
# 直接就能读到。
#
# 为什么不靠「未声明标识符自动导出」？—— 那条路也行，但导出的是**函数体里用到
# 的名字**，顺序取决于出现位置、没用到的形参根本不会存在。预导出让「参数表」
# 只有一份、且顺序固定为标签里写的顺序，宿主可以照参数表直接写槽位。

const DOC := """
<stml>
<func name="add" params="a b" stope>
    return a + b;
</func>
</stml>
"""

# 这个 demo 不给函数传实参，argc / args[i] 用不上；但接口要求必须给一个。
class NoArgs extends StopeBasicVM.Arguments:
	func at(_state:StopeBasicVM.State, _index_or_key) -> Variant:
		return null
	func num() -> int:
		return 0

func _ready() -> void:
	demo()
	get_tree().quit()

func demo() -> void:
	# ---------- 1. 从 STML 里取出函数定义 ----------
	# 带 stope 属性的元素，内容按 Stope 代码扫；切出来的 text 就是原样源码。
	var lexer := STMLLexer.Lexer.new(DOC)
	var parser := STMLParser.Parser.new(lexer)
	var root := STML.Element.new()
	if parser.parse(root, _state_func) != StopeResult.Success:
		for e in lexer.errors: print('[lex] ', e)
		for e in parser.errors: print('[parse] ', e)
		return

	var fn := _child_by_tag(root, 'func')
	var name:String = fn.attrs['name']
	var params := fn.attrs['params'].split(' ', false)	# "a b" -> ["a", "b"]
	print('[1] 从 <func> 取出：', name, '(', ', '.join(params), ')')

	# ---------- 2. 用参数表当 preExports 编译 ----------
	# 形参先占槽位（a=0、b=1），函数体里的 a、b 于是解析到文件作用域 ——
	# 反汇编里是 PushValue(0) / PushValue(1)。
	var program := StopeProgram.Program.new()
	print('\n[2] 编译函数体（preExports = 形参表）：')
	if not compile_and_report(fn.text, fn.text_line, params, program):
		return
	print(StopeDebug.disasm(program))
	var parts:Array[String] = []
	for k in program.exports:
		parts.append('%s=%d' % [k, program.exports[k]])
	print('  exports: ', ' '.join(parts))

	# ---------- 3. 塞实参、运行 ----------
	# 编译期就知道槽位，所以 run() 之前就能把值写进去 —— 这才是预导出的用处：
	# 宿主的「调用」就是写变量 + 跑一遍，不需要额外的参数传递机制。
	var state := StopeBasicVM.State.new()
	state.set_api(StopeBasicVM.Api.new())
	state.set_program(program)
	state.set_arguments(NoArgs.new())
	state.variables[program.exports['a']] = 3
	state.variables[program.exports['b']] = 4

	if state.run() != StopeResult.Success:
		for e in state.errors: print('[vm] ', e)
		return
	print('\n[3] add(3, 4) = ', state.returns[0])

	# ---------- 4. 陷阱：预导出的名字不能再声明 ----------
	# 名字已经进了文件作用域，源码里再 export 同名、或顶层 let 同名，都是
	# duplicate。预导出的变量只能赋值（a = 1;），不能重新声明。
	print('\n[4] 函数体里又写 export a;：')
	compile_and_report('export a; return a;', 1, params, StopeProgram.Program.new())

# 带 stope 属性的元素，内容按 Stope 代码扫；其余按子元素列表（Xml）解析。
static func _state_func(_tag:String, attrs:Dictionary) -> int:
	return STMLLexer.State.Stope if 'stope' in attrs else STMLLexer.State.Xml

# 按名字找子元素。
static func _child_by_tag(ele:STML.Element, tag:String) -> STML.Element:
	for c in ele.children:
		if c.tag == tag: return c
	return null

# 编译一份源码，pre_exports 原样交给 compiler.compile。失败时打印错误并返回 false。
# start_line 是 src 首行的物理行号 —— 从 STML 切出来的代码段不是从 1 开始，设给
# lexer 之后报错行号才和文档对得上（这里直接从 fn.text_line 取）。
static func compile_and_report(src:String, start_line:int, pre_exports:Array,
		out:StopeProgram.Program) -> bool:
	var lexer := StopeLexer.Lexer.new(src)
	lexer.line = start_line
	var parser := StopeParser.Parser.new(lexer)
	var tree := StopeAst.Prog.new()
	parser.parse_program(tree)
	for e in lexer.errors: print('  lexer: ', e)
	for e in parser.errors: print('  parser: ', e)

	var compiler := StopeCompiler.Compiler.new()
	var rc := compiler.compile(tree, out, pre_exports)
	for e in compiler.errors: print('  compiler: ', e)
	return rc == StopeResult.Success and lexer.errors.is_empty() \
		and parser.errors.is_empty()
