"""二进制数组字面量【内容】的解析 —— 端口 ``cpp/src/parse_binarr.cpp``。

规则见 ``docs/zh-cn/syntax-reference.md`` §2.6，与 C++ 逐条一致：

* ``b/B o/O d/D x/X`` 前缀选进制；**没有前缀按 16**（首字符就是数据本身，不能被吃掉）；
* 每段数字产生一个字节，依次追加；段内可含 ``_``，段之间用空白分隔；
* 超出一个字节的值**静默截断**到低 8 位且不报错：``'d 300'`` → ``0x2C``；
* 出现该进制不允许的字符（如 ``'x zz'``）→ 返回 ``Result.Error``，由上层报
  ``invalid binary array. ``；
* 空内容合法，得到零长数组；只有前缀没有数据（如 ``'b'``）同样是零长数组。

⚠ 岔路：``'b 0100 0001'`` 是**两个**字节 ``04 01``，不是 ``0x41`` —— 二进制前缀下
要写满 8 位。

调用方式与 C++ 的 ``parseBinaryArray(input, output) -> Result`` 同形::

    buf = bytearray()
    if BinaryArrayParser().parse_binary_array("x 41 42", buf) != Result.Success: ...
"""

from .common import Result

_INT_MAX = 2147483647

_WS = " \t\n\r\v\f"


def _is_ws(c: str) -> bool:
    return c in _WS


def _digit_of(c: str, base: int) -> int:
    """返回该进制下的数值；不是该进制的字符返回 -1。"""
    code = ord(c)
    if 48 <= code <= 57:
        d = code - 48
    elif 97 <= code <= 102:
        d = code - 97 + 10
    elif 65 <= code <= 70:
        d = code - 65 + 10
    else:
        d = -1
    return d if 0 <= d < base else -1


class BinaryArrayParser:
    """解析 ``'...'`` 里的内容（不含单引号），字节按顺序 append 进 ``output``。"""

    __slots__ = ("input", "pos")

    def __init__(self):
        self.input = ""
        self.pos = 0

    def parse_binary_array(self, input_src: str, output: bytearray) -> Result:
        self.input = input_src
        self.pos = 0
        self.skip_ws()
        if self.eof():
            return Result.Success
        c = self.input[self.pos]
        base = 16
        if c in ("b", "B"):
            self.pos += 1
            base = 2
        elif c in ("o", "O"):
            self.pos += 1
            base = 8
        elif c in ("d", "D"):
            self.pos += 1
            base = 10
        elif c in ("x", "X"):
            self.pos += 1
            base = 16
        return self.parse_by_base(output, base)

    def parse_by_base(self, output: bytearray, base: int) -> Result:
        self.skip_ws()
        while not self.eof():
            ok, value = self.parse_integer(base)
            if not ok:
                return Result.Error
            output.append(value & 0xFF)  # 超 0xFF 静默截断，等价于 C++ 的 static_cast<char>
            self.skip_ws()
        return Result.Success

    def parse_integer(self, base: int) -> tuple[bool, int]:
        """空段（只有下划线）与超出 int 范围的段都判失败 —— 与 ``std::stoi`` 抛异常等价。"""
        n = 0
        any_digit = False
        while not self.eof():
            c = self.input[self.pos]
            if _is_ws(c):
                break
            d = _digit_of(c, base)
            if d >= 0:
                if n > (_INT_MAX - d) // base:
                    return False, 0
                n = n * base + d
                self.pos += 1
                any_digit = True
            elif c == "_":
                self.pos += 1
            else:
                self.pos += 1
                return False, 0
        if not any_digit:
            return False, 0
        return True, n

    def eof(self) -> bool:
        return self.pos >= len(self.input)

    def skip_ws(self) -> None:
        while not self.eof() and _is_ws(self.input[self.pos]):
            self.pos += 1
