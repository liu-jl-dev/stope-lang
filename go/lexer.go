package stope

import (
	"strconv"
	"strings"
)

// 词法分析器。与 cpp/src/lexer.cpp、python/stope/lexer.py 逐项对齐：
// 同样的错误文案、同样的错误恢复（报错后继续产 token，不中断）。
// 源码按字节扫描（结构字符全是 ASCII，字符串内容按字节透传）。

var keywords = map[string]TokenType{
	"idiv": TIDiv, "not": TNot,
	"and": TAnd, "or": TOr,
	"if": TIf, "elif": TElif,
	"else": TElse, "let": TLet,
	"return": TReturn, "while": TWhile,
	"break": TBreak, "continue": TContinue,
	"null": TNull, "false": TFalse,
	"true": TTrue, "args": TArgs,
	"argc": TArgc, "export": TExport,
}

var twoCharOps = map[string]TokenType{
	"==": TEQ, "!=": TNE,
	"<=": TLE, ">=": TGE,
	"&&": TAnd, "||": TOr,
}

var oneCharOps = map[byte]TokenType{
	',': TComma, ';': TSemi,
	'(': TLParen, ')': TRParen,
	'[': TLBrack, ']': TRBrack,
	'{': TLBrace, '}': TRBrace,
	'+': TAdd, '-': TSub,
	'*': TMul, '/': TDiv,
	'%': TMod, '^': TPow,
	'=': TAssign, '!': TNot,
	'<': TLT, '>': TGT,
}

func isWhite(c byte) bool {
	return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f'
}

func isDigit(c byte) bool { return '0' <= c && c <= '9' }

func isAlpha(c byte) bool {
	return ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z')
}

func isIdentBegin(c byte) bool { return isAlpha(c) || c == '_' }

func isIdentChar(c byte) bool { return isIdentBegin(c) || isDigit(c) }

var escapeMap = map[byte]byte{
	'\\': '\\', '\'': '\'', '"': '"',
	'b': '\b', 'r': '\r', 't': '\t',
	'v': '\v', 'n': '\n', 'f': '\f',
}

// numberBase 按字面量前缀决定基数，并给出前缀长度。
func numberBase(s string) (base, prefixLen int) {
	if len(s) >= 2 && s[0] == '0' {
		switch s[1] {
		case 'b', 'B':
			return 2, 2
		case 'o', 'O':
			return 8, 2
		case 'x', 'X':
			return 16, 2
		}
	}
	return 10, 0
}

func digitsMatch(s string, base int) bool {
	if len(s) == 0 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		var ok bool
		switch {
		case '0' <= c && c <= '9':
			ok = int(c-'0') < base
		case 'a' <= c && c <= 'f':
			ok = int(c-'a'+10) < base
		case 'A' <= c && c <= 'F':
			ok = int(c-'A'+10) < base
		}
		if !ok {
			return false
		}
	}
	return true
}

// floatParsedMatch 对齐 Python 的 _RE_FLOAT：
// (?:[0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$
func floatParsedMatch(s string) bool {
	i := 0
	n := len(s)
	digits := func() int {
		c := 0
		for i < n && '0' <= s[i] && s[i] <= '9' {
			i++
			c++
		}
		return c
	}
	if digits() > 0 {
		if i < n && s[i] == '.' {
			i++
			digits()
		}
	} else if i < n && s[i] == '.' {
		i++
		if digits() == 0 {
			return false
		}
	} else {
		return false
	}
	if i < n && (s[i] == 'e' || s[i] == 'E') {
		i++
		if i < n && (s[i] == '+' || s[i] == '-') {
			i++
		}
		if digits() == 0 {
			return false
		}
	}
	return i == n
}

func hasNonzeroDigit(s string) bool {
	return strings.ContainsAny(s, "123456789")
}

// Lexer Lexer(src) → 反复调 NextToken 直到 TEof。
type Lexer struct {
	Input  string
	Pos    int
	Line   int
	Errors []string
}

