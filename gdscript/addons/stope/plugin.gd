# Stope 插件的编辑器入口。纯库插件：启用后只做一件事 —— 确认实现完整，不往编辑器里加任何 UI。
#
# 本目录的脚本【不注册 class_name 全局类】，避免占用工程的全局类命名空间
# （GDScript 唯一的命名空间，插件与用户项目共享）。使用方统一从 stope.gd 进入：
#
#   const Stope = preload("res://addons/stope/stope.gd")
#   var lexer := Stope.Lexer.Lexer.new(SRC)
#
# 各组件的职责与原名对照见 stope.gd 的头部注释。
#
# 两条约束：
#   1. 【不要】给这些脚本加回 class_name —— 那会重新污染全局命名空间，并重新引入对
#      .godot/global_script_class_cache.cfg 的依赖。
#   2. 分发时把整个 addons/stope/ 目录拷进目标项目的 addons/ 下再启用即可；
#      零全局类注册，与项目自带代码零撞名。

@tool
extends EditorPlugin

# 插件必须提供的脚本文件。少一个就说明目录拷得不全。
const IMPL_FILES := [
	"stope.gd", "stope_result.gd", "opcode.gd", "lexer.gd", "ast.gd",
	"ast_visitor.gd", "binarr_parser.gd", "expr_optim.gd", "parser.gd",
	"compiler.gd", "program.gd", "debug.gd", "basic_vm.gd",
	"stml.gd", "stml_lexer.gd", "stml_parser.gd",
]

func _enter_tree() -> void:
	_check_complete()

# 只在编辑器控制台里提示，不弹窗、不阻断 —— 缺文件时插件本身仍能加载，
# 真正的错误会在用到那个文件的脚本里报出来，这里只是把它提前说清楚。
func _check_complete() -> void:
	var missing: Array[String] = []
	for f in IMPL_FILES:
		if not ResourceLoader.exists("res://addons/stope/" + f):
			missing.append(f)
	if not missing.is_empty():
		push_warning(
			"Stope 插件不完整，缺少脚本：%s。请确认 addons/stope/ 未被裁剪。"
			% ", ".join(missing)
		)
