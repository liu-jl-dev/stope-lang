"""语法分析器（Pratt）—— 端口 ``cpp/src/parser.cpp``（C++ 为权威实现）。

行为契约见 ``docs/zh-cn/parser-test-plan.md``。几条容易踩错、且各实现必须一致的约定：

1. **错误恢复：分隔符缺失时只报错、不推进**，把后续 token 留给下一条语句重新解析。
   例外（有意保留旧语义）：``parse_let_stmt`` / ``parse_return_stmt`` 的兜底分支仍会推进。
2. 不变量：``parse_expr()`` 之后必有一次 ``next_token()``。删错误分支里的推进时别连带删它。
3. 顶层孤立 ``}`` 要报错**并跳过**继续解析；块内的 ``}`` 由外层消费，不报错。
4. 常量折叠挂在 ``parse_unary_op_expr`` / ``parse_binary_op_expr`` 的构造末尾，
   **不要**改成把 ``parse_expr`` 包一层 —— 那样每层递归多一个栈帧，深括号用例会崩。
5. 节点取 token 的 ``parsed`` 而非 ``lexeme``：字符串要转义后的值、标识符要拼好的 ``:``。
   只有 BinArr 取 ``lexeme``（词法阶段不做任何转义）。

⚠ 嵌套深度上限 256（``max_depth``，0 = 不限）：``depth`` 走**函数参数**（每个 parse_xxx
一个形参），不存成员 —— 哪一层递归、离上限还有多远，看签名就知道。超限时报一条
``line N: nesting too deep (max 256). `` 并置 ``aborted``（此后所有 ``error()`` 都不再
记账，否则 12000 层能刷出上万条连锁噪音），子函数返回 ``None`` 但**不逐层传染**。
"""

from . import ast as A
from .binarr_parser import BinaryArrayParser
from .common import Result
from .expr_optim import optimize
from .token import TokenType

_NT = A.NodeType

#: 默认嵌套深度上限（与 C++ ``Parser::maxDepth`` 相同，文案也逐字相同）
kDefaultMaxDepth = 256


