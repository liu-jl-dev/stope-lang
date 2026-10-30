"""Stope 的 Python 实现。

分层与另外四套实现一一对应（``cpp/include/stope/*.hpp``、``gdscript/addons/stope/*.gd``、
``nodejs/src/*.js``、``csharp/Stope/*.cs``）：

标准层
    ``Lexer`` / ``Parser`` / ``AST`` / ``ASTVisitor`` / ``optimize`` / ``Compiler`` /
    ``Program`` / ``BinaryArrayParser`` / ``disasm`` / STML 三件套 —— 名字与 C++ 逐项对应，
    只是方法名按 Python 惯例用 snake_case（``parse_program`` ↔ ``ParseProgram``）。

示例层
    ``Api`` / ``State`` / ``Arguments`` / ``Identifier`` —— **不是标准**

「标准」的含义见仓库根 README：Stope 只规定语言、STML 与编译产物 ``Program``；
虚拟机只是参考实现，换一个执行器这些名字可能一个都不存在。
"""

from . import ast as AST
from .ast_visitor import ASTVisitor
from .basic_vm import Api, Arguments, Identifier, State
from .binarr_parser import BinaryArrayParser
from .common import Result
from .compiler import Compiler
from .debug import disasm, disasm_no_custom
from .expr_optim import optimize
from .format import esc, fmt_bytes, fmt_g
from .lexer import Lexer
from .opcode import CustomOpcode, CustomOpcodeConfig, Opcode, kFirstCustomOpcode
from .parser import Parser
from .program import Program
from .stml import Element as StmlElement
from .stml import LexerState as StmlState
from .stml import Token as StmlToken
from .stml import TokenType as StmlTokenType
from .stml_lexer import Lexer as StmlLexer
from .stml_parser import Parser as StmlParser
from .token import Token, TokenType, type_name

__all__ = [
    # 标准层
    "AST",
    "ASTVisitor",
    "BinaryArrayParser",
    "Compiler",
    "CustomOpcode",
    "CustomOpcodeConfig",
    "Lexer",
    "Opcode",
    "Parser",
    "Program",
    "Result",
    "Token",
    "TokenType",
    "disasm",
    "disasm_no_custom",
    "esc",
    "fmt_bytes",
    "fmt_g",
    "kFirstCustomOpcode",
    "optimize",
    "type_name",
    # STML（带 Stml 前缀，免得与 Stope 的 Lexer / Parser / Token 撞名 ——
    # 与 C# 侧 using Stml = Stope.Stml 是同一个理由）
    "StmlElement",
    "StmlLexer",
    "StmlParser",
    "StmlState",
    "StmlToken",
    "StmlTokenType",
    # 示例层（不是标准）
    "Api",
    "Arguments",
    "Identifier",
    "State",
]
