"""Quick-start demo：编译一段 Stope 源码，再把它跑起来。

Stope 只规定三件事：语言、STML、编译产物 ``Program``，**不规定虚拟机**。所以下面
两个阶段性质不同：

  1. 编译：``Lexer`` / ``Parser`` / ``Compiler`` / ``Program`` —— 编译器接口，
     ``Program`` 有明确的编码契约，宿主可以依赖（也可以照抄）。
  2. 执行：``stope.basic_vm`` —— 内置的**基础虚拟机**，会一直维护、接口不随意改，
     但不属于标准；值的表示、栈布局、宿主函数绑定都是它自己的选择。

运行：python demo/01-quick-start.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from stope import (AST, Api, Arguments, Compiler, Lexer, Parser,  # noqa: E402
                   Program, Result, State, disasm, fmt_g)

# Windows 控制台默认按本地代码页编码，统一成 UTF-8，中文才不乱码。
sys.stdout.reconfigure(encoding="utf-8")

SRC = """
// example: sum all arguments

let result = 0.0;
let i = 0;
while i < argc {
  result = result + args[i];
  i = i + 1;
}

fmt:println("结果为: ", result);
return result;
"""


class MyArgs(Arguments):
    """实参表：源码里的 ``args[i]`` / ``argc`` 都落到它身上。"""

    def __init__(self, values):
        self.data = values

    def at(self, state, index_or_key):
        return self.data[index_or_key]  # 真取不到时：先 state.error("...") 再返回 None

    def num(self):
        return len(self.data)


def fmt(v):
    """浮点按 ``%g`` 打印（15.0 -> "15"），与库里的 ``format.fmt_g`` 一致。"""
    return fmt_g(v) if isinstance(v, float) else ("null" if v is None else str(v))


def println(argv):
    """宿主函数。签名统一是 ``fn(argv) -> 值``：参数整包进来，自己拆。

    函数本身就是值 —— 塞进变量槽，``Call`` 指令就能调到它。
    """
    print("[Host] " + "".join(fmt(a) for a in argv))


def main():
    # ---------------- 1. 编译：源码 -> Program ----------------
    lexer = Lexer(SRC)
    parser = Parser(lexer)  # 第二参是 CustomOpcodeConfig，这里没有自定义指令
    tree = AST.Prog()
    parser.parse_program(tree)

    compiler = Compiler()
    program = Program()
    if compiler.compile(tree, program) != Result.Success:
        # 三个环节都不抛异常，错误各自攒在 .errors 里；编译失败时 program 已被清空
        raise SystemExit("\n".join(lexer.errors + parser.errors + compiler.errors))

    print(disasm(program))  # 看一眼编出来的字节码

    # ---------------- 2. 执行：Program -> 结果 ----------------
    # 从这里开始是内置的基础虚拟机，不属于标准；换一个执行器，这段可以整个换掉。
    state = State()
    state.reset(Api(), program, MyArgs([1.0, 2.0, 3.0, 4.0, 5.0]))

    # 未声明的 fmt:println 被编译器当作外部变量登记进 exports；
    # 按名字取到槽位，填上宿主函数即可。
    state.variables[program.exports["fmt:println"]] = println

    if state.run() != Result.Success:
        raise SystemExit("\n".join(state.errors))
    print("result: " + fmt(state.returns[0]))


if __name__ == "__main__":
    main()