class Parser:
    """``Parser(lexer, custom=None)`` → :meth:`parse_program` 填充一个 :class:`ast.Prog`。"""

    def __init__(self, lexer=None, custom=None):
        self.bin_arr_parser = BinaryArrayParser()
        self.errors: list[str] = []
        self.aborted = False
        self.lexer = lexer
        self.custom = custom
        self.const_folding = True
        self.max_depth = kDefaultMaxDepth
        self.cur_token = None
        self.peek_token = None
        if lexer is not None:
            self.reset(lexer, custom)

    def reset(self, lexer, custom=None) -> None:
        """与 C++ 的 ``Parser::Reset`` 一致：清错误、重挂词法器、重读两个 token。"""
        self.errors = []
        self.aborted = False
        self.lexer = lexer
        self.custom = custom
        self.const_folding = True
        self.max_depth = kDefaultMaxDepth
        # 先读两个 token，cur / peek 才都有值 —— 顺序不能变，
        # 否则输入最开头的自定义指令或首个 token 会被漏掉。
        self.next_token()
        self.next_token()

    def parse_program(self, prog: A.Prog) -> None:
        self.parse_prog(prog, True, 1)

    # ================================ 语句 ================================
    def parse_prog(self, prog: A.Prog, is_top_level: bool, depth: int) -> None:
        """``is_top_level=True`` 只有 :meth:`parse_program` 用。

        块 / if / while 内部的 prog 都是 ``False``：它们的 ``}`` 属于外层语句，
        必须由外层自己消费。
        """
        if self.aborted:
            return
        while not self.aborted and self.cur_token.type != TokenType.Eof:
            t = self.cur_token.type
            if t == TokenType.RBrace:
                if not is_top_level:
                    break  # 块内：正常结束，不跳过，交给外层处理
                self.error(self.cur_token.line, 'unexpected "}" at top level. ')
                self.next_token()
                continue
            if t == TokenType.Semi:  # 空语句
                self.next_token()
                continue
            if t == TokenType.Let:
                stmt = self.parse_let_stmt(depth)
            elif t == TokenType.Export:
                stmt = self.parse_export_stmt(depth)
            elif t == TokenType.Return:
                stmt = self.parse_return_stmt(depth)
            elif t == TokenType.LBrace:
                stmt = self.parse_block_stmt(depth)
            elif t == TokenType.If:
                stmt = self.parse_if_stmt(depth)
            elif t == TokenType.While:
                stmt = self.parse_while_stmt(depth)
            elif t == TokenType.Break:
                stmt = self.parse_break_stmt(depth)
            elif t == TokenType.Continue:
                stmt = self.parse_continue_stmt(depth)
            else:
                stmt = self.parse_expr_or_assign_stmt(depth)  # 表达式语句或赋值语句
            # 超限中止时子函数返回 None：不追加、不再往下解析（否则拿着同一个
            # token 反复调用会死循环）。
            if stmt is None:
                break
            prog.stmts.append(stmt)

    def parse_let_stmt(self, depth: int):
        stmt = A.LetStmt(self.cur_token.line)
        stmt.has_assign = False
        self.next_token()  # 跳过 let
        if self.cur_token.type != TokenType.Ident:
            self.error(self.cur_token.line, 'expected identifier after "let". ')
            self.next_token()
            return stmt
        stmt.idents.append(self.cur_token.parsed)
        self.next_token()
        if self.cur_token.type == TokenType.Semi:
            # 单个标识符且不赋值
            self.next_token()
        elif self.cur_token.type == TokenType.Comma:
            # 多个标识符，禁止赋值
            while True:
                if self.cur_token.type == TokenType.Comma and self.peek_token.type == TokenType.Ident:
                    stmt.idents.append(self.peek_token.parsed)
                    self.next_token()
                    self.next_token()
                elif self.cur_token.type == TokenType.Semi:
                    self.next_token()
                    break
                elif self.cur_token.type in (TokenType.Eof, TokenType.RBrace):
                    # 缺 ";": 此处不能再推进。Eof 上推进不会前进会死循环，
                    # 推进又会吞掉外层块的 "}" 导致解析错位。
                    self.error(self.cur_token.line, 'expected ";" in let statement. ')
                    break
                else:
                    self.error(self.cur_token.line,
                               "failed to parse let statement with multiple identifiers. ")
                    self.next_token()
        elif self.cur_token.type == TokenType.Assign:
            stmt.has_assign = True
            self.next_token()
            stmt.expr = self.parse_expr(A.Precedence.Lowest, depth)
            self.next_token()
        else:
            self.error(self.cur_token.line, "unexpected token in let statement. ")
            self.next_token()
        return stmt

    def parse_export_stmt(self, _depth: int):
        stmt = A.ExportStmt(self.cur_token.line)
        self.next_token()  # 跳过 export
        if self.cur_token.type != TokenType.Ident:
            self.error(self.cur_token.line, 'expected identifier after "export". ')
            self.next_token()
            return stmt
        stmt.idents.append(self.cur_token.parsed)
        self.next_token()
        if self.cur_token.type == TokenType.Semi:
            self.next_token()
        elif self.cur_token.type == TokenType.Comma:
            while True:
                if self.cur_token.type == TokenType.Comma and self.peek_token.type == TokenType.Ident:
                    stmt.idents.append(self.peek_token.parsed)
                    self.next_token()
                    self.next_token()
                elif self.cur_token.type == TokenType.Semi:
                    self.next_token()
                    break
                elif self.cur_token.type in (TokenType.Eof, TokenType.RBrace):
                    self.error(self.cur_token.line, 'expected ";" in export statement. ')
                    break
                else:
                    self.error(self.cur_token.line,
                               "failed to parse export statement with multiple identifiers. ")
                    self.next_token()
        else:
            self.error(self.cur_token.line, "unexpected token in export statement. ")
            self.next_token()
        return stmt

    def parse_return_stmt(self, depth: int):
        """``return_stmt : "return" ( expr ( "," expr )* )? ";"``"""
        stmt = A.ReturnStmt(self.cur_token.line)
        self.next_token()  # 跳过 return
        if self.cur_token.type == TokenType.Semi:
            # 无返回值，exprs 为空
            self.next_token()
            return stmt
        if self.cur_token.type in (TokenType.Eof, TokenType.RBrace):
            # 缺 ";": 此时不能吞掉 } 或 Eof，否则外层块会解析错位
            self.error(self.cur_token.line, 'expected ";" in return statement. ')
            return stmt
        stmt.exprs.append(self.parse_expr(A.Precedence.Lowest, depth))  # 第一个表达式
        self.next_token()  # 到达 , 或 ;
        while True:
            # ("," expr)*
            if self.cur_token.type == TokenType.Semi:
                self.next_token()
                break
            elif self.cur_token.type == TokenType.Comma:
                self.next_token()
                stmt.exprs.append(self.parse_expr(A.Precedence.Lowest, depth))
                self.next_token()
            else:
                self.error(self.cur_token.line, 'expected ";" or "," in return statement. ')
                self.next_token()
                break
        return stmt

    def parse_block_stmt(self, depth: int):
        if self.aborted:
            return None  # 已超限：不再解析
        stmt = A.BlockStmt(self.cur_token.line)
        self.next_token()  # 跳过 {
        stmt.prog = A.Prog()
        self.parse_prog(stmt.prog, False, depth + 1)
        if self.cur_token.type != TokenType.RBrace:
            self.error(self.cur_token.line, 'expected "}" at end of block statement. ')
        self.next_token()  # 跳过 }
        return stmt

    def parse_if_stmt(self, depth: int):
        """``if_stmt : "if" expr "{" prog "}" ("elif" expr "{" prog "}")* ("else" "{" prog "}")?``"""
        if self.aborted:
            return None
        stmt = A.IfStmt(self.cur_token.line)
        self.next_token()  # 跳过 if
        stmt.cond = self.parse_expr(A.Precedence.Lowest, depth)
        self.next_token()  # 到达 {
        if self.cur_token.type != TokenType.LBrace:
            self.error(self.cur_token.line, 'expected "{" in if statement. ')
            return stmt
        self.next_token()  # 跳过 {
        stmt.first_prog = A.Prog()
        self.parse_prog(stmt.first_prog, False, depth + 1)
        if self.cur_token.type != TokenType.RBrace:
            self.error(self.cur_token.line, 'expected "}" in if statement. ')
            return stmt
        self.next_token()  # 跳过 }
        while self.cur_token.type == TokenType.Elif:
            # ("elif" expr "{" prog "}")*
            ei = A.IfStmtElif(self.cur_token.line)
            self.next_token()  # 跳过 elif
            ei.cond = self.parse_expr(A.Precedence.Lowest, depth)
            self.next_token()
            if self.cur_token.type != TokenType.LBrace:
                self.error(self.cur_token.line, 'expected "{" of elif. ')
                return stmt
            self.next_token()  # 跳过 {
            ei.prog = A.Prog()
            self.parse_prog(ei.prog, False, depth + 1)
            if self.cur_token.type != TokenType.RBrace:
                self.error(self.cur_token.line, 'expected "}" of elif. ')
                return stmt
            self.next_token()  # 跳过 }
            stmt.elifs.append(ei)
        if self.cur_token.type == TokenType.Else:
            self.next_token()
            if self.cur_token.type != TokenType.LBrace:
                self.error(self.cur_token.line, 'expected "{" after else. ')
                return stmt
            self.next_token()  # 跳过 {
            stmt.else_prog = A.Prog()
            self.parse_prog(stmt.else_prog, False, depth + 1)
            if self.cur_token.type != TokenType.RBrace:
                self.error(self.cur_token.line, 'expected "}" in if statement. ')
                return stmt
            self.next_token()  # 跳过 }
        return stmt

    def parse_while_stmt(self, depth: int):
        """``while_stmt : "while" expr? "{" prog "}"``"""
        if self.aborted:
            return None
        stmt = A.WhileStmt(self.cur_token.line)
        self.next_token()  # 跳过 while
        if self.cur_token.type != TokenType.LBrace:
            stmt.cond = self.parse_expr(A.Precedence.Lowest, depth)
            self.next_token()  # 到达 {
        if self.cur_token.type != TokenType.LBrace:
            self.error(self.cur_token.line, 'expected "{" in while statement. ')
            return stmt
        self.next_token()  # 跳过 {
        stmt.prog = A.Prog()
        self.parse_prog(stmt.prog, False, depth + 1)
        if self.cur_token.type != TokenType.RBrace:
            self.error(self.cur_token.line, 'expected "}" at end of while statement. ')
            return stmt
        self.next_token()
        return stmt

    def parse_break_stmt(self, _depth: int):
        stmt = A.BreakStmt(self.cur_token.line)
        self.next_token()  # 跳过 break
        if self.cur_token.type != TokenType.Semi:
            self.error(self.cur_token.line, 'expected ";" in break statement. ')
        else:
            self.next_token()
        return stmt

    def parse_continue_stmt(self, _depth: int):
        stmt = A.ContinueStmt(self.cur_token.line)
        self.next_token()  # 跳过 continue
        if self.cur_token.type != TokenType.Semi:
            self.error(self.cur_token.line, 'expected ";" in continue statement. ')
        else:
            self.next_token()
        return stmt

    def parse_expr_or_assign_stmt(self, depth: int):
        left_expr = self.parse_expr(A.Precedence.Lowest, depth)
        if left_expr is None:
            return None  # 超限中止：下面要读 left_expr.line
        self.next_token()  # 到达 = 或 ;
        if self.cur_token.type == TokenType.Semi:
            self.next_token()  # 跳过 ;
            s = A.ExprStmt(left_expr.line)
            s.expr = left_expr
            return s
        elif self.cur_token.type == TokenType.Assign:
            self.next_token()  # 跳过 =
            a = A.AssignStmt(left_expr.line)
            a.left_expr = left_expr
            a.right_expr = self.parse_expr(A.Precedence.Lowest, depth)
            self.next_token()  # 到达 ;
            if self.cur_token.type != TokenType.Semi:
                self.error(self.cur_token.line, 'expected ";" at end of assign statement. ')
            self.next_token()
            return a
        self.error(self.cur_token.line, 'expected ";" or "=". ')
        # 不推进：当前 token 不是合法的语句边界，留给下一轮语句解析。
        # 否则会吞掉后续语句（f(1, 2 x; y; 里的 x; 被吞）。
        s2 = A.ExprStmt(left_expr.line)
        s2.expr = left_expr
        return s2

    # ================================ 表达式主循环 ================================
    def parse_expr(self, precedence: int, depth: int):
        # 深度检查只在这里和 parse_prog 做 —— 只有这两处会递归。
        if self.aborted:
            return None
        if self.max_depth > 0 and depth > self.max_depth:
            self.abort_too_deep(self.cur_token.line)
            return None
        prefix = _PREFIX_FNS.get(self.cur_token.type)
        if prefix is None:
            self.error(self.cur_token.line, "no prefix parse function for token type. ")
            return A.Expr(self.cur_token.line)  # 失败路径返回裸节点，形状为 Err(L行号)
        left_expr = prefix(self, depth)
        if left_expr is None:
            return None  # 子表达式已中止（括号会原样透出）
        while (not self.aborted and self.peek_token.type != TokenType.Semi
               and precedence < self.peek_precedence()):
            infix = _INFIX_FNS.get(self.peek_token.type)
            if infix is None:
                self.error(self.peek_token.line, "no infix parse function for token type. ")
                return left_expr
            self.next_token()
            left_expr = infix(self, left_expr, depth)
            if left_expr is None:
                return None
        return left_expr

    def cur_precedence(self) -> int:
        return A.BINOP_PREC.get(self.cur_token.type, A.Precedence.Lowest)

    def peek_precedence(self) -> int:
        return A.BINOP_PREC.get(self.peek_token.type, A.Precedence.Lowest)

    def optimize_in_place(self, e):
        """常量折叠的单一入口。挂在 ``parse_unary_op_expr`` / ``parse_binary_op_expr``
        的构造末尾，**不要**改成把 ``parse_expr`` 包一层。"""
        if not self.const_folding:
            return e
        return optimize(e)

    # ================================ 基础设施 ================================
    def next_token(self) -> None:
        self.cur_token = self.peek_token
        self.peek_token = self.lexer.next_token(self.custom)

    def error(self, line: int, msg: str) -> None:
        # 嵌套超限中止之后的一切错误（缺 "}"、expected ")" 之类）都是连锁反应，
        # 不再记账 —— 否则一个 12000 层的块嵌套能刷出上万条噪音。
        if self.aborted:
            return
        self.errors.append("line %d: %s" % (line, msg))

    def abort_too_deep(self, line: int) -> None:
        self.error(line, "nesting too deep (max %d). " % self.max_depth)  # 必须在置位之前记账
        self.aborted = True

    def has_err(self) -> bool:
        return len(self.errors) > 0


