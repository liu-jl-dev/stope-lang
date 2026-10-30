"""Quick-start demo: compile a Stope program and run it.

Stope's standard covers three things only: the Stope language, STML, and the
compiler's output (`Program`). It does NOT define a virtual machine, so the
steps below have different stability guarantees:

  step 1 (compile) : Lexer / Parser / Compiler / Program
                     -> compiler API, relatively stable: `Program` has a
                        documented encoding contract, so this part can be
                        relied on (and copied) in host programs.
  step 2-4 (run)   : stope.basic_vm
                     -> a BUILT-IN EXAMPLE executor, not part of the
                        standard. Value representation, stack layout, host
                        function binding and error reporting are all
                        implementation details; another executor may not
                        look like this at all. See docs/zh-cn/vm-guide.md.

In other words: keep step 1, treat step 2-4 as one possible way to run the
`Program` produced above.

运行：python demo/01-quick-start.py

输出与 cpp/demo/01-quick-start.cpp、gdscript/demo/demo_01.gd、nodejs/demo/01-quick-start.js
逐字节相同 —— 四份实现（外加 C#）对同一份源码产出同一份字节码。
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from stope.ast import Prog                      # noqa: E402
from stope.basic_vm import Api, Arguments, State  # noqa: E402
from stope.compiler import Compiler             # noqa: E402
from stope.debug import disasm_no_custom        # noqa: E402
from stope.format import fmt_g                  # noqa: E402
from stope.lexer import Lexer                   # noqa: E402
from stope.parser import Parser                 # noqa: E402
from stope.program import Program               # noqa: E402

# 输出统一成 UTF-8 + LF：Windows 控制台默认按本地代码页编码、文本模式还会把 \n 换成
# \r\n，那样就没法跟另外四份实现逐字节比了。
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")


class MyArgs(Arguments):
    """宿主侧的参数表：源码里的 ``args[i]`` / ``argc`` 都落到它身上（对应 C++ demo
    的 ``MyArgs``）。与标准无关，纯属示例执行器的接口。"""

    __slots__ = ("data",)

    def __init__(self, values):
        self.data = list(values)

    def at(self, state, index_or_key):
        """取不到就**自己报错**：``state.error(...)`` 之后返回 ``None``，执行器立刻停。"""
        if not isinstance(index_or_key, int) or isinstance(index_or_key, bool):
            state.error("index must be an integer. ")
            return None
        if index_or_key < 0 or index_or_key >= len(self.data):
            state.error("index out of range. ")
            return None
        return self.data[index_or_key]

    def num(self) -> int:
        return len(self.data)


def fmt(v) -> str:
    """C++ 的 ``cout << double`` 把 15.0 打成 ``15``；用 ``%g`` 才与它一致
    （Python 的 ``str(15.0)`` 是 ``15.0``，会多出小数点和零）。"""
    if v is None:
        return "null"
    if isinstance(v, float):
        return fmt_g(v)
    return str(v)


def println(argv):
    """宿主函数（对应 C++ demo 里绑到 ``fmt:println`` 的那个 lambda）。

    Python 里函数本身就是值，直接塞进变量槽就能被 ``Call`` 指令调到。
    签名统一是 ``fn(argv) -> 值`` —— 参数**整包**进来，自己拆。
    """
    print("[Host] " + "".join(fmt(a) for a in argv))
    return None


def main() -> int:
    # ---------------- step 1: 编译源码 ----------------
    #
    # 稳定性：编译器接口。Program 有明确的编码契约（指令编号、操作数、跳转目标是
    # opcodes 下标），宿主可以依赖这一段。
    src = """
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

    lexer = Lexer(src)
    parser = Parser(lexer)  # 第二参是 CustomOpcodeConfig，可省
    tree = Prog()
    parser.parse_program(tree)
    for e in lexer.errors:
        print("[lex] " + e, file=sys.stderr)
    for e in parser.errors:
        print("[parse] " + e, file=sys.stderr)

    compiler = Compiler()  # 构造参同上，可省
    program = Program()
    rc = compiler.compile(tree, program)  # AST 与 Program 都传引用
    for e in compiler.errors:
        print("[compile] " + e, file=sys.stderr)
    if rc != 0:  # 0 == Result.Success
        # 编译失败时 compile() 已按约定把 program 清空，别拿它去反汇编或执行
        print("compile failed, nothing to run", file=sys.stderr)
        return 1
    print(disasm_no_custom(program))

    # ---------------- step 2-4: 装配执行器 ----------------
    #
    # 稳定性：内置示例，不是标准。换一个执行器，这段可以整个换掉。
    api = Api()
    args = MyArgs([1.0, 2.0, 3.0, 4.0, 5.0])

    # reset 一次做完：清 returns / stack / errors，并按 variable_num 开好槽位。
    # （C++ 侧那句必写的 state.variables.resize(...) 在这里由 reset 代做。）
    state = State()
    state.reset(api, program, args)

    # 宿主函数就是「某个变量槽里的值」：编译器把未声明的 fmt:println 当外部变量，
    # 登记进了 exports；按名字取槽位，填上函数即可。
    state.variables[program.exports["fmt:println"]] = println

    # ---------------- step 4: 跑 ----------------
    if state.run() != 0:
        for e in state.errors:
            print("[vm] " + e, file=sys.stderr)
        return 1
    print("result: " + fmt(state.returns[0]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
