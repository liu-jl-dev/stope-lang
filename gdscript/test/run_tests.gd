extends SceneTree

# GDScript 实现的测试入口。
#
# 用法（在 gdscript/ 目录下）：
#   godot --headless --path . --script res://test/run_tests.gd
# 退出码 0 = 全绿，1 = 有失败。
#
# 五组测试共用一个 Report：词法 / 语法 / 编译器 / STML / 执行器。前四组分别对应
# docs/zh-cn/lexer-test-plan.md、parser-test-plan.md、compiler-test-plan.md、
# stml-test-plan.md；执行器那组没有对应的跨实现契约（VM 不是标准，见
# docs/zh-cn/vm-guide.md），只锁 step() 与 run() 两条驱动路径的一致性。
# 前四组的期望值不是手写的，全部来自 C++ 侧探针 dump 的 test/data/*.txt
# （怎么重新生成见 gdscript/docs/testing.md）。

func _init() -> void:
	var rep := StopeTestUtil.Report.new()

	print('================ Stope GDScript 测试 ================')

	print('[1/5] 词法分析')
	StopeTestLexer.run(rep)
	print(rep.summary())

	var after_lex:int = rep.total
	print('[2/5] 语法分析')
	StopeTestParser.run(rep)
	print('  （语法累计）', rep.summary())

	print('[3/5] 编译器')
	StopeTestCompiler.run(rep)
	print(rep.summary())

	var after_compile:int = rep.total
	print('[4/5] STML')
	StopeTestSTML.run(rep)
	print('  （STML 本组）', rep.summary())
	var after_stml:int = rep.total

	print('[5/5] 执行器')
	StopeTestVM.run(rep)
	print('  （执行器本组）', rep.summary())

	print('====================================================')
	if rep.failed == 0:
		print('全部通过：共 ', rep.total, ' 条断言')
	else:
		print('失败 ', rep.failed, ' 条：')
		for l in rep.lines: print(l)
	print('  （其中词法组 ', after_lex, ' 条；词法+语法+编译器 ', after_compile, ' 条；',
		'STML ', after_stml, ' 条；执行器 ', rep.total - after_stml, ' 条）')
	quit(1 if rep.failed > 0 else 0)
