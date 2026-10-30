"""词法分析器。

与 ``cpp/src/lexer.cpp``、``nodejs/src/lexer.js`` 逐项对齐：同样的正则、同样的
错误文案、同样的错误恢复（报错后**继续**产 token，不中断）。

⚠ 与 C++ 的一处**有意差异**（C++ 未修的 D-8 / D-9）：本实现对**所有** token 都填
``lexeme``，C++ 里标识符与标点的 ``lexeme`` 恒为空。跨实现比对时只有数字 / 字符串 /
二进制数组的 lexeme 参与（见 docs/zh-cn/lexer-test-plan.md §2）。

⚠ 字符串按 **Python str（码点）** 处理：C++ 是 UTF-16 码元，非 BMP 字符（emoji）在两边
的列数与 lexeme 转义结果会不同 —— 与 GDScript 侧同类（GD-S-18），尚未定夺。
"""

import re

from .token import Token, TokenType

_INT64_MIN = -(2 ** 63)
_INT64_MAX = 2 ** 63 - 1

# ---- 正则：全部用 match 从头匹配 ----
_RE_BIN_INTEGER = re.compile(r"0[bB][_01]+")
_RE_OCT_INTEGER = re.compile(r"0[oO][_0-7]+")
_RE_HEX_INTEGER = re.compile(r"0[xX][_0-9a-fA-F]+")
_RE_DOT = re.compile(r"\.")
_RE_DEC_DIGITS = re.compile(r"[_0-9]+")     # 整数部分，至少一位
_RE_DEC_DIGITS_OPT = re.compile(r"[_0-9]*")  # 小数点之后的数字，可以没有
_RE_DEC_FRAC = re.compile(r"\.[_0-9]*")      # 小数点 + 数字
_RE_DEC_EXP = re.compile(r"[eE][+-]?[0-9]*")  # 指数部分（数字可以没有，如 "1e"）
# 浮点数（parsed，已去掉下划线）：整数部分允许省略，指数部分必须完整
_RE_FLOAT = re.compile(r"(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$")
_RE_IDENT_HEAD = re.compile(r"[a-zA-Z_][a-zA-Z0-9_]*")
# 字符串主体：普通字符或转义对，遇到单独的 " 或末尾孤立的 \ 停下
_RE_STRING_BODY = re.compile(r'(?:[^"\\]|\\.)*', re.S)
_RE_BINARR_BODY = re.compile(r"[^']*")

_DIGITS_RE = {
    2: re.compile(r"[01]+$"),
    8: re.compile(r"[0-7]+$"),
    16: re.compile(r"[0-9a-fA-F]+$"),
    10: re.compile(r"[0-9]+$"),
}

_ESCAPE = {
    "\\": "\\", "'": "'", '"': '"',
    "b": "\b", "r": "\r", "t": "\t",
    "v": "\v", "n": "\n", "f": "\f",
}

_KEYWORDS = {
    "idiv": TokenType.IDiv, "not": TokenType.Not,
    "and": TokenType.And, "or": TokenType.Or,
    "if": TokenType.If, "elif": TokenType.Elif,
    "else": TokenType.Else, "let": TokenType.Let,
    "return": TokenType.Return, "while": TokenType.While,
    "break": TokenType.Break, "continue": TokenType.Continue,
    "null": TokenType.Null, "false": TokenType.False_,
    "true": TokenType.True_, "args": TokenType.Args,
    "argc": TokenType.Argc, "export": TokenType.Export,
}

_TWO_CHAR_OPS = {
    "==": TokenType.EQ, "!=": TokenType.NE,
    "<=": TokenType.LE, ">=": TokenType.GE,
    "&&": TokenType.And, "||": TokenType.Or,
}

_ONE_CHAR_OPS = {
    ",": TokenType.Comma, ";": TokenType.Semi,
    "(": TokenType.LParen, ")": TokenType.RParen,
    "[": TokenType.LBrack, "]": TokenType.RBrack,
    "{": TokenType.LBrace, "}": TokenType.RBrace,
    "+": TokenType.Add, "-": TokenType.Sub,
    "*": TokenType.Mul, "/": TokenType.Div,
    "%": TokenType.Mod, "^": TokenType.Pow,
    "=": TokenType.Assign, "!": TokenType.Not,
    "<": TokenType.LT, ">": TokenType.GT,
}


