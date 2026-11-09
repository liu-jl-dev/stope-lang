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
from .expr_optim import NotConst, kind_of, truthy
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
    """名字作用域：标识符 → 变量总表中的索引。

    ``id_order``：名字 → 声明序号（``Compiler.decl_counter`` 的全局值，跨 scope 可比）。
    defer 的「冻结名字绑定」靠它判定：载荷解析到的本地名字若序号晚于 defer 语句处
    的基线，视为不可见——不被捕获，按隐式导出宿主变量处理（OQ-8）。隐式导出
    （从未声明的宿主变量）记 -1，豁免检查。

    ``defers``：defer 语句在本 scope 的登记（载荷节点、defer 行号、登记时的声明序号
    基线）。退出点（块尾 / break / continue / return）由 Compiler 逆序拼接 —— 运行时
    没有 defer 栈，顺序在编译期物化。

    ``is_defer_payload``：该 scope 是否为 defer 载荷的隐式作用域。break / continue /
    return 不得跨越它（break/continue 的目标循环在载荷外 → 报错；return 在载荷内
    一律报错）。
    """

    __slots__ = ("id_map", "id_order", "defers", "is_defer_payload")

    def __init__(self):
        super().__init__()
        self.type = "block"
        self.id_map: dict[str, int] = {}
        self.id_order: dict[str, int] = {}
        self.defers: list[tuple] = []  # (载荷节点, defer 行号, orderBaseline)
        self.is_defer_payload = False


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


