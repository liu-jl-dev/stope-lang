"""语法：``golden.txt``（195 条，``cpp/tools/golden.cpp`` dump）+ 嵌套深度上限。

每条用例断言六件事：AST 形状串、语句行号序列、语法 / 词法错误条数与文案。
期望值不手写 —— 改行为时重跑 ``cmake --build cpp/build --target gen-golden``。
"""

from stope.ast import Prog, shape_prog
from stope.lexer import Lexer
from stope.opcode import CustomOpcodeConfig
from stope.parser import Parser

from . import golden

#: golden 里所有用例都带着这两条自定义指令（与 cpp/tools/golden.cpp 的 g_cfg 一致）
CFG = CustomOpcodeConfig()
CFG.add_custom_opcode("myop", 100, 2)
CFG.add_custom_opcode("vop", 101, -1)


def run_case(rec: dict) -> dict:
    """跑一条 golden 用例：词法 → 语法，把结果摊平成与记录同名的字段。

    ⚠ ``SRC`` 要解**两**层转义：golden 里存的是 ``E_(escUtf8(源码))``，读文件时已解了
    外层的 ``E_``，这里再解一层 ``escUtf8``。而 ``SHAPE`` / ``OUT`` 这些字段存的就是
    「转义后的形态」，只解一层。
    """
    src = golden.unescape(rec.get("SRC", ""))
    fold = rec.get("FOLD", "") == "1"

    lx = Lexer(src)
    ps = Parser(lx, CFG)
    ps.const_folding = fold
    tree = Prog()
    ps.parse_program(tree)

    return {
        "SRC": src,
        "SHAPE": shape_prog(tree),
        "LINES": ",".join(str(s.line) for s in tree.stmts),
        "PERR": str(len(ps.errors)),
        "PERRS": golden.join_esc(ps.errors),
        "LEXERR": str(len(lx.errors)),
        "LEXERRS": golden.join_esc(lx.errors),
        "tree": tree,
    }


def run(rep) -> None:
    cases = golden.read_golden("golden.txt")
    if not cases:
        rep.add_fail("语法", "golden.txt 一条都没读到")
        return
    rep.check_int("golden.txt", "用例数", 195, len(cases))
    for rec in cases:
        cid = rec.get("ID", "")
        got = run_case(rec)
        rep.check(cid, "SHAPE", rec.get("SHAPE", ""), got["SHAPE"])
        rep.check(cid, "LINES", rec.get("LINES", ""), got["LINES"])
        rep.check(cid, "PERR", rec.get("PERR", ""), got["PERR"])
        rep.check(cid, "PERRS", rec.get("PERRS", ""), got["PERRS"])
        rep.check(cid, "LEXERR", rec.get("LEXERR", ""), got["LEXERR"])
        rep.check(cid, "LEXERRS", rec.get("LEXERRS", ""), got["LEXERRS"])


# ---------------- 嵌套深度上限 ----------------
# 期望值不 dump：限额与错误文案是**四方约定**（C++ Parser::maxDepth 与本实现的
# max_depth 同为 256，文案逐字相同），所以按约定写死。任一侧改了计数口径或文案，
# 各实现的测试都会红。
def depth_source(kind: str, n: int) -> str:
    """与 GD 侧 ``_depth_case`` 的构造逐字一致：块里要有语句，否则永远进不到
    ``parse_expr``，深度计数根本没机会检查。"""
    if kind == "paren":
        return "(" * n + "a" + ")" * n + ";"
    if kind == "block":
        return "{" * n + "a;" + "}" * n
    if kind == "unary":
        return "-" * n + "a;"
    if kind == "at":
        return "a[" * n + "0" + "]" * n + ";"
    raise ValueError("unknown kind " + kind)


def parse_depth(kind: str, n: int):
    ps = Parser(Lexer(depth_source(kind, n)))
    tree = Prog()
    ps.parse_program(tree)
    return ps.errors, tree


_DEPTH_CASES = [
    ("PD-DEPTH-1", "paren", 200, False),   # 限额内：照常解析
    ("PD-DEPTH-2", "paren", 300, True),
    ("PD-DEPTH-3", "block", 300, True),
    ("PD-DEPTH-4", "unary", 300, True),    # 没有括号的递归
    ("PD-DEPTH-5", "at", 300, True),
    ("PD-DEPTH-6", "paren", 12000, True),  # 曾真的栈溢出
    ("PD-DEPTH-7", "block", 200, False),
    ("PD-DEPTH-8", "unary", 200, False),
    ("PD-DEPTH-9", "at", 200, False),
]


def run_depth(rep) -> None:
    for cid, kind, n, deep in _DEPTH_CASES:
        errors, tree = parse_depth(kind, n)
        if not deep:
            rep.check_int("%s %s %d" % (cid, kind, n), "错误条数", 0, len(errors))
            rep.check_true(cid, "应解析出语句", len(tree.stmts) > 0)
            continue
        # 超限只报一条（不刷连锁噪音），文案逐字固定
        rep.check_int("%s %s %d" % (cid, kind, n), "错误条数", 1, len(errors))
        rep.check(cid, "错误文案", "line 1: nesting too deep (max 256). ",
                  errors[0] if errors else "<无错误>")

    rep.check_int("PD-DEFAULT", "默认 max_depth", 256, Parser(Lexer("")).max_depth)

    # max_depth = 0 时不检查：600 层（远超 256）仍能解析。
    # 这里不用 nodejs 侧的 2000 层 —— Python 每层递归 3 个栈帧，2000 层要在
    # 引擎层先把递归限制撞穿，测不到「不检查」这件事本身。
    ps0 = Parser(Lexer(depth_source("paren", 600)))
    ps0.max_depth = 0
    tree0 = Prog()
    ps0.parse_program(tree0)
    rep.check_int("PD-NOLIMIT", "错误条数", 0, len(ps0.errors))
    rep.check_int("PD-NOLIMIT", "语句数", 1, len(tree0.stmts))