# ================================ 前缀 ================================
def _parse_ident_expr(p: Parser, _depth: int):
    return A.IdentExpr(p.cur_token.line, p.cur_token.parsed)


def _parse_null_expr(p: Parser, _depth: int):
    return A.NullExpr(p.cur_token.line)


def _parse_bool_expr(p: Parser, _depth: int):
    return A.BoolExpr(p.cur_token.line, p.cur_token.type == TokenType.True_)


def _parse_int_expr(p: Parser, _depth: int):
    return A.IntExpr(p.cur_token.line, p.cur_token.value)


def _parse_float_expr(p: Parser, _depth: int):
    return A.FloatExpr(p.cur_token.line, p.cur_token.value)


def _parse_string_expr(p: Parser, _depth: int):
    # 取 parsed：转义已完成（lexeme 是未转义的原文）
    return A.StringExpr(p.cur_token.line, p.cur_token.parsed)


def _parse_binarr_expr(p: Parser, _depth: int):
    e = A.BinArrExpr(p.cur_token.line)
    # 取 lexeme：二进制数组不做转义，解析到一半失败也要保留前半段（报错但继续）
    buf = bytearray()
    rc = p.bin_arr_parser.parse_binary_array(p.cur_token.lexeme, buf)
    e.value = bytes(buf)
    if rc != Result.Success:
        p.error(p.cur_token.line, "invalid binary array. ")
    return e