def const_cond_truth(e):
    """OQ-2：条件是否为「解析期折叠后的字面量常量」；是则按语言真值表给出
    静态真值，否则返回 ``None``。truthy（expr_optim）是真值表的单一实现，
    这里只补常量判断。与 cpp/src/compiler.cpp 的 ``constCondTruth`` 一致。
    """
    if kind_of(e) == NotConst:
        return None
    return truthy(e)


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
        # 全局声明序号：declare_local / declare_exported（非隐式）时递增。
        # defer 的冻结名字绑定靠它判定「在 defer 之后才声明」。
        self.decl_counter = 0
        # defer 载荷编译期状态：当前生效的声明序号基线（-1 = 不在拼接中）与
        # 载荷编译期报错（duplicate export）的归责行号（defer 语句行）。
        self.defer_order_floor = -1
        self.defer_err_line = -1
        # 刚访问完的语句是否终止控制流（return / break / continue / 真死循环）。
        # 死代码消除：终止语句之后的语句不再发射，defer 也不再登记。
        self.stmt_terminates = False
        # 最内层 while 体里是否出现过本层 break（死循环判定用；按 while 保存/恢复）
        self.saw_break = False

    def reset(self, custom=None) -> None:
        """与 C++ 的 ``Compiler::Reset`` 一致：清错误、换自定义指令表。"""
        self.errors = []
        self.custom_opcodes = custom

    # ---------------- 对外接口 ----------------
    def compile(self, ast, out, pre_exports=()) -> Result:
        """编译 ``ast``，结果直接写进 ``out``。

        有错误时返回 ``Result.Error`` 并把 ``out`` 复原为空 —— 半成品 ``Program``
        跑不了，留着反而误导。

        ``pre_exports``：遍历 AST 之前先导出的标识符（宿主注入的全局）。每个名字按给定
        顺序占一个「永不回收」的槽位，所以源码里所有变量的编号整体后移；名字进了文件
        作用域，源码里再 ``export`` 同名、或顶层 ``let`` 同名，都会报 duplicate ——
        预导出的变量只能赋值。空名字与重名都是编译错误（行号记 0：这些名字不来自源码）。
        """
        self._reset_compile(out)
        self._export_pre_exports(pre_exports)
        self.visit(ast)
        # 顶层 defer：程序尾结算。程序以终止语句（return / 死循环等）结尾时
        # 这里不可达（return 出口已在 on_visit_return_stmt 结算过），再拼就是
        # Return 之后的死代码——跳过；自然结束（fall-through）才需要这份结算。
        if not self.stmt_terminates:
            self.splice_defers(self.file_scope())
        self.file_scope().defers.clear()
        if self.errors:
            self.prog.clear()
            return Result.Error
        out.variable_num = self.var_alloc.num()
        out.required_stack_size = self.stack_size_mgr.max_size
        return Result.Success

    def _export_pre_exports(self, names) -> None:
        """预导出：必须在 :meth:`_reset_compile` 之后调用（reset 会重建分配器、清空 exports）。

        走 ``new_unique_var``，并且先于源码里任何变量分配 —— 这一步定了整个程序的槽位编号。
        """
        fs = self.file_scope()
        for n in names:
            # 行号记 0：这些名字不来自源码，硬套 cur_line（此刻是 -1）只会误导
            if not n:
                self.error(0, "empty name in pre-exports. ")
                continue
            if n in fs.id_map:
                self.error(0, 'duplicate export of "%s". ' % n)
                continue
            self.declare_exported(n, self.var_alloc.new_unique_var(n))

    def _reset_compile(self, out) -> None:
        self.errors = []
        self.var_alloc = VariableAllocator()
        self.stack_size_mgr = StackSizeManager()
        self.scope_stack = []
        self.decl_counter = 0
        self.defer_order_floor = -1
        self.defer_err_line = -1
        self.stmt_terminates = False
        self.saw_break = False
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

    def find_ident_host(self, name: str):
        for s in reversed(self.scope_stack):
            if isinstance(s, BlockScope) and name in s.id_map:
                return s
        return None

    def find_ident_host_frozen(self, name: str, floor: int):
        """冻结名字绑定下的宿主查找（仅在拼接 defer 载荷时使用）。

        最内层载荷根（栈中最靠内的 ``is_defer_payload`` 块）以内是载荷自己的内部
        作用域，名字解析不过滤；它以外才应用「defer 语句处可见」的基线 —— 跳过
        声明序号 >= floor 的本地名（那些在 defer 之后才声明，对载荷不可见）。
        """
        payload_idx = -1
        for i in range(len(self.scope_stack) - 1, -1, -1):
            s = self.scope_stack[i]
            if isinstance(s, BlockScope) and s.is_defer_payload:
                payload_idx = i
                break
        for i in range(len(self.scope_stack) - 1, -1, -1):
            s = self.scope_stack[i]
            if not isinstance(s, BlockScope) or name not in s.id_map:
                continue
            if i < payload_idx:  # 登记 scope 一侧：跳过 defer 之后才声明的（遮蔽）
                order = s.id_order.get(name)
                # 基线 = 登记时的 declCounter（= 下一个待分配序号），所以
                # 「order >= 基线」⟺ 在 defer 之后声明。
                if order is not None and order >= 0 and order >= floor:
                    continue
            return s
        return None

    def resolve_at_splice(self, name: str):
        """拼接期间的名字解析（冻结绑定）。冻结查找命中 → 用冻结规则（名字→槽位
        按 defer 语句位置定）。未命中 → 不再查 now、不再报 declared after
        （OQ-8，2026-11-08 定夺：后文声明的本地名不被捕获，按隐式导出宿主变量
        处理，同未声明名字的路径）。FileScope 已有同名（后文顶层 let / export
        声明的文件级变量）时无法再建同名宿主变量，报重复——行号归 defer 语句
        （冲突在 defer 绑定符号时就已注定；若 defer 先于顶层声明结算，则由后文
        :meth:`declare_local` 报 duplicate declaration，两处报错互斥）。返回
        FileScope：编译已失败，避免连锁隐式导出。都空 → 返回 None，调用方走
        隐式导出路径（新建宿主变量）。与 cpp/src/compiler.cpp 的
        ``resolveAtSplice`` 一致。"""
        frozen = self.find_ident_host_frozen(name, self.defer_order_floor)
        if frozen is not None:
            return frozen
        fs = self.file_scope()
        if name in fs.id_map:
            self.error(self.defer_err_line, 'duplicate export of "%s". ' % name)
            return fs
        return None

    def splice_defers(self, bs: BlockScope) -> None:
        """退出点结算：逆序拼接 bs 登记的 defer 载荷（LIFO，后登记先执行）。

        ⚠ 不清空 ``bs.defers``：一个块可以有多个运行期出口（break / continue /
        return 各一处 + 块尾），每个出口都要拼一份自己的副本；只有块尾 / 程序尾
        的「最终结算」由调用方在拼接后清空。某个载荷编译出错即停（错误去重：
        载荷在每个退出点重编译，报一次就够）。
        """
        if not bs.defers or self.errors:
            return
        for k in range(len(bs.defers) - 1, -1, -1):
            if self.errors:
                return
            d = bs.defers[k]
            saved_floor = self.defer_order_floor
            saved_line = self.defer_err_line
            self.defer_order_floor = d[2]
            self.defer_err_line = d[1]
            # 载荷包一层隐式作用域并打标记：break/continue/return 的越界检查
            # 靠它识别「从收尾代码里跳回主流程」。
            ps = self.push_block_scope()
            ps.is_defer_payload = True
            self.visit(d[0])
            # 载荷 scope 自己的 defers（直接嵌套 defer defer X 落在这里）：
            # 触发点 = 载荷 scope 结束 = 同一退出点，就地拼接。
            self.splice_defers(ps)
            self.pop_scope()
            for idx in ps.id_map.values():
                self.var_alloc.free_var(idx)
            self.defer_order_floor = saved_floor
            self.defer_err_line = saved_line

    def file_scope(self) -> FileScope:
        return self.scope_stack[0]

    # ---------------- 语句 ----------------
    def on_visit_prog(self, p) -> None:
        """语句序列：终止语句（return / break / continue / 死循环）之后的语句
        在语言语义下执行不到——不再发射，也不登记它们的 defer（死代码消除）。
        序列的终止性 = 最后一条已发射语句。"""
        terminated = False
        for s in p.stmts:
            if terminated:
                break
            self.stmt_terminates = False  # 每条语句先清零；终止语句的 visitor 置 True
            self.visit(s)
            terminated = self.stmt_terminates
        self.stmt_terminates = terminated

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
            self.declare_local(bs, name, idx)
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
                self.declare_local(bs, nm, self.var_alloc.new_var())

    def on_visit_return_stmt(self, s) -> None:
        # defer 边界：return 的终点是整个程序，在载荷内必然越界，一律报错。
        for sc in self.scope_stack:
            if isinstance(sc, BlockScope) and sc.is_defer_payload:
                self.error(s.line, '"return" cannot be used in a defer statement. ')
                return
        # 顺序：先结算，再求返回值，最后 Return（结算 → PushValue → Return）。
        # 结算先于退出动作，与块退出一致——defer 可以影响返回值。
        for i in range(len(self.scope_stack) - 1, -1, -1):
            sc = self.scope_stack[i]
            if isinstance(sc, BlockScope):
                self.splice_defers(sc)
        for e in s.exprs:
            self.visit(e)
        self.emit_op(Opcode.Return)
        self.emit_index(len(s.exprs))
        self.prog.max_return_num = max(self.prog.max_return_num, len(s.exprs))
        self.stmt_terminates = True
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
        # 块尾结算：本 scope 的 defer 在这里执行（LIFO）。块体以终止语句结尾时
        # 这里不可达（return 出口已结算、break/continue 出口就地结算过）——
        # 跳过，避免拼出不可达的副本。
        if not self.stmt_terminates:
            self.splice_defers(bs)
        bs.defers.clear()  # 最终结算：途中出口（break/return）已各拼过副本
        self.pop_scope()
        for idx in bs.id_map.values():
            self.var_alloc.free_var(idx)  # 回收局部变量索引

    def on_visit_if_stmt(self, s) -> None:
        if s.cond is None:
            return
        # OQ-2（2026-11-09 落地）：字面量条件折叠。条件是常量字面量时按真值表
        # 静态判定——常量真只发该分支（零条件、零跳转指令），常量假整支消除
        # （体不访问，其中的 defer 不登记，与死代码消除一致）；链上遇到非常量
        # 条件才走普通发射路径，其后不再折（非常量打头时保守：嵌套折叠的收益
        # 不抵多路回填的复杂度）。常量真的分支体是链的最后一段发射——体走完
        # 就到链尾，不需要出口 GoTo。
        goto_end_indices = []
        pending_false = -1  # 上一个「条件为假」占位（-1 = 无）
        all_bodies_terminate = True
        any_body_emitted = False
        fallthrough_resolved = False  # 「一路为假」的落空路径被 else / 常量真接住
        chain_ended = False           # 常量真之后整条链不可达

        def visit_branch(prog) -> bool:
            self.visit_body_as_block(prog)
            t = self.stmt_terminates
            nonlocal all_bodies_terminate, any_body_emitted
            all_bodies_terminate = all_bodies_terminate and t
            any_body_emitted = True
            return t

        def close_pending_false() -> None:
            nonlocal pending_false
            if pending_false >= 0:
                self.patch_index(pending_false, self.code_size())
                pending_false = -1

        truth = const_cond_truth(s.cond)
        if truth is not None:
            if truth:  # 常量真：整条链只剩这一个分支体
                visit_branch(s.first_prog)
                fallthrough_resolved = True
                chain_ended = True
            # 常量假：跳过，看 elifs / else
        else:  # 非常量：普通发射
            self.visit(s.cond)
            self.emit_op(Opcode.If)
            self.stack_size_mgr.dec()
            pending_false = self.emit_placeholder()  # 条件为假时跳到这里
            if not visit_branch(s.first_prog):
                self.emit_op(Opcode.GoTo)
                goto_end_indices.append(self.emit_placeholder())
        for ei in s.elifs:
            if chain_ended or ei.cond is None:
                continue
            truth = const_cond_truth(ei.cond)
            if truth is not None:
                if truth:  # 常量真：之前的假路径在这里进体，链到此为止
                    close_pending_false()
                    visit_branch(ei.prog)
                    fallthrough_resolved = True
                    chain_ended = True  # 其后的 elif / else 不可达
                # 常量假：跳过该分支（pending_false 留给下一个真分支 / else 回填）
                continue
            close_pending_false()  # 假路径从上一个占位跳到本分支条件处
            self.visit(ei.cond)
            self.emit_op(Opcode.If)
            self.stack_size_mgr.dec()
            pending_false = self.emit_placeholder()
            if not visit_branch(ei.prog):
                self.emit_op(Opcode.GoTo)
                goto_end_indices.append(self.emit_placeholder())
        if not chain_ended and s.else_prog is not None:
            close_pending_false()
            visit_branch(s.else_prog)
            fallthrough_resolved = True
        if pending_false >= 0:  # 链以非常量条件结尾且无 else：假路径跳到链尾
            self.patch_index(pending_false, self.code_size())
        for pos in goto_end_indices:
            self.patch_index(pos, self.code_size())
        # if 语句的终止性：所有可达分支体终止，且「一路为假」的落空路径被
        # else / 常量真接住——否则那条路径直接落到 if 之后，不算终止。
        self.stmt_terminates = any_body_emitted and all_bodies_terminate and fallthrough_resolved

    def on_visit_while_stmt(self, s) -> None:
        # OQ-2：常量条件折叠——常量真折叠为无条件循环（其后语句按真死循环
        # 消除），常量假整环消除（体不访问，其中的 defer 不登记）。
        truth = const_cond_truth(s.cond)
        cond_const = truth is not None
        eliminate = cond_const and not truth

        ws = self.push_while_scope()
        ws.start_index = self.code_size()  # continue 回到这里
        case_goto_end_pos = -1
        if s.cond is not None and not cond_const:
            # 非常量条件才发射判断（while cond { } —— cond 可省）
            self.visit(s.cond)
            self.emit_op(Opcode.If)
            self.stack_size_mgr.dec()
            case_goto_end_pos = self.emit_placeholder()
        if eliminate:
            # 常量假：体永不执行，整环消除（break/continue 无可达）
            self.stmt_terminates = False
            self.pop_scope()
            return
        # saw_break 按 while 配对保存/恢复：嵌套循环里的 break 只算最内层的
        saved_saw_break = self.saw_break
        self.saw_break = False
        self.visit_body_as_block(s.prog)
        body_term = self.stmt_terminates
        body_saw_break = self.saw_break
        self.saw_break = saved_saw_break
        if not body_term:  # 体终止（return/break/continue 收尾）则回跳是死代码
            self.emit_op(Opcode.GoTo)
            self.emit_index(ws.start_index)
        for pos in ws.break_indices:
            self.patch_index(pos, self.code_size())
        # 条件可省。无条件时必须跳过回填，否则会把第 0 条指令改成跳转目标。
        if case_goto_end_pos >= 0:
            self.patch_index(case_goto_end_pos, self.code_size())
        # while 的终止性：无条件（含折叠为真的常量条件，OQ-2）且体不含本层
        # break 的真死循环才永不退出。
        self.stmt_terminates = (
            (s.cond is None or (cond_const and truth)) and not body_saw_break)
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
        # 找最内层 WhileScope。途中先撞到 defer 载荷边界 = 目标循环在载荷外：
        # 载荷在退出点才执行，break 从收尾代码里跳回主流程是灾难语义，禁。
        wi = -1
        for i in range(len(self.scope_stack) - 1, -1, -1):
            sc = self.scope_stack[i]
            if sc.type == "while":
                wi = i
                break
            if isinstance(sc, BlockScope) and sc.is_defer_payload:
                self.error(s.line, '"break" cannot cross a defer statement. ')
                return
        if wi < 0:
            self.error(s.line, 'cannot use "break" outside of a loop. ')
            return
        # 结算 break 越过的所有块：从最内层到循环体块（不含 WhileScope 本身、
        # 不含循环外的任何 scope）。运行时 break 直接跳循环尾，这些块的正常
        # 块尾拼接不会执行到，必须在跳转前就地结算。
        for i in range(len(self.scope_stack) - 1, wi, -1):
            if isinstance(self.scope_stack[i], BlockScope):
                self.splice_defers(self.scope_stack[i])
        self.emit_op(Opcode.GoTo)
        ws = self.scope_stack[wi]
        ws.break_indices.append(self.emit_placeholder())
        self.saw_break = True  # 告知最内层 while：本层有 break（死循环判定用）
        self.stmt_terminates = True

    def on_visit_continue_stmt(self, s) -> None:
        # 同 break：continue 也退出循环体块，体块的 defer 必须先结算。
        wi = -1
        for i in range(len(self.scope_stack) - 1, -1, -1):
            sc = self.scope_stack[i]
            if sc.type == "while":
                wi = i
                break
            if isinstance(sc, BlockScope) and sc.is_defer_payload:
                self.error(s.line, '"continue" cannot cross a defer statement. ')
                return
        if wi < 0:
            self.error(s.line, 'cannot use "continue" outside of a loop. ')
            return
        for i in range(len(self.scope_stack) - 1, wi, -1):
            if isinstance(self.scope_stack[i], BlockScope):
                self.splice_defers(self.scope_stack[i])
        self.emit_op(Opcode.GoTo)
        self.emit_index(self.scope_stack[wi].start_index)
        self.stmt_terminates = True

    def on_visit_defer_stmt(self, s) -> None:
        bs = self.top_block_scope()
        if bs is None:
            return  # 不可能：FileScope 常驻栈底
        # 纯编译期登记，defer 语句位置零指令。载荷在退出点才编译（每个退出点
        # 各编译一次——If/GoTo 操作数是绝对下标，编译一次再拷贝会破坏跳转目标）。
        bs.defers.append((s.stmt, s.line, self.decl_counter))

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
        的判据）。``PushValue`` / ``PushId`` 共用这一处查找；拼接 defer 载荷时
        走冻结名字绑定（:meth:`resolve_at_splice`）。
        """
        if self.defer_order_floor >= 0:
            host = self.resolve_at_splice(name)
        else:
            host = self.find_ident_host(name)
        if host is not None:
            return host.id_map[name]
        self.declare_exported(name, self.var_alloc.new_unique_var(name),
                              implicit_export=True)
        return self.file_scope().id_map[name]

    def declare_exported(self, name: str, idx: int, implicit_export: bool = False) -> None:
        """登记一个会进 ``Program.exports`` 的变量。索引来自 ``new_unique_var``（不回收）。

        隐式导出（从未声明的宿主变量）记序号 -1：豁免 defer 冻结绑定检查——它不是
        本地槽位，是宿主变量。
        """
        self.file_scope().id_map[name] = idx
        self.file_scope().id_order[name] = -1 if implicit_export else self._next_decl_order()
        self.prog.exports[name] = idx

    def declare_local(self, bs: BlockScope, name: str, idx: int) -> None:
        bs.id_map[name] = idx
        bs.id_order[name] = self._next_decl_order()

    def _next_decl_order(self) -> int:
        order = self.decl_counter
        self.decl_counter += 1
        return order

    def visit_body_as_block(self, p) -> None:
        """块 / if 分支 / 循环体在 AST 里都是裸 ``Prog``（没有 BlockStmt 包着），
        这里补一层 BlockScope，让内部 let 的变量在离开时被回收。"""
        bs = self.push_block_scope()
        self.visit(p)
        # 块尾结算（if 分支 / 循环体同普通块）。体以终止语句结尾时这里不可达，
        # 跳过——出口结算（return / break / continue）已就地拼过副本。
        if not self.stmt_terminates:
            self.splice_defers(bs)
        bs.defers.clear()  # 最终结算
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
