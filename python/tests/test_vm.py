"""参考执行器：值语义 + 两条驱动路径。**没有 golden 数据**。

执行器不属标准范围（见仓库根 README「标准范围」），C++ 侧也没有可 dump 的期望值。
所以这一组锁两件事：

1. **run 与 step 一致** —— 两条独立实现（热循环不套函数调用），连走的条数都一样；
2. **与另外四份实现同一种答案** —— 算术 / 序列 / 真值 / 除零 / 回绕 / 相等这些「顺手用
   宿主原生运算符就会错」的地方，结果必须与 C++ 逐条相同。

⚠ Python 在这一层要额外兜两类**宿主语言陷阱**，都是别处看不到的：

* ``1.0 / 0`` 抛 ZeroDivisionError（C++ 得 inf）、``math.fmod(x, 0)`` 抛 ValueError
  （C++ 得 nan）、``math.pow(-8, 0.5)`` 抛 ValueError 而 ``(-8.0) ** 0.5`` 返回**复数**；
* ``b"ab" * -1`` 静默得 ``b""``（C++ 报错），``-9223372036854775808 // -1`` 不抛错但要
  按 64 位回绕。

这些都由 ``common`` 的 fdiv / fmod / trunc / fpow 与 int_div / int_mod 兜住，本文件
用 ``V-07c`` / ``V-10e`` / ``V-10f`` / ``V-10g`` / ``V-13c`` 把它们钉住。
"""

import math

from stope.ast import Prog
from stope.basic_vm import Api, Arguments, State
from stope.common import Result
from stope.compiler import Compiler
from stope.debug import opcode_has_arg
from stope.format import fmt_g
from stope.lexer import Lexer
from stope.opcode import CustomOpcodeConfig, Opcode, kFirstCustomOpcode
from stope.parser import Parser
from stope.program import Program


# ============================== 夹具 ==============================

class _NoArgs(Arguments):
    """这组用例都不用 args / argc；真被取到就报错，立刻暴露「用例写错了」。"""

    __slots__ = ()

    def at(self, state, index_or_key):
        state.error("args not provided in this test. ")
        return None

    def num(self) -> int:
        return 0


class _ArrayArgs(Arguments):
    __slots__ = ("_data",)

    def __init__(self, data):
        self._data = list(data)

    def at(self, state, index_or_key):
        if not isinstance(index_or_key, int) or isinstance(index_or_key, bool) \
                or index_or_key < 0 or index_or_key >= len(self._data):
            state.error("argument out of range. ")
            return None
        return self._data[index_or_key]

    def num(self) -> int:
        return len(self._data)


def _compile(src: str, custom=None):
    """编译；成功返回 ``(Program, [])``，失败返回 ``(None, 错误列表)``。"""
    ps = Parser(Lexer(src), custom)
    tree = Prog()
    ps.parse_program(tree)
    out = Program()
    c = Compiler(custom)
    c.compile(tree, out)
    errs = list(ps.errors) + list(c.errors)
    return (None, errs) if errs else (out, [])


def _state(prog, args=None) -> State:
    """装配 State 但**不执行** —— 宿主函数要先往 ``variables`` 里塞值。"""
    s = State()
    s.reset(Api(), prog, args)
    return s


def _build(src: str, args=None, custom=None):
    """编译并执行；失败返回 ``(None, 错误列表)``。"""
    prog, errs = _compile(src, custom)
    if prog is None:
        return None, errs
    s = _state(prog, args)
    s.run()
    return s, []


def _fmt(v) -> str:
    """紧凑写法：null / 整数 / 浮点（无小数点时补 ``.0``）/ 字符串原样 / 字节数组 ``[1,2]``。"""
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "1" if v else "0"  # 值层面不该出现 bool，出现就是没归一
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if v != v:
            return "nan"
        if v == math.inf:
            return "inf"
        if v == -math.inf:
            return "-inf"
        t = fmt_g(v)
        if "." not in t and "e" not in t:
            t += ".0"
        return t
    if isinstance(v, str):
        return v
    if isinstance(v, (bytes, bytearray)):
        return "[" + ",".join(str(x) for x in v) + "]"
    return "<other>"


