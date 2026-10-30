"""STML：``stml_cases.txt``（121 条用例清单）+ ``golden_stml.txt``（C++ 探针 dump）。

与其它几组不同，这里**用例清单也是数据文件**：加删用例只改
``gdscript/test/data/stml_cases.txt``，然后重跑 ``cmake --build cpp/build --target gen-golden``。
本文件只有「读清单 → 打本实现 → 比字段」这一件事，没有内嵌用例。

每条用例的断言数：``KIND=lex`` 四条（TOKS / LEXS / ERRN / ERRS），
``KIND=parse`` 六条（SHAPE / RESULT / ERRN / ERRS / LEXERRN / LEXERRS）。

⚠ ``golden_stml.txt`` 的字段**不解转义**（探针只做了 escUtf8），读进来是什么就比什么。
而 ``stml_cases.txt`` 的 ``SRC`` 要按 ``\\\\ \\n \\r \\t`` 解一层。
"""

from stope import stml, stml_lexer, stml_parser
from stope.common import Result

from . import golden


def _esc16(text: str) -> str:
    """``escUtf8`` 的忠实实现，但按 **UTF-16 码元**遍历 —— 与 C++ 的 u16string 一致。

    :func:`golden.esc` 是按 Python 的**码点**遍历的：遇到非 BMP 字符（如 emoji）C++ 会
    给出两个 ``?``（代理对），按码点只有一个 —— 这正是 GDScript 侧残留的 GD-S-18 差异。
    Python 侧在这里纠正掉，所以与 C++ 逐字节相同。
    """
    units = text.encode("utf-16-le", "surrogatepass")
    out = []
    for i in range(0, len(units), 2):
        c = units[i] | (units[i + 1] << 8)
        if c == 0x5C:
            out.append("\\\\")
        elif c == 0x22:
            out.append('\\"')
        elif c == 0x0A:
            out.append("\\n")
        elif c == 0x0D:
            out.append("\\r")
        elif c == 0x09:
            out.append("\\t")
        elif c < 128:
            out.append(chr(c))
        else:
            out.append("?")
    return "".join(out)


def _join_esc16(errs) -> str:
    return "|".join(_esc16(e) for e in errs)


def _state_of(name: str) -> int:
    return {"Text": stml.LexerState.Text,
            "Nevext": stml.LexerState.Nevext,
            "Stope": stml.LexerState.Stope}.get(name, stml.LexerState.Xml)


def _shape(e) -> str:
    """元素形状串。字段顺序固定：tag、行号、自闭合、属性（**字典序**）、文本、子元素。

        Elem(a, L1)                        空元素对
        Elem(a, L1, /)                     自闭合
        Elem(a, L1, @id="x", @flag)        属性；无值属性只写名字
        Elem(a, L1, T="hello")             文本
        Elem(a, L1, C=[Elem(b, L1, /)])    子元素
    """
    out = "Elem(" + _esc16(e.tag) + ", L" + str(e.line)
    if e.self_closing:
        out += ", /"
    for name in sorted(e.attrs):
        out += ", @" + _esc16(name)
        if e.attrs[name]:
            out += '="' + _esc16(e.attrs[name]) + '"'
    if e.text:
        out += ', T="' + _esc16(e.text) + '"'
    if e.children:
        out += ", C=[" + " ".join(_shape(c) for c in e.children) + "]"
    return out + ")"


def _run_lex(rep, case, want, src) -> None:
    cid = case["ID"]
    lx = stml_lexer.Lexer(src, _state_of(case.get("ST", "Xml")))
    toks = []
    lexs = []
    for i in range(10000):  # 死循环保险丝（NextToken 不消费字符时）
        t = lx.next_token()
        toks.append(stml.type_name(t.type) + "(" + str(t.line) + ")")
        if t.type in stml_lexer.HAS_LEXEME:
            lexs.append(str(i) + ":" + _esc16(t.lexeme))
        if t.type == stml.TokenType.Eof:
            break
    rep.check(cid, "TOKS", want.get("TOKS", ""), " ".join(toks))
    rep.check(cid, "LEXS", want.get("LEXS", ""), ",".join(lexs))
    rep.check(cid, "ERRN", want.get("ERRN", ""), str(len(lx.errors)))
    rep.check(cid, "ERRS", want.get("ERRS", ""), _join_esc16(lx.errors))


def _run_parse(rep, case, want, src) -> None:
    cid = case["ID"]
    lx = stml_lexer.Lexer(src)
    ps = stml_parser.Parser(lx)
    root = stml.Element()
    sf = case.get("SF", "default")
    if sf == "null":
        state_func = None
    elif sf == "text":
        state_func = lambda _tag, _attrs: stml.LexerState.Text  # noqa: E731
    else:
        state_func = stml_parser.default_state_func

    rc = ps.parse(root, state_func)
    rep.check(cid, "SHAPE", want.get("SHAPE", ""), _shape(root))
    rep.check(cid, "RESULT", want.get("RESULT", ""),
              "Success" if rc == Result.Success else "Error")
    rep.check(cid, "ERRN", want.get("ERRN", ""), str(len(ps.errors)))
    rep.check(cid, "ERRS", want.get("ERRS", ""), _join_esc16(ps.errors))
    rep.check(cid, "LEXERRN", want.get("LEXERRN", ""), str(len(lx.errors)))
    rep.check(cid, "LEXERRS", want.get("LEXERRS", ""), _join_esc16(lx.errors))


def run(rep) -> None:
    cases = golden.read_stml_cases()
    if not cases:
        rep.add_fail("STML", "stml_cases.txt 一条都没读到")
        return
    want = {r["ID"]: r for r in golden.read_golden("golden_stml.txt", unescape_values=False)}

    seen_lex = 0
    seen_parse = 0
    for case in cases:
        cid = case["ID"]
        rec = want.get(cid)
        if rec is None:
            rep.add_fail(cid, "golden_stml.txt 里没有这条")
            continue
        src = case["src"] * case["times"]
        if case.get("KIND") == "parse":
            seen_parse += 1
            _run_parse(rep, case, rec, src)
        else:
            seen_lex += 1
            _run_lex(rep, case, rec, src)

    # 清单与期望值必须一一对应（少一条就是「用例没跑」而不是「用例通过」）
    rep.check_int("COUNT", "清单 ↔ golden 条数", len(cases), len(want))
    rep.check_int("COUNT", "词法 + 语法", len(cases), seen_lex + seen_parse)