// NewLexer 构造并 Reset。
func NewLexer(src string) *Lexer {
	lx := &Lexer{}
	lx.Reset(src)
	return lx
}

func (lx *Lexer) Reset(src string) {
	lx.Input = src
	lx.Pos = 0
	lx.Line = 1
	lx.Errors = nil
}

// rest 返回未消费的输入。
func (lx *Lexer) rest() string { return lx.Input[lx.Pos:] }

// NextToken 取下一个 token。custom 是 CustomOpcodeConfig，可为 nil。
// 不抛异常：出错只往 Errors 记一条，然后按最长可行前缀产出 Invalid token 继续扫。
func (lx *Lexer) NextToken(custom *CustomOpcodeConfig) Token {
	lx.skipWS()
	token := Token{Line: lx.Line, Type: TEof}
	r := lx.rest()
	if r == "" {
		return token
	}
	c := r[0]
	switch {
	case isDigit(c) || c == '.':
		lx.scanNumber(&token)
	case isIdentBegin(c):
		lx.scanIdent(&token)
		lx.analyzeIdent(&token, custom)
	case c == '\'':
		lx.scanBinarr(&token)
	case c == '"':
		lx.scanString(&token)
	default:
		lx.scanPunct(&token, c)
	}
	return token
}

// ---------- 数字 ----------

func (lx *Lexer) scanNumber(token *Token) {
	r := lx.rest()
	if strings.HasPrefix(r, "0b") || strings.HasPrefix(r, "0B") {
		token.Type = TInteger
		token.Lexeme = lx.matchRadixInteger(2)
	} else if strings.HasPrefix(r, "0o") || strings.HasPrefix(r, "0O") {
		token.Type = TInteger
		token.Lexeme = lx.matchRadixInteger(8)
	} else if strings.HasPrefix(r, "0x") || strings.HasPrefix(r, "0X") {
		token.Type = TInteger
		token.Lexeme = lx.matchRadixInteger(16)
	} else if r[0] == '.' {
		// .[_0-9]*([eE][+-]?[0-9]+)?
		token.Type = TFloat
		lx.Pos++ // .
		lexeme := "." + lx.matchDecDigitsOpt()
		lexeme += lx.scanExponent()
		token.Lexeme = lexeme
	} else {
		token.Type = TInteger
		lexeme := lx.matchDecDigits()
		if lx.rest() != "" && lx.rest()[0] == '.' {
			token.Type = TFloat
			lx.Pos++
			lexeme += "." + lx.matchDecDigitsOpt()
		}
		exp := lx.scanExponent()
		if exp != "" {
			token.Type = TFloat
		}
		token.Lexeme = lexeme + exp
	}
	token.Parsed = strings.ReplaceAll(token.Lexeme, "_", "")
	lx.getNumberValue(token)
}

// matchDecDigits 匹配 [_0-9]+（整数部分，至少一位）。
func (lx *Lexer) matchDecDigits() string {
	r := lx.rest()
	i := 0
	for i < len(r) && (r[i] == '_' || isDigit(r[i])) {
		i++
	}
	lx.Pos += i
	return r[:i]
}

// matchDecDigitsOpt 匹配 [_0-9]*。
func (lx *Lexer) matchDecDigitsOpt() string {
	r := lx.rest()
	i := 0
	for i < len(r) && (r[i] == '_' || isDigit(r[i])) {
		i++
	}
	lx.Pos += i
	return r[:i]
}

func (lx *Lexer) scanExponent() string {
	r := lx.rest()
	if r == "" || (r[0] != 'e' && r[0] != 'E') {
		return ""
	}
	// [eE][+-]?[0-9]*
	i := 1
	if i < len(r) && (r[i] == '+' || r[i] == '-') {
		i++
	}
	for i < len(r) && isDigit(r[i]) {
		i++
	}
	text := r[:i]
	lx.Pos += i
	return text
}