def _fmt_returns(s: State) -> str:
    return "[" + ",".join(_fmt(v) for v in s.returns) + "]"


def _msg_only(e: str) -> str:
    """``"3 Div: msg"`` → ``msg``：前缀（下标 + 指令名）由实现决定，跨实现只比消息。"""
    i = e.find(": ")
    return e if i < 0 else e[i + 2:]


def _inst_count(p) -> int:
    """产物里有几条指令（跳过操作数格）—— 与「走了几步」对照用。"""
    n = 0
    i = 0
    ops = p.opcodes
    while i < len(ops):
        n += 1
        i += 2 if opcode_has_arg(ops[i]) else 1
    return n


def _returns(rep, cid: str, src: str, want: str) -> None:
    s, errs = _build(src)
    if s is None:
        rep.add_fail(cid, "编译失败：" + src + " | " + "".join(errs))
        return
    rep.check(cid, "returns", want, _fmt_returns(s))
    rep.check(cid, "errors", "", "|".join(s.errors))


def _errs(rep, cid: str, src: str, want_msg: str) -> None:
    """断言**报错**：只比 ``: `` 之后的正文（前缀由实现自定）。"""
    s, errs = _build(src)
    if s is None:
        rep.add_fail(cid, "编译失败：" + src + " | " + "".join(errs))
        return
    rep.check_int(cid, "错误条数", 1, len(s.errors))
    rep.check(cid, "错误消息", want_msg, _msg_only(s.errors[0]) if s.errors else "<无错误>")


# ============================== 用例 ==============================

