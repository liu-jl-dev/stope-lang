package stope

import "strconv"

// AST 节点定义与形状串序列化 —— 与 cpp/include/stope/ast.hpp 逐项对齐。
//
// 两点容易踩：
//   - BlockStmt.Prog 永远是个 *Prog（错误路径上也是空 Prog），形状串是 Block{}
//     而不是 Block{null}；只有 IfStmt.ElseProg 是可选，没有 else 时为 nil。
//   - 解析失败时返回的是裸 *BareExpr（形状串打成 Err(L行号)）。

// NodeType 节点类型编号（与 C++ 同序同值）。
type NodeType int

const (
	NNode NodeType = iota
	NProg
	NStmt
	NExpr
	NExprStmt
	NLetStmt
	NReturnStmt
	NExportStmt
	NBlockStmt
	NIfStmt
	NWhileStmt
	NAssignStmt
	NBreakStmt
	NContinueStmt
	NDeferStmt
	NNullExpr
	NBoolExpr
	NIntExpr
	NFloatExpr
	NBinArrExpr
	NStringExpr
	NIdentExpr
	NArgcExpr
	NArgsExpr
	NUnaryOpExpr
	NBinaryOpExpr
	NCallExpr
	NAtExpr
	NCustomOpcodeExpr
)

// Node 所有 AST 节点的公共接口。
type Node interface{ Line() int }

// NodeBase 公共字段。
type NodeBase struct{ Line_ int }

func (n *NodeBase) Line() int { return n.Line_ }

// Precedence 10 档优先级，与 C++ 的 OpPrecedence 同序同值。
type Precedence struct{}

const (
	PLowest      = 0
	POr          = 1
	PAnd         = 2
	PEquals      = 3
	PLessGreater = 4
	PAddSub      = 5
	PMulDiv      = 6
	PPow         = 7
	PPrefix      = 8
	PParen       = 9
)

// BinopPrec 二元运算符 → 优先级。调用 ()、取元素 [] 也是二元形式，优先级最高。
var BinopPrec = map[TokenType]int{
	TOr: POr, TAnd: PAnd, TEQ: PEquals, TNE: PEquals,
	TLT: PLessGreater, TLE: PLessGreater, TGT: PLessGreater, TGE: PLessGreater,
	TAdd: PAddSub, TSub: PAddSub, TMul: PMulDiv, TDiv: PMulDiv,
	TIDiv: PMulDiv, TMod: PMulDiv, TPow: PPow,
	TLParen: PParen, TLBrack: PParen,
}

// BinopLiteral 二元运算符的显示文本（to_str 用）。
var BinopLiteral = map[TokenType]string{
	TOr: "||", TAnd: "&&", TEQ: "==", TNE: "!=",
	TLT: "<", TLE: "<=", TGT: ">", TGE: ">=",
	TAdd: "+", TSub: "-", TMul: "*", TDiv: "/",
	TIDiv: "idiv", TMod: "%", TPow: "^",
}

// ================================ prog ================================

// Prog prog : stmt*
type Prog struct {
	NodeBase
	Stmts []Node
}

// ================================ 语句 ================================

// ExprStmt expr_stmt : expr ";"
type ExprStmt struct {
	NodeBase
	Expr Node
}

// LetStmt let_stmt : "let" ident ( ("," ident)* | ("=" expr) )? ";"
type LetStmt struct {
	NodeBase
	HasAssign bool
	Idents    []string
	Expr      Node
}

// ReturnStmt return_stmt : "return" ( expr ( "," expr )* )? ";"
type ReturnStmt struct {
	NodeBase
	Exprs []Node
}

// ExportStmt export_stmt : "export" ident ( "," ident )* ";"
type ExportStmt struct {
	NodeBase
	Idents []string
}

// BlockStmt block_stmt : "{" prog "}"
type BlockStmt struct {
	NodeBase
	Prog *Prog
}

// IfStmtElif if 语句的一个 elif 分支。
type IfStmtElif struct {
	NodeBase
	Cond Node
	Prog *Prog
}

// IfStmt if_stmt : "if" expr "{" prog "}" ( "elif" expr "{" prog "}" )* ( "else" "{" prog "}" )?
type IfStmt struct {
	NodeBase
	Cond      Node
	FirstProg *Prog
	Elifs     []*IfStmtElif
	ElseProg  *Prog // 没有 else 分支时为 nil
}

