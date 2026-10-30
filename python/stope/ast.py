"""AST 节点定义与形状串序列化。

与 ``cpp/include/stope/ast.hpp`` 逐项对齐；字段名用 snake_case（Python 惯例），
对应 C++ 的 camelCase，对照见 ``docs/usage.md``。

``shape_prog`` / ``shape_stmt`` / ``shape_expr`` 是**测试用**序列化，严格照抄
``cpp/test/test_common.hpp`` 的同名函数，格式见 ``docs/zh-cn/parser-test-plan.md`` §2。

⚠ 两点容易踩：

* ``BlockStmt.prog`` 永远是个 :class:`Prog`（C++ 是值成员），错误路径上也是空 Prog，
  所以形状串是 ``Block{}`` 而不是 ``Block{null}``；只有 ``IfStmt.else_prog`` 是
  ``Optional``，没有 else 时是 ``None``。
* 解析失败时返回的是**裸** :class:`Expr`（``node_type = NodeType.Expr``，``line`` 恒为
  -1），形状串打成 ``Err(L-1)`` —— 这里的 -1 是「没有行号」，不是行号 -1。
"""

from enum import IntEnum

from .format import esc, fmt_bytes, fmt_g
from .token import TokenType, type_name


class NodeType(IntEnum):
    Node = 0
    Prog = 1
    Stmt = 2
    Expr = 3
    ExprStmt = 4
    LetStmt = 5
    ReturnStmt = 6
    ExportStmt = 7
    BlockStmt = 8
    IfStmt = 9
    WhileStmt = 10
    AssignStmt = 11
    BreakStmt = 12
    ContinueStmt = 13
    NullExpr = 14
    BoolExpr = 15
    IntExpr = 16
    FloatExpr = 17
    BinArrExpr = 18
    StringExpr = 19
    IdentExpr = 20
    ArgcExpr = 21
    ArgsExpr = 22
    UnaryOpExpr = 23
    BinaryOpExpr = 24
    CallExpr = 25
    AtExpr = 26
    CustomOpcodeExpr = 27


class Precedence:
    """10 档优先级，与 ``cpp/include/stope/common.hpp`` 的 ``OpPrecedence`` 同序同值。"""

    Lowest = 0
    Or = 1
    And = 2
    Equals = 3
    LessGreater = 4
    AddSub = 5
    MulDiv = 6
    Pow = 7
    Prefix = 8
    Paren = 9


_T = TokenType

#: 二元运算符 → 优先级。调用 ``()``、取元素 ``[]`` 也是二元形式，优先级最高。
BINOP_PREC = {
    _T.Or: Precedence.Or,
    _T.And: Precedence.And,
    _T.EQ: Precedence.Equals,
    _T.NE: Precedence.Equals,
    _T.LT: Precedence.LessGreater,
    _T.LE: Precedence.LessGreater,
    _T.GT: Precedence.LessGreater,
    _T.GE: Precedence.LessGreater,
    _T.Add: Precedence.AddSub,
    _T.Sub: Precedence.AddSub,
    _T.Mul: Precedence.MulDiv,
    _T.Div: Precedence.MulDiv,
    _T.IDiv: Precedence.MulDiv,
    _T.Mod: Precedence.MulDiv,
    _T.Pow: Precedence.Pow,
    _T.LParen: Precedence.Paren,
    _T.LBrack: Precedence.Paren,
}

#: 二元运算符的显示文本（错误信息与 ``to_str`` 用；节点里存的是 TokenType）
BINOP_LITERAL = {
    _T.Or: "||", _T.And: "&&", _T.EQ: "==", _T.NE: "!=",
    _T.LT: "<", _T.LE: "<=", _T.GT: ">", _T.GE: ">=",
    _T.Add: "+", _T.Sub: "-", _T.Mul: "*", _T.Div: "/",
    _T.IDiv: "idiv", _T.Mod: "%", _T.Pow: "^",
}


def _indent(level: int) -> str:
    return "  " * level


def _e(n) -> str:
    return n.to_str() if n is not None else "<null>"


