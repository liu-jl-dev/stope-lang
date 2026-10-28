class_name StopeTestCompiler
# 编译器测试。契约见 docs/zh-cn/compiler-test-plan.md。
#
# 期望值来自 C++ 侧探针 dump 的 test/data/golden.txt（195 条）的
# CMP / OUT / CERRS 三个字段，走完整 Lexer -> Parser -> Compiler，
# 比对返回码、Program 序列化串、编译器错误列表。

const GOLDEN := 'res://test/data/golden.txt'
const DISASM := 'res://test/data/golden_disasm.txt'

static func run(rep:StopeTestUtil.Report) -> void:
	var cases := StopeTestUtil.read_golden(GOLDEN)
	if cases.is_empty():
		rep.add_fail(str('  FAIL 编译器：读不到 ', GOLDEN))
		return
	for c in cases:
		var id:String = c.get('ID', '')
		var src := StopeTestUtil.unesc(c.get('SRC', ''))
		var fold:bool = c.get('FOLD', '0') == '1'
		var got := _one(src, fold)
		for k in ['CMP', 'OUT', 'CERRS']:
			rep.check(id, k, c.get(k, ''), got[k])
	_check_dup(rep)
	_check_disasm(rep)

static func _one(src:String, fold:bool) -> Dictionary:
	# 前端：Lexer + Parser
	var cfg := StopeTestUtil.custom_config()
	var lx := StopeLexer.Lexer.new(src)
	var ps := StopeParser.Parser.new(lx, cfg)
	ps.const_folding = fold
	var ast := StopeAst.Prog.new()
	ps.parse_program(ast)

	# 后端：Compiler
	var c := StopeCompiler.Compiler.new(cfg)
	var out := StopeTestUtil.new_program()
	var rc:int = c.compile(ast, out)
	return {
		'CMP': 'OK' if rc == StopeResult.Success else 'ERR',
		'OUT': StopeTestUtil.esc_(StopeTestUtil.dump_program(out, cfg.opcodes)),
		'CERRS': StopeTestUtil.join_esc(c.errors, StopeTestUtil.esc_),
	}

# 指令表注册的查重。C++ 的 addCustomOpcode 遇到同名返回
# DuplicateWithBuiltinOpcode 且**不插入**；GDScript 侧以前是直接覆盖，
# 调用看起来成功、实际把先注册的那个悄悄换掉了。
static func _check_dup(rep:StopeTestUtil.Report) -> void:
	var cfg := StopeTestUtil.custom_config() # 已有 myop / vop 两个
	rep.check('C-DUP', '新名字', str(StopeResult.Success),
		str(cfg.add_custom_opcode('dup', 200, 0)))
	rep.check('C-DUP', '重名返回值', str(StopeResult.DuplicateWithBuiltinOpcode),
		str(cfg.add_custom_opcode('dup', 201, 5)))
	rep.check('C-DUP', '保留首次注册', '200/0',
		str(cfg.opcodes['dup'].opcode, '/', cfg.opcodes['dup'].arg_num))
	rep.check('C-DUP', '条数没变', '3', str(cfg.opcodes.size()))

# 反汇编器（StopeDebug.disasm）与 C++ 的 DumpProgram 逐字节比对。
# 反汇编不是标准的一部分（debug.hpp 是调试工具），但两侧都实现了，输出就该一样：
# 列宽、表顺序、warning 文案这些手写期望值必错，所以数据照旧由 C++ 探针 dump。
static func _check_disasm(rep:StopeTestUtil.Report) -> void:
	var cases := StopeTestUtil.read_golden(DISASM)
	if cases.is_empty():
		rep.add_fail(str('  FAIL 反汇编：读不到 ', DISASM))
		return
	for c in cases:
		var id:String = c.get('ID', '')
		var prog:StopeProgram.Program
		var cfg:StopeOpcode.CustomOpcodeConfig
		if c.get('MODE', 'src') == 'raw':
			prog = _from_ops(c.get('OPS', ''))
		else:
			cfg = _dis_cfg(c.get('CFG', 'main'))
			prog = _compile(StopeTestUtil.unesc(c.get('SRC', '')), cfg)
		if prog == null:
			rep.add_fail(str('  FAIL ', id, '：编译失败（数据里这条是能编译的）'))
			continue
		rep.check(id, 'DIS', c.get('DIS', ''),
			StopeTestUtil.esc_(StopeDebug.disasm(prog, cfg)))

static func _dis_cfg(name:String) -> StopeOpcode.CustomOpcodeConfig:
	if name == 'none': return null	# 编译与反汇编都不传 config
	var cfg := StopeOpcode.CustomOpcodeConfig.new()
	if name == 'collide':
		# 故意用内置 Add 的编号：反汇编只能按内置解码，并报一条 warning
		cfg.add_custom_opcode('my:steal', StopeOpcode.Opcode.Add, 2)
	else:
		cfg.add_custom_opcode('myop', 100, 2)
		cfg.add_custom_opcode('vop', 101, -1)
	return cfg

static func _compile(src:String, cfg:StopeOpcode.CustomOpcodeConfig) -> StopeProgram.Program:
	var lx := StopeLexer.Lexer.new(src)
	var ps := StopeParser.Parser.new(lx, cfg)
	var ast := StopeAst.Prog.new()
	ps.parse_program(ast)
	var c := StopeCompiler.Compiler.new(cfg)
	var out := StopeProgram.Program.new()
	if c.compile(ast, out) != StopeResult.Success: return null
	return out

# MODE=raw 的记录：源码造不出来的 Program（未知编号、缺操作数），按 OPS 直接拼
static func _from_ops(ops:String) -> StopeProgram.Program:
	var p := StopeProgram.Program.new()
	for s in ops.split(','):
		if s == '': continue
		p.opcodes.append(int(s))
	return p
