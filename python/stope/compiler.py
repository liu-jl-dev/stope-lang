"""编译器：把 AST 编译成 ``Program``（指令流 + 常量池 + 变量表）——
端口 ``cpp/src/compiler.cpp``（C++ 为权威实现）。

【指令流的形状】``Program.opcodes`` 是 int 列表，指令与操作数混在同一个序列里。
带操作数的指令：

* ``PushInt / PushFloat / PushString / PushBinArr / PushValue / PushId`` —— 常量池或变量表的索引
* ``Call / At`` —— 参数个数
* ``If / GoTo`` —— 跳转目标（**opcodes 下标**）
* ``Return`` —— 返回值个数
* 自定义指令 —— 变长参数时多一个参数个数

其余指令无操作数。

【PushValue 与 PushId 的分工】``PushId`` 压的是**槽位引用**（左值），只有两处产生：
「有赋值的 let」左侧、``Assign`` 左端是裸标识符时。其余读变量一律 ``PushValue``（压值）。
所以执行器**不需要**在运算指令里做解引用兜底 —— 那样只会掩盖编译器的产物错误。

【遍历骨架】继承 :class:`ast_visitor.ASTVisitor`（对齐 C++：ASTVisitor + visitMap），
语义动作全在 ``on_visit_xxx`` 里。基类的默认实现只是「按源码顺序递归子节点」，
这里凡是需要发指令的一律整段重写（不再下钻到 super），其余靠基类递归。
``cur_line`` 由基类的 ``visit()`` 维护，没有专属行号的错误就用它。
"""

import heapq

from .ast import NodeType
from .ast_visitor import ASTVisitor
from .common import Result
from .opcode import Opcode
from .token import TokenType

# ====================================================================
# 作用域


class Scope:
    """作用域的公共基类。``type`` 只是给调试看的标记。"""

    __slots__ = ("type",)

    def __init__(self):
        self.type = "scope"


class BlockScope(Scope):
    """名字作用域：标识符 → 变量总表中的索引。"""

    __slots__ = ("id_map",)

    def __init__(self):
        super().__init__()
        self.type = "block"
        self.id_map: dict[str, int] = {}


class FileScope(BlockScope):
    """文件作用域。``export`` 与「未声明就使用的标识符」都落到这里。"""

    __slots__ = ()

    def __init__(self):
        super().__init__()
        self.type = "file"


class WhileScope(Scope):
    """循环作用域：**不参与名字查找**（``find_ident_host`` 只认 BlockScope）。"""

    __slots__ = ("start_index", "break_indices")

    def __init__(self):
        super().__init__()
        self.type = "while"
        self.start_index = 0        # continue 跳回这里（循环开头）
        self.break_indices = []     # 待回填的 break 跳转目标（code 中的操作数位置）


class MinHeap:
    """最小堆：变量索引回收用，保证总是复用最小的空位。

    与 C++ 的 ``std::priority_queue`` 配 ``greater`` 一样，产出的槽位编号可预测、可比对。
    Python 的 ``heapq`` 就是最小堆，额外用一个 set 记成员（等价 C++ 的 ``has()`` 线性查）。
    """

    __slots__ = ("data", "_members")

    def __init__(self):
        self.data: list[int] = []
        self._members: set[int] = set()

    def is_empty(self) -> bool:
        return not self.data

    def push(self, v: int) -> None:
        heapq.heappush(self.data, v)
        self._members.add(v)

    def pop(self) -> int:
        v = heapq.heappop(self.data)
        self._members.discard(v)
        return v

    def has(self, v: int) -> bool:
        return v in self._members


