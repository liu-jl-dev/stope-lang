"""golden 数据的读取、转义与「单行产物格式」。

数据由 ``cpp/tools/`` 下的探针生成并入库在 ``gdscript/test/data/`` —— 仓库里只有这一份，
GDScript 侧从 ``res://test/data/`` 读、nodejs / C# 从相对路径读同一个目录，本实现也从
那里读（**不复制第二份**，否则 C++ 改行为时会出现「哪一份才是真值」）。

记录格式：一条用例一行，字段之间用 TAB，每个字段 ``KEY=VALUE``，值里的
``\\\\ \\n \\r \\t`` 已转义。解析后按 KEY 取用。

⚠ **转义约定每个文件都不一样**，别照抄：

===============  ==========================  ============================================
文件             值要不要解转义              SRC 用什么解
===============  ==========================  ============================================
golden.txt       解一层                      解两层（探针写的是 E_(escUtf8(源码))）
golden_disasm    解一层                      解两层
golden_lex.txt   **不解**                    unescape_lex（多认 \\v \\f）
golden_stml.txt  **不解**                    unescape_lex
stml_cases.txt   —（清单本身）              unescape_lex
===============  ==========================  ============================================
"""

import os

from stope.opcode import Opcode as _Opcode

_DATA_DIR = None


def locate_data_dir() -> str:
    """从本文件位置向上找 ``gdscript/test/data``（与 C# 的 LocateDataDir 同法）。"""
    global _DATA_DIR
    if _DATA_DIR is not None:
        return _DATA_DIR
    d = os.path.dirname(os.path.abspath(__file__))
    while True:
        cand = os.path.join(d, "gdscript", "test", "data")
        if os.path.isdir(cand):
            _DATA_DIR = cand
            return cand
        parent = os.path.dirname(d)
        if parent == d:
            raise FileNotFoundError(
                "找不到 gdscript/test/data —— 请在仓库里运行（测试数据不入包）。")
        d = parent


def data_path(name: str) -> str:
    return os.path.join(locate_data_dir(), name)


def read_text(name: str) -> str:
    """读一份数据文件，统一剥掉 ``\\r``（Windows 上探针输出 CRLF）。"""
    with open(data_path(name), "r", encoding="utf-8", newline="") as f:
        return f.read().replace("\r", "")


def unescape(s: str) -> str:
    """反转义：与探针的 ``E_()`` 对称（``\\\\  \\n  \\r  \\t``，其余原样保留）。"""
    out = []
    i = 0
    n = len(s)
    while i < n:
        ch = s[i]
        if ch != "\\":
            out.append(ch)
            i += 1
            continue
        i += 1
        c = s[i] if i < n else "\0"
        i += 1
        if c == "\\":
            out.append("\\")
        elif c == "n":
            out.append("\n")
        elif c == "r":
            out.append("\r")
        elif c == "t":
            out.append("\t")
        else:
            out.append("\\")
            out.append(c)
    return "".join(out)


def unescape_lex(s: str) -> str:
    """与 :func:`unescape` 相同，但**多认 ``\\v`` 与 ``\\f``** —— 词法与 STML 的 SRC 用这套。"""
    out = []
    i = 0
    n = len(s)
    while i < n:
        ch = s[i]
        if ch == "\\" and i + 1 < n:
            c = s[i + 1]
            if c == "\\":
                out.append("\\")
                i += 2
                continue
            if c == "n":
                out.append("\n")
                i += 2
                continue
            if c == "r":
                out.append("\r")
                i += 2
                continue
            if c == "t":
                out.append("\t")
                i += 2
                continue
            if c == "v":
                out.append("\v")
                i += 2
                continue
            if c == "f":
                out.append("\f")
                i += 2
                continue
        out.append(ch)
        i += 1
    return "".join(out)


def esc(s: str) -> str:
    """与 C++ 的 ``escUtf8`` 一致：``\\ " \\n \\r \\t`` 转义，非 ASCII 一律变 ``?``。"""
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


def esc_lex(s: str) -> str:
    """词法比对专用转义：比 :func:`esc` 多 ``\\v \\f``、不转义引号。"""
    out = []
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\v":
            out.append("\\v")
        elif ch == "\f":
            out.append("\\f")
        else:
            out.append(ch)
    return "".join(out)


def esc_quote(s: str) -> str:
    """``E_()`` 那一套：把 ``\\`` 与 ``"`` 双写（``golden_stml.txt`` 的 ERRS 用）。"""
    return s.replace("\\", "\\\\").replace('"', '\\"')


def join_quoted(errs) -> str:
    return "|".join(esc_quote(e) for e in errs)


def join_esc(errs) -> str:
    return "|".join(esc_lex(e) for e in errs)


def read_golden(name: str, unescape_values: bool = True) -> list[dict]:
    """读一份 golden 文件 → 若干 ``KEY=VALUE`` 字典，行首 ``#`` 是注释。

    ``unescape_values``：``golden.txt`` 与 ``golden_disasm.txt`` 的字段经过探针的
    ``E_()`` **二次**转义，读进来要解一层；``golden_stml.txt`` 只做了 escUtf8，
    多解一层会把 ``\\n`` 变成真换行。
    """
    out = []
    for line in read_text(name).split("\n"):
        if not line or line.startswith("#"):
            continue
        rec = {}
        for field in line.split("\t"):
            eq = field.find("=")
            if eq < 0:
                continue
            v = field[eq + 1:]
            rec[field[:eq]] = unescape(v) if unescape_values else v
        if rec:
            out.append(rec)
    return out


