"""词法单元类型与 ``Token``。

编号与 C++ 的 ``stope::TokenType`` 逐项相同（0..46），**不要重排**：golden_lex.txt 里
落的是 ``Name(line)`` 形态的名字，编号本身不进数据，但反查名必须一一对应。

⚠ 两个成员带下划线：``True_`` / ``False_`` —— ``True`` 与 ``False`` 是 Python 关键字，
不能作类属性名。对外打印一律走 :func:`type_name`，它把下划线去掉，输出 ``True`` / ``False``。
"""

from enum import IntEnum


class TokenType(IntEnum):
    Invalid = 0
    Eof = 1
    Ident = 2
    Integer = 3
    Float = 4
    String = 5
    BinArr = 6
    Comma = 7
    Semi = 8
    LParen = 9

    RParen = 10
    LBrack = 11
    RBrack = 12
    LBrace = 13
    RBrace = 14
    Assign = 15
    Add = 16
    Sub = 17
    Mul = 18
    Div = 19

    IDiv = 20
    Mod = 21
    Pow = 22
    EQ = 23
    NE = 24
    LT = 25
    LE = 26
    GT = 27
    GE = 28
    Not = 29

    And = 30
    Or = 31
    If = 32
    Elif = 33
    Else = 34
    Let = 35
    Return = 36
    While = 37
    Break = 38
    Continue = 39

    Null = 40
    False_ = 41
    True_ = 42
    Args = 43
    Argc = 44
    Export = 45
    Custom = 46


# 关键字名 → TokenType。Lexer 扫完标识符后查这张表（自定义指令优先于关键字？
# 不 —— 关键字优先，见 opcode.CustomOpcodeConfig 的注释）。
TOKEN_TYPE_NAMES = ["Invalid", "Eof", "Ident", "Integer", "Float", "String", "BinArr",
                    "Comma", "Semi", "LParen", "RParen", "LBrack", "RBrack", "LBrace",
                    "RBrace", "Assign", "Add", "Sub", "Mul", "Div", "IDiv", "Mod", "Pow",
                    "EQ", "NE", "LT", "LE", "GT", "GE", "Not", "And", "Or", "If", "Elif",
                    "Else", "Let", "Return", "While", "Break", "Continue", "Null", "False",
                    "True", "Args", "Argc", "Export", "Custom"]


def type_name(t: TokenType) -> str:
    """枚举 → golden 里用的名字（去掉 ``True_`` / ``False_`` 的下划线）。"""
    return TOKEN_TYPE_NAMES[int(t)]


class Token:
    """一个词法单元。

    ``lexeme`` 是**实现自定**的字段：只有数字 / 字符串 / 二进制数组参与跨实现比对
    （见 docs/zh-cn/lexer-test-plan.md §2）；标识符与标点的 lexeme 不作为契约，
    但本实现会给所有 token 填上原文，方便排错。
    """

    __slots__ = ("line", "type", "lexeme", "parsed", "value")

    def __init__(self, line: int = 0, type: TokenType = TokenType.Invalid):
        self.line = line
        self.type = type
        self.lexeme = ""
        # parsed 是「语义形态」：数字去掉下划线、标识符去掉命名空间两侧空白、字符串反转义后
        self.parsed = ""
        self.value = None

    def __repr__(self) -> str:
        return f"Token({type_name(self.type)}, line={self.line}, lexeme={self.lexeme!r})"
