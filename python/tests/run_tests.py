"""测试入口。

分组与输出格式与 GDScript 的 ``run_tests.gd``、C# 的 ``Runner`` 一致，
方便三条命令横向对照::

    python python/tests/run_tests.py
    godot --headless --path gdscript --script res://test/run_tests.gd
    dotnet run --project csharp/Stope.Tests

期望值全部来自 ``gdscript/test/data/`` 的 golden 数据（执行器与嵌套深度两组例外），
所以**跑测试不需要 C++ 工具链**。
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# 嵌套深度上限那组要构造 600 / 12000 层的嵌套：Python 每层递归 3 个栈帧，
# 默认 1000 的限制在 300 层就先撞穿了。这里放宽到足够大（纯 Python 帧，内存很小）。
sys.setrecursionlimit(30000)

from tests import (  # noqa: E402
    test_binarr, test_compiler, test_disasm, test_lexer, test_parser, test_stml, test_vm,
)
from tests.report import Report  # noqa: E402


def main() -> int:
    print("====================================================")
    print("Stope Python 实现 —— 测试跑器")
    from tests import golden
    print("数据目录：" + golden.locate_data_dir())
    print("====================================================")

    groups = [
        ("词法（golden_lex.txt）", test_lexer.run),
        ("二进制数组 + 常量折叠（golden_binarr.txt）", test_binarr.run),
        ("语法（golden.txt）", test_parser.run),
        ("编译器（golden.txt）", test_compiler.run),
        ("嵌套深度上限", test_parser.run_depth),
        ("反汇编（golden_disasm.txt）", test_disasm.run),
        ("STML（stml_cases.txt + golden_stml.txt）", test_stml.run),
        ("参考执行器", test_vm.run),
    ]

    total = Report()
    for i, (title, fn) in enumerate(groups, 1):
        print()
        print(f"[{i}/{len(groups)}] {title}")
        rep = Report()
        try:
            fn(rep)
        except Exception as ex:  # 一组崩了不影响其它组
            rep.add_fail(title, f"抛异常：{type(ex).__name__}: {ex}")
        rep.dump()
        print(f"  （本组）  断言 {rep.total} 条，失败 {rep.failed} 条")
        total.passed += rep.passed
        total.failed += rep.failed

    print()
    print("====================================================")
    if total.failed == 0:
        print("全部通过：共 %d 条断言" % total.passed)
        print("====================================================")
        return 0
    print("失败 %d 条 / 共 %d 条断言" % (total.failed, total.total))
    print("====================================================")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
