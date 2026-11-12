// Package stope 是 Stope 语言的 Go 实现 —— 语言核心层（词法 / 语法 / 常量折叠 /
// 编译 / 反汇编 / Program），与 cpp/src 逐项对齐。STML 在子包 stope/stml，
// 内置参考执行器在子包 stope/basicvm。
//
// 整数一律 int64：Go 规范保证有符号溢出回绕，除法向零截断；
// 浮点走 IEEE（除零得 ±Inf / NaN，math.Pow / math.Mod 与 C 语义一致）。
package stope

import (
	"math"
	"strconv"
	"strings"
	"unicode/utf16"
)

// Result 与 C++ 的 stope::Result、Python 的 common.Result 逐值对应。
type Result int

const (
	RSuccess                     Result = 0
	RError                       Result = 1
	RUnknownError                Result = 2
	RDuplicateWithBuiltinOpcode  Result = 3
)

// Int64Min / Int64Max —— 整数字面量的合法范围。
const (
	Int64Min = math.MinInt64
	Int64Max = math.MaxInt64
)

// IntDiv 向零取整的整除（C++ 的 / 语义）。b 不能为 0（调用方先查）。
// MinInt64 / -1 在 Go 里会 panic，特判为按 64 位回绕的结果。
func IntDiv(a, b int64) int64 {
	if a == math.MinInt64 && b == -1 {
		return math.MinInt64
	}
	return a / b
}

// IntMod 向零取整的余数（C++ 的 % 语义，余数符号跟被除数）。
// MinInt64 % -1 在 Go 里会 panic，特判为 0。
func IntMod(a, b int64) int64 {
	if a == math.MinInt64 && b == -1 {
		return 0
	}
	return a % b
}

// IntPow 整数快速幂，exp >= 0；溢出不检查、按 64 位回绕（Go 的 int64 乘法本身回绕）。
func IntPow(base, exp int64) int64 {
	result := int64(1)
	b, e := base, exp
	for e > 0 {
		if e&1 == 1 {
			result *= b
		}
		e >>= 1
		if e > 0 {
			b *= b
		}
	}
	return result
}

// FDiv IEEE 除法：Go 的浮点除法本身就是 IEEE 语义（x/0 得 ±Inf、0/0 得 NaN），
// 与 C++ 一致；保留这层封装让折叠与 VM 共用同一入口。
func FDiv(a, b float64) float64 { return a / b }

// FMod std::fmod 语义：余数符号跟被除数；b == 0 得 NaN（math.Mod 即 C fmod）。
func FMod(a, b float64) float64 { return math.Mod(a, b) }

// Trunc std::trunc：向零取整但保持浮点；Inf / NaN 原样返回（math.Trunc 即此语义）。
func Trunc(v float64) float64 { return math.Trunc(v) }

// FPow std::pow 语义：负底数 + 非整数指数得 NaN、溢出得 ±Inf、0 ^ 负数得 +Inf。
// math.Pow 即 C pow，语义一致；保留封装与 Python 侧 fpow 对应。
func FPow(a, b float64) float64 { return math.Pow(a, b) }

// IsSpecial NaN / ±Inf —— 这几个值参与折叠时要小心（折叠遇到它们就不折）。
func IsSpecial(v float64) bool {
	return math.IsNaN(v) || math.IsInf(v, 0)
}

// Esc 与 C++ 的 escUtf8 一致：\\ " \n \r \t 转义，非 ASCII 一律变 ?（不是 \uXXXX）。
// 按 UTF-16 码元遍历：非 BMP 字符给出两个 ?（与 C++ 的 u16string 行为一致）。
func Esc(s string) string {
	return escUnits(utf16.Encode([]rune(s)), true, false)
}

