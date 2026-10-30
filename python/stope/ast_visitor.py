"""遍历骨架 —— 逐项对齐 ``cpp/include/stope/ast_visitor.hpp``（+ ``.cpp`` 的分发表）。

用法：继承 :class:`ASTVisitor`，按需重写 ``on_visit_xxx``。默认实现一律「按源码顺序
递归子节点」，子类重写后若要继续下钻，调 ``super().on_visit_xxx(...)`` 即可。

⚠ 分发表 ``VISIT_MAP`` 是 ``NodeType -> 方法名``：漏一项**不会报错**，只会静默跳过
整类节点（``Node`` / ``Stmt`` / ``Expr`` 三个裸基类本来就没有表项，它们在错误恢复
路径上出现，``visit()`` 直接跳过 —— 这是有意的，不是 bug）。
"""

from .ast import NodeType
from .token import TokenType

#: NodeType -> 方法名，等价于 C++ 的 ``ASTVisitor::visitMap``
VISIT_MAP = {
    NodeType.Prog: "on_visit_prog",

    NodeType.ExprStmt: "on_visit_expr_stmt",
    NodeType.LetStmt: "on_visit_let_stmt",
    NodeType.ReturnStmt: "on_visit_return_stmt",
    NodeType.ExportStmt: "on_visit_export_stmt",
    NodeType.BlockStmt: "on_visit_block_stmt",
    NodeType.IfStmt: "on_visit_if_stmt",
    NodeType.WhileStmt: "on_visit_while_stmt",
    NodeType.AssignStmt: "on_visit_assign_stmt",
    NodeType.BreakStmt: "on_visit_break_stmt",
    NodeType.ContinueStmt: "on_visit_continue_stmt",

    NodeType.NullExpr: "on_visit_null_expr",
    NodeType.BoolExpr: "on_visit_bool_expr",
    NodeType.IntExpr: "on_visit_int_expr",
    NodeType.FloatExpr: "on_visit_float_expr",
    NodeType.BinArrExpr: "on_visit_binarr_expr",
    NodeType.StringExpr: "on_visit_string_expr",
    NodeType.IdentExpr: "on_visit_ident_expr",
    NodeType.ArgcExpr: "on_visit_argc_expr",
    NodeType.ArgsExpr: "on_visit_args_expr",
    NodeType.UnaryOpExpr: "on_visit_unary_op_expr",
    NodeType.BinaryOpExpr: "on_visit_binary_op_expr",
    NodeType.CallExpr: "on_visit_call_expr",
    NodeType.AtExpr: "on_visit_at_expr",
    NodeType.CustomOpcodeExpr: "on_visit_custom_opcode_expr",
}


class ASTVisitor:
    """所有钩子都是空实现或「按顺序下钻」，子类只重写关心的那几个。"""

    def __init__(self):
        #: 当前正在访问的节点行号，由 visit() 顺带更新。基类自己不用，留给要报诊断的
        #: 子类（编译器那些没有专属行号的错误就取它）。
        self.cur_line = -1

    @property
    def visit_map(self) -> dict:
        return VISIT_MAP

    def visit(self, n) -> None:
        if n is None:
            return
        self.cur_line = n.line
        fn = VISIT_MAP.get(n.node_type)
        if fn is not None:
            getattr(self, fn)(n)

    # ==================== 子类要重写的钩子 ====================
    # 只有 NullExpr / ArgcExpr 没有子节点，它们的参数写成可选的，这样 visit()
    # 能对所有钩子统一 getattr(self, fn)(n)，不必为「无参钩子」单开一条分支。

    def on_visit_prog(self, p) -> None:
        for s in p.stmts:
            self.visit(s)

    # ---------------- 语句 ----------------
    def on_visit_expr_stmt(self, s) -> None:
        self.visit(s.expr)

    def on_visit_let_stmt(self, s) -> None:
        """只走初值：``idents`` 是名字（str 列表），不是 Expr。"""
        if s.has_assign:
            self.visit(s.expr)

    def on_visit_return_stmt(self, s) -> None:
        for e in s.exprs:
            self.visit(e)

    def on_visit_export_stmt(self, _s) -> None:
        pass

    def on_visit_block_stmt(self, s) -> None:
        self.visit(s.prog)

    def on_visit_if_stmt(self, s) -> None:
        """顺序：条件 -> 首分支 -> 每个 elif（条件 -> 块）-> else 块。"""
        self.visit(s.cond)
        self.visit(s.first_prog)
        for ei in s.elifs:
            self.visit(ei.cond)
            self.visit(ei.prog)
        if s.else_prog is not None:
            self.visit(s.else_prog)

    def on_visit_while_stmt(self, s) -> None:
        self.visit(s.cond)  # 条件可省（while { }），visit(None) 自己会返回
        self.visit(s.prog)

    def on_visit_assign_stmt(self, s) -> None:
        self.visit(s.left_expr)
        self.visit(s.right_expr)

    def on_visit_break_stmt(self, _s) -> None:
        pass

    def on_visit_continue_stmt(self, _s) -> None:
        pass

    # ---------------- 表达式 ----------------
    def on_visit_null_expr(self, _n=None) -> None:
        pass

    def on_visit_bool_expr(self, _e) -> None:
        pass

    def on_visit_int_expr(self, _e) -> None:
        pass

    def on_visit_float_expr(self, _e) -> None:
        pass

    def on_visit_binarr_expr(self, _e) -> None:
        pass

    def on_visit_string_expr(self, _e) -> None:
        pass

    def on_visit_ident_expr(self, _e) -> None:
        pass

    def on_visit_argc_expr(self, _n=None) -> None:
        pass

    def on_visit_args_expr(self, e) -> None:
        self.visit(e.key_expr)  # args[] 的下标缺失时为 None

    def on_visit_unary_op_expr(self, e) -> None:
        self.visit(e.expr)

    def on_visit_binary_op_expr(self, e) -> None:
        if e.op == TokenType.Or:
            self.on_visit_or_expr(e)
            return
        if e.op == TokenType.And:
            self.on_visit_and_expr(e)
            return
        self.visit(e.left_expr)
        self.visit(e.right_expr)

    # 短路语义的钩子：默认实现与上面的普通路径等价，需要特判的后端（编译器）自行重写
    def on_visit_or_expr(self, e) -> None:
        self.visit(e.left_expr)
        self.visit(e.right_expr)

    def on_visit_and_expr(self, e) -> None:
        self.visit(e.left_expr)
        self.visit(e.right_expr)

    def on_visit_call_expr(self, e) -> None:
        self.visit(e.callee)
        for a in e.args:
            self.visit(a)

    def on_visit_at_expr(self, e) -> None:
        self.visit(e.container)
        for k in e.key_exprs:
            self.visit(k)

    def on_visit_custom_opcode_expr(self, e) -> None:
        for a in e.args:
            self.visit(a)
