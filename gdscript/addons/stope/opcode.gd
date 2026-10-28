class_name StopeOpcode

enum Opcode {
	Assign, PushNull, PushFalse, PushTrue, PushInt,
	PushFloat, PushString, PushBinArr, PushValue, PushId,
	Call, At, Pop, Minus, Not,
	Pow, Mul, Div, IDiv, Mod,
	Add, Sub, EQ, NE, LT,
	LE, GT, GE, If, GoTo,
	GetArg, ArgNum, Return,
} # 共 33 个

# 自定义指令的编号从这里往上排（对应 cpp/include/stope/debug.hpp 的 kFirstCustomOpcode）。
# 占用 0..32 的编号会在反汇编时被当成内置指令解码，没有别的选择。
const FIRST_CUSTOM_OPCODE := Opcode.Return + 1

class CustomOpcode:
	var name:String
	var opcode:int
	var arg_num:int
	func _init(name_:String, opcode_:int, arg_n:int=-1) -> void:
		name = name_; opcode = opcode_; arg_num = arg_n

class CustomOpcodeConfig:
	var opcodes:Dictionary[String,CustomOpcode]
	# 同名重复注册**不插入**，返回 DuplicateWithBuiltinOpcode —— 与 C++
	# 的 addCustomOpcode 一致（cpp/include/stope/opcode.hpp）。以前这里直接覆盖，
	# 调用看起来成功、实际把先注册的那个悄悄换掉了。返回值可以不管（GDScript
	# 允许丢弃），要查就接。
	func add_custom_opcode(name:String, opcode:int, arg_num:int=-1) -> int:
		if opcodes.has(name): return StopeResult.DuplicateWithBuiltinOpcode
		opcodes[name] = CustomOpcode.new(name, opcode, arg_num)
		return StopeResult.Success

# 该指令是否带一个操作数。**唯一实现**：StopeDebug.opcode_has_arg 与测试侧的
# StopeTestUtil.dump_program 都从这里取，分档与 golden 探针 / VM 的步进规则一致。
# 对应 cpp/include/stope/debug.hpp 的 OpcodeHasArg（那边只管内置指令，自定义指令
# 由 CustomOpcodeHasArg 看 arg_num）。
static func has_a_param(inst:int) -> bool:
	if inst <= Opcode.PushTrue: return false	# 0..3
	if inst <= Opcode.At: return true			# 4..11  常量/变量索引、参数个数
	if inst <= Opcode.GE: return false		# 12..27
	if inst <= Opcode.GoTo: return true		# 28..29 If / GoTo 的跳转目标
	if inst <= Opcode.ArgNum: return false	# 30..31
	return true								# 32 Return 的返回值个数
