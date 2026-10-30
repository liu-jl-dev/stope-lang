"""Demo 03: 自定义指令 —— 给编译器加几条自己的指令，只编译 + 反汇编，不运行。

对应 cpp/demo/03-custom-opcode.cpp、gdscript/demo/demo_03.gd、nodejs/demo/03-custom-opcode.js。

运行：python demo/03-custom-opcode.py

项目只规定 33 条内置指令（``stope/opcode.py``）与 ``Program`` 的编码契约；再往上加指令
是宿主自己的事，三步：

  1. 用 ``CustomOpcodeConfig`` 登记「名字 -> (编号, 参数个数)」；
  2. **同一份 config 同时交给 Parser 和 Compiler**：Parser 靠它把名字识别成 Custom token
     （查不到就只是普通标识符），Compiler 靠它查编号与参数个数；
  3. 产物里就只是一串 number —— 编号什么含义、谁来执行，全由宿主决定。

本 demo 不运行程序：自定义指令在 ``stope.basic_vm`` 里没有实现，也不该有 —— 那只是内置
示例执行器，不是标准的一部分（见 01-quick-start.py 开头与 docs/zh-cn/vm-guide.md）。
自定义指令的意义正在于此：宿主自己定义、自己执行。

两条硬约束（见 docs/zh-cn/compiler-test-plan.md §4.4）：

* 编号必须 >= ``kFirstCustomOpcode``（= ``Opcode.Return + 1``）。opcodes 是混排序列，
  撞号以后与内置指令无法区分；``disasm()`` 会把这种注册报成 warning（[5] 演示）。
* 定长指令的 ``arg_num`` 必须与实际调用一致，否则编译期报错、不产出（[4] 演示）。
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from stope.ast import Prog                                    # noqa: E402
from stope.compiler import Compiler                           # noqa: E402
from stope.debug import disasm, disasm_no_custom              # noqa: E402
from stope.lexer import Lexer                                 # noqa: E402
from stope.opcode import (CustomOpcodeConfig, Opcode,         # noqa: E402
                         kFirstCustomOpcode)
from stope.parser import Parser                               # noqa: E402
from stope.program import Program                             # noqa: E402

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")


def compile_and_report(src: str, config, out: Program) -> bool:
    """编译一份源码并打印错误。``config`` 为 ``None`` 时按「没有自定义指令」处理。"""
    lexer = Lexer(src)
    parser = Parser(lexer, config)  # 第二参：可空的 config
    tree = Prog()
    parser.parse_program(tree)
    for e in lexer.errors:
        print("  lexer: " + e)
    for e in parser.errors:
        print("  parser: " + e)

    compiler = Compiler(config)  # 配置只在构造时注入一次
    rc = compiler.compile(tree, out)
    for e in compiler.errors:
        print("  compiler: " + e)
    return rc == 0 and not lexer.errors and not parser.errors


def main() -> int:
    # ---------- 1. 登记自定义指令 ----------
    #
    # arg_num >= 0 定长；arg_num < 0（默认值 -1）变长，编译产物里会多写一个「本次调用的
    # 参数个数」。名字里的 ':' 是词法器支持的命名空间写法，用来避开宿主函数名
    # （fmt:println 那种）。
    config = CustomOpcodeConfig()
    print("[1] 登记自定义指令：")
    # 返回 Result：同名重复注册会拿到 DuplicateWithBuiltinOpcode。这里三条都新，
    # 不为返回值打断流程。
    config.add_custom_opcode("my:add", kFirstCustomOpcode + 0, 2)
    config.add_custom_opcode("my:log", kFirstCustomOpcode + 1, -1)
    config.add_custom_opcode("my:halt", kFirstCustomOpcode + 2, 0)
    # 打印时按编号排序：config.opcodes 是 dict（插入序），而 C++ 侧是 std::map（名字序）。
    # 显式排序，几份实现的输出才一致。
    for name, info in sorted(config.opcodes.items(), key=lambda kv: kv[1].opcode):
        kind = "（变长）" if info.is_var_arg else f"（定长 {info.arg_num} 参）"
        print(f"  {name} -> #{info.opcode}{kind}")

    # ---------- 2. 编译并反汇编 ----------
    #
    # 注意 my:add 的参数照常先压栈，指令本身不再带操作数；只有 my:log 这种变长指令后面
    # 多一个 number。反汇编要认出这些，必须把同一份 config 交给 disasm()。
    src = """
    let x = 3;

    my:add(x, 4);        // 定长 2 参
    my:log("x =", x);    // 变长 2 参
    my:log();            // 变长 0 参
    my:halt();           // 定长 0 参

    return x;
  """
    program = Program()
    print("\n[2] 编译结果：")
    if not compile_and_report(src, config, program):
        return 1
    print(disasm(program, config))

    # ---------- 3. 对照：名字没登记就只是普通调用 ----------
    #
    # 词法器只有在 config 里查得到名字时才吐 Custom token，否则 "my:add" 就是个普通
    # 标识符 —— 编译成 Call，即「调用一个名叫 my:add 的宿主函数」。
    plain = Program()
    print("\n[3] 同样的调用，不传 config：")
    if compile_and_report("my:add(1, 2);", None, plain):
        print(disasm_no_custom(plain))

    # ---------- 4. 参数个数不符 ----------
    #
    # 定长指令的参数量在编译期校验；报错后 compile() 会把 out 复原为空，免得一个半成品
    # Program 被当成能跑的东西。
    bad = Program()
    print("\n[4] 定长 2 参却只给 1 个：")
    if not compile_and_report("my:add(1);", config, bad):
        print(f"  -> 编译失败，Program 已清空（opcodes 剩 {len(bad.opcodes)} 个 number）")

    # ---------- 5. 陷阱：编号撞到内置指令 ----------
    #
    # 自定义编号必须 >= kFirstCustomOpcode。这里故意用一个内置编号注册：编译器写出的仍是
    # 同一个 number，谁也分不清它到底是 Add 还是 my:steal —— disasm() 只能按内置指令解码，
    # 并把它报成 warning。
    collide = CustomOpcodeConfig()
    collide.add_custom_opcode("my:steal", int(Opcode.Add), 2)
    stolen = Program()
    print("\n[5] 用内置 Add 的编号注册 my:steal：")
    if compile_and_report("my:steal(1, 2);", collide, stolen):
        print(disasm(stolen, collide))
        print("  -> 反汇编只认得出 Add：my:steal 这个名字已经丢了，编号千万别撞内置。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
