"""``Program`` 反汇编（调试用）—— 端口 ``cpp/include/stope/debug.hpp`` 的 ``Disasm``。

内置 33 条指令的名字与「是否带操作数」是固定的；自定义指令（编号 > ``Opcode.Return``）
的名字、参数个数只有 :class:`CustomOpcodeConfig` 知道。所以产物里只要可能有自定义指令，
就得用 ``disasm(program, config)`` 打印：

* 不带 config 只能用 ``Custom#编号`` 占位，而且变长指令后面那个「参数个数」会被当成
  下一条指令（两者只差一个数字，读起来会全错位）；
* 带 config 才会印出名字，并按 ``is_var_arg`` 决定要不要吃掉后面那个数字。

输出与 C++ / GDScript / Node.js / C# **逐字节一致**（``golden_disasm.txt`` 就是五方的
共同期望值）：编号列宽 8、名字列宽 ``max(10, 最长名字)``、int/float 常量同列连排、
字符串常量一行一个、二进制数组只印字节数、最后是 warning 段。
"""

from .format import fmt_g
from .opcode import Opcode, kFirstCustomOpcode

#: 下标与内置名一一对应，顺序必须跟 Opcode 枚举一致。
_BUILTIN_NAMES = [
    "Assign", "PushNull", "PushFalse", "PushTrue", "PushInt",
    "PushFloat", "PushString", "PushBinArr", "PushValue", "PushId",
    "Call", "At", "Pop", "Minus", "Not",
    "Pow", "Mul", "Div", "IDiv", "Mod",
    "Add", "Sub", "EQ", "NE", "LT",
    "LE", "GT", "GE", "If", "GoTo",
    "GetArg", "ArgNum", "Return",
]
_BUILTIN_COUNT = len(_BUILTIN_NAMES)

#: 名字列的对齐宽度下限 = 内置名里最长的两个（PushString / PushBinArr，10 字节）。
#: 自定义名更长时整列变宽。名字按 **UTF-8 字节数**丈量（与 C++ 的 std::string::size 一致）。
_MIN_NAME_WIDTH = 10


def _pad_right(s: str, width: int) -> str:
    """按 UTF-8 字节数右填充空格（非 ASCII 名会少填几个空格，与 C++ 一致）。"""
    n = len(s.encode("utf-8"))
    return s if n >= width else s + " " * (width - n)


def opcode_has_arg(op: int) -> bool:
    """内置指令是否带一个操作数（操作数占紧随其后的一个数字）。

    自定义指令不走这里：它们的「带不带操作数」由 ``CustomOpcodeConfig`` 决定。
    """
    if Opcode.PushInt <= op <= Opcode.At:
        return True
    return op in (Opcode.If, Opcode.GoTo, Opcode.Return)


def custom_opcode_has_arg(raw: int, config) -> bool:
    """自定义指令只有在**变长参数**时才带操作数 —— 那个操作数是本次调用的参数个数
    （定长指令的参数个数是注册时定死的，编译产物里不再重复写）。"""
    if config is None:
        return False
    for info in config.opcodes.values():
        if info.opcode == raw and info.is_var_arg:
            return True
    return False