def _is_white(c: str) -> bool:
    return c in (" ", "\t", "\r", "\n", "\v", "\f")


def _is_digit(c: str) -> bool:
    return "0" <= c <= "9"


def _is_alpha(c: str) -> bool:
    return ("a" <= c <= "z") or ("A" <= c <= "Z")


def _is_ident_begin(c: str) -> bool:
    return _is_alpha(c) or c == "_"


def _number_base(s: str) -> tuple[int, int]:
    """按字面量前缀决定基数，并给出前缀长度。"""
    if len(s) >= 2 and s[0] == "0":
        if s[1] in ("b", "B"):
            return 2, 2
        if s[1] in ("o", "O"):
            return 8, 2
        if s[1] in ("x", "X"):
            return 16, 2
    return 10, 0


class Lexer:
    """``Lexer(src)`` → 反复调 :meth:`next_token` 直到 ``TokenType.Eof``。"""

    __slots__ = ("input", "line", "errors")

    def __init__(self, input_src: str = ""):
        self.reset(input_src)

    def reset(self, input_src: str = "") -> None:
        self.input = input_src
        self.line = 1
        self.errors: list[str] = []

    # ------------------------------------------------------------------ 主循环

    def next_token(self, custom=None) -> Token:
        """取下一个 token。``custom`` 是 :class:`stope.opcode.CustomOpcodeConfig`，可省略。

        ⚠ 与另外几套实现一致：这里**不抛异常**，出错只往 ``errors`` 里记一条，然后
        按最长可行前缀产出一个 ``Invalid`` token 继续扫。
        """
        self.skip_ws()
        token = Token(self.line, TokenType.Eof)
        if not self.input:  # 输入结尾，直接返回 Eof
            return token
        c = self.input[0]
        if _is_digit(c) or c == ".":            # 数字字面量
            self.scan_number(token)
        elif _is_ident_begin(c):                # 标识符 / 关键字 / 自定义指令
            self.scan_ident(token)
            self.analyze_ident(token, custom)
        elif c == "'":                          # '...'
            self.scan_binarr(token)
        elif c == '"':                          # "..."
            self.scan_string(token)
        else:                                   # 标点
            self.scan_punct(token, c)
        return token

    # ------------------------------------------------------------ 数字

    def scan_number(self, token: Token) -> None:
        if self.test("0b") or self.test("0B"):      # ^0[bB][_01]+
            token.type = TokenType.Integer
            token.lexeme = self.match_radix_integer(_RE_BIN_INTEGER)
        elif self.test("0o") or self.test("0O"):    # ^0[oO][_0-7]+
            token.type = TokenType.Integer
            token.lexeme = self.match_radix_integer(_RE_OCT_INTEGER)
        elif self.test("0x") or self.test("0X"):    # ^0[xX][_0-9a-fA-F]+
            token.type = TokenType.Integer
            token.lexeme = self.match_radix_integer(_RE_HEX_INTEGER)
        elif self.input[:1] == ".":                 # .[_0-9]*([eE][+-]?[0-9]+)?
            token.type = TokenType.Float
            token.lexeme = self.match_and_consume(_RE_DOT) + self.match_and_consume(_RE_DEC_DIGITS_OPT)
            token.lexeme += self.scan_exponent()
        else:                                       # [_0-9]+(.[_0-9]*)?([eE][+-]?[0-9]+)?
            token.type = TokenType.Integer
            lexeme = self.match_and_consume(_RE_DEC_DIGITS)
            if self.input[:1] == ".":               # 有小数点就是浮点数
                token.type = TokenType.Float
                lexeme += self.match_and_consume(_RE_DEC_FRAC)
            exp = self.scan_exponent()
            if exp:
                token.type = TokenType.Float
            token.lexeme = lexeme + exp
        self.parse_number(token)
        self.get_number_value(token)

    def scan_exponent(self) -> str:
        """``([eE][+-]?[0-9]*)?`` —— 返回 ``""`` 表示没有指数。

        数字部分可以为空（``"1e"`` 的 ``e`` 也算进 lexeme），交给
        :meth:`get_number_value` 报错。
        """
        if not self.input:
            return ""
        c = self.input[0]
        if c != "e" and c != "E":
            return ""
        return self.match_and_consume(_RE_DEC_EXP)

    def match_radix_integer(self, rx: re.Pattern) -> str:
        """取走正则匹配到的文本；不匹配时只取前缀（如 ``"0b"``），让后面报错。"""
        m = rx.match(self.input)
        return self.match_and_consume(rx, m.group(0) if m else self.input[:2])

    def match_and_consume(self, rx: re.Pattern, fallback: str = "") -> str:
        m = rx.match(self.input)
        text = m.group(0) if m else fallback
        self.input = self.input[len(text):]
        return text

    def parse_number(self, token: Token) -> None:
        """数字字面量允许下划线分隔，``parsed`` 是去掉下划线后的文本。"""
        token.parsed = token.lexeme.replace("_", "")

    def get_number_value(self, token: Token) -> None:
        """按 ``parsed`` 求数值；不合法（含超出 int64）则报错并把 token 置为 Invalid。"""
        if token.type == TokenType.Integer:
            base, prefix_len = _number_base(token.parsed)
            digits = token.parsed[prefix_len:]
            if not _DIGITS_RE[base].match(digits):
                self.error("invalid integer. ")
                token.type = TokenType.Invalid
                return
            try:
                value = int(digits, base)
            except ValueError:
                self.error("invalid integer. ")
                token.type = TokenType.Invalid
                return
            if value < _INT64_MIN or value > _INT64_MAX:  # 对齐 C++ stoll 的 out_of_range
                self.error("invalid integer. ")
                token.type = TokenType.Invalid
                return
            token.value = value
        elif token.type == TokenType.Float:
            if not _RE_FLOAT.match(token.parsed):  # 如 "1e"、"." —— C++ 用 stod 的 pos 判断
                self.error("invalid float. ")
                token.type = TokenType.Invalid
                return
            value = float(token.parsed)
            # C++ 用 stod，上溢与下溢都抛 out_of_range → Invalid。Python 的 float() 不抛，
            # 只能自己判：非有限值（1e999），或者有非零数字却算出 0（1e-999 下溢）
            if value in (float("inf"), float("-inf")) or value != value or \
                    (value == 0.0 and re.search(r"[1-9]", token.parsed)):
                self.error("invalid float. ")
                token.type = TokenType.Invalid
                return
            token.value = value

    # ------------------------------------------------------------ 序列 / 字符串

    def scan_binarr(self, token: Token) -> None:
        """``'...'`` 到下一个 ``'`` 为止，中间可以换行（换行计入 line）。"""
        token.type = TokenType.BinArr
        self.input = self.input[1:]  # 跳过开头的 '
        body = self.match_and_consume(_RE_BINARR_BODY, "")
        self.line += body.count("\n")
        if not self.input:  # 没扫到闭合的 '
            self.error("unclosed binary array. ")
            token.type = TokenType.Invalid
            token.lexeme = body
            self.input = ""
            return
        token.lexeme = body
        self.input = self.input[1:]  # 跳过结尾的 '

    def scan_string(self, token: Token) -> None:
        """``"..."`` 里的 ``\\`` 会转义后一个字符（含 ``\\"``），未闭合则报错。"""
        token.type = TokenType.String
        self.input = self.input[1:]  # 跳过开头的 "
        body = self.match_and_consume(_RE_STRING_BODY, "")
        if not self.input or self.input[0] != '"':  # 没扫到闭合的 "
            self.error("unclosed string literal. ")
            token.type = TokenType.Invalid
            token.lexeme = body
            self.input = ""
            return
        token.lexeme = body
        self.input = self.input[1:]  # 跳过结尾的 "
        self.escape_string(token)

    def escape_string(self, token: Token) -> None:
        """处理转义序列；遇到非法转义就报错并停下（已解析的部分保留）。"""
        parsed = []
        i = 0
        n = len(token.lexeme)
        while i < n:
            ch = token.lexeme[i]
            if ch == "\\":
                i += 1
                if i >= n:  # 末尾一个孤立的 \
                    self.error("invalid escape character. ")
                    break
                c = _ESCAPE.get(token.lexeme[i])
                if c is None:
                    self.error("invalid escape character. ")
                    break
                parsed.append(c)
                i += 1
            else:
                parsed.append(ch)
                i += 1
        token.parsed = "".join(parsed)

    # ------------------------------------------------------------ 标识符

    def scan_ident(self, token: Token) -> None:
        """``^[a-zA-Z_][a-zA-Z0-9_]*(:[a-zA-Z_][a-zA-Z0-9_]*)*``，冒号两侧允许空白与注释。"""
        token.type = TokenType.Ident
        src = []
        parsed = self.match_and_consume(_RE_IDENT_HEAD)
        src.append(parsed)
        while True:
            src.append(self.skip_ws_returning_skipped())  # 冒号之前的空白与注释
            if not self.input or self.input[0] != ":":
                break
            src.append(":")
            parsed += ":"
            self.input = self.input[1:]
            src.append(self.skip_ws_returning_skipped())  # 冒号之后的空白与注释
            seg = _RE_IDENT_HEAD.match(self.input)
            if not seg:  # 冒号后面不是标识符
                self.error("unclosed identifier. ")
                token.type = TokenType.Invalid
                break
            text = seg.group(0)
            src.append(text)
            parsed += text
            self.input = self.input[len(text):]
        token.lexeme = "".join(src)
        token.parsed = parsed

    def analyze_ident(self, token: Token, custom) -> None:
        """关键字 > 自定义指令 > 标识符。"""
        if token.type == TokenType.Invalid:
            return
        kw = _KEYWORDS.get(token.parsed)
        if kw is not None:
            token.type = kw
        elif custom is not None and token.parsed in custom.opcodes:
            token.type = TokenType.Custom
        else:
            token.type = TokenType.Ident

    # ------------------------------------------------------------ 标点 / 空白

    def scan_punct(self, token: Token, c: str) -> None:
        """先按两字符查表（``== != <= >= && ||``），再按单字符查表。"""
        two = _TWO_CHAR_OPS.get(self.input[:2])
        if two is not None:
            token.type = two
            token.lexeme = self.input[:2]
            self.input = self.input[2:]
            return
        one = _ONE_CHAR_OPS.get(c)
        token.type = TokenType.Invalid if one is None else one
        token.lexeme = c
        self.input = self.input[1:]
        if one is None:
            self.error("unknown token. ")

    def test(self, prefix: str) -> bool:
        return self.input.startswith(prefix)

    def skip_ws(self) -> None:
        while self.input:
            c = self.input[0]
            if _is_white(c):
                if c == "\n":
                    self.line += 1
                self.input = self.input[1:]
            elif self.test("//"):  # 单行注释
                pos = self.input.find("\n")
                if pos < 0:        # 直接到字符串结尾
                    self.input = ""
                else:              # 还有新行
                    self.input = self.input[pos + 1:]
                    self.line += 1
            elif self.test("/*"):  # 多行注释
                self.skip_multiline_comment()
            else:
                break

    def skip_ws_returning_skipped(self) -> str:
        """与 :meth:`skip_ws` 相同，但返回被跳过的原文（标识符的 ``:`` 两侧要记进 lexeme）。"""
        before = self.input
        self.skip_ws()
        return before[:len(before) - len(self.input)]

    def skip_multiline_comment(self) -> None:
        self.input = self.input[2:]  # 跳过 /*
        while self.input:
            if self.test("*/"):
                self.input = self.input[2:]
                break
            if self.input[0] == "\n":
                self.line += 1
            self.input = self.input[1:]

    def error(self, msg: str) -> None:
        self.errors.append("line %d: %s" % (self.line, msg))