def _op_text(op: TokenType) -> str:
    if op == _T.Sub:
        return "-"
    if op == _T.Not:
        return "!"
    return type_name(op) + "("


# ================================ 基类 ================================


class Node:
    __slots__ = ("line", "node_type")

    def __init__(self, line: int = -1):
        self.line = line
        self.node_type = NodeType.Node

    def to_str(self, level: int = 0) -> str:
        return ""


class Stmt(Node):
    __slots__ = ()

    def __init__(self, line: int = -1):
        super().__init__(line)
        self.node_type = NodeType.Stmt

    def to_str(self, level: int = 0) -> str:
        return ";\n"


class Expr(Node):
    __slots__ = ()

    def __init__(self, line: int = -1):
        super().__init__(line)
        self.node_type = NodeType.Expr

    def to_str(self, level: int = 0) -> str:
        return "()"


# ================================ prog ================================
# prog : stmt*


class Prog(Node):
    __slots__ = ("stmts",)

    def __init__(self, line: int = -1):
        super().__init__(line)
        self.node_type = NodeType.Prog
        self.stmts: list = []

    def to_str(self, level: int = 0) -> str:
        return "".join(s.to_str(level) for s in self.stmts)


# ================================ 语句 ================================
# expr_stmt : expr ";"


class ExprStmt(Stmt):
    __slots__ = ("expr",)

    def __init__(self, line: int = -1):
        super().__init__(line)
        self.node_type = NodeType.ExprStmt
        self.expr = None

    def to_str(self, level: int = 0) -> str:
        return _indent(level) + _e(self.expr) + ";\n"


# let_stmt : "let" ident ( ("," ident)* | ("=" expr) )? ";"


class LetStmt(Stmt):
    __slots__ = ("has_assign", "idents", "expr")

    def __init__(self, line: int = -1):
        super().__init__(line)
        self.node_type = NodeType.LetStmt
        self.has_assign = False
        self.idents: list[str] = []
        self.expr = None

    def ident_num(self) -> int:
        return len(self.idents)

    def to_str(self, level: int = 0) -> str:
        s = _indent(level) + "let"
        if self.has_assign:
            first = self.idents[0] if self.idents else "?"
            s += " %s = %s" % (first, _e(self.expr))
        else:
            for i in self.idents:
                s += " %s," % i
            if self.idents:
                s = s[:-1]
        return s + ";\n"


# return_stmt : "return" ( expr ( "," expr )* )? ";"


class ReturnStmt(Stmt):
    __slots__ = ("exprs",)

    def __init__(self, line: int = -1):
        super().__init__(line)
        self.node_type = NodeType.ReturnStmt
        self.exprs: list = []

    def expr_num(self) -> int:
        return len(self.exprs)

    def to_str(self, level: int = 0) -> str:
        s = _indent(level) + "return"
        for e in self.exprs:
            s += " %s," % _e(e)
        if self.exprs:
            s = s[:-1]
        return s + ";\n"


# export_stmt : "export" ident ( "," ident )* ";"


class ExportStmt(Stmt):
    __slots__ = ("idents",)

    def __init__(self, line: int = -1):
        super().__init__(line)
        self.node_type = NodeType.ExportStmt
        self.idents: list[str] = []

    def ident_num(self) -> int:
        return len(self.idents)

    def to_str(self, level: int = 0) -> str:
        s = _indent(level) + "export"
        for i in self.idents:
            s += " %s," % i
        if self.idents:
            s = s[:-1]
        return s + ";\n"


# block_stmt : "{" prog "}"


class BlockStmt(Stmt):
    __slots__ = ("prog",)

    def __init__(self, line: int = -1):
        super().__init__(line)
        self.node_type = NodeType.BlockStmt
        self.prog = Prog()

    def to_str(self, level: int = 0) -> str:
        return "%s{\n%s%s}\n" % (_indent(level), self.prog.to_str(level + 1), _indent(level))


class IfStmtElif(Node):
    __slots__ = ("cond", "prog")

    def __init__(self, line: int = -1):
        super().__init__(line)
        self.cond = None
        self.prog = Prog()


# if_stmt : "if" expr "{" prog "}" ( "elif" expr "{" prog "}" )* ( "else" "{" prog "}" )?