def run(rep) -> None:
    # ==================== 布尔就是整数 1 / 0 ====================
    _returns(rep, "V-06", "return true;", "[1]")
    _returns(rep, "V-06b", "return false;", "[0]")
    _returns(rep, "V-06c", "let t = true; let f = false; return t + f + (1 == 1);", "[2]")
    _returns(rep, "V-06d", "let a = 1; let b = 2; return a < b;", "[1]")

    # ==================== 整数幂：回绕 / 负指数转浮点 ====================
    _returns(rep, "V-07", "let a = 2; let b = 64; return a ^ b;", "[0]")
    _returns(rep, "V-07b", "let a = 2; return a ^ -1;", "[0.5]")
    # ⚠ 负底数 + 分数指数：C++ 是 nan，Python 的 `**` 返回复数 ⇒ 必须 fpow
    _returns(rep, "V-07c", "let a = -8.0; let b = 0.5; return a ^ b;", "[nan]")

    # ==================== 序列重复与拼接 ====================
    _returns(rep, "V-08", 'let s = "ab"; return s * 2;', "[abab]")
    _returns(rep, "V-08b", 'let s = "ab"; return 2 * s;', "[abab]")
    _returns(rep, "V-08c", "let b = 'd 1 2'; return b * 2;", "[[1,2,1,2]]")
    _errs(rep, "V-08d", 'let s = "ab"; let n = -1; return s * n;',
          '"Mul" cannot repeat a sequence by a negative number. ')
    _returns(rep, "V-08e", 'let a = "x"; let b = "y"; return a + b;', "[xy]")
    _returns(rep, "V-08f", "let a = 'd 1'; let b = 'd 2'; return a + b;", "[[1,2]]")
    # ⚠ b"ab" * -1 在 Python 里静默得 b""（C++ 报错）—— 上面 V-08d 已用字符串锁住，
    # 这条补字节数组那一侧
    _errs(rep, "V-08g", "let b = 'd 1'; let n = -2; return b * n;",
          '"Mul" cannot repeat a sequence by a negative number. ')

    # ==================== 真值 ====================
    _returns(rep, "V-09", 'let s = ""; if s { return 1; } return 2;', "[2]")
    _returns(rep, "V-09b", 'let s = "x"; if s { return 1; } return 2;', "[1]")
    _returns(rep, "V-09c", "let b = 'd'; if b { return 1; } return 2;", "[2]")

    # ==================== 除零 ====================
    _errs(rep, "V-10", "let a = 1; let b = 0; return a / b;", '"Div" division by zero. ')
    _errs(rep, "V-10b", "let a = 1; let b = 0; return a idiv b;", '"IDiv" division by zero. ')
    _errs(rep, "V-10c", "let a = 1; let b = 0; return a % b;", '"Mod" division by zero. ')
    # 浮点除零走 IEEE，不报错（`1.0 / 0` 得 inf）—— ⚠ Python 这里会抛 ZeroDivisionError
    _returns(rep, "V-10d", "let a = 1.0; let b = 0; return a / b;", "[inf]")
    _returns(rep, "V-10e", "let a = 0.0; let b = 0; return a / b;", "[nan]")
    # 浮点取模同理：`%` 在 Python 抛 ZeroDivisionError、符号还跟除数
    _returns(rep, "V-10f", "let a = 1.5; let b = 0; return a % b;", "[nan]")
    _returns(rep, "V-10g", "let a = -7.0; let b = 2.0; return a % b;", "[-1.0]")

    # ==================== `!` 只接受 null / 整数 / 浮点 ====================
    _errs(rep, "V-11", 'let s = "abc"; return !s;',
          '"Not" can only operate on integer or float. ')

    # ==================== INT64_MIN 的三个角落 ====================
    _returns(rep, "V-12", "let m = 0 - 9223372036854775807 - 1; return -m;",
             "[-9223372036854775808]")
    _returns(rep, "V-12b", "let m = 0 - 9223372036854775807 - 1; return m idiv -1;",
             "[-9223372036854775808]")
    _returns(rep, "V-12c", "let m = 0 - 9223372036854775807 - 1; return m % -1;", "[0]")

    # ==================== idiv：含浮点仍向零取整，但保持浮点 ====================
    _returns(rep, "V-13", "let a = 7; let b = 2; return a idiv b;", "[3]")
    _returns(rep, "V-13b", "let a = 7.5; let b = 2; return a idiv b;", "[3.0]")
    # ⚠ trunc(inf)：C++ 是 inf，Python 的 math.trunc(inf) 抛 OverflowError
    _returns(rep, "V-13c", "let a = 1.0; let b = 0; return a idiv b;", "[inf]")

    # ==================== 相等：类型不同一律不等 ====================
    _returns(rep, "V-15", 'let a = "1"; let b = 1; return a == b;', "[0]")
    _returns(rep, "V-15b", "let a = null; let b = 0; return a == b;", "[0]")
    _returns(rep, "V-15c", "let a = 'd 1 2'; let b = 'd 1 2'; return a == b;", "[1]")
    _returns(rep, "V-15d", "let a = 'd 1'; let b = 'd 2'; return a == b;", "[0]")
    _returns(rep, "V-15e", 'let a = "ab"; let n = 0; return a * n;', "[]")

    # ==================== 下标取码元 ====================
    _returns(rep, "V-15f", "let b = 'd 1 2'; return b[1];", "[2]")
    # ⚠ 取的是 UTF-16 码元：非 BMP 字符（U+1F600）在 Python 里是**一个**码点，
    # 直接下标会得到 128512，而 C++ / C# 给出高位代理 55357
    _returns(rep, "V-15g", 'let s = "\U0001F600"; return s[0];', "[55357]")
    _errs(rep, "V-15h", "let b = 'd 1'; return b[5];", "index out of range. ")

    # ==================== 宿主函数 / 实参表 ====================
    _host_functions(rep)
    _arguments(rep)

    # ==================== 错误串带指令下标 ====================
    _error_index(rep)

    # ==================== 自定义指令 ====================
    _custom_opcode(rep)

    # ==================== run 与 step 等价 ====================
    _run_step_equivalence(rep)


