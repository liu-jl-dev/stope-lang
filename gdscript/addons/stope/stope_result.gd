class_name StopeResult

# 对应 cpp/include/stope/common.hpp 的 Stope::Result，四项一一对应。
# 编译器、STML 语法器、指令表注册三处共用这一份 —— 以前 compiler.gd 内嵌 4 项、
# stml_parser.gd 内嵌 2 项，同名不同义，跨模块赋值时无法互相比较。
#
# 用匿名 enum 是为了让引用写成 StopeResult.Success，而不是 StopeResult.Result.Success。
# 数值与 C++ 一致（Success == 0），但**别用真假判断**：Success 是 0，反过来写
# `if not ok` 才对。
enum { Success, Error, UnknownError, DuplicateWithBuiltinOpcode }
