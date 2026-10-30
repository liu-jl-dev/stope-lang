"""常量折叠 —— 端口 ``cpp/src/expr_optim.cpp``（C++ 为权威实现）。

契约：

* 只做「**单节点**」变换，不递归。挂在 parser 构造 ``UnaryOpExpr`` / ``BinaryOpExpr``
  的末尾，子节点返回时就已折好，整棵树自底向上折叠完毕；
* :func:`optimize` 成功折叠时返回**新**节点（原节点不再使用），未折叠时返回入参本身；
* 拿不准就一律不折叠：除零、含浮点的 ``idiv``、跨类型 ``==``、``null`` 参与比较、
  ``Bool`` 参与比较 —— 全部保留原节点。折叠后的节点沿用运算符节点的 ``line``。

本项目自定的三条算术规则（详见 ``cpp/docs/expr-optim.md`` §4.9）：

1. ``BinArr + BinArr`` == 字节连接；
2. ``String / BinArr * 非负整数`` == 串重复（整数 ``*`` 串同理）；
3. ``+ - * / idiv % ^`` 里 ``Bool`` 视作 0 / 1，但 ``< <= > >=`` 与 ``== !=`` 仍按类型区分。

判断顺序与 C++ 一一对应（层号同 expr-optim.md §4.2 / §4.7）：
L0 两侧必须都是字面量常量 -> L1 and/or -> L2 任一侧 null -> L3 比较 -> L4 算术。
刻意**不**拆成 foldXxx 分派函数，保持「一个格子 = 一个分支」，方便与 C++ 对照。

⚠ 整数**溢出不检查、按 64 位补码回绕**（与 C++ 走 unsigned 的 intAdd/intMul 等价）：
统一走 :func:`wrap64`，不要改成抛错。⚠ Python 的 ``//`` 与 ``%`` 是**向下取整**，
C++ 是**向零取整** —— 必须走 :func:`int_div` / :func:`int_mod`，直接用运算符会错在负数上。
"""

from . import ast as A
from .common import is_special, fmod, fpow, int_div, int_mod, int_pow, wrap64
from .token import TokenType

_NT = A.NodeType

_INT64_MAX = 2 ** 63 - 1
MAX_REPEAT_ELEM = 1 << 20  # 串重复的元素数上限：1 M

# 常量分类
NotConst = 0
Null = 1
Bool = 2
Int = 3
Float = 4
String = 5
BinArr = 6


# ==================== 入口 ====================


def optimize(e):
    """返回一个（可能是新的）节点：成功折叠时是新常量节点，否则是入参本身。"""
    if e is None:
        return None
    if e.node_type == _NT.UnaryOpExpr:
        return fold_unary(e)
    if e.node_type == _NT.BinaryOpExpr:
        return fold_binary(e)
    return e


# ==================== 常量分类与取值 ====================
# 只有 6 种字面量是「常量」。Ident / Call / At / Args / Argc / Custom 都不是
# （值要运行期才知道，且 Call / Custom 可能有副作用）。
def kind_of(e) -> int:
    if e is None:
        return NotConst
    t = e.node_type
    if t == _NT.NullExpr:
        return Null
    if t == _NT.BoolExpr:
        return Bool
    if t == _NT.IntExpr:
        return Int
    if t == _NT.FloatExpr:
        return Float
    if t == _NT.StringExpr:
        return String
    if t == _NT.BinArrExpr:
        return BinArr
    return NotConst


def _is_const(k: int) -> bool:
    return k != NotConst


def _is_numeric(k: int) -> bool:
    """真正的 Int / Float（不含 Bool）。"""
    return k == Int or k == Float


def _both_int(lk: int, rk: int) -> bool:
    return lk == Int and rk == Int


def _is_seq(k: int) -> bool:
    """String / BinArr 统称「序列」：连接、重复、相等的规则一致。"""
    return k == String or k == BinArr