// EscLex 词法比对专用转义：比 Esc 多 \v \f、不转义引号、非 ASCII 变 ?
//（对应 C++ 侧打印用的 toUtf8 —— 只做打印映射；与 python/tests/golden.py 的
// esc_lex 一致）。
func EscLex(s string) string {
	var b strings.Builder
	for _, ch := range s {
		switch ch {
		case '\\':
			b.WriteString("\\\\")
		case '\n':
			b.WriteString("\\n")
		case '\r':
			b.WriteString("\\r")
		case '\t':
			b.WriteString("\\t")
		case '\v':
			b.WriteString("\\v")
		case '\f':
			b.WriteString("\\f")
		default:
			if ch < 128 {
				b.WriteRune(ch)
			} else {
				b.WriteByte('?')
			}
		}
	}
	return b.String()
}

func escUnits(units []uint16, escapeQuote bool, keepNonASCII bool) string {
	var b strings.Builder
	for _, c := range units {
		switch {
		case c == '\\':
			b.WriteString("\\\\")
		case c == '"' && escapeQuote:
			b.WriteString("\\\"")
		case c == '\n':
			b.WriteString("\\n")
		case c == '\r':
			b.WriteString("\\r")
		case c == '\t':
			b.WriteString("\\t")
		case c == '\v' && !escapeQuote:
			b.WriteString("\\v")
		case c == '\f' && !escapeQuote:
			b.WriteString("\\f")
		case c < 128:
			b.WriteByte(byte(c))
		default:
			if keepNonASCII {
				b.WriteRune(rune(c))
			} else {
				b.WriteByte('?')
			}
		}
	}
	return b.String()
}

// FmtG printf("%g") 的忠实实现（Go 的 %g 用最短表示，与 C 的默认 6 位有效数字不同，
// 必须自己实现）。nan / inf / -inf 小写；-0.0 打成 "-0"。
func FmtG(v float64) string {
	if math.IsNaN(v) {
		return "nan"
	}
	if math.IsInf(v, 1) {
		return "inf"
	}
	if math.IsInf(v, -1) {
		return "-inf"
	}
	if v == 0 {
		if math.Signbit(v) {
			return "-0"
		}
		return "0"
	}
	const prec = 6
	// 先用 %e（精度 prec-1）拿到十进制指数
	se := strconv.FormatFloat(v, 'e', prec-1, 64)
	eIdx := strings.IndexByte(se, 'e')
	exp, _ := strconv.Atoi(se[eIdx+1:])
	if exp < -4 || exp >= prec {
		mant := stripTrailingZeros(se[:eIdx])
		return mant + "e" + expFormat(exp)
	}
	fp := prec - 1 - exp
	if fp < 0 {
		fp = 0
	}
	return stripTrailingZeros(strconv.FormatFloat(v, 'f', fp, 64))
}

func stripTrailingZeros(s string) string {
	if !strings.ContainsRune(s, '.') {
		return s
	}
	s = strings.TrimRight(s, "0")
	s = strings.TrimSuffix(s, ".")
	return s
}

func expFormat(exp int) string {
	sign := "+"
	if exp < 0 {
		sign = "-"
		exp = -exp
	}
	if exp < 10 {
		return sign + "0" + strconv.Itoa(exp)
	}
	return sign + strconv.Itoa(exp)
}

// FmtBytes 二进制数组 → "01,0a,ff"（小写两位十六进制，逗号分隔）。
func FmtBytes(b []byte) string {
	var parts []string
	for _, x := range b {
		parts = append(parts, hex2(x))
	}
	return strings.Join(parts, ",")
}

const hexDigits = "0123456789abcdef"

func hex2(x byte) string {
	return string([]byte{hexDigits[x>>4], hexDigits[x&0xf]})
}

// SeqSize 字符串按 UTF-16 码元计长度（与 C++ 的 u16string 一致，不是 rune 也不是字节）。
func SeqSize(s string) int {
	n := 0
	for _, r := range s {
		if r > 0xFFFF {
			n += 2
		} else {
			n++
		}
	}
	return n
}