def read_binarr_golden() -> list[dict]:
    """``golden_binarr.txt`` 有两类记录，按 TAB 位置切。

    ``BA\\t内容\\tok|err\\t[字节]`` —— 内容本身可能含 TAB，所以最后两段固定是状态与字节；
    ``FB\\t运算符\\t左\\t右`` / ``FU\\t运算符\\t操作数`` —— 折叠矩阵。
    """
    out = []
    for line in read_text("golden_binarr.txt").split("\n"):
        if not line or line.startswith("#"):
            continue
        head = line[:3]
        if head == "BA\t":
            parts = line[3:].split("\t")
            status = parts[-2]
            content = "\t".join(parts[:-2])
            out.append({"kind": "BA", "content": content,
                        "ok": status == "ok", "bytes": parts[-1]})
        elif head in ("FB\t", "FU\t"):
            parts = line.split("\t")
            out.append({"kind": "FB" if head == "FB\t" else "FU",
                        "op": parts[1], "left": parts[2], "result": parts[3]})
    return out


def read_stml_cases() -> list[dict]:
    """``stml_cases.txt``：STML 的**用例清单**（四方共用），加删用例只改它。"""
    out = []
    for line in read_text("stml_cases.txt").split("\n"):
        if not line or line.startswith("#"):
            continue
        rec = {}
        for part in line.split("\t"):
            eq = part.find("=")
            if eq < 0:
                continue
            rec[part[:eq]] = part[eq + 1:]
        if "ID" not in rec:
            continue
        rec["src"] = unescape_lex(rec.get("SRC", ""))
        rec["times"] = int(rec.get("TIMES", "1"))
        out.append(rec)
    return out


def fmt_g(v: float) -> str:
    """``printf("%g")`` 的忠实实现（C 的 ``%g`` 与 Python 的 ``%g`` 一致）。"""
    return "%g" % v


def fmt_bytes(b: bytes) -> str:
    """二进制数组 → ``01,0a,ff``（小写两位十六进制，与 C++ 的 fmtBytes 一致）。"""
    return ",".join("%02x" % x for x in b)


def dump_program(prog, custom=None) -> str:
    """「单行产物格式」（``docs/zh-cn/compiler-test-plan.md`` §2.3）。

    对应 C++ 的私有 ``dumpLine``、GD 的 ``dump_program``、nodejs 的 ``dumpProgram``
    —— 四份都**不进库**，只在测试里用。
    """
    # 每条指令占几格：True 表示后面还跟一个操作数
    def has_arg(op: int) -> bool:
        if op > int(_RETURN):
            if custom is None:
                return False
            for info in custom.opcodes.values():
                if info.opcode == op:
                    return info.is_var_arg
            return False
        if op <= int(_PUSH_TRUE):
            return False
        if op <= int(_AT):
            return True
        if op <= int(_GE):
            return False
        if op <= int(_GOTO):
            return True
        if op <= int(_ARGNUM):
            return False
        return True

    parts = ["code["]
    ops = prog.opcodes
    i = 0
    local = []  # 局部列表拼起来更快
    while i < len(ops):
        if i:
            local.append(" ")
        op = ops[i]
        i += 1
        if op > int(_RETURN):
            local.append("Opcode(%d)" % op)
        else:
            local.append(_BUILTIN_NAMES[op])
        if has_arg(op) and i < len(ops):
            local.append("(%d)" % ops[i])
            i += 1
    parts.append("".join(local))
    parts.append("]")

    out = "".join(parts)
    out += " vars=%d" % prog.variable_num
    out += " stack=%d" % prog.required_stack_size
    out += " maxRet=%d" % prog.max_return_num
    out += " ints=[" + ",".join(str(x) for x in prog.int_consts) + "]"
    out += " floats=[" + ",".join(fmt_g(x) for x in prog.float_consts) + "]"
    out += " strs=[" + ",".join(esc(s) for s in prog.string_consts) + "]"
    out += " binarrs=[" + " ".join("[" + fmt_bytes(b) + "]" for b in prog.binarr_consts) + "]"
    # C++ 的 exports 是 std::map：按名字排序打印（不是插入序）
    names = sorted(prog.exports.keys())
    out += " exports=[" + ",".join(esc(k) + ":" + str(prog.exports[k]) for k in names) + "]"
    return out


_BUILTIN_NAMES = ["Assign", "PushNull", "PushFalse", "PushTrue", "PushInt", "PushFloat",
                  "PushString", "PushBinArr", "PushValue", "PushId", "Call", "At", "Pop",
                  "Minus", "Not", "Pow", "Mul", "Div", "IDiv", "Mod", "Add", "Sub", "EQ",
                  "NE", "LT", "LE", "GT", "GE", "If", "GoTo", "GetArg", "ArgNum", "Return"]

_PUSH_TRUE = _Opcode.PushTrue
_AT = _Opcode.At
_GE = _Opcode.GE
_GOTO = _Opcode.GoTo
_ARGNUM = _Opcode.ArgNum
_RETURN = _Opcode.Return