def _is_num_like(k: int) -> bool:
    """「算术上下文」里的 Bool：视作 0 / 1 的整数（只对 ``+ - * / idiv % ^`` 生效）。"""
    return k == Bool or _is_numeric(k)


def _both_num_int(lk: int, rk: int) -> bool:
    """两侧都参与整数运算（Bool 算整数），只有出现 Float 才走浮点分支。"""
    return _is_num_like(lk) and _is_num_like(rk) and lk != Float and rk != Float


def _as_int(e) -> int:
    return e.value


def _num_as_int(e) -> int:
    """取值：``Bool`` 折算成 0 / 1。"""
    if e.node_type == _NT.BoolExpr:
        return 1 if e.value else 0
    return e.value


def _as_double(e) -> float:
    if e.node_type == _NT.BoolExpr:
        return 1.0 if e.value else 0.0
    if e.node_type == _NT.IntExpr:
        return float(e.value)
    return e.value


# ==================== 序列（String / BinArr）的载荷读写 ====================
def _seq_size(e) -> int:
    return len(e.value)


def _seq_equal(a, b) -> bool:
    if a.node_type == _NT.StringExpr:
        return a.value == b.value
    return bytes(a.value) == bytes(b.value)


def _make_seq(line: int, k: int):
    return A.StringExpr(line) if k == String else A.BinArrExpr(line)


def _seq_append(dst, src) -> None:
    # str + str / bytes + bytes，两种载荷都走 `+`
    dst.value = dst.value + src.value


def _truthy(e) -> bool:
    """真值规则：null 假；bool 自身；int/float 非零；序列非空。"""
    t = e.node_type
    if t == _NT.NullExpr:
        return False
    if t == _NT.BoolExpr:
        return e.value
    if t == _NT.IntExpr:
        return e.value != 0
    if t == _NT.FloatExpr:
        return e.value != 0.0
    if _is_seq(kind_of(e)):
        return _seq_size(e) != 0
    return False


# 别名：与 nodejs / C# 的命名对齐（对外也导出）
truthy = _truthy


# ==================== 有符号整数运算（64 位回绕） ====================
def _int_add(a: int, b: int) -> int:
    return wrap64(a + b)


def _int_sub(a: int, b: int) -> int:
    return wrap64(a - b)


def _int_mul(a: int, b: int) -> int:
    return wrap64(a * b)


def _int_neg(a: int) -> int:
    return wrap64(-a)


# ==================== 造节点 / 拷贝常量 / 取负 / 串重复 ====================
def _make_bool(line: int, v: bool):
    return A.BoolExpr(line, v)


def _make_int(line: int, v: int):
    return A.IntExpr(line, v)


def _make_float(line: int, v: float):
    return A.FloatExpr(line, v)


def _clone_const(line: int, e):
    """拷贝一个字面量常量节点（用于 ``null + X -> X`` 这类规则），非常量返回 None。"""
    t = e.node_type
    if t == _NT.NullExpr:
        return A.NullExpr()
    if t == _NT.BoolExpr:
        return _make_bool(line, e.value)
    if t == _NT.IntExpr:
        return _make_int(line, _as_int(e))
    if t == _NT.FloatExpr:
        return _make_float(line, e.value)
    k = kind_of(e)
    if not _is_seq(k):
        return None
    r = _make_seq(line, k)
    _seq_append(r, e)
    return r


def _negate_const(line: int, e):
    """取负：Int/Float 同类型取负；Bool 转成 Int 取负；null / 序列不可取负。"""
    t = e.node_type
    if t == _NT.BoolExpr:
        return _make_int(line, -1 if e.value else 0)
    if t == _NT.IntExpr:
        return _make_int(line, _int_neg(_as_int(e)))
    if t == _NT.FloatExpr:
        return _make_float(line, -e.value)
    return None


