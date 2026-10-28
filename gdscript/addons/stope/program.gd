class_name StopeProgram

# 程序 = 指令流 + 常量池 + 变量表。字段名取 cpp/stope/program.hpp 的 snake_case 形式。
# 各容器都给默认空值，`Program.new()` 拿到的就是可直接编译/执行的空程序
# （与 C++ 的 Program 默认构造一致）。
class Program:
	var opcodes:Array[int] = []
	var variable_num:int = 0 # 变量数量
	var exports:Dictionary[String,int] = {} # 导出的变量的索引
	var int_consts:Array = []
	var float_consts:Array = []
	var string_consts:Array = []
	var bin_arr_consts:Array = []
	var max_return_num:int = 0 # return 语句最大返回值数量
	var required_stack_size:int = 0
	func to_map() -> Dictionary:
		return {
			'c': opcodes, 'i': int_consts, 'f': float_consts, 's': string_consts,
			'ba': bin_arr_consts, 'vn': variable_num, 'e': exports,
			'sc': required_stack_size, 'mr': max_return_num
		}
	func  to_json_string() -> String:
		return JSON.stringify(to_map(), '', false)
