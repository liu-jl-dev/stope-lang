package stope

// TokenType 词法单元类型。编号与 C++ 的 stope::TokenType 逐项相同（0..47），不要重排。
type TokenType int

const (
	TInvalid TokenType = iota
	TEof
	TIdent
	TInteger
	TFloat
	TString
	TBinArr
	TComma
	TSemi
	TLParen

	TRParen
	TLBrack
	TRBrack
	TLBrace
	TRBrace
	TAssign
	TAdd
	TSub
	TMul
	TDiv

	TIDiv
	TMod
	TPow
	TEQ
	TNE
	TLT
	TLE
	TGT
	TGE
	TNot

	TAnd
	TOr
	TIf
	TElif
	TElse
	TLet
	TReturn
	TWhile
	TBreak
	TContinue
	TDefer

	TNull
	TFalse
	TTrue
	TArgs
	TArgc
	TExport
	TCustom
)

// tokenTypeNames 下标即编号；对外打印一律走 TypeName（True/False 去掉关键字冲突）。
var tokenTypeNames = []string{
	"Invalid", "Eof", "Ident", "Integer", "Float", "String", "BinArr",
	"Comma", "Semi", "LParen", "RParen", "LBrack", "RBrack", "LBrace",
	"RBrace", "Assign", "Add", "Sub", "Mul", "Div", "IDiv", "Mod", "Pow",
	"EQ", "NE", "LT", "LE", "GT", "GE", "Not", "And", "Or", "If", "Elif",
	"Else", "Let", "Return", "While", "Break", "Continue", "Defer", "Null",
	"False", "True", "Args", "Argc", "Export", "Custom",
}

// TypeName 枚举 → golden 里用的名字。
func TypeName(t TokenType) string {
	if t < 0 || int(t) >= len(tokenTypeNames) {
		return "?"
	}
	return tokenTypeNames[t]
}

// Token 一个词法单元。
//
// Lexeme 是原文片段；Parsed 是「语义形态」：数字去掉下划线、标识符拼好冒号、
// 字符串反转义后。只有数字 / 字符串 / 二进制数组参与跨实现比对。
// IVal / FVal 分别是整数与浮点的值（按 Type 取用）。
type Token struct {
	Line   int
	Type   TokenType
	Lexeme string
	Parsed string
	IVal   int64
	FVal   float64
	HasVal bool
}
