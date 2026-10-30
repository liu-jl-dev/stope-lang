"""STML 词法器。四态状态机（Xml / Text / Nevext / Stope）—— 端口 ``cpp/src/stml_lexer.cpp``。

三条最容易写错的规则：

1. Text / Nevext / Stope 扫完一段后**必须把 state 交还 Xml**，否则后续 ``next_token()``
   会产出无限个空 token（C++ 侧由 ``NextToken`` 自己收尾）；
2. 输入耗尽后**永远**返回 ``Eof``，与当前状态无关 —— 而且此时**不改 state**
   （C++ 的 ``if (input.empty())`` 分支在状态分支之前）；
3. 任何异常路径都要**消费字符**，否则调用方的 while 会死循环。

⚠ 与 Stope 词法器的关系：``<sto>`` 段里的 Stope 代码在这里**只当作一段文本**跳过
（引号串与注释整段吞掉，免得 ``</`` 被误判成结束标签），真正解析由 ``stope.lexer`` 做。
"""

from .stml import LexerState, Token, TokenType

_WHITE = frozenset(" \t\v\f\r\n")

#: 只有这几类 token 的 lexeme 是「双方实现都提供」的；标点与 Eof 的 lexeme 属实现自定，
#: 计划 §2.2 不断言（本实现对它们也填了 lexeme，但比对时不看）。
HAS_LEXEME = frozenset((TokenType.Word, TokenType.String, TokenType.Text,
                        TokenType.NevextSrc, TokenType.StopeSrc))


def _is_alpha(ch: str) -> bool:
    o = ord(ch)
    return 97 <= o <= 122 or 65 <= o <= 90


def _is_digit(ch: str) -> bool:
    return "0" <= ch <= "9"


def _is_word_begin(ch: str) -> bool:
    return _is_alpha(ch) or ch == "_" or ch == ":"


def _is_word_char(ch: str) -> bool:
    return _is_word_begin(ch) or _is_digit(ch) or ch == "-"


def trim_trailing_ws(s: str) -> str:
    """去掉尾部空白（B-8：内容段尾部的空白不计入 lexeme）。"""
    n = len(s)
    while n > 0 and s[n - 1] in _WHITE:
        n -= 1
    return s[:n]