class IfStmt(Stmt):
    __slots__ = ("cond", "first_prog", "elifs", "else_prog")

    def __init__(self, line: int = -1):
        super().__init__(line)
        self.node_type = NodeType.IfStmt
        self.cond = None
        self.first_prog = Prog()
        self.elifs: list[IfStmtElif] = []
        self.else_prog = None  # 没有 else 分支时为 None

    def has_else(self) -> bool:
        return self.else_prog is not None

    def to_str(self, level: int = 0) -> str:
        o = "%sif %s %s" % (_indent(level), _e(self.cond), self.first_prog.to_str(level))
        for ei in self.elifs:
            o += "%selif %s %s" % (_indent(level), _e(ei.cond), ei.prog.to_str(level))
        if self.has_else():
            o += "%selse %s" % (_indent(level), self.else_prog.to_str(level))
        return o


# while_stmt : "while" expr? "{" prog "}"   —— cond 为 None 表示无条件循环


class WhileStmt(Stmt):
    __slots__ = ("cond", "prog")

    def __init__(self, line: int = -1):
        super().__init__(line)
        self.node_type = NodeType.WhileStmt
        self.cond = None
        self.prog = Prog()

    def to_str(self, level: int = 0) -> str:
        return "%swhile %s %s" % (_indent(level), _e(self.cond), self.prog.to_str(level))


# assign_stmt : expr "=" expr ";"


class AssignStmt(Stmt):
    __slots__ = ("left_expr", "right_expr")

    def __init__(self, line: int = -1):
        super().__init__(line)
        self.node_type = NodeType.AssignStmt
        self.left_expr = None
        self.right_expr = None

    def to_str(self, level: int = 0) -> str:
        return "%s%s = %s;\n" % (_indent(level), _e(self.left_expr), _e(self.right_expr))


class BreakStmt(Stmt):
    __slots__ = ()

    def __init__(self, line: int = -1):
        super().__init__(line)
        self.node_type = NodeType.BreakStmt

    def to_str(self, level: int = 0) -> str:
        return _indent(level) + "break;\n"


class ContinueStmt(Stmt):
    __slots__ = ()

    def __init__(self, line: int = -1):
        super().__init__(line)
        self.node_type = NodeType.ContinueStmt

    def to_str(self, level: int = 0) -> str:
        return _indent(level) + "continue;\n"


# ================================ 表达式 ================================


class NullExpr(Expr):
    __slots__ = ()

    def __init__(self, line: int = -1):
        super().__init__(line)
        self.node_type = NodeType.NullExpr

    def to_str(self, level: int = 0) -> str:
        return "null"


class BoolExpr(Expr):
    __slots__ = ("value",)

    def __init__(self, line: int = -1, v: bool = False):
        super().__init__(line)
        self.node_type = NodeType.BoolExpr
        self.value = v

    def to_str(self, level: int = 0) -> str:
        return "true" if self.value else "false"


class IntExpr(Expr):
    """``value`` 是 int64 范围内的 Python ``int``（与 lexer 一致）。"""

    __slots__ = ("value",)

    def __init__(self, line: int = -1, v: int = 0):
        super().__init__(line)
        self.node_type = NodeType.IntExpr
        self.value = v

    def to_str(self, level: int = 0) -> str:
        return str(self.value)


class FloatExpr(Expr):
    __slots__ = ("value",)

    def __init__(self, line: int = -1, v: float = 0.0):
        super().__init__(line)
        self.node_type = NodeType.FloatExpr
        self.value = v

    def to_str(self, level: int = 0) -> str:
        return fmt_g(self.value)


class BinArrExpr(Expr):
    """``value`` 是 ``bytes``（对应 C++ 的 ``std::vector<char>`` / GD 的 PackedByteArray）。"""

    __slots__ = ("value",)

    def __init__(self, line: int = -1, v: bytes = b""):
        super().__init__(line)
        self.node_type = NodeType.BinArrExpr
        self.value = v

    def to_str(self, level: int = 0) -> str:
        return "'%s'" % fmt_bytes(self.value)


