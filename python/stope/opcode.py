"""指令集与自定义指令登记表。

33 条内置指令，编号与 C++ 的 ``stope::Opcode`` 逐项相同（0..32）。golden 的产物段
（``code[Assign(2) ...]``）与反汇编都按编号取名字，所以**加枚举项必须同步**：

* 本文件的成员顺序（= 编号）；
* ``debug._BUILTIN_NAMES``（反汇编用）；
* ``basic_vm`` 的分派表。

少一处就会在 Run 时落到空处理函数上。自定义指令从 33 起。
"""

from enum import IntEnum

from .common import Result


class Opcode(IntEnum):
    Assign = 0
    PushNull = 1
    PushFalse = 2
    PushTrue = 3
    PushInt = 4
    PushFloat = 5
    PushString = 6
    PushBinArr = 7
    PushValue = 8
    PushId = 9

    Call = 10
    At = 11
    Pop = 12
    Minus = 13
    Not = 14
    Pow = 15
    Mul = 16
    Div = 17
    IDiv = 18
    Mod = 19

    Add = 20
    Sub = 21
    EQ = 22
    NE = 23
    LT = 24
    LE = 25
    GT = 26
    GE = 27
    If = 28
    GoTo = 29

    GetArg = 30
    ArgNum = 31
    Return = 32


#: 第一个可用的自定义指令编号（= Return + 1）
kFirstCustomOpcode = int(Opcode.Return) + 1


class CustomOpcode:
    """一条自定义指令的登记项。

    ``arg_num`` < 0 表示变长（产物里不带参数）；定长时产物紧跟一个操作数（参数个数）。
    """

    __slots__ = ("opcode", "arg_num", "is_var_arg")

    def __init__(self, opcode: int, arg_num: int = -1):
        self.opcode = opcode
        self.arg_num = arg_num
        self.is_var_arg = arg_num < 0

    def __repr__(self) -> str:
        return f"CustomOpcode({self.opcode}, arg_num={self.arg_num})"


class CustomOpcodeConfig:
    """名字 → :class:`CustomOpcode` 的登记表。

    Lexer / Parser / Compiler **必须共用同一个对象**，各建一份会出现「编译期找不到
    指令」或「退化成普通函数调用」。名字是普通标识符或命名空间形式 ``a:b``
    （词法器保证），且**关键字优先** —— 注册一个叫 ``if`` 的指令是无效的。
    """

    __slots__ = ("opcodes",)

    def __init__(self):
        self.opcodes: dict[str, CustomOpcode] = {}

    def add_custom_opcode(self, name: str, opcode: int, arg_num: int = -1) -> Result:
        """登记一条自定义指令；同名重复返回 ``DuplicateWithBuiltinOpcode`` 且不插入。"""
        if name in self.opcodes:
            return Result.DuplicateWithBuiltinOpcode
        self.opcodes[name] = CustomOpcode(opcode, arg_num)
        return Result.Success
