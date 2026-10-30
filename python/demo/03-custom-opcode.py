"""Demo 03：自定义指令 —— 登记几条自己的指令，编译并反汇编。

项目只规定 33 条内置指令和 ``Program`` 的编码契约；再往上加是宿主自己的事，三步：

  1. 用 ``CustomOpcodeConfig`` 登记「名字 -> (编号, 参数个数)」；
  2. **同一份 config 同时交给 Parser 和 Compiler** —— Parser 靠它把名字识别成 Custom
     token（查不到就只是个普通标识符），Compiler 靠它查编号与参数个数；
  3. 产物里就只是一串 number —— 编号什么含义、谁来执行，全由宿主决定。

本 demo 不运行程序：自定义指令在 ``stope.basic_vm`` 里没有实现，也不该有 —— 那是内置的
基础虚拟机（会一直维护，但不是标准的一部分），默认只有那 33 项。

运行：python demo/03-custom-opcode.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from stope import (AST, Compiler, CustomOpcodeConfig, Lexer, Opcode,  # noqa: E402
                   Parser, Program, Result, disasm, kFirstCustomOpcode)

sys.stdout.reconfigure(encoding="utf-8")

SRC = """
let x = 3;

my:add(x, 4);        // 定长 2 参
my:log("x =", x);    // 变长 2 参
my:log();            // 变长 0 参
my:halt();           // 定长 0 参

return x;
"""


def compile_src(src, config):
    """编译一份源码，返回 ``(program, 错误列表)``。``config`` 可空。"""
    lexer = Lexer(src)
    parser = Parser(lexer, config)
    tree = AST.Prog()
    parser.parse_program(tree)

    program = Program()
    compiler = Compiler(config)  # 配置只在构造时注入一次
    compiler.compile(tree, program)
    return program, lexer.errors + parser.errors + compiler.errors


def main():
    # ---------------- 1. 登记 ----------------
    # arg_num >= 0 定长；< 0（默认 -1）变长，产物里会多写一个「本次调用的参数个数」。
    config = CustomOpcodeConfig()
    print("[1] 登记自定义指令：")
    config.add_custom_opcode("my:add", kFirstCustomOpcode + 0, 2)
    config.add_custom_opcode("my:log", kFirstCustomOpcode + 1, -1)
    config.add_custom_opcode("my:halt", kFirstCustomOpcode + 2, 0)
    for name, info in config.opcodes.items():  # dict 是插入序，与登记顺序一致
        kind = "变长" if info.is_var_arg else f"定长 {info.arg_num} 参"
        print(f"  {name} -> #{info.opcode}（{kind}）")

    # ---------------- 2. 编译 + 反汇编 ----------------
    # 反汇编要认出这些指令，必须拿到同一份 config（否则只能印 Custom#编号）。
    program, errors = compile_src(SRC, config)
    print("\n[2] 编译结果：")
    if errors:
        raise SystemExit("\n".join(errors))
    print(disasm(program, config))

    # ---------------- 3. 对照：名字没登记就只是普通调用 ----------------
    # 词法器只有在 config 里查得到名字时才吐 Custom token，否则 "my:add" 就是个普通
    # 标识符 —— 编译成 Call，即「调用一个名叫 my:add 的宿主函数」。
    plain, _ = compile_src("my:add(1, 2);", None)
    print("\n[3] 同样的调用，不传 config：")
    print(disasm(plain))

    # ---------------- 4. 参数个数不符 ----------------
    # 定长指令的参数量在编译期校验；报错后 compile() 会把 program 复原为空。
    bad, errors = compile_src("my:add(1);", config)
    print("\n[4] 定长 2 参却只给 1 个：")
    print("  " + "\n  ".join(errors))
    print(f"  -> 编译失败，Program 已清空（opcodes 剩 {len(bad.opcodes)} 个 number）")

    # ---------------- 5. 陷阱：编号撞到内置指令 ----------------
    # 编号必须 >= kFirstCustomOpcode，否则与内置指令无法区分：编译器写出的仍是同一个
    # number，disasm() 只能按内置指令解码，并把它报成 warning。
    collide = CustomOpcodeConfig()
    collide.add_custom_opcode("my:steal", int(Opcode.Add), 2)
    stolen, _ = compile_src("my:steal(1, 2);", collide)
    print("\n[5] 用内置 Add 的编号注册 my:steal：")
    print(disasm(stolen, collide))
    print("  -> 反汇编只认得出 Add：my:steal 这个名字已经丢了。")


if __name__ == "__main__":
    main()