def _repeat_seq(line: int, base, times: int):
    """串重复：``"ab" * 3`` / ``'x 41' * 3``；负次或结果过大 -> None（不折叠）。"""
    if times < 0:
        return None
    unit = _seq_size(base)
    if unit == 0:
        return _make_seq(line, kind_of(base))  # 空串/空数组的任意次重复仍是空
    if times > MAX_REPEAT_ELEM // unit:
        return None
    r = _make_seq(line, kind_of(base))
    for _ in range(times):
        _seq_append(r, base)
    return r


def _cmp_of(op: TokenType, a, b) -> bool:
    if op == TokenType.LT:
        return a < b
    if op == TokenType.LE:
        return a <= b
    if op == TokenType.GT:
        return a > b
    return a >= b


# ==================== 一元 ====================
def fold_unary(e):
    if e is None or e.expr is None:
        return e
    line = e.line
    inn = e.expr
    ck = kind_of(inn)
    if not _is_const(ck):
        return e  # 非常量 -> 不折叠
    ret = None
    if e.op == TokenType.Not:
        # `!` 走 truthy；序列与 Bool 之外的非常量已在上面挡掉
        if ck == Null or _is_num_like(ck):
            ret = _make_bool(line, not _truthy(inn))
    elif e.op == TokenType.Sub:
        ret = _negate_const(line, inn)
    return e if ret is None else ret


# ==================== 二元 ====================
def fold_binary(e):
    if e is None or e.left_expr is None or e.right_expr is None:
        return e
    ret = _try_fold_binary(e)
    return e if ret is None else ret