def _host_functions(rep) -> None:
    # 宿主函数：一个值，直接放变量槽（对应 C++ 的 Value::Type::HostFunction）
    prog, errs = _compile("return f(1, 2);")
    if prog is None:
        rep.add_fail("V-14", "编译失败：" + "".join(errs))
    else:
        s = _state(prog)
        # 未声明就被调用 → 编译器隐式登记进 exports；槽位号由编译器分配，不能写死
        s.variables[prog.exports["f"]] = lambda argv: argv[0] + argv[1]
        rc = s.run()
        rep.check("V-14", "run 返回", "Success", rc.name)
        rep.check("V-14", "returns", "[3]", _fmt_returns(s))

    # 宿主函数返回 bool：归一成整数（Stope 没有布尔值类型）
    prog2, errs2 = _compile("return g();")
    if prog2 is None:
        rep.add_fail("V-14b", "编译失败：" + "".join(errs2))
    else:
        s2 = _state(prog2)
        s2.variables[prog2.exports["g"]] = lambda _argv: True
        s2.run()
        rep.check("V-14b", "returns", "[1]", _fmt_returns(s2))
        rep.check("V-14b", "returns[0] 类型", "int", type(s2.returns[0]).__name__)

    # Call 到非函数
    s3, _ = _build("let x = 1; return x(2);")
    if s3 is None:
        rep.add_fail("V-17", "编译失败")
    else:
        rep.check_int("V-17", "错误条数", 1, len(s3.errors))
        rep.check("V-17", "错误消息", '"Call" can only call a function. ',
                  _msg_only(s3.errors[0]) if s3.errors else "<无错误>")


def _arguments(rep) -> None:
    # argc + args[i]
    s, _ = _build("return argc + args[0];", _ArrayArgs([2]))
    if s is None:
        rep.add_fail("V-18", "编译失败")
    else:
        rep.check("V-18", "returns", "[3]", _fmt_returns(s))  # argc(1) + args[0](2)

    # 没给实参表
    s2, _ = _build("return argc;", None)
    if s2 is None:
        rep.add_fail("V-19", "编译失败")
    else:
        rep.check_int("V-19", "错误条数", 1, len(s2.errors))
        rep.check("V-19", "错误消息", "no args. ",
                  _msg_only(s2.errors[0]) if s2.errors else "<无错误>")

    # 实参表越界由宿主自己报错
    s3, _ = _build("return args[5];", _ArrayArgs([1]))
    if s3 is None:
        rep.add_fail("V-20", "编译失败")
    else:
        rep.check_int("V-20", "错误条数", 1, len(s3.errors))
        rep.check("V-20", "错误消息", "argument out of range. ",
                  _msg_only(s3.errors[0]) if s3.errors else "<无错误>")

    # 宿主 at() 里报错之后执行器必须停：错误进同一个 errors，且定位到 GetArg 那条
    prog, _ = _compile("return args[0];")
    opts = _state(prog, _NoArgs()) if prog is not None else None
    if opts is None:
        rep.add_fail("V-04", "编译失败")
    else:
        rc = opts.run()
        rep.check("V-04", "run 返回", "Error", rc.name)
        rep.check_int("V-04", "错误条数", 1, len(opts.errors))
        rep.check("V-04", "错误消息", "args not provided in this test. ",
                  _msg_only(opts.errors[0]) if opts.errors else "<无错误>")
        rep.check_true("V-04", "停机在 GetArg 上",
                       opts.i < len(prog.opcodes)
                       and prog.opcodes[opts.i] == int(Opcode.GetArg))