// WhileStmt while_stmt : "while" expr? "{" prog "}"   —— Cond 为 nil 表示无条件循环
type WhileStmt struct {
	NodeBase
	Cond Node
	Prog *Prog
}

// AssignStmt assign_stmt : expr "=" expr ";"
type AssignStmt struct {
	NodeBase
	LeftExpr  Node
	RightExpr Node
}

// BreakStmt break 语句。
type BreakStmt struct{ NodeBase }

// ContinueStmt continue 语句。
type ContinueStmt struct{ NodeBase }

// DeferStmt defer_stmt : "defer" stmt —— 载荷缺省（defer; 报错路径）时 Stmt 为 nil。
type DeferStmt struct {
	NodeBase
	Stmt Node
}

// ================================ 表达式 ================================

// NullExpr null 字面量。
type NullExpr struct{ NodeBase }

// BoolExpr true / false 字面量。
type BoolExpr struct {
	NodeBase
	Value bool
}

// IntExpr 整数字面量（int64）。
type IntExpr struct {
	NodeBase
	Value int64
}

// FloatExpr 浮点字面量。
type FloatExpr struct {
	NodeBase
	Value float64
}

// BinArrExpr 二进制数组字面量（值不转义）。
type BinArrExpr struct {
	NodeBase
	Value []byte
}

// StringExpr 字符串字面量（已反转义）。
type StringExpr struct {
	NodeBase
	Value string
}

// IdentExpr 标识符。
type IdentExpr struct {
	NodeBase
	Ident string
}

// ArgcExpr argc。
type ArgcExpr struct{ NodeBase }

// ArgsExpr args[key]。
type ArgsExpr struct {
	NodeBase
	KeyExpr Node
}

// UnaryOpExpr 一元运算（- !）。
type UnaryOpExpr struct {
	NodeBase
	Op   TokenType
	Expr Node
}

// BinaryOpExpr 二元运算。
type BinaryOpExpr struct {
	NodeBase
	LeftExpr  Node
	Op        TokenType
	RightExpr Node
}

// CallExpr 函数调用。
type CallExpr struct {
	NodeBase
	Callee Node
	Args   []Node
}

// AtExpr 取元素 a[i]。
type AtExpr struct {
	NodeBase
	Container Node
	KeyExprs  []Node
}

// CustomOpcodeExpr 自定义指令调用。
type CustomOpcodeExpr struct {
	NodeBase
	OpcodeName string
	Args       []Node
}

// BareExpr 解析失败时返回的裸节点（形状串 Err(L行号)）。
type BareExpr struct{ NodeBase }

// ================================ 形状串（测试用） ================================
// 严格照抄 cpp/test/test_common.hpp 的 shapeExpr / shapeStmt / shapeProg。

// ShapeProg prog → 形状串：语句按 " ; " 连接，空 prog → ""。
func ShapeProg(p *Prog) string {
	if p == nil {
		return "null"
	}
	out := ""
	for i, s := range p.Stmts {
		if i > 0 {
			out += " ; "
		}
		out += ShapeStmt(s)
	}
	return out
}

// ShapeStmt 语句 → 形状串。
func ShapeStmt(s Node) string {
	if s == nil {
		return "null"
	}
	switch n := s.(type) {
	case *ExprStmt:
		return "ExprStmt(" + ShapeExpr(n.Expr) + ")"
	case *LetStmt:
		d := "Let["
		for i, id := range n.Idents {
			if i > 0 {
				d += ","
			}
			d += Esc(id)
		}
		d += "]"
		if n.HasAssign {
			d += "=" + ShapeExpr(n.Expr)
		}
		return d
	case *ReturnStmt:
		d := "Return("
		for i, e := range n.Exprs {
			if i > 0 {
				d += ", "
			}
			d += ShapeExpr(e)
		}
		return d + ")"
	case *ExportStmt:
		d := "Export["
		for i, id := range n.Idents {
			if i > 0 {
				d += ","
			}
			d += Esc(id)
		}
		return d + "]"
	case *BlockStmt:
		return "Block{" + ShapeProg(n.Prog) + "}"
	case *IfStmt:
		d := "If(" + ShapeExpr(n.Cond) + "){" + ShapeProg(n.FirstProg) + "}"
		for _, ei := range n.Elifs {
			d += "Elif(" + ShapeExpr(ei.Cond) + "){" + ShapeProg(ei.Prog) + "}"
		}
		if n.ElseProg != nil {
			d += "Else{" + ShapeProg(n.ElseProg) + "}"
		}
		return d
	case *WhileStmt:
		return "While(" + ShapeExpr(n.Cond) + "){" + ShapeProg(n.Prog) + "}"
	case *AssignStmt:
		return "Assign(" + ShapeExpr(n.LeftExpr) + ", " + ShapeExpr(n.RightExpr) + ")"
	case *BreakStmt:
		return "Break"
	case *ContinueStmt:
		return "Continue"
	case *DeferStmt:
		return "Defer(" + ShapeStmt(n.Stmt) + ")"
	}
	return "?" + nodeTypeName(s)
}