// matchRadixInteger 取走 0b/0o/0x 前缀 + [_digits]+；没有数字时只取前缀（让后面报错）。
func (lx *Lexer) matchRadixInteger(base int) string {
	r := lx.rest()
	i := 2
	for i < len(r) {
		c := r[i]
		ok := c == '_'
		if !ok {
			switch base {
			case 2:
				ok = c == '0' || c == '1'
			case 8:
				ok = '0' <= c && c <= '7'
			case 16:
				ok = isDigit(c) || ('a' <= c && c <= 'f') || ('A' <= c && c <= 'F')
			}
		}
		if !ok {
			break
		}
		i++
	}
	text := r[:i]
	lx.Pos += i
	return text
}

func (lx *Lexer) getNumberValue(token *Token) {
	if token.Type == TInteger {
		base, prefixLen := numberBase(token.Parsed)
		digits := token.Parsed[prefixLen:]
		if !digitsMatch(digits, base) {
			lx.error("invalid integer. ")
			token.Type = TInvalid
			return
		}
		value, err := strconv.ParseInt(digits, base, 64)
		if err != nil {
			lx.error("invalid integer. ")
			token.Type = TInvalid
			return
		}
		token.IVal = value
		token.HasVal = true
	} else if token.Type == TFloat {
		if !floatParsedMatch(token.Parsed) { // 如 "1e"、"."
			lx.error("invalid float. ")
			token.Type = TInvalid
			return
		}
		value, err := strconv.ParseFloat(token.Parsed, 64)
		// C++ 用 stod：上溢 / 下溢都算错。ParseFloat 的 ErrRange 恰好覆盖这两类
		//（1e999 → Inf、1e-999 → 0）；再加一道与 Python 相同的兜底判断。
		if err != nil || value != value || value > 1.7976931348623157e308 || value < -1.7976931348623157e308 ||
			(value == 0.0 && hasNonzeroDigit(token.Parsed)) {
			lx.error("invalid float. ")
			token.Type = TInvalid
			return
		}
		token.FVal = value
		token.HasVal = true
	}
}

// ---------- 序列 / 字符串 ----------

func (lx *Lexer) scanBinarr(token *Token) {
	// '...' 到下一个 ' 为止，中间可以换行（换行计入 line）
	token.Type = TBinArr
	lx.Pos++ // 跳过开头的 '
	r := lx.rest()
	end := strings.IndexByte(r, '\'')
	if end < 0 {
		lx.error("unclosed binary array. ")
		token.Type = TInvalid
		token.Lexeme = r
		lx.Line += strings.Count(r, "\n")
		lx.Pos = len(lx.Input)
		return
	}
	token.Lexeme = r[:end]
	lx.Line += strings.Count(r[:end], "\n")
	lx.Pos += end + 1
}

func (lx *Lexer) scanString(token *Token) {
	// ⚠ 与 C++/Python 一致：字符串体内**不**计换行（line 不变）
	token.Type = TString
	lx.Pos++ // 跳过开头的 "
	r := lx.rest()
	// 主体：普通字符或转义对，遇到单独的 " 停下；末尾孤立的 \ 不属于 body
	i := 0
	for i < len(r) {
		if r[i] == '"' {
			break
		}
		if r[i] == '\\' {
			if i+1 >= len(r) {
				break
			}
			i += 2
		} else {
			i++
		}
	}
	if i >= len(r) || r[i] != '"' { // 没扫到闭合的 "
		lx.error("unclosed string literal. ")
		token.Type = TInvalid
		token.Lexeme = r[:i]
		lx.Pos = len(lx.Input)
		return
	}
	token.Lexeme = r[:i]
	lx.Pos += i + 1 // 跳过结尾的 "
	lx.escapeString(token)
}

func (lx *Lexer) escapeString(token *Token) {
	// 处理转义序列；遇到非法转义就报错并停下（已解析的部分保留）
	var b strings.Builder
	body := token.Lexeme
	i := 0
	n := len(body)
	for i < n {
		ch := body[i]
		if ch == '\\' {
			i++
			if i >= n { // 末尾一个孤立的 \
				lx.error("invalid escape character. ")
				break
			}
			c, ok := escapeMap[body[i]]
			if !ok {
				lx.error("invalid escape character. ")
				break
			}
			b.WriteByte(c)
			i++
		} else {
			b.WriteByte(ch)
			i++
		}
	}
	token.Parsed = b.String()
}

