"""STML 语法分析器 —— 端口 ``cpp/src/stml_parser.cpp``。

STML 比 XML 更严格：

* 没有字符实体；
* 属性可以没有值：``<a flag>`` 等价于 ``flag = ""``（因此属性循环**不能**在开头无条件
  ``next_token()``，否则无值属性会多吞一个 token）；
* 子元素与元素内文本互斥；元素内文本只有一段，由词法器一次性给出，不做多段拼接。

宿主回调 ``state_func(tag, attrs) -> LexerState`` 决定元素内容怎么扫（``<sto>`` 走 Stope、
``<nev>`` 走 Nevext、``<p>`` 走 Text、其余按 Xml 递归子元素）。传 ``None`` 表示「一律 Xml」。
"""

from .common import Result
from .stml import Element, LexerState, Token, TokenType
from .stml_lexer import Lexer


def default_state_func(tag: str, attrs) -> LexerState:
    """默认回调：``<sto>`` → Stope、``<nev>`` → Nevext、``<p>`` → Text，其余 Xml。"""
    if tag == "sto":
        return LexerState.Stope
    if tag == "nev":
        return LexerState.Nevext
    if tag == "p":
        return LexerState.Text
    return LexerState.Xml


class Parser:
    __slots__ = ("lexer", "state_func", "errors", "token")

    def __init__(self, lexer: Lexer):
        self.lexer = lexer
        self.state_func = None
        self.errors: list[str] = []
        self.token = Token()

    def parse(self, root: Element, state_func=default_state_func) -> Result:
        self.state_func = state_func
        self._next_token()
        self._parse_element(root)
        return Result.Success if not self.errors else Result.Error

    def _parse_element(self, e: Element) -> None:
        # 进入元素一律先回到 Xml 状态：自闭合分支与出错提前返回的路径都走不到下面的
        # state_func，留着上一次的 Text / Nevext / Stope 会污染后续 token
        self.lexer.state = LexerState.Xml
        e.line = self.token.line
        if self.token.type != TokenType.LAngle:
            self._error('expected "<". ')
            return
        self._next_token()
        if self.token.type != TokenType.Word:
            self._error("expected tag name. ")
            return
        e.tag = self.token.lexeme
        self._next_token()  # 第一个属性名，或 > 或 />
        # 每个分支自己负责推进到下一个待判断的 token。
        # 不能写成「循环开头 next_token」，否则无值属性的向前看会多吞一个 token。
        while True:  # (word ("=" string)?)*
            if self.token.type == TokenType.RAngle:
                break
            if self.token.type == TokenType.CRAngle:
                e.self_closing = True
                return
            if self.token.type == TokenType.Word:
                name = self.token.lexeme
                self._next_token()
                if self.token.type == TokenType.EQ:
                    self._next_token()
                    if self.token.type != TokenType.String:
                        self._error("expected string. ")
                        return
                    # C++ 用 std::map::emplace：同名属性保留**先出现的**那个
                    if name not in e.attrs:
                        e.attrs[name] = self.token.lexeme
                    self._next_token()
                else:
                    # 无值属性：<a flag> 等价于 attrs["flag"] = ""
                    # 此时 token 已经是下一个属性名 / > 或 />，不能再推进
                    if name not in e.attrs:
                        e.attrs[name] = ""
            else:
                self._error('expected ">" or "/>" or attribute. ')
                return
        # 此时 e.self_closing 为 False，且停在 ">"
        self.lexer.state = self.state_func(e.tag, e.attrs) if self.state_func else LexerState.Xml

        if self.lexer.state == LexerState.Xml:  # 递归解析子元素
            while True:
                self._next_token()
                if self.token.type == TokenType.CLAngle:  # </>
                    break
                if self.token.type == TokenType.LAngle:  # < 子元素
                    child = Element()
                    e.children.append(child)
                    self._parse_element(child)
                else:
                    self._error('expected "<" or "</". ')
                    return
        else:  # Text / Nevext / Stope：整段内容由词法器一次性给出
            self._next_token()  # 词法器保证只会结束在 </ ，不会结束在 <
            if self.token.type not in (TokenType.Text, TokenType.NevextSrc,
                                       TokenType.StopeSrc):
                self._error("expected element content. ")
                return
            e.text = self.token.lexeme  # 只有一段，不拼接（见模块注释）
            self._next_token()          # 停在 CLAngle，与上面 Xml 分支的 break 处汇合

        self._next_token()  # 结束标签名
        if self.token.type != TokenType.Word:
            self._error("expected tag name. ")
            return
        if self.token.lexeme != e.tag:
            self._error("tag name mismatch. ")
            return
        self._next_token()
        if self.token.type != TokenType.RAngle:
            self._error('expected ">". ')
            return

    def _next_token(self) -> None:
        self.token = self.lexer.next_token()

    def _error(self, msg: str) -> None:
        self.errors.append(f"line {self.token.line}: {msg}")


__all__ = ["Parser", "default_state_func"]