def _error_index(rep) -> None:
    """错误串前缀是 ``"<指令下标>: "`` —— 下标就是出错那条指令在产物里的位置。"""
    s, _ = _build("return 1 / 0;")
    if s is None or len(s.errors) != 1:
        rep.add_fail("V-16", "`return 1 / 0;` 应当恰好报一条错")
        return
    # 产物是 PushInt(0) PushInt(1) Div Return(1) —— Div 在下标 4（操作数各占一格）
    rep.check_true("V-16", "错误串形如 \"4: ...\"：" + s.errors[0],
                   s.errors[0].startswith('4: "Div" division by zero. '))


def _custom_opcode(rep) -> None:
    """自定义指令（编号 >= 33）能跑、能报错，且 ``set_opcode`` 会把中间补齐。"""
    cfg = CustomOpcodeConfig()
    cfg.add_custom_opcode("my:boom", kFirstCustomOpcode, 0)
    prog, errs = _compile("my:boom();", cfg)
    if prog is None:
        rep.add_fail("V-05", "编译失败：" + "".join(errs))
        return

    def boom(s):
        s.error("boom. ")

    api = Api()
    api.set_opcode(kFirstCustomOpcode, boom)
    s = State()
    s.reset(api, prog, _NoArgs())
    rc = s.run()
    rep.check("V-05", "run 返回", "Error", rc.name)
    rep.check_int("V-05", "错误条数", 1, len(s.errors))
    rep.check("V-05", "错误全文", "0: boom. ", "|".join(s.errors))

    # 跳号注册：33 是刚注册的，34/35 必须补成占位函数而不是留空（留空会在 Run 时
    # 抛 IndexError，看起来像「产物坏了」而不是「表没填」）
    api2 = Api()
    rep.check_int("V-05b", "内置表长度", kFirstCustomOpcode, len(api2.op_map))
    api2.set_opcode(kFirstCustomOpcode + 2, boom)
    rep.check_int("V-05b", "补齐后长度", kFirstCustomOpcode + 3, len(api2.op_map))


def _run_step_equivalence(rep) -> None:
    """``run`` 与 ``step`` 是两份独立实现（热循环不套函数调用）。同一批程序跑两遍：
    返回值必须一致，顺序执行时**指令条数也必须一致**。"""
    cases = [
        ("return 1 + 2 * 3;", True),
        ("let a = 1; while a < 5 { a = a + 1; } return a;", False),
        ("let s = 0; let i = 0; while i < 10 { if i % 2 == 0 { s = s + i; } i = i + 1; } return s;",
         False),
        ("let a = 1; let b = 2; return a < b and b < 3;", False),
        ("if 1 { return 10; } else { return 20; }", False),
        ("let x = 0; while { x = x + 1; if x > 3 { break; } } return x;", False),
    ]

    for src, linear in cases:
        cid = "V-21 " + src
        prog, errs = _compile(src)
        if prog is None:
            rep.add_fail("V-21", "编译失败：" + src + " | " + "".join(errs))
            continue

        s1 = _state(prog)
        s1.run()

        s2 = _state(prog)
        steps = 0
        while s2.i < len(prog.opcodes) and s2.step() == Result.Success:
            steps += 1
            if steps > 100000:
                break

        rep.check(cid, "returns", _fmt_returns(s1), _fmt_returns(s2))
        rep.check(cid, "errors", "|".join(s1.errors), "|".join(s2.errors))
        rep.check_true(cid, "step 应把指令流走完", s2.i >= len(prog.opcodes))
        rep.check_int(cid, "停机时 i", s1.i, s2.i)
        if linear:
            rep.check_int(cid, "步数应等于指令条数", _inst_count(prog), steps)

        # 停机后再驱动一次：不执行指令、不追加错误（结束态与错误态都应如此）
        err_before = len(s2.errors)
        i_before = s2.i
        again = s2.step()
        rep.check_true(cid, "停机后 step 返回 Success（什么都不做）", again == Result.Success)
        rep.check_int(cid, "停机后 i 不变", i_before, s2.i)
        rep.check_int(cid, "停机后 errors 不变", err_before, len(s2.errors))
