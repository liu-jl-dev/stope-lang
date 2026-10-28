class_name StopeBinArrParser
# 二进制数组字面量【内容】的解析 —— 端口 cpp/stope/parse_binarr.hpp。
#
# 规则见 docs/zh-cn/syntax-reference.md §2.6，与 C++ 逐条一致：
#   - b/B o/O d/D x/X 前缀选进制；没有前缀按 16（首字符就是数据本身，不能被吃掉）
#   - 每段数字产生一个字节，依次追加；段内可含 '_'，段之间用空白分隔
#   - 超出一个字节的值【静默截断】到低 8 位且不报错：'d 300' -> 0x2C
#   - 出现该进制不允许的字符（如 'x zz'）-> 失败，由上层报 invalid binary array.
#   - 空内容合法，得到零长数组；只有前缀没有数据（如 'b'）同样是零长数组
#
# 注意岔路：'b 0100 0001' 是两个字节 04 01，不是 0x41 —— 二进制前缀下要写满 8 位。

const INT_MAX := 2147483647

var input:String = ''
var pos:int = 0

# 把 text 里的字节追加到 out；返回是否成功。失败时 out 可能已经写入了前半段，
# 调用方负责丢弃（parser 走的是「报错但继续」的路径，与 C++ 一致）。
func parse(text:String, out:PackedByteArray) -> bool:
	input = text
	pos = 0
	skip_ws()
	if eof(): return true
	var c := input[pos]
	var base:int
	if c == 'b' or c == 'B': pos += 1; base = 2
	elif c == 'o' or c == 'O': pos += 1; base = 8
	elif c == 'd' or c == 'D': pos += 1; base = 10
	elif c == 'x' or c == 'X': pos += 1; base = 16
	else: base = 16
	return parse_by_base(out, base)

func parse_by_base(out:PackedByteArray, base:int) -> bool:
	skip_ws()
	while not eof():
		var iv := parse_integer(base)
		if not iv[0]: return false
		out.append(iv[1] & 0xFF)	# 超 0xFF 静默截断，等价于 C++ 的 static_cast<char>
		skip_ws()
	return true

# 返回 [是否成功, 数值]。
# 空段（只有下划线）与超出 int 范围的段都判失败 —— 与 std::stoi 抛异常等价。
func parse_integer(base:int) -> Array:
	var n:int = 0
	var any := false
	while not eof():
		var c := input[pos]
		if is_ws(c): break
		var d := digit_of(c, base)
		if d >= 0:
			if n > (INT_MAX - d) / base: return [false, 0]
			n = n * base + d
			pos += 1
			any = true
		elif c == '_':
			pos += 1
		else:
			pos += 1
			return [false, 0]
	if not any: return [false, 0]
	return [true, n]

func eof() -> bool: return pos >= input.length()
func skip_ws() -> void:
	while not eof() and is_ws(input[pos]): pos += 1

static func is_ws(c:String) -> bool:
	return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\v' or c == '\f'

# 返回该进制下的数值；不是该进制的字符返回 -1
static func digit_of(c:String, base:int) -> int:
	if c >= '0' and c <= '9':
		var d:int = ord(c) - ord('0')
		return d if d < base else -1
	elif c >= 'a' and c <= 'f':
		var da:int = ord(c) - ord('a') + 10
		return da if da < base else -1
	elif c >= 'A' and c <= 'F':
		var dA:int = ord(c) - ord('A') + 10
		return dA if dA < base else -1
	return -1
