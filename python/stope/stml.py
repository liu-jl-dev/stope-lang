"""STML 的公共类型：元素与 Token —— 对应 ``cpp/include/stope/stml.hpp`` 的角色。

真正的权威实现是 ``cpp/src/stml_lexer.cpp`` + ``cpp/src/stml_parser.cpp``，契约见
``docs/zh-cn/stml-test-plan.md``。

元素模型只有 6 个字段（与 C++ 的 ``STML::Element`` 一一对应），**不要加字段**：
形状串与跨实现比对都按这 6 项来。
"""

from enum import IntEnum


class TokenType(IntEnum):
    """12 项，与 C++ 的 ``STML::TokenType`` **值和名字都一样**（顺序不能改）。"""

    Invalid = 0
    Eof = 1
    LAngle = 2     # <
    RAngle = 3     # >
    CLAngle = 4    # </>
    CRAngle = 5    # />
    EQ = 6         # =
    Word = 7       # ^[a-zA-Z_:][a-zA-Z0-9_:-]*$（不含 '.'，见 stml-test-plan.md TD-1）
    String = 8     # "" '' —— Xml 属性串，不转义
    Text = 9       # 元素内普通文本
    NevextSrc = 10 # Nevext 代码
    StopeSrc = 11  # Stope 代码


#: 下标即编号，与枚举逐项对应（打印类型名用 ``type_name``）。
TOKEN_TYPE_NAMES = [
    "Invalid", "Eof", "LAngle", "RAngle", "CLAngle", "CRAngle",
    "EQ", "Word", "String", "Text", "NevextSrc", "StopeSrc",
]


def type_name(t: int) -> str:
    """类型名 —— 与 C++ 的 ``stmlTokenName`` / GD 的 ``StopeStmlLexer.token_name`` 一致。"""
    return TOKEN_TYPE_NAMES[t] if 0 <= t < len(TOKEN_TYPE_NAMES) else "?"


class LexerState(IntEnum):
    """词法四态。扫完一段 Text / Nevext / Stope 后**必须交还 Xml**（见 lexer 注释）。"""

    Xml = 0
    Text = 1
    Nevext = 2
    Stope = 3


class Token:
    """一个词法单元。``lexeme`` 是**输入的子串**（C++ 用 string_view 借用，Python 复制）。"""

    __slots__ = ("type", "line", "lexeme")

    def __init__(self, t: int = TokenType.Invalid, line: int = -1, lexeme: str = ""):
        self.type = t
        self.line = line
        self.lexeme = lexeme

    def set(self, t: int, lexeme: str) -> None:
        self.type = t
        self.lexeme = lexeme

    def __repr__(self) -> str:
        return f"Token({type_name(self.type)}, line={self.line}, {self.lexeme!r})"


class Element:
    """一个元素。``children`` 与 ``text`` 互斥；``text`` 只有一段，不拼接。"""

    __slots__ = ("line", "tag", "attrs", "self_closing", "children", "text")

    def __init__(self):
        self.line = -1
        self.tag = ""            # 标签名
        self.attrs: dict[str, str] = {}   # 属性；无值属性的值是空串
        self.self_closing = False
        self.children: list["Element"] = []
        self.text = ""

    def to_str(self, level: int = 0) -> str:
        """调试用：不一定与源文本逐字符相同（属性顺序、自闭合写法都不保留）。"""
        sp = "  " * level
        out = sp + "<" + self.tag
        for name, value in self.attrs.items():
            out += " " + name + (f'="{value}"' if value else "")
        if self.self_closing:
            out += " />\n"
        else:
            out += ">\n" + self.text
            for c in self.children:
                out += c.to_str(level + 1)
            out += sp + "</" + self.tag + ">\n"
        return out

    def __repr__(self) -> str:
        return f"Element({self.tag!r}, line={self.line}, children={len(self.children)})"


__all__ = ["Element", "LexerState", "TOKEN_TYPE_NAMES", "Token", "TokenType", "type_name"]
