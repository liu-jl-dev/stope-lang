"""编译器：``golden.txt`` 的 ``CMP`` / ``OUT`` / ``CERRS`` 三个字段（195 条）。

``golden.txt`` 被语法组与编译器组共用：:func:`test_parser.run_case` 一次跑完
词法 → 语法 → 编译，两边各取自己那几个字段。195 条 × 3 个字段 = 585 条断言。
"""

from stope.common import Result
from stope.compiler import Compiler
from stope.program import Program

from . import golden
from .test_parser import CFG, run_case


def run(rep) -> None:
    cases = golden.read_golden("golden.txt")
    if not cases:
        rep.add_fail("编译器", "golden.txt 一条都没读到")
        return
    for rec in cases:
        cid = rec.get("ID", "")
        got = run_case(rec)
        prog = Program()
        c = Compiler(CFG)
        rc = c.compile(got["tree"], prog)
        rep.check(cid, "CMP", rec.get("CMP", ""), "OK" if rc == Result.Success else "ERR")
        rep.check(cid, "OUT", rec.get("OUT", ""), golden.dump_program(prog, CFG))
        rep.check(cid, "CERRS", rec.get("CERRS", ""), golden.join_esc(c.errors))