def _parse_argc_expr(p: Parser, _depth: int):
    return A.ArgcExpr(p.cur_token.line)


def _parse_unary_op_expr(p: Parser, depth: int):
    e = A.UnaryOpExpr(p.cur_token.line)
    e.op = p.cur_token.type
    p.next_token()
    e.expr = p.parse_expr(A.Precedence.Prefix, depth + 1)
    return p.optimize_in_place(e)  # 自底向上：子表达式已折好，这里折自己


def _parse_paren_expr(p: Parser, depth: int):
    p.next_token()
    e = p.parse_expr(A.Precedence.Lowest, depth + 1)
    p.next_token()
    if p.cur_token.type != TokenType.RParen:
        p.error(p.cur_token.line, 'expected ")". ')
    return e  # 停在 )


def _parse_custom_opcode_expr(p: Parser, depth: int):
    e = A.CustomOpcodeExpr(p.cur_token.line)
    e.opcode_name = p.cur_token.parsed
    p.next_token()  # 到达 (
    if p.cur_token.type != TokenType.LParen:
        p.error(p.cur_token.line, 'expected "(" after custom opcode. ')
        p.next_token()
        return e
    p.next_token()
    if p.cur_token.type == TokenType.RParen:
        pass  # 空参数表，cur 停在 )
    else:
        # expr ("," expr)*
        e.args.append(p.parse_expr(A.Precedence.Lowest, depth + 1))
        while p.peek_token.type == TokenType.Comma:
            p.next_token()
            p.next_token()
            e.args.append(p.parse_expr(A.Precedence.Lowest, depth + 1))
        if p.peek_token.type != TokenType.RParen:
            p.error(p.cur_token.line, 'expected ")". ')
        p.next_token()  # 到达 )
    return e