def disasm(prog, config=None) -> str:
    """把 ``Program`` 反汇编成可读文本。

    ``config`` 可空：产物里没有自定义指令时传 ``None`` 即可（等价于
    :func:`disasm_no_custom`）。含自定义指令时**必须**传注册时用的那一份，否则名字、
    变长指令的参数个数都无从得知。
    """
    # ---------- 编号 -> (名字, 注册项) 的反查表 ----------
    custom_by_opcode: dict[int, tuple[str, object]] = {}
    warnings: list[str] = []
    name_width = _MIN_NAME_WIDTH
    if config is not None:
        # C++ 的 CustomOpcodeConfig 是 std::map（按名字字典序）。这里显式排序，
        # 否则「谁先注册谁在前」会让自定义指令表的行序与 C++ 不一致。
        for name in sorted(config.opcodes.keys()):
            info = config.opcodes[name]
            if info.opcode < kFirstCustomOpcode:
                if 0 <= info.opcode < _BUILTIN_COUNT:
                    what = _BUILTIN_NAMES[info.opcode]
                else:
                    what = "(not an opcode)"
                warnings.append(
                    'custom opcode "%s" uses #%d, which collides with %s; '
                    "builtin decoding wins." % (name, info.opcode, what))
                continue
            prev = custom_by_opcode.get(info.opcode)
            if prev is not None:
                warnings.append(
                    'custom opcodes "%s" and "%s" share #%d; the former wins.'
                    % (prev[0], name, info.opcode))
                continue
            custom_by_opcode[info.opcode] = (name, info)
            name_width = max(name_width, len(name.encode("utf-8")))

    # ---------- 指令流 ----------
    parts: list[str] = []
    unknown: list[int] = []  # 不认识的编号，最后统一提示（保持首次出现顺序）
    ops = prog.opcodes
    n = len(ops)
    i = 0
    while i < n:
        raw = ops[i]
        has_arg = False
        if 0 <= raw < _BUILTIN_COUNT:
            name = _BUILTIN_NAMES[raw]
            has_arg = opcode_has_arg(raw)
        else:
            it = custom_by_opcode.get(raw)
            if it is not None:
                name = it[0]
                has_arg = it[1].is_var_arg
            else:
                # 编号不认识就只能印数字。绝不能猜「有没有操作数」，否则会把下一条
                # 指令当成操作数吃掉、后面整段错位。
                name = ("Custom%d" % raw) if raw > Opcode.Return else ("Op#%d" % raw)
                if raw not in unknown:
                    unknown.append(raw)
        parts.append(_pad_right("[%d]" % i, 8) + _pad_right(name, name_width) + " ")
        i += 1
        if has_arg:
            if i < n:
                parts.append(str(ops[i]))
                i += 1
            else:
                parts.append("<missing operand>")
                warnings.append(
                    "opcode at [%d] expects an operand but the stream ends there." % (i - 1))
        parts.append("\n")
    ss = "".join(parts)

    # ---------- 自定义指令表（名字、编号、参数形态一次交代清楚） ----------
    if custom_by_opcode:
        ss += "custom opcodes:\n"
        # 必须按**编号**排序打印：C++ 的 customByOpcode 是 map<short, ...>，迭代序是
        # 编号序。上面那张表是按名字排序建的（撞号时「谁赢」取决于此，与 C++ 一致），
        # 直接迭代会印成名字序，多指令时与 C++ 不一致。
        for opcode in sorted(custom_by_opcode.keys()):
            name, info = custom_by_opcode[opcode]
            ss += "  " + _pad_right(name, name_width) + " -> " + str(info.opcode)
            if info.is_var_arg:
                ss += " (vararg)"
            else:
                ss += " (%d args)" % info.arg_num
            ss += "\n"

    # ---------- 变量表与常量池 ----------
    ss += "variables:\n"
    variables = [""] * prog.variable_num
    for name, idx in prog.exports.items():
        if 0 <= idx < len(variables):
            variables[idx] = name
    ss += "  "
    for k, v in enumerate(variables):
        ss += '"' + v + '"'
        if k < len(variables) - 1:
            ss += " "
    ss += "\nint consts:\n"
    for v in prog.int_consts:
        ss += "  " + str(v)
    ss += "\nfloat consts:\n"
    for v in prog.float_consts:
        ss += "  " + fmt_g(v)
    ss += "\nstring consts:\n"
    for v in prog.string_consts:
        ss += '  "' + v + '"\n'
    ss += "binary array consts:\n"
    for v in prog.binarr_consts:
        ss += "  " + str(len(v)) + " bytes\n"
    ss += "max return num: " + str(prog.max_return_num) + "\n"
    ss += "required stack size: " + str(prog.required_stack_size) + "\n"

    for raw in unknown:
        if raw > Opcode.Return:
            warnings.append(
                "opcode #%d is not a builtin; pass the CustomOpcodeConfig to "
                "Disasm() to decode it." % raw)
        else:
            warnings.append(
                "opcode #%d is not a valid instruction (unpatched placeholder?)." % raw)
    for w in warnings:
        ss += "warning: " + w + "\n"
    return ss


def disasm_no_custom(prog) -> str:
    """产物里确定没有自定义指令时的简写。"""
    return disasm(prog, None)