class Lexer:
    """按需产出 token。``errors`` 累积词法错误（与语法错误分开报）。"""

    __slots__ = ("state", "src", "line", "errors")

    def __init__(self, source: str = "", state: int = LexerState.Xml):
        self.state = state
        self.src = source   # 未消费的剩余输入（C++ 是 input.remove_prefix，这里是切片）
        self.line = 1
        self.errors: list[str] = []

    def next_token(self) -> Token:
        token = Token()
        self._skip_ws()
        token.line = self.line
        if not self.src:
            token.type = TokenType.Eof
        elif self.state == LexerState.Xml:
            if self.src.startswith("</"):
                token.set(TokenType.CLAngle, "</")
                self.src = self.src[2:]
            elif self.src.startswith("/>"):
                token.set(TokenType.CRAngle, "/>")
                self.src = self.src[2:]
            elif self.src[0] == "<":
                token.set(TokenType.LAngle, "<")
                self.src = self.src[1:]
            elif self.src[0] == ">":
                token.set(TokenType.RAngle, ">")
                self.src = self.src[1:]
            elif self.src[0] == "=":
                token.set(TokenType.EQ, "=")
                self.src = self.src[1:]
            elif self.src[0] == '"' or self.src[0] == "'":
                self._scan_string(token)
            elif _is_word_begin(self.src[0]):
                token.set(TokenType.Word, self._scan_word())
            else:
                self._error("unexpected character. ")
                token.set(TokenType.Invalid, "")
                self.src = self.src[1:]  # 必须消费，否则死循环
        elif self.state == LexerState.Text:
            token.set(TokenType.Text, self._scan_content("text"))
            self.state = LexerState.Xml
        elif self.state == LexerState.Nevext:
            token.set(TokenType.NevextSrc, self._scan_content("nevext"))
            self.state = LexerState.Xml
        else:  # LexerState.Stope
            token.set(TokenType.StopeSrc, self._scan_content("stope"))
            self.state = LexerState.Xml
        return token

    # ============================ Xml 状态 ============================

    def _scan_string(self, token: Token) -> None:
        """Xml 属性串：**不转义**（``\\"`` 里的引号就是结束引号，TD-9）。
        未闭合时报错（文案比代码段那条**少一个句号**，TD-8）并吃掉剩余全部输入。"""
        token.type = TokenType.String
        quote = self.src[0]
        self.src = self.src[1:]  # 跳过开头的引号
        n = 0
        while True:
            if n >= len(self.src):
                self._error("unclosed string literal")
                self.src = ""
                token.type = TokenType.Invalid
                return
            if self.src[n] == quote:
                token.lexeme = self.src[:n]
                self.src = self.src[n + 1:]
                return
            if self.src[n] == "\n":
                self.line += 1
            n += 1

    def _scan_word(self) -> str:
        end = 1
        while end < len(self.src) and _is_word_char(self.src[end]):
            end += 1
        s = self.src[:end]
        self.src = self.src[end:]
        return s

    # ============================ 内容三态 ============================

    def _scan_content(self, mode: str) -> str:
        """Text / Nevext / Stope 三个扫描函数同构（C++ 是三份代码，这里合成一份）：

        从当前位置一路吃到 ``</`` 或输入耗尽，尾部空白不计入 lexeme（B-8）。
        ``text`` 只认 ``</``（``<b/>`` 会被整段当文本吃掉，B-2）；两个代码段还把引号串与
        注释整段跳过，其中的 ``</`` 不算结束标签（B-3）。
        """
        begin = self.src
        while self.src:
            if self.src.startswith("</"):
                break
            if mode != "text":
                ch = self.src[0]
                if ch == "'" or ch == '"':
                    # Nevext：两种引号都转义；Stope：双引号转义、单引号（BinArr）不转义
                    self._scan_code_str(ch, escapes=(mode == "nevext" or ch == '"'))
                    continue
                if self.src.startswith("//"):
                    self._skip_singleline_comment()
                    continue
                if self.src.startswith("/*"):
                    self._skip_multiline_comment()
                    continue
            if self.src[0] == "\n":
                self.line += 1
            self.src = self.src[1:]
        return trim_trailing_ws(begin[:len(begin) - len(self.src)])

    def _scan_code_str(self, quote: str, escapes: bool) -> None:
        """代码段里的引号串，含两侧引号。到输入末尾仍未闭合时报错并**吃掉剩余全部输入**
        （保证调用方不会死循环）；报的是**起始行**，不是当前行。"""
        begin_line = self.line
        self.src = self.src[1:]  # 跳过开头的引号
        while True:
            if not self.src:
                self._error_at(begin_line, "unclosed string literal. ")
                return
            c = self.src[0]
            self.src = self.src[1:]
            if escapes and c == "\\":  # 转义：连同紧跟的一个字符一起吃掉
                if not self.src:
                    self._error_at(begin_line, "unclosed string literal. ")
                    return
                if self.src[0] == "\n":
                    self.line += 1
                self.src = self.src[1:]
            elif c == quote:
                return
            elif c == "\n":
                self.line += 1

    def _skip_singleline_comment(self) -> None:
        """``//`` 到行尾；换行符一并消费并推进行号。"""
        self.src = self.src[2:]
        while self.src:
            c = self.src[0]
            self.src = self.src[1:]
            if c == "\n":
                self.line += 1
                return

    def _skip_multiline_comment(self) -> None:
        """``/*`` 到 ``*/``。未闭合**不是错误**，一直吃到输入末尾。"""
        self.src = self.src[2:]
        while self.src:
            if self.src.startswith("*/"):
                self.src = self.src[2:]
                return
            if self.src[0] == "\n":
                self.line += 1
            self.src = self.src[1:]

    # ============================ 空白与注释 ============================

    def _skip_ws(self) -> None:
        while self.src:
            ch = self.src[0]
            if ch in _WHITE:
                if ch == "\n":
                    self.line += 1
                self.src = self.src[1:]
            elif self.state == LexerState.Xml and self.src.startswith("<!--"):
                # `<!--` 只在 Xml 状态是注释；Nevext / Stope 里的 '<' 是小于号
                self._skip_xml_comment()
            else:
                break

    def _skip_xml_comment(self) -> None:
        self.src = self.src[4:]
        while self.src:
            if self.src.startswith("-->"):
                self.src = self.src[3:]
                return
            if self.src[0] == "\n":
                self.line += 1
            self.src = self.src[1:]

    # ============================ 报错 ============================

    def _error(self, msg: str) -> None:
        self.errors.append(f"line {self.line}: {msg}")

    def _error_at(self, line: int, msg: str) -> None:
        """指定行号报错：跨行的字面量 / 注释报的是**起始行**，不是当前行。"""
        self.errors.append(f"line {line}: {msg}")


__all__ = ["HAS_LEXEME", "Lexer", "LexerState", "TokenType", "trim_trailing_ws"]
