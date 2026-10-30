"""参考执行器 —— 端口 ``cpp/include/stope/basic_vm.hpp``。

**这不是标准。** Stope 只规定语言、STML 与编译器的产物 ``Program``（见仓库根 README），
执行器的接口、值的表示、栈布局、宿主函数约定全属实现自由。这个模块只用来证明
``Program`` 确实能跑；自己写执行器请看 ``docs/zh-cn/vm-guide.md``。

值的 Python 表示（对应 C++ 的 ``Value::Type``）：

===============  ===========================================================
Null             ``None``
Integer          ``int``（语义是 int64：溢出不检查、经 :func:`wrap64` 回绕）
Float            ``float``
String           ``str``
BinArr           ``bytes``
HostFunction     可调用对象 ``fn(argv: list) -> 值``
Identifier       :class:`Identifier` 实例（``PushId`` 压的槽位引用，只有 ``Assign`` 认它）
===============  ===========================================================

⚠ C++ 里**没有 Bool 值类型**：``PushTrue`` / ``PushFalse`` 压的是 Integer 1 / 0，
所以 ``true == 1`` 在运行期为真。宿主函数返回 ``True`` / ``False`` 时由
:func:`op_call` 归一成整数 —— 不然算术会拿到一个「既不是整数也不是浮点」的值。

⚠ Python 有三处与 C++ / JS 语义**天然不同**，一律走 ``common`` 的 :func:`fdiv` /
:func:`fmod` / :func:`trunc` / :func:`fpow` 兜住（否则会抛异常打断执行）：

* ``1.0 / 0`` —— C++ 是 ``inf``，Python 抛 ``ZeroDivisionError``；
* ``math.fmod(x, 0)`` —— C++ 是 ``nan``，Python 抛 ``ValueError``；
* ``math.pow(-8, 0.5)`` —— C++ 是 ``nan``、``math.pow(1e308, 2)`` C++ 是 ``inf``，
  Python 分别抛 ``ValueError`` / ``OverflowError``。

常量折叠用的是同一组函数 —— 折叠与执行器对同一个表达式必须给出同一个答案。
"""

from .common import (Result, fdiv, fmod, fpow, int_div, int_mod, int_pow, trunc,
                     wrap64)
from .opcode import Opcode


class Identifier:
    """槽位引用。``PushId`` 压它（左值），``Assign`` 靠它取槽位；其余指令当普通值。"""

    __slots__ = ("index",)

    def __init__(self, index: int):
        self.index = index

    def __repr__(self) -> str:
        return f"Identifier({self.index})"


class Arguments:
    """宿主的实参表。取不到就**自己报错**：``state.error(...)`` 之后返回 ``None`` ——
    与 C++ 的 ``At(State&, const Value&, Value&) -> Result`` 等价（错误进同一个
    ``errors``，执行器立刻停）。"""

    __slots__ = ()

    def at(self, state: "State", index_or_key):
        raise NotImplementedError("Arguments.at() 必须由宿主实现（C++ 里是纯虚函数）")

    def num(self) -> int:
        raise NotImplementedError("Arguments.num() 必须由宿主实现（C++ 里是纯虚函数）")


# ============================== 类型判定 ==============================
# ⚠ bool 是 int 的子类，必须先排掉：宿主函数返回 True 时不能当成整数 1 参与判断，
# 而是走 op_call 的归一（见 Runtime.Normalize）。

