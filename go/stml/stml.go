// Package stml 是 STML 标记语言的 Go 实现 —— 四态词法器 + 语法解析器，
// 端口 cpp/src/stml_lexer.cpp 与 cpp/src/stml_parser.cpp。
package stml

// TokenType 12 项，与 C++ 的 STML::TokenType 值和名字都一样（顺序不能改）。
type TokenType int

const (
	TInvalid TokenType = iota
	TEof
	TLAngle   // <
	TRAngle   // >
	TCLAngle  // </
	TCRAngle  // />
	TEQ       // =
	TWord     // ^[a-zA-Z_:][a-zA-Z0-9_:-]*$（不含 '.'）
	TString   // "" '' —— Xml 属性串，不转义
	TText     // 元素内普通文本
	TNevextSrc // Nevext 代码
	TStopeSrc  // Stope 代码
)

// tokenTypeNames 下标即编号（打印类型名用 TypeName）。
var tokenTypeNames = []string{
	"Invalid", "Eof", "LAngle", "RAngle", "CLAngle", "CRAngle",
	"EQ", "Word", "String", "Text", "NevextSrc", "StopeSrc",
}

// TypeName 类型名 —— 与 C++ 的 stmlTokenName 一致。
func TypeName(t TokenType) string {
	if t < 0 || int(t) >= len(tokenTypeNames) {
		return "?"
	}
	return tokenTypeNames[t]
}

// LexerState 词法四态。扫完一段 Text / Nevext / Stope 后必须交还 Xml。
type LexerState int

const (
	XmlState    LexerState = 0
	TextState   LexerState = 1
	NevextState LexerState = 2
	StopeState  LexerState = 3
)

// Token 一个词法单元。Lexeme 是输入的子串。
type Token struct {
	Type   TokenType
	Line   int
	Lexeme string
}

// Set 一次赋值。
func (t *Token) Set(typ TokenType, lexeme string) {
	t.Type = typ
	t.Lexeme = lexeme
}

// AttrEntry 一条属性（保序）。
type AttrEntry struct {
	Name  string
	Value string
}

// Element 一个元素。Children 与 Text 互斥；Text 只有一段，不拼接。
type Element struct {
	Line int // 开始标签的行号
	// TextLine text / 代码段第一个字符的物理行号；元素没有内容时为 -1。
	// 词法器切内容前已跳过前导空白（含换行），所以这是【内容】的首行而不是标签行。
	TextLine    int
	Tag         string
	Attrs       []AttrEntry // 属性；无值属性的值是空串（同名保留先出现的）
	SelfClosing bool
	Children    []*Element
	Text        string
}

// NewElement 构造（line = -1, textLine = -1）。
func NewElement() *Element {
	return &Element{Line: -1, TextLine: -1}
}

// Attr 按名字查属性值；不存在返回 ""（与无值属性同形，需要区分时用 HasAttr）。
func (e *Element) Attr(name string) string {
	for _, a := range e.Attrs {
		if a.Name == name {
			return a.Value
		}
	}
	return ""
}

// HasAttr 属性是否存在。
func (e *Element) HasAttr(name string) bool {
	for _, a := range e.Attrs {
		if a.Name == name {
			return true
		}
	}
	return false
}

// setAttr 记录属性：同名保留先出现的那个（C++ 的 std::map::emplace 语义）。
func (e *Element) setAttr(name, value string) {
	for i := range e.Attrs {
		if e.Attrs[i].Name == name {
			return
		}
	}
	e.Attrs = append(e.Attrs, AttrEntry{name, value})
}

// ToStr 调试用：不一定与源文本逐字符相同（属性顺序、自闭合写法都不保留）。
func (e *Element) ToStr(level int) string {
	sp := ""
	for i := 0; i < level; i++ {
		sp += "  "
	}
	out := sp + "<" + e.Tag
	for _, a := range e.Attrs {
		out += " " + a.Name
		if a.Value != "" {
			out += "=\"" + a.Value + "\""
		}
	}
	if e.SelfClosing {
		return out + " />\n"
	}
	out += ">\n" + e.Text
	for _, c := range e.Children {
		out += c.ToStr(level + 1)
	}
	return out + sp + "</" + e.Tag + ">\n"
}
