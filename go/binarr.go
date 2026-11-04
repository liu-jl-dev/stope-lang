package stope

// 二进制数组字面量【内容】的解析 —— 端口 cpp/src/parse_binarr.cpp。
//
//   - b/B o/O d/D x/X 前缀选进制；没有前缀按 16；
//   - 每段数字产生一个字节；段内可含 _，段之间用空白分隔；
//   - 超一个字节的值静默截断到低 8 位且不报错；
//   - 该进制不允许的字符 → RError（上层报 invalid binary array. ）；
//   - 空内容 / 只有前缀没有数据都是零长数组。
//
// ⚠ 'b 0100 0001' 是两个字节 04 01，不是 0x41 —— 二进制前缀下要写满 8 位。

const intMax32 = 2147483647

func isByteWS(c byte) bool {
	switch c {
	case ' ', '\t', '\n', '\r', '\v', '\f':
		return true
	}
	return false
}

func digitOf(c byte, base int) int {
	var d int
	switch {
	case '0' <= c && c <= '9':
		d = int(c - '0')
	case 'a' <= c && c <= 'f':
		d = int(c-'a') + 10
	case 'A' <= c && c <= 'F':
		d = int(c-'A') + 10
	default:
		return -1
	}
	if 0 <= d && d < base {
		return d
	}
	return -1
}

// BinaryArrayParser 解析 '...' 里的内容（不含单引号）。
type BinaryArrayParser struct {
	input string
	pos   int
}

// ParseBinaryArray 解析内容，字节按顺序 append 进 output。
func (p *BinaryArrayParser) ParseBinaryArray(input string, output *[]byte) Result {
	p.input = input
	p.pos = 0
	p.skipWS()
	if p.eof() {
		return RSuccess
	}
	base := 16
	switch c := p.input[p.pos]; c {
	case 'b', 'B':
		p.pos++
		base = 2
	case 'o', 'O':
		p.pos++
		base = 8
	case 'd', 'D':
		p.pos++
		base = 10
	case 'x', 'X':
		p.pos++
		base = 16
	}
	return p.parseByBase(output, base)
}

func (p *BinaryArrayParser) parseByBase(output *[]byte, base int) Result {
	p.skipWS()
	for !p.eof() {
		ok, value := p.parseInteger(base)
		if !ok {
			return RError
		}
		*output = append(*output, byte(value&0xFF)) // 超 0xFF 静默截断
		p.skipWS()
	}
	return RSuccess
}

// parseInteger 空段（只有下划线）与超出 int 范围的段都判失败（等价 std::stoi 抛异常）。
func (p *BinaryArrayParser) parseInteger(base int) (bool, int) {
	n := 0
	anyDigit := false
	for !p.eof() {
		c := p.input[p.pos]
		if isByteWS(c) {
			break
		}
		d := digitOf(c, base)
		if d >= 0 {
			if n > (intMax32-d)/base {
				return false, 0
			}
			n = n*base + d
			p.pos++
			anyDigit = true
		} else if c == '_' {
			p.pos++
		} else {
			p.pos++
			return false, 0
		}
	}
	if !anyDigit {
		return false, 0
	}
	return true, n
}

func (p *BinaryArrayParser) eof() bool { return p.pos >= len(p.input) }

func (p *BinaryArrayParser) skipWS() {
	for !p.eof() && isByteWS(p.input[p.pos]) {
		p.pos++
	}
}
