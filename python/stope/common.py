"""返回码 + 数值助手（整数 int64 语义 / 浮点 IEEE 语义）。

``Result`` 与 C++ 的 ``stope::Result``、GDScript 的 ``StopeResult``、C# 的 ``Result``
逐值对应。用来取代「返回 bool + 输出参数」—— 需要区分的失败类型只有这四种。

⚠ Python 的整数是**无限精度**，``//`` 与 ``%`` 还是**向下取整**。Stope 要的是
「int64 补码回绕 + 向零取整」，所以整数运算一律走本文件这四个函数，别直接写 ``//``：

* :func:`wrap64` —— 按 64 位回绕（等价 C++ 的 unsigned 算术 / C# 的 unchecked）；
* :func:`int_div` —— 向零取整的整除（C++ 的 ``/`` / ``idiv``）；
* :func:`int_mod` —— 向零取整的余数（C++ 的 ``%``）；
* :func:`int_pow` —— 快速幂，溢出不检查、按 64 位回绕。

⚠ 浮点更隐蔽：C++ 走 IEEE（除零得 ±inf、``0/0`` 得 nan、``std::fmod`` 的余数符号跟
**被除数**、域错误得 nan），而 Python **抛异常**或**换了语义**。所以这四个函数也是唯一
入口，常量折叠与执行器共用（两边必须给出同一个答案）：

* :func:`fdiv` —— ``x / 0`` 得 ±inf、``0 / 0`` 得 nan（Python 抛 ZeroDivisionError）；
* :func:`fmod` —— ``std::fmod`` 语义（Python 的 ``%`` 余数符号跟**除数**，方向相反）；
* :func:`trunc` —— 向零取整但**保持浮点**（``math.trunc`` 返回 int 且对 inf 抛错）；
* :func:`fpow` —— ``std::pow`` 语义（``math.pow`` 对负底数/溢出抛异常，``**`` 还会返回复数）。
"""

from enum import IntEnum

import math

INT64_MIN = -(2 ** 63)
INT64_MAX = 2 ** 63 - 1
_MASK64 = (1 << 64) - 1
_INF = float("inf")
_NAN = float("nan")


class Result(IntEnum):
    Success = 0
    Error = 1
    UnknownError = 2
    DuplicateWithBuiltinOpcode = 3


def wrap64(v: int) -> int:
    """按 64 位补码回绕（Python 的 ``&`` 对负数也是无限位补码，结果正确）。"""
    return ((v + (1 << 63)) & _MASK64) - (1 << 63)


def int_div(a: int, b: int) -> int:
    """向零取整的整除（C++ 的 ``/`` 语义），结果按 64 位回绕。``b`` 不能为 0。"""
    q = abs(a) // abs(b)
    if (a < 0) != (b < 0):
        q = -q
    return wrap64(q)


def int_mod(a: int, b: int) -> int:
    """向零取整的余数（C++ 的 ``%`` 语义），结果按 64 位回绕。``b`` 不能为 0。"""
    return wrap64(a - int_div(a, b) * b)


def int_pow(base: int, exp: int) -> int:
    """整数快速幂，``exp >= 0``；溢出不检查、按 64 位回绕（与 C++ 走 unsigned 一致）。"""
    result = 1
    b = base
    e = exp
    while e > 0:
        if e & 1:
            result = wrap64(result * b)
        e >>= 1
        if e > 0:
            b = wrap64(b * b)
    return result


def is_special(v: float) -> bool:
    """``nan`` / ``±inf`` —— 这几个值过 ``trunc`` / 比较会抛异常或给出意外结果。"""
    return v != v or v == _INF or v == -_INF


def fdiv(a: float, b: float) -> float:
    """IEEE 除法：``x / 0`` 得 ±inf、``0 / 0`` 得 nan（Python 会抛 ZeroDivisionError）。"""
    if b != 0.0:
        return a / b
    if a == 0.0 or a != a:
        return _NAN
    return math.copysign(_INF, a) * math.copysign(1.0, b)


def fmod(a: float, b: float) -> float:
    """``std::fmod``：余数符号跟**被除数**（Python 的 ``%`` 跟除数，遇负数就反了）。
    ``b == 0`` 得 nan，而不是抛 ValueError。"""
    if b == 0.0 or a != a or b != b:
        return _NAN
    return math.fmod(a, b)


def trunc(v: float) -> float:
    """``std::trunc``：向零取整但**保持浮点**。``math.trunc`` 会返回 int 且对 inf 抛错。"""
    if is_special(v):
        return v
    return float(math.trunc(v))


def fpow(a: float, b: float) -> float:
    """``std::pow``：负底数 + 非整数指数得 nan、溢出得 ±inf、``0 ^ 负数`` 得 inf。

    ⚠ 别改成 ``a ** b``：Python 对负底数 + 分数指数返回**复数**（``(-8.0) ** 0.5`` 是
    ``1.7e-16+2.8j``），一路混进 FloatExpr 就再也没人发现。
    """
    try:
        return math.pow(a, b)
    except OverflowError:
        neg = a < 0.0 and b == math.floor(b) and int(b) % 2 == 1
        return -_INF if neg else _INF
    except ValueError:
        if a == 0.0 and b < 0.0:
            return _INF
        return _NAN