def _parse_args_expr(p: Parser, depth: int):
    e = A.ArgsExpr(p.cur_token.line)
    if p.peek_token.type != TokenType.LBrack:
        # 不推进（cur 停在 "args"）：把后续 token 留给下一条语句，避免吞掉
        p.error(p.peek_token.line, 'expected "[" after "args". ')
        return e
    p.next_token()  # 到达 [
    p.next_token()
    e.key_expr = p.parse_expr(A.Precedence.Lowest, depth + 1)
    p.next_token()
    if p.cur_token.type != TokenType.RBrack:
        p.error(p.cur_token.line, 'expected "]". ')
    return e


# ================================ 中缀 ================================
def _parse_binary_op_expr(p: Parser, left_expr, depth: int):
    if left_expr is None:
        return None  # 左操作数已中止（正常路径进不来）
    e = A.BinaryOpExpr(left_expr.line)
    e.left_expr = left_expr
    e.op = p.cur_token.type
    prec = p.cur_precedence()
    # ^ 右结合：优先级 -1 让右侧继续吃同级的 ^（2^3^2 = 2^(3^2)）。
    if e.op == TokenType.Pow:
        prec -= 1
    p.next_token()
    e.right_expr = p.parse_expr(prec, depth + 1)
    return p.optimize_in_place(e)  # 两侧都已折好，折叠只在最深的节点先发生