class VariableAllocator:
    """变量分配器：所有变量统一编号；块结束时索引进入回收堆复用。

    ``new_unique_var`` **不参与回收** —— 它给 export 与「未声明就使用的标识符」用，
    变量名非空正是 ``Program.exports`` 的判据。
    """

    __slots__ = ("vars", "recycled")

    def __init__(self):
        self.vars: list[str] = []
        self.recycled = MinHeap()

    def num(self) -> int:
        return len(self.vars)

    def new_var(self, name: str = "") -> int:
        if not self.recycled.is_empty():
            idx = self.recycled.pop()
            self.vars[idx] = name
            return idx
        i = len(self.vars)
        self.vars.append(name)
        return i

    def new_unique_var(self, name: str) -> int:
        i = len(self.vars)
        self.vars.append(name)  # 不回收：导出变量必须一直占着一个位置
        return i

    def free_var(self, idx: int) -> None:
        if self.recycled.has(idx):
            return  # 同一索引不重复回收
        self.recycled.push(idx)


class StackSizeManager:
    """只记「相对变化」，最大值最后落到 ``Program.required_stack_size``。

    记账是**线性**的（按 emit 顺序走一遍），遇到分支就得手动「掰回去」—— 见
    :meth:`converge`。
    """

    __slots__ = ("size", "max_size")

    def __init__(self):
        self.size = 0
        self.max_size = 0

    def inc(self, n: int = 1) -> None:
        self.size += n
        if self.size > self.max_size:
            self.max_size = self.size

    def dec(self, n: int = 1) -> None:
        self.size -= n

    def converge(self, depth: int) -> None:
        """分支汇合。

        线性记账只能沿一条路径走，所以某条路径被 GoTo 送走以后，要把 size 扳回到
        「从别处跳到这里」时应有的深度，否则 if / 短路运算符会把容量算成各分支
        深度之和（实测 ``a or b;`` 会算成 3）。
        """
        self.size = depth


def same_const(a, b) -> bool:
    """常量池里「值相等」的判据。

    int / float / str 用 ``==``；``bytes`` 逐字节比（Python 的 ``bytes.__eq__`` 就是
    逐字节，所以这里统一 ``==`` 即可）。C++ 的 ``std::find`` 对 ``std::vector<char>``
    也是逐元素比较。
    """
    return type(a) is type(b) and a == b