class StringExpr(Expr):
    __slots__ = ("value",)

    def __init__(self, line: int = -1, v: str = ""):
        super().__init__(line)
        self.node_type = NodeType.StringExpr
        self.value = v

    def to_str(self, level: int = 0) -> str:
        return '"%s"' % self.value


class IdentExpr(Expr):
    __slots__ = ("ident",)

    def __init__(self, line: int = -1, v: str = ""):
        super().__init__(line)
        self.node_type = NodeType.IdentExpr
        self.ident = v

    def to_str(self, level: int = 0) -> str:
        return self.ident


class ArgcExpr(Expr):
    __slots__ = ()

    def __init__(self, line: int = -1):
        super().__init__(line)
        self.node_type = NodeType.ArgcExpr

    def to_str(self, level: int = 0) -> str:
        return "argc"


class ArgsExpr(Expr):
    __slots__ = ("key_expr",)

    def __init__(self, line: int = -1):
        super().__init__(line)
        self.node_type = NodeType.ArgsExpr
        self.key_expr = None

    def to_str(self, level: int = 0) -> str:
        return "args[%s]" % _e(self.key_expr)


class UnaryOpExpr(Expr):
    __slots__ = ("op", "expr")

    def __init__(self, line: int = -1):
        super().__init__(line)
        self.node_type = NodeType.UnaryOpExpr
        self.op = _T.Invalid
        self.expr = None

    def to_str(self, level: int = 0) -> str:
        return _op_text(self.op) + _e(self.expr)


class BinaryOpExpr(Expr):
    __slots__ = ("left_expr", "op", "right_expr")

    def __init__(self, line: int = -1):
        super().__init__(line)
        self.node_type = NodeType.BinaryOpExpr
        self.left_expr = None
        self.op = _T.Invalid
        self.right_expr = None

    def to_str(self, level: int = 0) -> str:
        o = BINOP_LITERAL.get(self.op, "?")
        o = " idiv " if o == "idiv" else " %s " % o
        return "(%s%s%s)" % (_e(self.left_expr), o, _e(self.right_expr))


class CallExpr(Expr):
    __slots__ = ("callee", "args")

    def __init__(self, line: int = -1):
        super().__init__(line)
        self.node_type = NodeType.CallExpr
        self.callee = None
        self.args: list = []

    def to_str(self, level: int = 0) -> str:
        s = "%s(" % _e(self.callee)
        for a in self.args:
            s += "%s," % _e(a)
        if self.args:
            s = s[:-1]
        return s + ")"


class AtExpr(Expr):
    __slots__ = ("container", "key_exprs")

    def __init__(self, line: int = -1):
        super().__init__(line)
        self.node_type = NodeType.AtExpr
        self.container = None
        self.key_exprs: list = []

    def to_str(self, level: int = 0) -> str:
        s = "%s[" % _e(self.container)
        for a in self.key_exprs:
            s += "%s," % _e(a)
        if self.key_exprs:
            s = s[:-1]
        return s + "]"


# custom_opcode_expr : custom "(" ( expr ( "," expr )* )? ")"


class CustomOpcodeExpr(Expr):
    __slots__ = ("opcode_name", "args")

    def __init__(self, line: int = -1):
        super().__init__(line)
        self.node_type = NodeType.CustomOpcodeExpr
        self.opcode_name = ""
        self.args: list = []

    def to_str(self, level: int = 0) -> str:
        s = "%s(" % self.opcode_name
        for a in self.args:
            s += "%s," % _e(a)
        if self.args:
            s = s[:-1]
        return s + ")"


# ================================ 序列化：测试用 ================================
# 严格照抄 cpp/test/test_common.hpp 的 shapeExpr / shapeStmt / shapeProg：
#   Null / Argc / Bool(true) / Int(31) / Float(1.5) / BinArr[04,01] / Str("a\nb") /
#   Ident(a) / Args(null) / Unary(Sub, Int(1)) / Bin(Add, Int(1), Int(2)) /
#   Call(f; Int(1)) / At(a; Int(1)) / Custom(myop; Int(1)) / Err(L-1)
#   ExprStmt(..) / Let[a,b]=Int(1) / Return(Int(1), Int(2)) / Export[a] /
#   Block{..} / If(c){..}Elif(c){..}Else{..} / While(c){..} /
#   Assign(l, r) / Break / Continue
# prog：语句按 " ; " 连接，无外层包装；空 prog -> ""


