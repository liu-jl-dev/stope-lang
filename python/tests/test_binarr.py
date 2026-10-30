"""二进制数组解析 + 常量折叠矩阵：``golden_binarr.txt``（86 条）。

文件里有两类记录，按位置分列（没有 ``key=``）：

* ``BA\\t内容\\tok|err\\t[字节]`` —— 直接打 :class:`BinaryArrayParser`；
* ``FB`` / ``FU\\t运算符\\t是否折叠\\t结果`` —— 直接打常量折叠矩阵（不经过词法/语法）。

用例表照抄 GD 的 ``test_parser.gd`` 与 nodejs 的 ``binary.test.js``
（**顺序即行序**，缺一条就整体错位），结果串格式与 C++ 的 ``fmtValue`` 逐字一致。
"""

from stope import ast as A
from stope.binarr_parser import BinaryArrayParser
from stope.common import Result
from stope.expr_optim import optimize
from stope.format import fmt_bytes, fmt_g
from stope.token import TokenType

from . import golden

INT64_MAX = 2 ** 63 - 1
INT64_MIN = -(2 ** 63)

# BA 用例表：与 GD test_parser.gd 的 _dump_binarr 逐条一致
_BA_CASES = [
    "", " ", "a", "ab", "b 0100 0001", "b 01000001", "B 1", "o 101", "O 7",
    "d 65", "d 300", "D 255 0", "x 41", "x ff FF", "X 0f", "41", "4_1", "_41",
    "01 02", "  01   02  ", "x zz", "z", "b", "d", "b 2", "o 8", "0 1",
    "9999999999999999999999", "d 2147483647", "d 2147483648", "ff",
]


def _val(e) -> str:
    """折叠结果的紧凑写法，与 C++ 的 ``fmtValue`` / GD 的 ``_val`` 一致。"""
    if e is None:
        return "null"
    t = e.node_type
    if t == A.NodeType.NullExpr:
        return "Null"
    if t == A.NodeType.BoolExpr:
        return "true" if e.value else "false"
    if t == A.NodeType.IntExpr:
        return str(e.value)
    if t == A.NodeType.FloatExpr:
        return fmt_g(e.value)
    if t == A.NodeType.BinArrExpr:
        return "[" + fmt_bytes(e.value) + "]"
    if t == A.NodeType.StringExpr:
        return '"' + e.value + '"'
    return "?"


def _int(v):
    return A.IntExpr(1, v)


def _float(v):
    return A.FloatExpr(1, v)


def _bool(v):
    return A.BoolExpr(1, v)


def _null():
    return A.NullExpr(1)


def _str(v):
    return A.StringExpr(1, v)


def _bin(v):
    return A.BinArrExpr(1, v)


def _fb(name: str, op: TokenType, l, r) -> str:
    e = A.BinaryOpExpr(1)
    e.op = op
    e.left_expr = l
    e.right_expr = r
    o = optimize(e)
    folded = 0 if o.node_type == A.NodeType.BinaryOpExpr else 1
    return "FB\t%s\t%d\t%s" % (name, folded, _val(o))


def _fu(name: str, op: TokenType, v) -> str:
    e = A.UnaryOpExpr(1)
    e.op = op
    e.expr = v
    o = optimize(e)
    folded = 0 if o.node_type == A.NodeType.UnaryOpExpr else 1
    return "FU\t%s\t%d\t%s" % (name, folded, _val(o))