class Compiler(ASTVisitor):
    """``Compiler(custom=None)`` → :meth:`compile` 把 AST 写进一个 ``Program``。"""

    def __init__(self, custom=None):
        super().__init__()
        self.prog = None              # 正在写入的 Program，不拥有
        self.custom_opcodes = custom  # 可空，只读（不拥有）
        self.errors: list[str] = []
        self.var_alloc = None
        self.stack_size_mgr = None
        self.scope_stack: list[Scope] = []

    def reset(self, custom=None) -> None:
        """与 C++ 的 ``Compiler::Reset`` 一致：清错误、换自定义指令表。"""
        self.errors = []
        self.custom_opcodes = custom

    # ---------------- 对外接口 ----------------
    def compile(self, ast, out) -> Result:
        """编译 ``ast``，结果直接写进 ``out``。

        有错误时返回 ``Result.Error`` 并把 ``out`` 复原为空 —— 半成品 ``Program``
        跑不了，留着反而误导。
        """
        self._reset_compile(out)
        self.visit(ast)
        if self.errors:
            self.prog.clear()
            return Result.Error
        out.variable_num = self.var_alloc.num()
        out.required_stack_size = self.stack_size_mgr.max_size
        return Result.Success

    def _reset_compile(self, out) -> None:
        self.errors = []
        self.var_alloc = VariableAllocator()
        self.stack_size_mgr = StackSizeManager()
        self.scope_stack = []
        self.cur_line = -1
        self.prog = out
        out.clear()
        self.scope_stack.append(FileScope())

    # ---------------- 指令输出 ----------------
    def code_size(self) -> int:
        return len(self.prog.opcodes)

    def emit_op(self, op) -> None:
        self.prog.opcodes.append(int(op))

    def emit_index(self, idx: int) -> None:
        """写一个操作数（索引 / 跳转目标）。超出 int16 要报错，否则回绕出来的跳转目标
        会把 VM 带飞。"""
        if idx < -32768 or idx > 32767:
            self.error(self.cur_line, "compile output too large: index exceeds int16. ")
            idx = 0
        self.prog.opcodes.append(idx)

    def emit_placeholder(self) -> int:
        """占位：先写 -1，回填时才知道目标。"""
        self.prog.opcodes.append(-1)
        return self.code_size() - 1

    def patch_index(self, pos: int, target: int) -> None:
        if target < -32768 or target > 32767:
            self.error(self.cur_line, "compile output too large: jump target exceeds int16. ")
            target = 0
        self.prog.opcodes[pos] = target

    def const_index(self, pool: list, v) -> int:
        """常量入池：相同的值只存一份，返回索引。"""
        for i, cur in enumerate(pool):
            if same_const(cur, v):
                return i
        pool.append(v)
        return len(pool) - 1

    def error(self, line: int, msg: str) -> None:
        self.errors.append("line %d: %s" % (line, msg))

    # ---------------- 作用域 ----------------
    def push_block_scope(self) -> BlockScope:
        s = BlockScope()
        self.scope_stack.append(s)
        return s

    def push_while_scope(self) -> WhileScope:
        s = WhileScope()
        self.scope_stack.append(s)
        return s

    def pop_scope(self) -> None:
        self.scope_stack.pop()

    def top_block_scope(self):
        """由内向外找最近的名字作用域（FileScope 也算，它继承 BlockScope）。"""
        for s in reversed(self.scope_stack):
            if isinstance(s, BlockScope):
                return s
        return None

    def top_while_scope(self):
        for s in reversed(self.scope_stack):
            if isinstance(s, WhileScope):
                return s
        return None

    def find_ident_host(self, name: str):
        for s in reversed(self.scope_stack):
            if isinstance(s, BlockScope) and name in s.id_map:
                return s
        return None

    def file_scope(self) -> FileScope:
        return self.scope_stack[0]

    # ---------------- 语句 ----------------
    def on_visit_prog(self, p) -> None:
        for s in p.stmts:
            self.visit(s)

    def on_visit_expr_stmt(self, s) -> None:
        self.visit(s.expr)
        self.emit_op(Opcode.Pop)
        self.stack_size_mgr.dec()

    def on_visit_let_stmt(self, s) -> None:
        bs = self.top_block_scope()
        if bs is None:
            return
        if s.has_assign:
            # let a = expr; —— 只有一个标识符
            if not s.idents:
                return
            name = s.idents[0]
            if name in bs.id_map:
                self.error(s.line, "duplicate declaration of '%s'. " % name)
                return
            # 不要 visit 标识符本身（那会生成 PushValue 取值），这里是要绑定到新变量
            idx = self.var_alloc.new_var()
            bs.id_map[name] = idx
            self.emit_op(Opcode.PushId)
            self.emit_index(idx)
            self.stack_size_mgr.inc()
            self.visit(s.expr)
            self.emit_op(Opcode.Assign)
            self.stack_size_mgr.dec(2)
        else:
            for nm in s.idents:
                if nm in bs.id_map:
                    self.error(s.line, "duplicate declaration of '%s'. " % nm)
                    continue
                bs.id_map[nm] = self.var_alloc.new_var()

    def on_visit_return_stmt(self, s) -> None:
        for e in s.exprs:
            self.visit(e)
        self.emit_op(Opcode.Return)
        self.emit_index(len(s.exprs))
        self.prog.max_return_num = max(self.prog.max_return_num, len(s.exprs))
        # Return 会让 VM 直接跳到 code 末尾，栈上的返回值不回收

    def on_visit_export_stmt(self, s) -> None:
        if len(self.scope_stack) > 1:
            self.error(s.line, '"export" can only be used at top scope. ')
        fs = self.file_scope()
        for name in s.idents:
            if name in fs.id_map:
                self.error(s.line, 'duplicate export of "%s". ' % name)
                continue
            self.declare_exported(name, self.var_alloc.new_unique_var(name))

    def on_visit_block_stmt(self, s) -> None:
        bs = self.push_block_scope()
        self.visit(s.prog)
        self.pop_scope()
        for idx in bs.id_map.values():
            self.var_alloc.free_var(idx)  # 回收局部变量索引

    def on_visit_if_stmt(self, s) -> None:
        if s.cond is None:
            return
        goto_end_indices = []
        self.visit(s.cond)
        self.emit_op(Opcode.If)
        self.stack_size_mgr.dec()
        last_if_pos = self.emit_placeholder()  # 条件为假时跳到这里
        self.visit_body_as_block(s.first_prog)
        self.emit_op(Opcode.GoTo)  # 分支走完，跳出整个 if
        goto_end_indices.append(self.emit_placeholder())
        self.patch_index(last_if_pos, self.code_size())
        for ei in s.elifs:
            if ei.cond is None:
                continue
            self.visit(ei.cond)
            self.emit_op(Opcode.If)
            self.stack_size_mgr.dec()
            last_if_pos = self.emit_placeholder()
            self.visit_body_as_block(ei.prog)
            self.emit_op(Opcode.GoTo)
            goto_end_indices.append(self.emit_placeholder())
            self.patch_index(last_if_pos, self.code_size())
        if s.else_prog is not None:
            self.visit_body_as_block(s.else_prog)
        for pos in goto_end_indices:
            self.patch_index(pos, self.code_size())

    def on_visit_while_stmt(self, s) -> None:
        ws = self.push_while_scope()
        ws.start_index = self.code_size()  # continue 回到这里
        case_goto_end_pos = -1
        if s.cond is not None:
            # while cond { } —— cond 可省
            self.visit(s.cond)
            self.emit_op(Opcode.If)
            self.stack_size_mgr.dec()
            case_goto_end_pos = self.emit_placeholder()
        self.visit_body_as_block(s.prog)
        self.emit_op(Opcode.GoTo)
        self.emit_index(ws.start_index)
        for pos in ws.break_indices:
            self.patch_index(pos, self.code_size())
        # 条件可省。无条件时必须跳过回填，否则会把第 0 条指令改成跳转目标。
        if case_goto_end_pos >= 0:
            self.patch_index(case_goto_end_pos, self.code_size())
        self.pop_scope()

    def on_visit_assign_stmt(self, s) -> None:
        if s.left_expr.node_type == NodeType.IdentExpr:
            # 赋值左端的裸标识符要压【槽位】而不是值，否则 Assign 无处可存。
            # 这条与 on_visit_ident_expr 的 PushValue 是一对：只有这里和
            # 「有赋值的 let」会产生 PushId。
            idx = self.ident_slot(s.left_expr.ident)
            self.emit_op(Opcode.PushId)
            self.emit_index(idx)
            self.stack_size_mgr.inc()
        else:
            # 可能是使用者设计的数组元素引用、对象成员引用等。压入值。
            self.visit(s.left_expr)
        self.visit(s.right_expr)
        self.emit_op(Opcode.Assign)
        self.stack_size_mgr.dec(2)

    def on_visit_break_stmt(self, s) -> None:
        ws = self.top_while_scope()
        if ws is None:
            self.error(s.line, 'cannot use "break" outside of a loop. ')
            return
        self.emit_op(Opcode.GoTo)
        ws.break_indices.append(self.emit_placeholder())

    def on_visit_continue_stmt(self, s) -> None:
        ws = self.top_while_scope()
        if ws is None:
            self.error(s.line, 'cannot use "continue" outside of a loop. ')
            return
        self.emit_op(Opcode.GoTo)
        self.emit_index(ws.start_index)

    # ---------------- 表达式 ----------------
    def on_visit_null_expr(self, _n=None) -> None:
        self.emit_op(Opcode.PushNull)
        self.stack_size_mgr.inc()

    def on_visit_bool_expr(self, e) -> None:
        self.emit_op(Opcode.PushTrue if e.value else Opcode.PushFalse)
        self.stack_size_mgr.inc()

    def on_visit_int_expr(self, e) -> None:
        self.emit_op(Opcode.PushInt)
        self.emit_index(self.const_index(self.prog.int_consts, e.value))
        self.stack_size_mgr.inc()

    def on_visit_float_expr(self, e) -> None:
        self.emit_op(Opcode.PushFloat)
        self.emit_index(self.const_index(self.prog.float_consts, e.value))
        self.stack_size_mgr.inc()

    def on_visit_string_expr(self, e) -> None:
        self.emit_op(Opcode.PushString)
        self.emit_index(self.const_index(self.prog.string_consts, e.value))
        self.stack_size_mgr.inc()

    def on_visit_binarr_expr(self, e) -> None:
        self.emit_op(Opcode.PushBinArr)
        self.emit_index(self.const_index(self.prog.binarr_consts, e.value))
        self.stack_size_mgr.inc()

    def on_visit_ident_expr(self, e) -> None:
        idx = self.ident_slot(e.ident)
        self.emit_op(Opcode.PushValue)  # 压的是变量的【值】；要槽位请用 PushId
        self.emit_index(idx)
        self.stack_size_mgr.inc()

    def on_visit_argc_expr(self, _n=None) -> None:
        self.emit_op(Opcode.ArgNum)
        self.stack_size_mgr.inc()

    def on_visit_args_expr(self, e) -> None:
        self.visit(e.key_expr)
        self.emit_op(Opcode.GetArg)  # 弹下标、压结果，栈大小不变

    def on_visit_unary_op_expr(self, e) -> None:
        self.visit(e.expr)
        if e.op == TokenType.Not:
            self.emit_op(Opcode.Not)
        elif e.op == TokenType.Sub:
            self.emit_op(Opcode.Minus)
        # 一元指令：弹 1 压 1，栈大小不变

    def on_visit_binary_op_expr(self, e) -> None:
        if e.op == TokenType.Or:
            self.on_visit_or_expr(e)
            return
        if e.op == TokenType.And:
            self.on_visit_and_expr(e)
            return
        self.visit(e.left_expr)
        self.visit(e.right_expr)
        self.emit_op(binary_opcode(e.op))
        self.stack_size_mgr.dec()  # 弹 2 压 1

    def on_visit_or_expr(self, e) -> None:
        """短路或：任一侧为真就 PushTrue，两条路径都在栈上留下恰好 1 个结果。"""
        self.visit(e.left_expr)
        self.emit_op(Opcode.If)
        self.stack_size_mgr.dec()
        first_if_pos = self.emit_placeholder()
        depth_at_if_target = self.stack_size_mgr.size  # If 已弹掉条件 = 汇合点深度
        self.emit_op(Opcode.PushTrue)
        self.stack_size_mgr.inc()
        self.emit_op(Opcode.GoTo)
        goto_end1 = self.emit_placeholder()
        self.patch_index(first_if_pos, self.code_size())
        self.stack_size_mgr.converge(depth_at_if_target)  # 后面接的是「左侧为假」这条路径

        self.visit(e.right_expr)
        self.emit_op(Opcode.If)
        self.stack_size_mgr.dec()
        second_if_pos = self.emit_placeholder()
        depth_at_if_target = self.stack_size_mgr.size
        self.emit_op(Opcode.PushTrue)
        self.stack_size_mgr.inc()
        self.emit_op(Opcode.GoTo)
        goto_end2 = self.emit_placeholder()
        self.patch_index(second_if_pos, self.code_size())
        self.stack_size_mgr.converge(depth_at_if_target)

        self.emit_op(Opcode.PushFalse)  # 两侧都不成立
        self.stack_size_mgr.inc()
        self.patch_index(goto_end1, self.code_size())
        self.patch_index(goto_end2, self.code_size())

    def on_visit_and_expr(self, e) -> None:
        self.visit(e.left_expr)
        self.emit_op(Opcode.If)
        self.stack_size_mgr.dec()
        first_if_pos = self.emit_placeholder()
        self.visit(e.right_expr)
        self.emit_op(Opcode.If)
        self.stack_size_mgr.dec()
        second_if_pos = self.emit_placeholder()
        depth_at_if_target = self.stack_size_mgr.size  # 两侧都为真才落到这里
        self.emit_op(Opcode.PushTrue)
        self.stack_size_mgr.inc()
        self.emit_op(Opcode.GoTo)
        goto_end = self.emit_placeholder()
        self.patch_index(first_if_pos, self.code_size())
        self.patch_index(second_if_pos, self.code_size())
        self.stack_size_mgr.converge(depth_at_if_target)
        self.emit_op(Opcode.PushFalse)
        self.stack_size_mgr.inc()
        self.patch_index(goto_end, self.code_size())

    def on_visit_call_expr(self, e) -> None:
        self.visit(e.callee)
        for a in e.args:
            self.visit(a)
        self.emit_op(Opcode.Call)
        self.emit_index(len(e.args))
        self.stack_size_mgr.dec(len(e.args))  # callee + args 换成 1 个返回值

    def on_visit_at_expr(self, e) -> None:
        self.visit(e.container)
        for k in e.key_exprs:
            self.visit(k)
        self.emit_op(Opcode.At)
        self.emit_index(len(e.key_exprs))
        self.stack_size_mgr.dec(len(e.key_exprs))

    def on_visit_custom_opcode_expr(self, e) -> None:
        if self.custom_opcodes is None or e.opcode_name not in self.custom_opcodes.opcodes:
            self.error(e.line, 'undefined custom opcode "%s". ' % e.opcode_name)
            return
        info = self.custom_opcodes.opcodes[e.opcode_name]
        is_var_arg = info.arg_num < 0  # 与 C++ 的 isVarArg 同一判据
        if not is_var_arg and info.arg_num != len(e.args):
            self.error(e.line,
                       'custom opcode "%s" expected %d args, but got %d. '
                       % (e.opcode_name, info.arg_num, len(e.args)))
        for a in e.args:
            self.visit(a)
        self.emit_op(info.opcode)
        if is_var_arg:
            self.emit_index(len(e.args))
        # 自定义指令没有 callee 入栈，结果仍占 1 格 => dec(参数个数 - 1)
        self.stack_size_mgr.dec(len(e.args) - 1)

    # ---------------- 小工具 ----------------
    def ident_slot(self, name: str) -> int:
        """标识符 → 变量槽位索引。

        没声明过就当作外部变量，登记到文件作用域（名字非空正是 ``Program.exports``
        的判据）。``PushValue`` / ``PushId`` 共用这一处查找。
        """
        host = self.find_ident_host(name)
        if host is not None:
            return host.id_map[name]
        self.declare_exported(name, self.var_alloc.new_unique_var(name))
        return self.file_scope().id_map[name]

    def declare_exported(self, name: str, idx: int) -> None:
        """登记一个会进 ``Program.exports`` 的变量。索引来自 ``new_unique_var``（不回收）。"""
        self.file_scope().id_map[name] = idx
        self.prog.exports[name] = idx

    def visit_body_as_block(self, p) -> None:
        """块 / if 分支 / 循环体在 AST 里都是裸 ``Prog``（没有 BlockStmt 包着），
        这里补一层 BlockScope，让内部 let 的变量在离开时被回收。"""
        bs = self.push_block_scope()
        self.visit(p)
        self.pop_scope()
        for idx in bs.id_map.values():
            self.var_alloc.free_var(idx)


def binary_opcode(op: TokenType) -> Opcode:
    """二元运算符 → 指令。注意二元 ``-`` 是 ``Sub`` 而不是 ``Minus``。"""
    T = TokenType
    if op == T.EQ:
        return Opcode.EQ
    if op == T.NE:
        return Opcode.NE
    if op == T.LT:
        return Opcode.LT
    if op == T.LE:
        return Opcode.LE
    if op == T.GT:
        return Opcode.GT
    if op == T.GE:
        return Opcode.GE
    if op == T.Add:
        return Opcode.Add
    if op == T.Sub:
        return Opcode.Sub
    if op == T.Mul:
        return Opcode.Mul
    if op == T.Div:
        return Opcode.Div
    if op == T.IDiv:
        return Opcode.IDiv
    if op == T.Mod:
        return Opcode.Mod
    if op == T.Pow:
        return Opcode.Pow
    return Opcode.Pop  # 到不了：parser 只会用上面这些 op 构造 BinaryOpExpr