def shape_prog(p) -> str:
    if p is None:
        return "null"
    return " ; ".join(shape_stmt(s) for s in p.stmts)


def shape_stmt(s) -> str:
    if s is None:
        return "null"
    t = s.node_type
    if t == NodeType.ExprStmt:
        return "ExprStmt(%s)" % shape_expr(s.expr)
    if t == NodeType.LetStmt:
        d = "Let[%s]" % ",".join(esc(i) for i in s.idents)
        if s.has_assign:
            d += "=" + shape_expr(s.expr)
        return d
    if t == NodeType.ReturnStmt:
        return "Return(%s)" % ", ".join(shape_expr(e) for e in s.exprs)
    if t == NodeType.ExportStmt:
        return "Export[%s]" % ",".join(esc(i) for i in s.idents)
    if t == NodeType.BlockStmt:
        return "Block{%s}" % shape_prog(s.prog)
    if t == NodeType.IfStmt:
        d = "If(%s){%s}" % (shape_expr(s.cond), shape_prog(s.first_prog))
        for ei in s.elifs:
            d += "Elif(%s){%s}" % (shape_expr(ei.cond), shape_prog(ei.prog))
        if s.else_prog is not None:
            d += "Else{%s}" % shape_prog(s.else_prog)
        return d
    if t == NodeType.WhileStmt:
        return "While(%s){%s}" % (shape_expr(s.cond), shape_prog(s.prog))
    if t == NodeType.AssignStmt:
        return "Assign(%s, %s)" % (shape_expr(s.left_expr), shape_expr(s.right_expr))
    if t == NodeType.BreakStmt:
        return "Break"
    if t == NodeType.ContinueStmt:
        return "Continue"
    return "?" + node_type_name(t)


def shape_expr(e) -> str:
    if e is None:
        return "null"
    t = e.node_type
    if t == NodeType.Expr:  # 失败路径返回的裸节点：line 恒为 -1
        return "Err(L%d)" % e.line
    if t == NodeType.NullExpr:
        return "Null"
    if t == NodeType.ArgcExpr:
        return "Argc"
    if t == NodeType.BoolExpr:
        return "Bool(true)" if e.value else "Bool(false)"
    if t == NodeType.IntExpr:
        return "Int(%d)" % e.value
    if t == NodeType.FloatExpr:
        return "Float(%s)" % fmt_g(e.value)
    if t == NodeType.BinArrExpr:
        return "BinArr[%s]" % fmt_bytes(e.value)
    if t == NodeType.StringExpr:
        return 'Str("%s")' % esc(e.value)
    if t == NodeType.IdentExpr:
        return "Ident(%s)" % esc(e.ident)
    if t == NodeType.ArgsExpr:
        return "Args(null)" if e.key_expr is None else "Args(%s)" % shape_expr(e.key_expr)
    if t == NodeType.UnaryOpExpr:
        return "Unary(%s, %s)" % (type_name(e.op), shape_expr(e.expr))
    if t == NodeType.BinaryOpExpr:
        return "Bin(%s, %s, %s)" % (type_name(e.op), shape_expr(e.left_expr),
                                    shape_expr(e.right_expr))
    if t == NodeType.CallExpr:
        return "Call(%s%s)" % (shape_expr(e.callee),
                               "".join("; " + shape_expr(a) for a in e.args))
    if t == NodeType.AtExpr:
        return "At(%s%s)" % (shape_expr(e.container),
                             "".join("; " + shape_expr(k) for k in e.key_exprs))
    if t == NodeType.CustomOpcodeExpr:
        return "Custom(%s%s)" % (esc(e.opcode_name),
                                 "".join("; " + shape_expr(a) for a in e.args))
    return "?" + node_type_name(t)


def node_type_name(t) -> str:
    try:
        return NodeType(t).name
    except ValueError:
        return "?%d" % int(t)