// ---------- 标识符 ----------

func (lx *Lexer) scanIdent(token *Token) {
	// ^[a-zA-Z_][a-zA-Z0-9_]*(:[a-zA-Z_][a-zA-Z0-9_]*)*，冒号两侧允许空白与注释
	token.Type = TIdent
	var src strings.Builder
	parsed := lx.matchIdentHead()
	src.WriteString(parsed)
	for {
		src.WriteString(lx.skipWSReturningSkipped()) // 冒号之前的空白与注释
		r := lx.rest()
		if r == "" || r[0] != ':' {
			break
		}
		src.WriteByte(':')
		parsed += ":"
		lx.Pos++
		src.WriteString(lx.skipWSReturningSkipped()) // 冒号之后的空白与注释
		seg := lx.matchIdentHead()
		if seg == "" { // 冒号后面不是标识符
			lx.error("unclosed identifier. ")
			token.Type = TInvalid
			break
		}
		src.WriteString(seg)
		parsed += seg
	}
	token.Lexeme = src.String()
	token.Parsed = parsed
}

func (lx *Lexer) matchIdentHead() string {
	r := lx.rest()
	if r == "" || !isIdentBegin(r[0]) {
		return ""
	}
	i := 1
	for i < len(r) && isIdentChar(r[i]) {
		i++
	}
	lx.Pos += i
	return r[:i]
}

func (lx *Lexer) analyzeIdent(token *Token, custom *CustomOpcodeConfig) {
	if token.Type == TInvalid {
		return
	}
	if kw, ok := keywords[token.Parsed]; ok {
		token.Type = kw
	} else if custom != nil {
		if _, ok := custom.Opcodes[token.Parsed]; ok {
			token.Type = TCustom
		}
	}
}

// ---------- 标点 / 空白 ----------

func (lx *Lexer) scanPunct(token *Token, c byte) {
	// 先按两字符查表（== != <= >= && ||），再按单字符查表
	r := lx.rest()
	if len(r) >= 2 {
		if two, ok := twoCharOps[r[:2]]; ok {
			token.Type = two
			token.Lexeme = r[:2]
			lx.Pos += 2
			return
		}
	}
	one, ok := oneCharOps[c]
	if !ok {
		token.Type = TInvalid
	} else {
		token.Type = one
	}
	token.Lexeme = string(c)
	lx.Pos++
	if !ok {
		lx.error("unknown token. ")
	}
}

func (lx *Lexer) skipWS() {
	for {
		r := lx.rest()
		if r == "" {
			return
		}
		c := r[0]
		if isWhite(c) {
			if c == '\n' {
				lx.Line++
			}
			lx.Pos++
		} else if strings.HasPrefix(r, "//") { // 单行注释
			pos := strings.IndexByte(r, '\n')
			if pos < 0 { // 直接到字符串结尾
				lx.Pos = len(lx.Input)
			} else {
				lx.Pos += pos + 1
				lx.Line++
			}
		} else if strings.HasPrefix(r, "/*") { // 多行注释
			lx.skipMultilineComment()
		} else {
			return
		}
	}
}

func (lx *Lexer) skipWSReturningSkipped() string {
	before := lx.rest()
	lx.skipWS()
	return before[:len(before)-len(lx.rest())]
}

func (lx *Lexer) skipMultilineComment() {
	lx.Pos += 2 // 跳过 /*
	for {
		r := lx.rest()
		if r == "" {
			return
		}
		if strings.HasPrefix(r, "*/") {
			lx.Pos += 2
			return
		}
		if r[0] == '\n' {
			lx.Line++
		}
		lx.Pos++
	}
}

func (lx *Lexer) error(msg string) {
	lx.Errors = append(lx.Errors, "line "+strconv.Itoa(lx.Line)+": "+msg)
}
