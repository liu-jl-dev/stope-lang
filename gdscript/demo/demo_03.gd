extends Node

# Demo 03: 自定义指令 —— 给编译器加几条自己的指令，只编译 + 反汇编，不运行。
# 对应 cpp/demo/03-custom-opcode.cpp。
#
# 项目只规定 33 条内置指令（addons/stope/opcode.gd）与 Program 的编码契约；
# 再往上加指令是宿主自己的事，三步：
#
#   1. 用 CustomOpcodeConfig 登记「名字 -> (编号, 参数个数)」；
#   2. 同一份 config 同时交给 Parser 和 Compiler：Parser 靠它把名字识别成
#      Custom token（查不到就只是普通标识符），Compiler 靠它查编号与参数个数；
#   3. 产物里就只是一串 int —— 编号什么含义、谁来执行，全由宿主决定。
#
# 本 demo 不运行程序：自定义指令在 StopeBasicVM 里没有实现，也不该有 ——
# BasicVM 只是内置示例执行器，不是标准的一部分（见 docs/zh-cn/vm-guide.md）。
# 自定义指令的意义正在于此：宿主自己定义、自己执行。
#
# 两条硬约束（见 docs/zh-cn/compiler-test-plan.md §4.4）：
#   * 编号必须 > Opcode.Return（即 >= StopeOpcode.FIRST_CUSTOM_OPCODE）。
#     opcodes 是 int 混排序列，撞号以后与内置指令无法区分（[5] 演示）。
#   * 定长指令的 arg_num 必须与实际调用一致，否则编译期报错、不产出（[4] 演示）。
#
# 反汇编用 StopeDebug.disasm()（对应 C++ 的 DumpProgram）：它会拿 config 反查
# 自定义指令的名字、按是否变长决定吃不吃后面那个「参数个数」，并在编号撞内置时
# 打 warning（[5] 演示）。测试比对用的单行格式在测试侧（StopeTestUtil.dump_program），不进库。

func _ready() -> void:
	demo()
	get_tree().quit()

func demo() -> void:
	# ---------- 1. 登记自定义指令 ----------
	# arg_num >= 0 定长；arg_num < 0（默认 -1）变长，编译产物里会多写一个
	# 「本次调用的参数个数」。名字里的 ':' 是词法器支持的命名空间写法，
	# 用来避开宿主函数名（fmt:println 那种）。
	var config := StopeOpcode.CustomOpcodeConfig.new()
	config.add_custom_opcode('my:add', StopeOpcode.FIRST_CUSTOM_OPCODE + 0, 2)
	config.add_custom_opcode('my:log', StopeOpcode.FIRST_CUSTOM_OPCODE + 1, -1)
	config.add_custom_opcode('my:halt', StopeOpcode.FIRST_CUSTOM_OPCODE + 2, 0)
	print('[1] 登记自定义指令：')
	var items:Array[StopeOpcode.CustomOpcode] = []
	for k in config.opcodes: items.append(config.opcodes[k])
	items.sort_custom(func(a:StopeOpcode.CustomOpcode, b:StopeOpcode.CustomOpcode) -> bool:
		return a.opcode < b.opcode)
	for info in items:
		print('  ', info.name, ' -> #', info.opcode,
			'（变长）' if info.arg_num < 0 else str('（定长 ', info.arg_num, ' 参）'))

	# ---------- 2. 编译并反汇编 ----------
	# 注意 my:add 的参数照常先压栈，指令本身不再带操作数；只有 my:log 这种变长
	# 指令后面多一个 int。反汇编要认出这些，必须拿着同一份 config。
	const src := """
    let x = 3;

    my:add(x, 4);        // 定长 2 参
    my:log("x =", x);    // 变长 2 参
    my:log();            // 变长 0 参
    my:halt();           // 定长 0 参

    return x;
  """
	var program := StopeProgram.Program.new()
	print('\n[2] 编译结果：')
	if not compile_and_report(src, config, program):
		return
	print(StopeDebug.disasm(program, config))

	# ---------- 3. 对照：名字没登记就只是普通调用 ----------
	# 词法器只有在 config 里查得到名字时才吐 Custom token，否则 "my:add" 就是个
	# 普通标识符 —— 编译成 Call，即「调用一个名叫 my:add 的宿主函数」，
	# 它会被登记进 exports。
	var plain := StopeProgram.Program.new()
	print('\n[3] 同样的调用，不传 config：')
	if compile_and_report('my:add(1, 2);', null, plain):
		print(StopeDebug.disasm(plain))

	# ---------- 4. 参数个数不符 ----------
	# 定长指令的参数量在编译期校验；报错后 compile() 会把 out 复原为空，
	# 免得一个半成品 Program 被当成能跑的东西。
	var bad := StopeProgram.Program.new()
	print('\n[4] 定长 2 参却只给 1 个：')
	if not compile_and_report('my:add(1);', config, bad):
		print('  -> 编译失败，Program 已清空（opcodes 剩 ', len(bad.opcodes), ' 个 int）')

	# ---------- 5. 陷阱：编号撞到内置指令 ----------
	# 这里故意用一个内置编号注册：编译器写出的仍是同一个 int，谁也分不清它
	# 到底是 Add 还是 my:steal —— 反汇编只能按内置指令解码。
	var collide := StopeOpcode.CustomOpcodeConfig.new()
	collide.add_custom_opcode('my:steal', StopeOpcode.Opcode.Add, 2)
	var stolen := StopeProgram.Program.new()
	print('\n[5] 用内置 Add 的编号注册 my:steal：')
	if compile_and_report('my:steal(1, 2);', collide, stolen):
		print(StopeDebug.disasm(stolen, collide))
		print('  -> 反汇编只认得出 Add：my:steal 这个名字已经丢了，编号千万别撞内置。')

# 编译一份源码并打印错误。config 为 null 时按「没有自定义指令」处理。
static func compile_and_report(src:String, config:StopeOpcode.CustomOpcodeConfig,
		out:StopeProgram.Program) -> bool:
	var lexer := StopeLexer.Lexer.new(src)
	var parser := StopeParser.Parser.new(lexer, config)	# 第二参：可空的 config
	var tree := StopeAst.Prog.new()
	parser.parse_program(tree)
	for e in lexer.errors: print('  lexer: ', e)
	for e in parser.errors: print('  parser: ', e)

	var compiler := StopeCompiler.Compiler.new(config)	# 配置只在构造时注入一次
	var rc := compiler.compile(tree, out)
	for e in compiler.errors: print('  compiler: ', e)
	return rc == StopeResult.Success and lexer.errors.is_empty() \
		and parser.errors.is_empty()
