"""反汇编：``golden_disasm.txt``（12 条，``cpp/tools/golden_disasm.cpp`` dump）。

逐字节比 ``disasm`` 的完整输出（含 ``variables:`` / 常量池 / warning 段）。

两种模式：``MODE=src`` 走「源码 → 编译 → 反汇编」；``MODE=raw`` 直接给指令流
（``OPS=200,1``），用来覆盖「产物里有不认识的编号」这类正常编译路径造不出来的情况。
四份实现（C++ / GDScript / Node.js / C#）对同一份产物必须输出同一串文本 ——
这是唯一能逐字节比对的中介物。
"""

from stope.ast import Prog
from stope.compiler import Compiler
from stope.debug import custom_opcode_has_arg, disasm, disasm_no_custom, opcode_has_arg
from stope.lexer import Lexer
from stope.opcode import CustomOpcodeConfig, Opcode
from stope.parser import Parser
from stope.program import Program

from . import golden

#: 与探针里的 g_cfg 一致：myop #100（2 个参数）/ vop #101（变长）
MAIN_CFG = CustomOpcodeConfig()
MAIN_CFG.add_custom_opcode("myop", 100, 2)
MAIN_CFG.add_custom_opcode("vop", 101, -1)

#: 故意撞内置 Add
COLLIDE_CFG = CustomOpcodeConfig()
COLLIDE_CFG.add_custom_opcode("my:steal", int(Opcode.Add), 2)


def run(rep) -> None:
    cases = golden.read_golden("golden_disasm.txt")
    if not cases:
        rep.add_fail("反汇编", "golden_disasm.txt 一条都没读到")
        return

    for rec in cases:
        cid = rec.get("ID", "")
        cfg_name = rec.get("CFG", "none")
        cfg = {"main": MAIN_CFG, "collide": COLLIDE_CFG}.get(cfg_name)

        if rec.get("MODE", "") == "src":
            # SRC 是 E_(escUtf8(源码))，要解两层（见 test_parser.run_case 的注释）
            src = golden.unescape(rec.get("SRC", ""))
            tree = Prog()
            Parser(Lexer(src), cfg).parse_program(tree)
            prog = Program()
            Compiler(cfg).compile(tree, prog)
            got = disasm(prog, cfg)
        else:
            # raw：直接给指令流，不经过前端
            prog = Program()
            for s in rec.get("OPS", "").split(","):
                if s:
                    prog.opcodes.append(int(s))
            prog.variable_num = int(rec.get("VARS", "0") or 0)
            got = disasm(prog, cfg)
        rep.check(cid, "DIS", rec.get("DIS", ""), got)

    # ---- 单测：这四条锁的是「golden 恰好看不出差别」的细节 ----
    rep.check_true("DISP-NOCUSTOM", "disasm_no_custom 等价于 disasm(prog, None)",
                   disasm_no_custom(Program()) == disasm(Program(), None))

    # OpcodeHasArg 的分档：PushInt..At 与 If/GoTo/Return 带操作数
    want_arg = set(range(int(Opcode.PushInt), int(Opcode.At) + 1)) | {
        int(Opcode.If), int(Opcode.GoTo), int(Opcode.Return)}
    bad = [op for op in range(33) if opcode_has_arg(op) != (op in want_arg)]
    rep.check_true("DISP-ARG", "opcode_has_arg 的分档：" + str(bad), not bad)

    # 只有变长自定义指令才带操作数
    rep.check_true("DISP-CUSTOM-ARG", "定长指令不带操作数", not _custom_has_arg(100))
    rep.check_true("DISP-CUSTOM-ARG", "变长指令带操作数", _custom_has_arg(101))

    # custom opcodes 段按**编号**排序，不是名字序（golden 那 12 条两种序恰好一致，
    # 看不出来；这里构造一组「名字序与编号序相反」的配置把它锁住）
    cfg = CustomOpcodeConfig()
    cfg.add_custom_opcode("a_first", 101, -1)   # 名字序在前，编号在后
    cfg.add_custom_opcode("b_second", 100, 2)   # 名字序在后，编号在前
    prog = Program()
    prog.opcodes.extend([101, 0, 100, 3])
    text = disasm(prog, cfg)
    table = text[text.index("custom opcodes:"):]
    rep.check_true("DISP-SORT", "custom opcodes 段按编号排序（100 在 101 之前）",
                   table.index("b_second") < table.index("a_first"))


def _custom_has_arg(opcode: int) -> bool:
    cfg = CustomOpcodeConfig()
    cfg.add_custom_opcode("x", opcode, -1 if opcode == 101 else 2)
    return custom_opcode_has_arg(opcode, cfg)
