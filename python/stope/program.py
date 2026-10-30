"""编译产物 ``Program``：指令流 + 常量池 + 变量表。

对应 ``cpp/include/stope/program.hpp``。字段名用 snake_case（Python 惯例），
与 C++ 的 camelCase 一一对应，对照表见 ``docs/usage.md``。

整数常量是 Python ``int``，但**语义上是 int64**：写进 ``int_consts`` 之前已经过
64 位回绕（见 ``basic_vm.wrap64``），所以这里存的就是「可打印的 int64 值」。
"""


class Program:
    """可直接编译 / 执行的空程序（与 C++ 的默认构造一致）。"""

    __slots__ = ("opcodes", "variable_num", "exports", "int_consts", "float_consts",
                 "string_consts", "binarr_consts", "max_return_num", "required_stack_size")

    def __init__(self):
        self.opcodes: list[int] = []       # 指令与操作数混排，int16 范围内
        self.variable_num = 0              # 变量数量
        self.exports: dict[str, int] = {}  # 导出变量名 → 槽位
        self.int_consts: list[int] = []
        self.float_consts: list[float] = []
        self.string_consts: list[str] = []
        self.binarr_consts: list[bytes] = []
        self.max_return_num = 0            # return 语句最大返回值数量
        self.required_stack_size = 0

    def clear(self) -> None:
        """清空成「刚构造」的状态（编译器在每次 Compile 开头调用）。"""
        self.opcodes.clear()
        self.int_consts.clear()
        self.float_consts.clear()
        self.string_consts.clear()
        self.binarr_consts.clear()
        self.exports.clear()
        self.variable_num = 0
        self.max_return_num = 0
        self.required_stack_size = 0

    def to_map(self) -> dict:
        """序列化成普通 dict（键名与 GDScript 的 ``to_map`` 一致）。"""
        return {
            "c": list(self.opcodes),
            "i": [str(x) for x in self.int_consts],
            "f": list(self.float_consts),
            "s": list(self.string_consts),
            "ba": [list(b) for b in self.binarr_consts],
            "vn": self.variable_num,
            "e": dict(self.exports),
            "sc": self.required_stack_size,
            "mr": self.max_return_num,
        }
