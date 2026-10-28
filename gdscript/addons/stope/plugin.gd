# Stope 插件的编辑器入口。纯库插件：启用后只做一件事 —— 确认实现完整，不往编辑器里加任何 UI。
#
# 插件的实体是本目录下那 15 个脚本（外加本文件），它们全部靠 class_name 互相引用，
# 因此它们是【全局类】，启用本插件后项目里任何脚本都能直接用：
#
#   StopeOpcode       指令集（33 条内置 + 自定义指令登记）
#   StopeLexer        Token 类型 + 词法分析
#   StopeParser       语法分析
#   StopeAst          AST 节点定义 + 形状串序列化
#   StopeASTVisitor   遍历骨架
#   StopeBinArrParser '...' 内容的字节解析
#   StopeExprOptim    常量折叠
#   StopeCompiler     编译器（AST -> Program）
#   StopeResult       跨模块共用的返回码（对齐 C++ 的 Stope::Result）
#   StopeProgram      Program 数据结构（to_map / to_json_string）
#   StopeDebug        Program 反汇编（disasm，对应 C++ debug.hpp 的 Disasm）
#   StopeBasicVM      参考执行器（不是标准；说明见仓库的 docs/zh-cn/vm-guide.md）
#   STML / STMLLexer / STMLParser   STML 词法与语法
#
# 两条约束：
#   1. 【不要】给这些脚本改名，也不要删掉 class_name —— 改名会让全部引用同时失效。
#   2. 分发时把整个 addons/stope/ 目录拷进目标项目的 addons/ 下再启用即可；
#      全局类名带 Stope 前缀，与项目自带代码撞名的概率很低，但并非不可能。

@tool
extends EditorPlugin

# 插件必须提供的全局类。少一个就说明目录拷得不全，或 class_name 被改过。
const IMPL_CLASSES := [
	"StopeOpcode", "StopeLexer", "StopeParser", "StopeAst", "StopeASTVisitor",
	"StopeBinArrParser", "StopeExprOptim", "StopeCompiler", "StopeProgram",
	"StopeBasicVM", "STML", "STMLLexer", "STMLParser",
]

func _enter_tree() -> void:
	_check_complete()

# 只在编辑器控制台里提示，不弹窗、不阻断 —— 缺类时插件本身仍能加载，
# 真正的错误会在用到那个类的脚本里报出来，这里只是把它提前说清楚。
func _check_complete() -> void:
	var have := {}
	for c in ProjectSettings.get_global_class_list():
		have[c.get("class", "")] = c.get("path", "")
	var missing: Array[String] = []
	for name in IMPL_CLASSES:
		if not have.has(name):
			missing.append(name)
	if not missing.is_empty():
		push_warning(
			"Stope 插件不完整，缺少全局类：%s。请确认 addons/stope/ 未被裁剪；"
			% ", ".join(missing)
			+ "若是刚拷入，先执行 godot --headless --import 刷新全局类缓存。"
		)
