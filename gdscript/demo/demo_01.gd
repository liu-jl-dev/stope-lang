extends Node

# 统一入口：addons/stope 不注册全局类，preload 门面后按 Stope.模块 访问
const Stope = preload("res://addons/stope/stope.gd")

const SRC := """
// example: sum all arguments

let result = 0.0;
let i = 0;
while i < argc {
  result = result + args[i];
  i = i + 1;
}

fmt:println("结果为: ", result);
return result;
"""

# 宿主侧的参数表：args[i] / argc 都落到它身上（对应 C++ demo 的 MyArgs）。
# 与标准无关，纯属示例执行器的接口。
class MyArgs extends "res://addons/stope/basic_vm.gd".Arguments:
	var data:Array[float] = []

	func _init(values:Array[float]) -> void:
		data = values
	func at(state:Stope.BasicVM.State, index_or_key) -> Variant:
		if not (index_or_key is int):
			state.error('index must be an integer. ')
			return null
		if index_or_key < 0 or index_or_key >= data.size():
			state.error('index out of range. ')
			return null
		return data[index_or_key]
	func num() -> int:
		return data.size()

# 宿主函数表（对应 C++ demo 里 v_fmtPrintln 绑的那个 lambda）。
# GDScript 里 Callable 本身就是值，直接塞进变量槽就能被 Call 指令调到，
# 不需要再有一层 Link。签名统一是 func(args:Array) -> Variant。
class HostFns:
	func println(args:Array):
		var parts:Array[String] = []
		for a in args: parts.append(_fmt(a))
		print('[Host] ', ''.join(parts))
		return null

	# 浮点按 %g 的样子打（15.0 -> "15"），读起来清楚
	static func _fmt(v) -> String:
		if v is float and v == floor(v) and abs(v) < 1e15:
			return str(int(v))
		return str(v)

func _ready() -> void:
	demo()
	get_tree().quit()

func demo() -> void:
	var lexer := Stope.Lexer.Lexer.new(SRC)
	var parser := Stope.Parser.Parser.new(lexer)	# 第二参是 CustomOpcodeConfig，这里不需要
	var tree := Stope.Ast.Prog.new()
	parser.parse_program(tree)
	for e in lexer.errors: print('[lex] ', e)
	for e in parser.errors: print('[parse] ', e)

	var compiler := Stope.Compiler.Compiler.new()
	var program := Stope.Program.Program.new()
	var rc := compiler.compile(tree, program)	# 输入、输出都是引用语义
	for e in compiler.errors: print('[compile] ', e)
	if rc != Stope.Result.Success:
		push_error('compile failed, nothing to run')
		return
	print(Stope.Debug.disasm(program))	# 对齐 cpp/demo/01-quick-start.cpp 的 DisasmNoCustom

	# ---------------- step 2-3: 装配执行器 ----------------
	# 稳定性：内置的基础虚拟机 —— 会维护、接口不随意改，但不属于标准。
	# 换一个执行器，这一段可以整个换掉。
	var api := Stope.BasicVM.Api.new()
	var host := HostFns.new()
	var args := MyArgs.new([1.0, 2.0, 3.0, 4.0, 5.0])
	var state := Stope.BasicVM.State.new()
	state.set_api(api)
	state.set_program(program)
	state.set_arguments(args)
	# 宿主函数就是「某个变量槽里的值」：编译器把 fmt:println 当成未声明的标识符，
	# 于是它进了 exports，按索引把槽位填上一个 Callable，调用时 _call 直接调它。
	state.variables[program.exports['fmt:println']] = Callable(host, 'println')

	# ---------------- step 4: 跑 ----------------
	if state.run() != Stope.Result.Success:
		for e in state.errors: print('[vm] ', e)
		return
	print('result: ', HostFns._fmt(state.returns[0]))