def _try_fold_binary(e):
    line = e.line
    op = e.op
    L = e.left_expr
    R = e.right_expr
    lk = kind_of(L)
    rk = kind_of(R)
    # L0 两侧必须都是字面量常量：否则既算不出值，也可能吞掉 Call/Custom 的副作用
    if not _is_const(lk) or not _is_const(rk):
        return None

    # ---------- L1 and / or：结果与类型无关，恒返回 Bool ----------
    if op == TokenType.And:
        return _make_bool(line, _truthy(L) and _truthy(R))
    if op == TokenType.Or:
        return _make_bool(line, _truthy(L) or _truthy(R))

    # ---------- L2 null 参与 ----------
    # null 不是数字，也不参与算术：`+ - * / idiv % ^` 一律不折叠，交给后端报错。
    # 只有 `==` `!=` 有确定结论：null 只与 null 相等。`< <= > >=` 本该是类型错误 -> 不折叠。
    if lk == Null or rk == Null:
        both_null = lk == Null and rk == Null
        if op == TokenType.EQ:
            return _make_bool(line, both_null)
        if op == TokenType.NE:
            return _make_bool(line, not both_null)
        return None

    # ---------- L3 相等与大小比较 ----------
    # 到这里两侧都非 null；跨类型一律不折叠（强制转换规则未定，见 expr-optim.md §4.5）
    if op == TokenType.EQ or op == TokenType.NE:
        decided = False
        eq = False
        if lk == Bool and rk == Bool:
            decided = True
            eq = L.value == R.value
        elif _is_numeric(lk) and _is_numeric(rk):
            # Bool ⊕ 数字 -> 不折
            decided = True
            eq = (_as_int(L) == _as_int(R) if _both_int(lk, rk)
                  else _as_double(L) == _as_double(R))
        elif _is_seq(lk) and lk == rk:
            decided = True
            eq = _seq_equal(L, R)
        if decided:
            return _make_bool(line, eq if op == TokenType.EQ else not eq)
        return None
    if op in (TokenType.LT, TokenType.LE, TokenType.GT, TokenType.GE):
        # Bool 与序列不参与数值比较 -> 两侧都必须是 Int / Float
        if _is_numeric(lk) and _is_numeric(rk):
            return _make_bool(
                line,
                (_cmp_of(op, _as_int(L), _as_int(R)) if _both_int(lk, rk)
                 else _cmp_of(op, _as_double(L), _as_double(R))),
            )
        return None

    # ---------- L4 算术 + - * / idiv % ^ ----------
    # 到这里两侧都非 null，左值只剩两类：数值（Bool 折算成 0/1）与序列
    if _is_num_like(lk):
        # ===== L4a 左值是 Bool / Int / Float =====
        if op in (TokenType.Add, TokenType.Sub, TokenType.Mul):
            if _is_num_like(rk):
                if _both_num_int(lk, rk):
                    # 两侧都没有 Float -> 整数路径，溢出不检查、按 64 位回绕
                    a = _num_as_int(L)
                    b = _num_as_int(R)
                    if op == TokenType.Add:
                        return _make_int(line, _int_add(a, b))
                    if op == TokenType.Sub:
                        return _make_int(line, _int_sub(a, b))
                    return _make_int(line, _int_mul(a, b))
                # 任一侧是 Float -> 浮点路径
                x = _as_double(L)
                y = _as_double(R)
                if op == TokenType.Add:
                    return _make_float(line, x + y)
                if op == TokenType.Sub:
                    return _make_float(line, x - y)
                return _make_float(line, x * y)
            elif op == TokenType.Mul and _is_seq(rk) and lk != Float:
                return _repeat_seq(line, R, _num_as_int(L))  # 数字 * 串 == 串重复
        elif op == TokenType.Div:
            if _is_num_like(rk):
                if _both_num_int(lk, rk):
                    a = _num_as_int(L)
                    b = _num_as_int(R)
                    # 除零 -> 不折叠；除不尽 -> 浮点数
                    if b != 0:
                        return (_make_int(line, int_div(a, b))
                                if int_mod(a, b) == 0
                                else _make_float(line, float(a) / float(b)))
                else:
                    bb = _as_double(R)
                    if bb != 0.0:
                        return _make_float(line, _as_double(L) / bb)
        elif op == TokenType.IDiv:
            if _both_num_int(lk, rk):
                # 含浮点 -> 收窄成整数，不折叠
                a = _num_as_int(L)
                b = _num_as_int(R)
                if b != 0:
                    return _make_int(line, int_div(a, b))  # 向零取整
        elif op == TokenType.Mod:
            if _is_num_like(rk):
                if _both_num_int(lk, rk):
                    a = _num_as_int(L)
                    b = _num_as_int(R)
                    if b != 0:
                        return _make_int(line, int_mod(a, b))
                else:
                    bb = _as_double(R)
                    if bb != 0.0:
                        # ⚠ 必须 fmod：Python 的 `%` 余数符号跟除数，与 C++/JS/C# 相反
                        return _make_float(line, fmod(_as_double(L), bb))
        elif op == TokenType.Pow:
            if _is_num_like(rk):
                if _both_num_int(lk, rk):
                    b = _num_as_int(R)
                    # 非负整数指数走快速幂（溢出回绕）；负指数落到浮点分支
                    if b >= 0:
                        return _make_int(line, int_pow(_num_as_int(L), b))
                # 负指数 / 含浮点：必须 fpow（`**` 对负底数 + 分数指数会返回复数）
                rr = fpow(_as_double(L), _as_double(R))
                if not is_special(rr):
                    return _make_float(line, rr)  # NaN / Inf -> 不折叠
    elif _is_seq(lk):
        # ===== L4b 左值是序列（String / BinArr）=====
        if op == TokenType.Add:
            if rk == lk:
                # 同类才连接：字符串拼接 / 字节连接（跨类型不折）
                ret = _make_seq(line, lk)
                _seq_append(ret, L)
                _seq_append(ret, R)
                return ret
        elif op == TokenType.Mul:
            if rk == Int or rk == Bool:
                return _repeat_seq(line, L, _num_as_int(R))  # 串 * 整数 == 串重复
        # 其余运算符（Sub 等）对序列无定义 -> 不折叠
    return None