def _parse_call_expr(p: Parser, callee, depth: int):
    if callee is None:
        return None
    e = A.CallExpr(callee.line)
    e.callee = callee
    # 外层已保证此处是 (
    if p.peek_token.type != TokenType.RParen:
        # expr ("," expr)*
        p.next_token()  # 到达第一个表达式
        e.args.append(p.parse_expr(A.Precedence.Lowest, depth + 1))
        while p.peek_token.type == TokenType.Comma:
            p.next_token()  # 到达 ","
            p.next_token()  # 到达下一个表达式
            e.args.append(p.parse_expr(A.Precedence.Lowest, depth + 1))
    if p.peek_token.type == TokenType.RParen:
        p.next_token()  # 跳过 )
    else:
        # 缺 ")" 时不推进，避免吞掉后面的 token
        p.error(p.peek_token.line, 'expected ")". ')
    return e


def _parse_at_expr(p: Parser, container, depth: int):
    if container is None:
        return None
    e = A.AtExpr(container.line)
    e.container = container
    if p.peek_token.type != TokenType.RBrack:
        # expr ("," expr)*
        p.next_token()  # 到达第一个表达式
        e.key_exprs.append(p.parse_expr(A.Precedence.Lowest, depth + 1))
        while p.peek_token.type == TokenType.Comma:
            p.next_token()  # 到达 ","
            p.next_token()  # 到达下一个表达式
            e.key_exprs.append(p.parse_expr(A.Precedence.Lowest, depth + 1))
    if p.peek_token.type == TokenType.RBrack:
        p.next_token()  # 跳过 ]
    else:
        # 缺 "]" 时不推进，避免吞掉后面的 token
        p.error(p.peek_token.line, 'expected "]". ')
    return e


# 表在模块加载后一次性填好（与 C++ 的 prefixParseFns / infixParseFns 逐项对应）
_PREFIX_FNS = {
    TokenType.Ident: _parse_ident_expr,
    TokenType.Null: _parse_null_expr,
    TokenType.False_: _parse_bool_expr,
    TokenType.True_: _parse_bool_expr,
    TokenType.Integer: _parse_int_expr,
    TokenType.Float: _parse_float_expr,
    TokenType.String: _parse_string_expr,
    TokenType.BinArr: _parse_binarr_expr,
    TokenType.Argc: _parse_argc_expr,
    TokenType.Sub: _parse_unary_op_expr,
    TokenType.Not: _parse_unary_op_expr,
    TokenType.LParen: _parse_paren_expr,
    TokenType.Custom: _parse_custom_opcode_expr,
    TokenType.Args: _parse_args_expr,
}

_INFIX_FNS = {t: _parse_binary_op_expr for t in (
    TokenType.Or, TokenType.And, TokenType.EQ, TokenType.NE,
    TokenType.LT, TokenType.LE, TokenType.GT, TokenType.GE,
    TokenType.Add, TokenType.Sub, TokenType.Mul, TokenType.Div,
    TokenType.IDiv, TokenType.Mod, TokenType.Pow,
)}
_INFIX_FNS[TokenType.LParen] = _parse_call_expr   # () 函数调用
_INFIX_FNS[TokenType.LBrack] = _parse_at_expr     # [] 取元素


#: 表达式/中缀分发表对外可见（与 nodejs 的 prefixFns / infixFns 同义）
PREFIX_FNS = _PREFIX_FNS
INFIX_FNS = _INFIX_FNS
