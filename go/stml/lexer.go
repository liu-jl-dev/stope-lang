package stml

import (
	"strconv"
	"strings"
)

// STML 词法器。四态状态机（Xml / Text / Nevext / Stope）—— 端口 cpp/src/stml_lexer.cpp。
//
// 三条最容易写错的规则：
//  1. Text / Nevext / Stope 扫完一段后必须把 state 交还 Xml；
//  2. 输入耗尽后永远返回 Eof，与当前状态无关 —— 而且此时不改 state；
//  3. 任何异常路径都要消费字符，否则调用方的 while 会死循环。

var whiteSet = map[byte]bool{
	' ': true, '\t': true, '\v': true, '\f': true, '\r': true, '\n': true,
}

// HasLexeme 只有这几类 token 的 lexeme 是「双方实现都提供」的；
// 标点与 Eof 的 lexeme 属实现自定，计划 §2.2 不断言。
func HasLexeme(t TokenType) bool {
	switch t {
	case TWord, TString, TText, TNevextSrc, TStopeSrc:
		return true
	}
	return false
}

func isAlphaCh(c byte) bool {
	return ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z')
}

func isDigitCh(c byte) bool { return '0' <= c && c <= '9' }

func isWordBegin(c byte) bool { return isAlphaCh(c) || c == '_' || c == ':' }

func isWordChar(c byte) bool {
	return isWordBegin(c) || isDigitCh(c) || c == '-'
}

// TrimTrailingWS 去掉尾部空白（B-8：内容段尾部的空白不计入 lexeme）。
func TrimTrailingWS(s string) string {
	n := len(s)
	for n > 0 && whiteSet[s[n-1]] {
		n--
	}
	return s[:n]
}

// Lexer 按需产出 token。Errors 累积词法错误（与语法错误分开报）。
type Lexer struct {
	State  LexerState
	Src    string // 未消费的剩余输入
	Line   int
	Errors []string
}

// NewLexer 构造。state 可为 XmlState / TextState / NevextState / StopeState。
func NewLexer(source string, state LexerState) *Lexer {
	return &Lexer{State: state, Src: source, Line: 1}
}

// NextToken 取下一个 token。先跳空白、再定 token.line。
func (lx *Lexer) NextToken() Token {
	var token Token
	lx.skipWS()
	token.Line = lx.Line
	if lx.Src == "" {
		token.Type = TEof
	} else if lx.State == XmlState {
		lx.scanXml(&token)
	} else if lx.State == TextState {
		token.Set(TText, lx.scanContent(modeText))
		lx.State = XmlState
	} else if lx.State == NevextState {
		token.Set(TNevextSrc, lx.scanContent(modeNevext))
		lx.State = XmlState
	} else { // StopeState
		token.Set(TStopeSrc, lx.scanContent(modeStope))
		lx.State = XmlState
	}
	return token
}

// ============================ Xml 状态 ============================

func (lx *Lexer) scanXml(token *Token) {
	if strings.HasPrefix(lx.Src, "</") {
		token.Set(TCLAngle, "</")
		lx.Src = lx.Src[2:]
	} else if strings.HasPrefix(lx.Src, "/>") {
		token.Set(TCRAngle, "/>")
		lx.Src = lx.Src[2:]
	} else if lx.Src[0] == '<' {
		token.Set(TLAngle, "<")
		lx.Src = lx.Src[1:]
	} else if lx.Src[0] == '>' {
		token.Set(TRAngle, ">")
		lx.Src = lx.Src[1:]
	} else if lx.Src[0] == '=' {
		token.Set(TEQ, "=")
		lx.Src = lx.Src[1:]
	} else if lx.Src[0] == '"' || lx.Src[0] == '\'' {
		lx.scanString(token)
	} else if isWordBegin(lx.Src[0]) {
		token.Set(TWord, lx.scanWord())
	} else {
		lx.error("unexpected character. ")
		token.Set(TInvalid, "")
		lx.Src = lx.Src[1:] // 必须消费，否则死循环
	}
}

func (lx *Lexer) scanString(token *Token) {
	// Xml 属性串：不转义（\" 里的引号就是结束引号，TD-9）。
	// 未闭合时报错（文案比代码段那条少一个句号，TD-8）并吃掉剩余全部输入。
	token.Type = TString
	quote := lx.Src[0]
	lx.Src = lx.Src[1:] // 跳过开头的引号
	n := 0
	for {
		if n >= len(lx.Src) {
			lx.error("unclosed string literal")
			lx.Src = ""
			token.Type = TInvalid
			return
		}
		if lx.Src[n] == quote {
			token.Lexeme = lx.Src[:n]
			lx.Src = lx.Src[n+1:]
			return
		}
		if lx.Src[n] == '\n' {
			lx.Line++
		}
		n++
	}
}