def is_int(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def is_float(v) -> bool:
    return isinstance(v, float)


def is_number(v) -> bool:
    return is_int(v) or is_float(v)


def is_string(v) -> bool:
    return isinstance(v, str)


def is_binarr(v) -> bool:
    return isinstance(v, (bytes, bytearray))


def is_func(v) -> bool:
    return callable(v)


def is_sequence(v) -> bool:
    return is_string(v) or is_binarr(v)


def is_null(v) -> bool:
    return v is None


def as_double(v) -> float:
    return float(v) if is_int(v) else v


def normalize(v):
    """宿主可能返回 ``bool``（宿主语言里有这个类型，Stope 没有）：折成整数 1 / 0。"""
    if isinstance(v, bool):
        return 1 if v else 0
    return v


# ============================== 真值 / 相等 ==============================

def truely(val) -> bool:
    """null→假；整数/宿主函数→非零；浮点→非 0；序列→非空；其余→真。"""
    if val is None:
        return False
    if is_int(val):
        return val != 0
    if is_func(val):
        return True
    if is_float(val):
        return val != 0.0
    if is_sequence(val):
        return len(val) != 0
    return True


def equals(left, right) -> bool:
    """类型不同一律不等（Python 里 ``"1" == 1`` 恰好也是 False，但 GDScript 会抛引擎
    错误 —— 五份实现统一在这里自己判，不借宿主的 ``==``）。"""
    if left is None or right is None:
        return left is None and right is None
    if is_int(left) and is_int(right):
        return left == right
    if is_int(left) and is_float(right):
        return float(left) == right
    if is_float(left) and is_int(right):
        return left == float(right)
    if is_float(left) and is_float(right):
        return left == right
    if is_string(left) and is_string(right):
        return left == right
    if is_binarr(left) and is_binarr(right):
        return bytes(left) == bytes(right)
    if is_func(left) and is_func(right):
        return left is right
    return False


def _less_than(s: "State", left, right) -> bool:
    if is_number(left) and is_number(right):
        return as_double(left) < as_double(right)
    s.error("only on integer or float can be compared. ")
    return False


def _greater_than(s: "State", left, right) -> bool:
    return _less_than(s, right, left)


def _check_arith(s: "State", op: str, left, right) -> bool:
    if left is None or right is None:
        s.error(f'"{op}" cannot operate on null. ')
        return False
    if not is_number(left) or not is_number(right):
        s.error(f'"{op}" can only operate on integer or float. ')
        return False
    return True


def _check_int_zero(s: "State", op: str, left, right) -> bool:
    """整数除以 0 → 报错（不做除法）。判定看**运算走哪条路径**：只有两侧都是整数才是
    整数除法；任一侧是 Float 就走 IEEE，不拦（``1.0 / 0`` 与 ``1 / 0.0`` 都得 inf）。"""
    if is_int(left) and is_int(right) and right == 0:
        s.error(f'"{op}" division by zero. ')
        return False
    return True


# ============================== State ==============================

class State:
    """指令指针 + 变量槽 + 求值栈 + 错误列表。"""

    __slots__ = ("api", "program", "args", "returns", "i", "variables", "stack", "errors")

    def __init__(self):
        self.api = None
        self.program = None
        self.args = None
        self.returns: list = []
        self.i = 0
        self.variables: list = []
        self.stack: list = []
        self.errors: list[str] = []

    def reset(self, api: "Api", program, args=None) -> None:
        """三样都要给；同时清 ``returns`` / ``stack`` / ``errors``，并按 ``variable_num``
        开好槽位（C++ 要宿主自己 ``resize``，这里替你做掉，免得漏一步就是空槽位）。"""
        self.api = api
        self.program = program
        self.args = args
        self.returns = []
        self.i = 0
        self.variables = [None] * program.variable_num
        self.stack = []
        self.errors = []

    def set_arguments(self, args) -> None:
        self.args = args

    def error(self, msg: str) -> None:
        """宿主的报错入口：``"<指令下标>: msg"``。"""
        self.errors.append(f"{self.i}: {msg}")

    def has_error(self) -> bool:
        return len(self.errors) > 0

    def step(self) -> Result:
        """执行**一条**指令。``Result.Success`` = 这条跑完了且没出错，可以接着 step。

        返回 ``Error`` 有两种情况，靠 ``errors`` 区分：

        * ``errors`` 非空 —— 出错了，``i`` 停在出错的那条指令上；
        * ``errors`` 为空 —— 指令流已经走完（``i`` 越过末尾）。

        所以 ``while s.i < len(...) and s.step() == Result.Success: ...`` 与 :meth:`run`
        等价，连走的条数都一样。
        """
        if self.errors:
            return Result.Error
        if self.i >= len(self.program.opcodes):
            return Result.Success
        self.api.op_map[self.program.opcodes[self.i]](self)
        if self.errors:
            return Result.Error
        self.i += 1
        return Result.Success

    def run(self) -> Result:
        """一直执行到指令流结束；出错立即停。与 :meth:`step` 是**两份独立实现**（热循环里
        不套一层函数调用），代价是改步进规则要同时改两处 —— 由 ``test_vm.py`` 的
        ``V-21`` 锁着。"""
        ops = self.program.opcodes  # 执行中不会变长（Return 只是把 i 拨到末尾）
        n = len(ops)
        op_map = self.api.op_map
        while self.i < n:
            op_map[ops[self.i]](self)
            if self.errors:
                return Result.Error
            self.i += 1
        return Result.Success

    # 栈顶下标一律「从栈顶数、1 起算」：at_top(1) 就是 stack[-1]
    def at_top(self, k: int):
        return self.stack[len(self.stack) - k]

    def pop(self) -> None:
        self.stack.pop()

    def pop_n(self, num: int) -> None:
        for _ in range(num):
            self.stack.pop()

    def push_int(self, v: int) -> None:
        self.stack.append(wrap64(int(v)))

    def store_binary(self, result) -> None:
        """二元算术统一的收尾：弹出右操作数，结果写回左操作数的位置。"""
        self.stack.pop()
        self.stack[-1] = result

    # ⚠ 这里**没有**「解引用」helper：编译器保证 PushId 只出现在赋值左端（「有赋值的
    # let」与「Assign 左端是裸标识符」），其余读变量一律 PushValue。所以栈上除了 Assign
    # 的左值之外**一定是值**；收到 Identifier 就是产物错了，该让它当场暴露，而不是悄悄
    # 换成变量内容（C++ / GD / JS / C# 都没有这层兜底）。


# ============================== 指令 ==============================

def _op_assign(s: State) -> None:
    if len(s.stack) < 2:
        s.error("stack underflow. ")
        return
    target = s.at_top(2)
    if not isinstance(target, Identifier):
        s.error("no implement for value type. ")
        return
    s.variables[target.index] = s.stack[-1]
    s.pop_n(2)


def _op_push_null(s: State) -> None:
    s.stack.append(None)


def _op_push_false(s: State) -> None:
    s.stack.append(0)


def _op_push_true(s: State) -> None:
    s.stack.append(1)


def _op_push_int(s: State) -> None:
    s.i += 1
    s.stack.append(s.program.int_consts[s.program.opcodes[s.i]])


def _op_push_float(s: State) -> None:
    s.i += 1
    s.stack.append(s.program.float_consts[s.program.opcodes[s.i]])


def _op_push_string(s: State) -> None:
    s.i += 1
    s.stack.append(s.program.string_consts[s.program.opcodes[s.i]])


def _op_push_binarr(s: State) -> None:
    s.i += 1
    s.stack.append(s.program.binarr_consts[s.program.opcodes[s.i]])


def _op_push_value(s: State) -> None:
    s.i += 1
    s.stack.append(s.variables[s.program.opcodes[s.i]])  # 压【值】；要槽位引用请用 PushId


def _op_push_id(s: State) -> None:
    s.i += 1
    s.stack.append(Identifier(s.program.opcodes[s.i]))  # 不能是值，否则无法 Assign


def _op_call(s: State) -> None:
    # 不检查栈下溢：参数个数在编译期就定了
    s.i += 1
    arg_num = s.program.opcodes[s.i]
    callee = s.at_top(arg_num + 1)
    if not is_func(callee):
        s.error('"Call" can only call a function. ')
        return
    argv = [s.at_top(k) for k in range(arg_num, 0, -1)]
    out = normalize(callee(argv))  # 参数整包进来，由宿主自己拆（对齐 C++ 的 args span）
    s.pop_n(arg_num)
    s.stack[-1] = out


def _str_units(text: str) -> bytes:
    """按 UTF-16 码元取字节（C++ 是 ``u16string``、C# 是 UTF-16 ``char``，五份一致）。"""
    return text.encode("utf-16-le", "surrogatepass")


def _op_at(s: State) -> None:
    # 不检查栈下溢：key 个数在编译期就定了
    s.i += 1
    key_num = s.program.opcodes[s.i]
    if key_num != 1:
        s.error("no implement for key num != 1. ")
        return
    container = s.at_top(2)
    key = s.at_top(1)
    if not is_int(key):
        s.error("index must be integer. ")
        return
    index = key
    if is_binarr(container):
        if index < 0 or index >= len(container):
            s.error("index out of range. ")
            return
        result = container[index]
    elif is_string(container):
        units = _str_units(container)
        if index < 0 or index * 2 + 2 > len(units):
            s.error("index out of range. ")
            return
        # 取的是**码元**（UTF-16），不是单字符子串 —— 与 C++ / C# 一致。
        # ⚠ Python 的 ``str`` 下标是码点，非 BMP 字符（如 emoji）会给出不同的结果。
        result = int.from_bytes(units[index * 2:index * 2 + 2], "little")
    else:
        s.error("no implement for container type. ")
        return
    s.pop_n(key_num + 1)
    s.stack.append(result)


def _op_pop(s: State) -> None:
    s.pop()


def _op_minus(s: State) -> None:
    val = s.stack[-1]
    if is_int(val):
        s.stack[-1] = wrap64(-val)  # 回绕，不检查溢出
    elif is_float(val):
        s.stack[-1] = -val
    else:
        s.error('"Minus" can only operate on integer or float. ')


def _op_not(s: State) -> None:
    val = s.stack[-1]
    if val is None:
        s.stack[-1] = 1
    elif is_int(val):
        s.stack[-1] = 1 if val == 0 else 0
    elif is_float(val):
        s.stack[-1] = 1 if val == 0.0 else 0
    else:
        s.error('"Not" can only operate on integer or float. ')


def _op_pow(s: State) -> None:
    left = s.at_top(2)
    right = s.at_top(1)
    if not _check_arith(s, "Pow", left, right):
        return
    # 两个整数且指数 >= 0 → 整数结果；负指数（`2 ^ -1`）→ Float(0.5)。
    # 与常量折叠的 Pow 分支一致。
    if is_int(left) and is_int(right) and right >= 0:
        s.store_binary(int_pow(left, right))
    else:
        s.store_binary(fpow(as_double(left), as_double(right)))


def _op_mul(s: State) -> None:
    left = s.at_top(2)
    right = s.at_top(1)
    if left is None or right is None:
        s.error('"Mul" cannot operate on null. ')
        return
    if is_number(left) and is_number(right):
        if is_int(left) and is_int(right):
            s.store_binary(wrap64(left * right))  # 回绕
        else:
            s.store_binary(as_double(left) * as_double(right))
        return
    if (is_sequence(left) and is_int(right)) or (is_int(left) and is_sequence(right)):
        # 序列重复：`2 * "ab"` 与 `"ab" * 2` 都要成立 —— 取序列那一侧
        seq = left if is_sequence(left) else right
        times = right if is_sequence(left) else left
        if times < 0:
            # ⚠ Python 里 `b"ab" * -1` 会静默得到 `b""`，不判就是错的
            s.error('"Mul" cannot repeat a sequence by a negative number. ')
            return
        s.store_binary(seq * times)
        return
    s.error('"Mul" can only operate on numbers, or repeat a string / bin array by an integer. ')


def _op_div(s: State) -> None:
    left = s.at_top(2)
    right = s.at_top(1)
    if not _check_arith(s, "Div", left, right) or not _check_int_zero(s, "Div", left, right):
        return
    if is_int(left) and is_int(right):
        # 除不尽 → 浮点数（`7 / 2` 是 Float(3.5)）；整除要用 idiv。
        # 与常量折叠的规则一致。
        if int_mod(left, right) == 0:
            s.store_binary(int_div(left, right))
        else:
            s.store_binary(fdiv(float(left), float(right)))
    else:
        s.store_binary(fdiv(as_double(left), as_double(right)))


def _op_idiv(s: State) -> None:
    left = s.at_top(2)
    right = s.at_top(1)
    if not _check_arith(s, "IDiv", left, right) or not _check_int_zero(s, "IDiv", left, right):
        return
    if is_int(left) and is_int(right):
        s.store_binary(int_div(left, right))  # 向零取整
    else:
        # 含浮点：仍按数值整除（向零取整），结果保持浮点，不做 float→int 收窄
        s.store_binary(trunc(fdiv(as_double(left), as_double(right))))


def _op_mod(s: State) -> None:
    left = s.at_top(2)
    right = s.at_top(1)
    if not _check_arith(s, "Mod", left, right) or not _check_int_zero(s, "Mod", left, right):
        return
    if is_int(left) and is_int(right):
        s.store_binary(int_mod(left, right))  # 余数符号跟被除数
    else:
        # ⚠ 用 fmod 而不是 Python 的 `%`：后者的符号跟除数，与 C++/JS/C# 相反
        s.store_binary(fmod(as_double(left), as_double(right)))


def _op_add(s: State) -> None:
    left = s.at_top(2)
    right = s.at_top(1)
    # null 不是「加法单位元」，也不与任何值做算术 —— 一律报错
    if left is None or right is None:
        s.error('"Add" cannot operate on null. ')
        return
    if is_int(left):
        if is_int(right):
            s.store_binary(wrap64(left + right))  # 回绕，不检查溢出
        elif is_float(right):
            s.store_binary(float(left) + right)
        else:
            s.error("integer can only add integer or float. ")
    elif is_float(left):
        if is_number(right):
            s.store_binary(left + as_double(right))
        else:
            s.error("float can only add integer or float. ")
    elif is_string(left) and is_string(right):
        s.store_binary(left + right)
    elif is_binarr(left) and is_binarr(right):
        s.store_binary(bytes(left) + bytes(right))
    else:
        s.error('"Add" can only operate on numbers, strings or bin arrays. ')


def _op_sub(s: State) -> None:
    left = s.at_top(2)
    right = s.at_top(1)
    if not _check_arith(s, "Sub", left, right):
        return
    if is_int(left):
        if is_int(right):
            s.store_binary(wrap64(left - right))  # 回绕，不检查溢出
        elif is_float(right):
            s.store_binary(float(left) - right)
        else:
            s.error("integer can only subtract integer or float. ")
    elif is_float(left):
        if is_number(right):
            s.store_binary(left - as_double(right))
        else:
            s.error("float can only subtract integer or float. ")
    else:
        s.error('"Sub" can only operate on integer or float. ')


def _op_eq(s: State) -> None:
    s.store_binary(1 if equals(s.at_top(2), s.at_top(1)) else 0)


def _op_ne(s: State) -> None:
    s.store_binary(0 if equals(s.at_top(2), s.at_top(1)) else 1)


def _op_lt(s: State) -> None:
    s.store_binary(1 if _less_than(s, s.at_top(2), s.at_top(1)) else 0)


def _op_le(s: State) -> None:
    s.store_binary(0 if _greater_than(s, s.at_top(2), s.at_top(1)) else 1)


def _op_gt(s: State) -> None:
    s.store_binary(1 if _greater_than(s, s.at_top(2), s.at_top(1)) else 0)


def _op_ge(s: State) -> None:
    s.store_binary(0 if _less_than(s, s.at_top(2), s.at_top(1)) else 1)


def _op_if(s: State) -> None:
    yes = truely(s.stack[-1])
    s.pop()  # 条件用完即弹，不再留在栈上
    s.i += 1  # 跳过操作数；条件成立时 step/run 的 +1 正好落到下一句
    target = s.program.opcodes[s.i]
    if not yes:
        s.i = target - 1


def _op_goto(s: State) -> None:
    s.i = s.program.opcodes[s.i + 1] - 1  # 操作数在 i+1


def _op_get_arg(s: State) -> None:
    if s.args is None:
        s.error("no args. ")
        return
    # 先弹 key 再取参：实参表可能拿 key 做准备
    key = s.stack.pop()  # 栈上一定是值：读变量走 PushValue
    s.stack.append(normalize(s.args.at(s, key)))


def _op_arg_num(s: State) -> None:
    if s.args is None:
        s.error("no args. ")
        return
    s.stack.append(s.args.num())


def _op_return(s: State) -> None:
    s.i += 1
    num = s.program.opcodes[s.i]
    s.returns = [s.at_top(k) for k in range(num, 0, -1)]
    s.i = len(s.program.opcodes)


def _op_unimplemented(s: State) -> None:
    """占位处理函数：指令表被 ``set_opcode`` 撑出来但那一格没注册。"""
    s.error(f"no implement for opcode {s.program.opcodes[s.i]}. ")


class Api:
    """指令分派表。

    ``op_map`` 的下标就是指令编号，稠密（与 C++ 的 ``std::array<OpFunc, kOpCount>``
    同形）。要跑自定义指令必须自己扩表 —— 用 :meth:`set_opcode`，它会先把中间补齐，
    否则中间的空格会在 Run 时静默走到占位函数上。
    """

    __slots__ = ("op_map",)

    def __init__(self):
        self.op_map = [
            _op_assign, _op_push_null, _op_push_false, _op_push_true, _op_push_int,
            _op_push_float, _op_push_string, _op_push_binarr, _op_push_value, _op_push_id,
            _op_call, _op_at, _op_pop, _op_minus, _op_not,
            _op_pow, _op_mul, _op_div, _op_idiv, _op_mod,
            _op_add, _op_sub, _op_eq, _op_ne, _op_lt,
            _op_le, _op_gt, _op_ge, _op_if, _op_goto,
            _op_get_arg, _op_arg_num, _op_return,
        ]

    def set_opcode(self, opcode: int, fn) -> None:
        """装一条自定义指令的处理函数：``fn(state) -> None``。"""
        while len(self.op_map) <= opcode:
            self.op_map.append(_op_unimplemented)
        self.op_map[opcode] = fn


__all__ = [
    "Api",
    "Arguments",
    "Identifier",
    "Opcode",
    "State",
    "equals",
    "is_binarr",
    "is_float",
    "is_func",
    "is_int",
    "is_null",
    "is_number",
    "is_sequence",
    "is_string",
    "truely",
]
