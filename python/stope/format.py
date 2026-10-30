"""跨实现逐字节一致的格式化小工具。

对应 C# 的 ``Format.cs``：凡是出现在 golden 数据里的字符串，都必须用这里的函数生成，
换一个写法就可能多一个 0 或少一个引号。

* :func:`esc` —— ``escUtf8``：``\\ " \\n \\r \\t`` 转义，非 ASCII 一律 ``?``；
* :func:`fmt_g` —— ``printf("%g")``，浮点常量与 shape 串共用；
* :func:`fmt_bytes` —— 二进制数组的 ``01,0a,ff``。
"""


def esc(s: str) -> str:
    """与 C++ 的 ``escUtf8`` 一致：非 ASCII 一律变 ``?``（不是 ``\\uXXXX``）。"""
    out = []
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif ord(ch) < 128:
            out.append(ch)
        else:
            out.append("?")
    return "".join(out)


def fmt_g(v: float) -> str:
    """``printf("%g")`` 的忠实实现（Python 的 ``%g`` 与 C 的 ``%g`` 决策相同）。

    ``nan`` / ``inf`` / ``-inf`` 与 C 一样是小写；``-0.0`` 打成 ``-0``。
    """
    return "%g" % v


def fmt_bytes(b) -> str:
    """二进制数组 → ``01,0a,ff``（小写两位十六进制，逗号分隔）。"""
    return ",".join("%02x" % x for x in b)