func (lx *Lexer) scanWord() string {
	end := 1
	for end < len(lx.Src) && isWordChar(lx.Src[end]) {
		end++
	}
	s := lx.Src[:end]
	lx.Src = lx.Src[end:]
	return s
}

// ============================ 内容三态 ============================

type contentMode int

const (
	modeText   contentMode = iota
	modeNevext
	modeStope
)

func (lx *Lexer) scanContent(mode contentMode) string {
	// Text / Nevext / Stope 三个扫描函数同构：从当前位置一路吃到 </ 或输入耗尽，
	// 尾部空白不计入 lexeme（B-8）。text 只认 </（<b/> 会被整段当文本吃掉，B-2）；
	// 两个代码段还把引号串与注释整段跳过，其中的 </ 不算结束标签（B-3）。
	begin := lx.Src
	for lx.Src != "" {
		if strings.HasPrefix(lx.Src, "</") {
			break
		}
		if mode != modeText {
			ch := lx.Src[0]
			if ch == '\'' || ch == '"' {
				// Nevext：两种引号都转义；Stope：双引号转义、单引号（BinArr）不转义
				lx.scanCodeStr(ch, mode == modeNevext || ch == '"')
				continue
			}
			if strings.HasPrefix(lx.Src, "//") {
				lx.skipSinglelineComment()
				continue
			}
			if strings.HasPrefix(lx.Src, "/*") {
				lx.skipMultilineComment()
				continue
			}
		}
		if lx.Src[0] == '\n' {
			lx.Line++
		}
		lx.Src = lx.Src[1:]
	}
	return TrimTrailingWS(begin[:len(begin)-len(lx.Src)])
}

func (lx *Lexer) scanCodeStr(quote byte, escapes bool) {
	// 代码段里的引号串，含两侧引号。到输入末尾仍未闭合时报错并吃掉剩余全部输入
	//（保证调用方不会死循环）；报的是起始行，不是当前行。
	beginLine := lx.Line
	lx.Src = lx.Src[1:] // 跳过开头的引号
	for {
		if lx.Src == "" {
			lx.errorAt(beginLine, "unclosed string literal. ")
			return
		}
		c := lx.Src[0]
		lx.Src = lx.Src[1:]
		if escapes && c == '\\' { // 转义：连同紧跟的一个字符一起吃掉
			if lx.Src == "" {
				lx.errorAt(beginLine, "unclosed string literal. ")
				return
			}
			if lx.Src[0] == '\n' {
				lx.Line++
			}
			lx.Src = lx.Src[1:]
		} else if c == quote {
			return
		} else if c == '\n' {
			lx.Line++
		}
	}
}

func (lx *Lexer) skipSinglelineComment() {
	// // 到行尾；换行符一并消费并推进行号。
	lx.Src = lx.Src[2:]
	for lx.Src != "" {
		c := lx.Src[0]
		lx.Src = lx.Src[1:]
		if c == '\n' {
			lx.Line++
			return
		}
	}
}

func (lx *Lexer) skipMultilineComment() {
	// /* 到 */。未闭合不是错误，一直吃到输入末尾。
	lx.Src = lx.Src[2:]
	for lx.Src != "" {
		if strings.HasPrefix(lx.Src, "*/") {
			lx.Src = lx.Src[2:]
			return
		}
		if lx.Src[0] == '\n' {
			lx.Line++
		}
		lx.Src = lx.Src[1:]
	}
}

// ============================ 空白与注释 ============================

func (lx *Lexer) skipWS() {
	for lx.Src != "" {
		ch := lx.Src[0]
		if whiteSet[ch] {
			if ch == '\n' {
				lx.Line++
			}
			lx.Src = lx.Src[1:]
		} else if lx.State == XmlState && strings.HasPrefix(lx.Src, "<!--") {
			// <!-- 只在 Xml 状态是注释；Nevext / Stope 里的 '<' 是小于号
			lx.skipXmlComment()
		} else {
			return
		}
	}
}

func (lx *Lexer) skipXmlComment() {
	lx.Src = lx.Src[4:]
	for lx.Src != "" {
		if strings.HasPrefix(lx.Src, "-->") {
			lx.Src = lx.Src[3:]
			return
		}
		if lx.Src[0] == '\n' {
			lx.Line++
		}
		lx.Src = lx.Src[1:]
	}
}

// ============================ 报错 ============================

func (lx *Lexer) error(msg string) {
	lx.Errors = append(lx.Errors, "line "+strconv.Itoa(lx.Line)+": "+msg)
}

func (lx *Lexer) errorAt(line int, msg string) {
	// 指定行号报错：跨行的字面量 / 注释报的是起始行，不是当前行。
	lx.Errors = append(lx.Errors, "line "+strconv.Itoa(line)+": "+msg)
}
