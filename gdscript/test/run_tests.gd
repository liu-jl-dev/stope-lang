extends SceneTree

# GDScript 实现的测试入口。
#
# 用法（在 gdscript/ 目录下）：
#   godot --headless --path . --script res://test/run_tests.gd
# 退出码 0 = 全绿，1 = 有失败。
#
# 三组测试共用一个 Report：词法 / 语法 / 编译器，分别对应
# docs/zh-cn/lexer-test-plan.md、parser-test-plan.md、compiler-test-plan.md。
# 期望值不是手写的，全部来自 C++ 侧探针 dump 的 test/data/*.txt
# （怎么重新生成见 gdscript/docs/testing.md）。

func _init() -> void:
	var rep := StopeTestUtil.Report.new()

	print('================ Stope GDScript 测试 ================')

	print('[1/3] 词法分析')
	StopeTestLexer.run(rep)
	print(rep.summary())

	var after_lex:int = rep.total
	print('[2/3] 语法分析')
	StopeTestParser.run(rep)
	print('  （语法累计）', rep.summary())

	print('[3/3] 编译器')
	StopeTestCompiler.run(rep)
	print(rep.summary())

	print('====================================================')
	if rep.failed == 0:
		print('全部通过：共 ', rep.total, ' 条断言')
	else:
		print('失败 ', rep.failed, ' 条：')
		for l in rep.lines: print(l)
	print('  （其中词法组 ', after_lex, ' 条断言）')
	quit(1 if rep.failed > 0 else 0)
