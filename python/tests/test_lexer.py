"""词法：全部由 ``golden_lex.txt``（147 条，C++ 探针 dump）驱动。

每条用例断言四件事：``TOKS`` / ``LEXEMES`` / ``ERRN`` / ``ERRS``。合计 588 条。

token 流写法与 GD / C# 一致：``Type(line)[parsed]=value`` —— ``[]`` 只在 parsed 非空时
出现，``=value`` 只对整数与浮点出现（浮点用 ``%g``）。``LEXEMES`` 只比四方实现都提供的
类型（数字 / 字符串 / 二进制数组）：标识符与标点的 lexeme 属实现自定，契约里不断言。
"""

from stope.lexer import Lexer
from stope.opcode import CustomOpcodeConfig
from stope.token import TokenType, type_name

from . import golden

#: golden 里所有用例都带着这两条自定义指令（与 cpp/tools/golden.cpp 的 g_cfg 一致）
CFG = CustomOpcodeConfig()
CFG.add_custom_opcode("myop", 100, 2)
CFG.add_custom_opcode("vop", 101, -1)

_LEXEME_TYPES = (TokenType.Integer, TokenType.Float, TokenType.String, TokenType.BinArr)


def one(src: str):
    """扫到底，返回 (TOKS, LEXEMES, ERR_N, ERRS) 四个字段的实际值。"""
    lx = Lexer(src)
    toks = []
    lexemes = []
    for i in range(10000):
        t = lx.next_token(CFG)
        s = type_name(t.type) + "(" + str(t.line) + ")"
        if t.parsed:
            s += "[" + golden.esc_lex(t.parsed) + "]"
        if t.type == TokenType.Integer:
            s += "=" + str(t.value)
        elif t.type == TokenType.Float:
            s += "=" + golden.fmt_g(t.value)
        toks.append(s)
        if t.type in _LEXEME_TYPES:
            lexemes.append(str(i) + ":" + golden.esc_lex(t.lexeme))
        if t.type == TokenType.Eof:
            break
    return " ".join(toks), ",".join(lexemes), len(lx.errors), golden.join_esc(lx.errors)


def run(rep) -> None:
    # ⚠ 这个文件的 TOKS / LEXEMES / ERRS **不做二次转义**：直接就是 esc_lex 形态，
    # 只有 SRC 是转义过的（且转义表里多 \v \f）。解错一层，字符串用例会大批红。
    cases = golden.read_golden("golden_lex.txt", unescape_values=False)
    if not cases:
        rep.add_fail("词法", "golden_lex.txt 一条都没读到")
        return
    for c in cases:
        cid = c.get("ID", "")
        src = golden.unescape_lex(c.get("SRC", ""))
        toks, lexemes, errn, errs = one(src)
        rep.check(cid, "TOKS", c.get("TOKS", ""), toks)
        rep.check(cid, "LEXEMES", c.get("LEXEMES", ""), lexemes)
        rep.check(cid, "ERRN", c.get("ERRN", ""), str(errn))
        rep.check(cid, "ERRS", c.get("ERRS", ""), errs)