// ShapeExpr 表达式 → 形状串。
func ShapeExpr(e Node) string {
	if e == nil {
		return "null"
	}
	switch n := e.(type) {
	case *BareExpr: // 失败路径返回的裸节点
		return "Err(L" + strconv.Itoa(n.Line_) + ")"
	case *NullExpr:
		return "Null"
	case *ArgcExpr:
		return "Argc"
	case *BoolExpr:
		if n.Value {
			return "Bool(true)"
		}
		return "Bool(false)"
	case *IntExpr:
		return "Int(" + strconv.FormatInt(n.Value, 10) + ")"
	case *FloatExpr:
		return "Float(" + FmtG(n.Value) + ")"
	case *BinArrExpr:
		return "BinArr[" + FmtBytes(n.Value) + "]"
	case *StringExpr:
		return "Str(\"" + Esc(n.Value) + "\")"
	case *IdentExpr:
		return "Ident(" + Esc(n.Ident) + ")"
	case *ArgsExpr:
		if n.KeyExpr == nil {
			return "Args(null)"
		}
		return "Args(" + ShapeExpr(n.KeyExpr) + ")"
	case *UnaryOpExpr:
		return "Unary(" + TypeName(n.Op) + ", " + ShapeExpr(n.Expr) + ")"
	case *BinaryOpExpr:
		return "Bin(" + TypeName(n.Op) + ", " + ShapeExpr(n.LeftExpr) + ", " + ShapeExpr(n.RightExpr) + ")"
	case *CallExpr:
		d := "Call(" + ShapeExpr(n.Callee)
		for _, a := range n.Args {
			d += "; " + ShapeExpr(a)
		}
		return d + ")"
	case *AtExpr:
		d := "At(" + ShapeExpr(n.Container)
		for _, k := range n.KeyExprs {
			d += "; " + ShapeExpr(k)
		}
		return d + ")"
	case *CustomOpcodeExpr:
		d := "Custom(" + Esc(n.OpcodeName)
		for _, a := range n.Args {
			d += "; " + ShapeExpr(a)
		}
		return d + ")"
	}
	return "?" + nodeTypeName(e)
}

func nodeTypeName(n Node) string {
	switch n.(type) {
	case *Prog:
		return "Prog"
	case *ExprStmt:
		return "ExprStmt"
	case *LetStmt:
		return "LetStmt"
	case *ReturnStmt:
		return "ReturnStmt"
	case *ExportStmt:
		return "ExportStmt"
	case *BlockStmt:
		return "BlockStmt"
	case *IfStmt:
		return "IfStmt"
	case *WhileStmt:
		return "WhileStmt"
	case *AssignStmt:
		return "AssignStmt"
	case *BreakStmt:
		return "BreakStmt"
	case *ContinueStmt:
		return "ContinueStmt"
	case *DeferStmt:
		return "DeferStmt"
	case *NullExpr:
		return "NullExpr"
	case *BoolExpr:
		return "BoolExpr"
	case *IntExpr:
		return "IntExpr"
	case *FloatExpr:
		return "FloatExpr"
	case *BinArrExpr:
		return "BinArrExpr"
	case *StringExpr:
		return "StringExpr"
	case *IdentExpr:
		return "IdentExpr"
	case *ArgcExpr:
		return "ArgcExpr"
	case *ArgsExpr:
		return "ArgsExpr"
	case *UnaryOpExpr:
		return "UnaryOpExpr"
	case *BinaryOpExpr:
		return "BinaryOpExpr"
	case *CallExpr:
		return "CallExpr"
	case *AtExpr:
		return "AtExpr"
	case *CustomOpcodeExpr:
		return "CustomOpcodeExpr"
	case *BareExpr:
		return "Expr"
	}
	return "Node"
}