def dump_all() -> list[str]:
    """按 golden 文件的顺序产出一整份文本的行列表。"""
    out = []

    # ---- BA：二进制数组解析 ----
    for t in _BA_CASES:
        buf = bytearray()
        ok = BinaryArrayParser().parse_binary_array(t, buf)
        out.append("BA\t%s\t%s\t[%s]" % (t, "ok" if ok == Result.Success else "err",
                                         fmt_bytes(bytes(buf))))

    # ---- FB：二元折叠 ----
    out.append(_fb("+", TokenType.Add, _int(1), _int(2)))
    out.append(_fb("-", TokenType.Sub, _int(5), _int(3)))
    out.append(_fb("*", TokenType.Mul, _int(2), _int(3)))
    out.append(_fb("/", TokenType.Div, _int(7), _int(2)))
    out.append(_fb("/", TokenType.Div, _int(6), _int(3)))
    out.append(_fb("/", TokenType.Div, _int(1), _int(0)))
    out.append(_fb("idiv", TokenType.IDiv, _int(7), _int(2)))
    out.append(_fb("%", TokenType.Mod, _int(7), _int(2)))
    out.append(_fb("^", TokenType.Pow, _int(2), _int(10)))
    out.append(_fb("^", TokenType.Pow, _int(2), _int(-1)))
    out.append(_fb("+", TokenType.Add, _float(1.5), _int(1)))
    out.append(_fb("+", TokenType.Add, _int(INT64_MAX), _int(1)))
    out.append(_fb("*", TokenType.Mul, _int(INT64_MAX), _int(2)))
    out.append(_fb("+", TokenType.Add, _bool(True), _bool(True)))
    out.append(_fb("+", TokenType.Add, _str("ab"), _str("cd")))
    out.append(_fb("*", TokenType.Mul, _str("ab"), _int(3)))
    out.append(_fb("*", TokenType.Mul, _int(3), _str("ab")))
    out.append(_fb("*", TokenType.Mul, _str(""), _int(1000000)))
    out.append(_fb("*", TokenType.Mul, _str("ab"), _int(-1)))
    out.append(_fb("*", TokenType.Mul, _float(1.5), _str("ab")))
    out.append(_fb("+", TokenType.Add, _bin(b"\x01"), _bin(b"\x02")))
    out.append(_fb("*", TokenType.Mul, _bin(b"\x01"), _int(3)))
    out.append(_fb("+", TokenType.Add, _null(), _int(5)))
    out.append(_fb("+", TokenType.Add, _int(5), _null()))
    out.append(_fb("+", TokenType.Add, _null(), _null()))
    out.append(_fb("-", TokenType.Sub, _null(), _int(5)))
    out.append(_fb("-", TokenType.Sub, _int(5), _null()))
    out.append(_fb("-", TokenType.Sub, _null(), _null()))
    out.append(_fb("*", TokenType.Mul, _null(), _int(5)))
    out.append(_fb("^", TokenType.Pow, _null(), _int(5)))
    out.append(_fb("==", TokenType.EQ, _null(), _null()))
    out.append(_fb("==", TokenType.EQ, _null(), _int(1)))
    out.append(_fb("!=", TokenType.NE, _null(), _int(1)))
    out.append(_fb("<", TokenType.LT, _null(), _int(1)))
    out.append(_fb("==", TokenType.EQ, _bool(True), _bool(True)))
    out.append(_fb("==", TokenType.EQ, _bool(True), _int(1)))
    out.append(_fb("==", TokenType.EQ, _int(1), _float(1.0)))
    out.append(_fb("==", TokenType.EQ, _str("a"), _str("a")))
    out.append(_fb("<", TokenType.LT, _int(1), _int(2)))
    out.append(_fb("<", TokenType.LT, _bool(True), _int(2)))
    out.append(_fb("<=", TokenType.LE, _float(1.5), _float(1.5)))
    out.append(_fb(">", TokenType.GT, _int(2), _int(1)))
    out.append(_fb(">=", TokenType.GE, _int(2), _int(2)))
    out.append(_fb("and", TokenType.And, _int(1), _int(0)))
    out.append(_fb("or", TokenType.Or, _int(0), _str("a")))

    # ---- FU：一元折叠 ----
    out.append(_fu("-", TokenType.Sub, _bool(True)))
    out.append(_fu("-", TokenType.Sub, _bool(False)))
    out.append(_fu("-", TokenType.Sub, _int(5)))
    out.append(_fu("-", TokenType.Sub, _float(1.5)))
    out.append(_fu("-", TokenType.Sub, _int(INT64_MIN)))
    out.append(_fu("!", TokenType.Not, _null()))
    out.append(_fu("!", TokenType.Not, _int(0)))
    out.append(_fu("!", TokenType.Not, _float(0.0)))
    out.append(_fu("!", TokenType.Not, _int(5)))
    out.append(_fu("!", TokenType.Not, _str("")))
    return out


def run(rep) -> None:
    want = [line for line in golden.read_text("golden_binarr.txt").split("\n") if line]
    got = dump_all()
    rep.check_int("golden_binarr.txt", "行数", len(want), len(got))
    for i in range(min(len(want), len(got))):
        rep.check("#%d" % (i + 1), "行", want[i], got[i])
