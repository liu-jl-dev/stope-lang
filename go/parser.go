package stope

import "strconv"

// 语法分析器（Pratt）—— 端口 cpp/src/parser.cpp。行为契约：
//
//  1. 错误恢复：分隔符缺失时只报错、不推进（parse_let_stmt / parse_return_stmt
//     的兜底分支例外，仍会推进）。
//  2. 不变量：parseExpr 之后必有一次 nextToken。
//  3. 顶层孤立 } 要报错并跳过继续解析；块内的 } 由外层消费，不报错。
//  4. 常量折叠挂在 parseUnaryOpExpr / parseBinaryOpExpr 的构造末尾。
//  5. 节点取 token 的 Parsed 而非 Lexeme；只有 BinArr 取 Lexeme。
//
// ⚠ 嵌套深度上限 256（MaxDepth，0 = 不限）：depth 走函数参数。超限时报一条
// "line N: nesting too deep (max 256). " 并置 Aborted，此后所有 error 不再记账，
// 子函数返回 nil 但不逐层传染。

// KDefaultMaxDepth 默认嵌套深度上限（与 C++ Parser::maxDepth 相同，文案也逐字相同）。
const KDefaultMaxDepth = 256

// Parser Pratt 解析器。
type Parser struct {
	BinArrParser BinaryArrayParser
	Errors       []string
	Aborted      bool
	Lexer        *Lexer
	Custom       *CustomOpcodeConfig
	ConstFolding bool
	MaxDepth     int
	CurToken     Token
	PeekToken    Token
}

// NewParser 构造并 Reset。
func NewParser(lx *Lexer, custom *CustomOpcodeConfig) *Parser {
	p := &Parser{}
	p.Reset(lx, custom)
	return p
}

// Reset 与 C++ 的 Parser::Reset 一致：清错误、重挂词法器、重读两个 token。
func (p *Parser) Reset(lx *Lexer, custom *CustomOpcodeConfig) {
	p.Errors = nil
	p.Aborted = false
	p.Lexer = lx
	p.Custom = custom
	p.ConstFolding = true
	p.MaxDepth = KDefaultMaxDepth
	// 先读两个 token，cur / peek 才都有值 —— 顺序不能变。
	p.nextToken()
	p.nextToken()
}

// ParseProgram 填充一个 Prog。
func (p *Parser) ParseProgram(prog *Prog) {
	p.parseProg(prog, true, 1)
}

// ================================ 语句 ================================

func (p *Parser) parseProg(prog *Prog, isTopLevel bool, depth int) {
	if p.Aborted {
		return
	}
	for !p.Aborted && p.CurToken.Type != TEof {
		t := p.CurToken.Type
		var stmt Node
		switch t {
		case TRBrace:
			if !isTopLevel {
				return // 块内：正常结束，不跳过，交给外层处理
			}
			p.error(p.CurToken.Line, "unexpected \"}\" at top level. ")
			p.nextToken()
			continue
		case TSemi: // 空语句
			p.nextToken()
			continue
		case TLet:
			stmt = p.parseLetStmt(depth)
		case TExport:
			stmt = p.parseExportStmt(depth)
		case TReturn:
			stmt = p.parseReturnStmt(depth)
		case TLBrace:
			stmt = p.parseBlockStmt(depth)
		case TIf:
			stmt = p.parseIfStmt(depth)
		case TWhile:
			stmt = p.parseWhileStmt(depth)
		case TBreak:
			stmt = p.parseBreakStmt(depth)
		case TContinue:
			stmt = p.parseContinueStmt(depth)
		default:
			stmt = p.parseExprOrAssignStmt(depth)
		}
		// 超限中止时子函数返回 nil：不追加、不再往下解析。
		if stmt == nil {
			break
		}
		prog.Stmts = append(prog.Stmts, stmt)
	}
}

func (p *Parser) parseLetStmt(depth int) Node {
	stmt := &LetStmt{NodeBase{p.CurToken.Line}, false, nil, nil}
	p.nextToken() // 跳过 let
	if p.CurToken.Type != TIdent {
		p.error(p.CurToken.Line, "expected identifier after \"let\". ")
		p.nextToken()
		return stmt
	}
	stmt.Idents = append(stmt.Idents, p.CurToken.Parsed)
	p.nextToken()
	switch p.CurToken.Type {
	case TSemi:
		// 单个标识符且不赋值
		p.nextToken()
	case TComma:
		// 多个标识符，禁止赋值
		for {
			if p.CurToken.Type == TComma && p.PeekToken.Type == TIdent {
				stmt.Idents = append(stmt.Idents, p.PeekToken.Parsed)
				p.nextToken()
				p.nextToken()
			} else if p.CurToken.Type == TSemi {
				p.nextToken()
				break
			} else if p.CurToken.Type == TEof || p.CurToken.Type == TRBrace {
				// 缺 ";": 此处不能再推进。
				p.error(p.CurToken.Line, "expected \";\" in let statement. ")
				break
			} else {
				p.error(p.CurToken.Line, "failed to parse let statement with multiple identifiers. ")
				p.nextToken()
			}
		}
	case TAssign:
		stmt.HasAssign = true
		p.nextToken()
		stmt.Expr = p.parseExpr(PLowest, depth)
		p.nextToken()
	default:
		p.error(p.CurToken.Line, "unexpected token in let statement. ")
		p.nextToken()
	}
	return stmt
}

func (p *Parser) parseExportStmt(depth int) Node {
	stmt := &ExportStmt{NodeBase{p.CurToken.Line}, nil}
	p.nextToken() // 跳过 export
	if p.CurToken.Type != TIdent {
		p.error(p.CurToken.Line, "expected identifier after \"export\". ")
		p.nextToken()
		return stmt
	}
	stmt.Idents = append(stmt.Idents, p.CurToken.Parsed)
	p.nextToken()
	switch p.CurToken.Type {
	case TSemi:
		p.nextToken()
	case TComma:
		for {
			if p.CurToken.Type == TComma && p.PeekToken.Type == TIdent {
				stmt.Idents = append(stmt.Idents, p.PeekToken.Parsed)
				p.nextToken()
				p.nextToken()
			} else if p.CurToken.Type == TSemi {
				p.nextToken()
				break
			} else if p.CurToken.Type == TEof || p.CurToken.Type == TRBrace {
				p.error(p.CurToken.Line, "expected \";\" in export statement. ")
				break
			} else {
				p.error(p.CurToken.Line, "failed to parse export statement with multiple identifiers. ")
				p.nextToken()
			}
		}
	default:
		p.error(p.CurToken.Line, "unexpected token in export statement. ")
		p.nextToken()
	}
	return stmt
}

func (p *Parser) parseReturnStmt(depth int) Node {
	// return_stmt : "return" ( expr ( "," expr )* )? ";"
	stmt := &ReturnStmt{NodeBase{p.CurToken.Line}, nil}
	p.nextToken() // 跳过 return
	if p.CurToken.Type == TSemi {
		// 无返回值，exprs 为空
		p.nextToken()
		return stmt
	}
	if p.CurToken.Type == TEof || p.CurToken.Type == TRBrace {
		// 缺 ";": 此时不能吞掉 } 或 Eof，否则外层块会解析错位
		p.error(p.CurToken.Line, "expected \";\" in return statement. ")
		return stmt
	}
	stmt.Exprs = append(stmt.Exprs, p.parseExpr(PLowest, depth)) // 第一个表达式
	p.nextToken()                                                // 到达 , 或 ;
	for {
		if p.CurToken.Type == TSemi {
			p.nextToken()
			break
		} else if p.CurToken.Type == TComma {
			p.nextToken()
			stmt.Exprs = append(stmt.Exprs, p.parseExpr(PLowest, depth))
			p.nextToken()
		} else {
			p.error(p.CurToken.Line, "expected \";\" or \",\" in return statement. ")
			p.nextToken()
			break
		}
	}
	return stmt
}

func (p *Parser) parseBlockStmt(depth int) Node {
	if p.Aborted {
		return nil // 已超限：不再解析
	}
	stmt := &BlockStmt{NodeBase{p.CurToken.Line}, nil}
	p.nextToken() // 跳过 {
	stmt.Prog = &Prog{}
	p.parseProg(stmt.Prog, false, depth+1)
	if p.CurToken.Type != TRBrace {
		p.error(p.CurToken.Line, "expected \"}\" at end of block statement. ")
	}
	p.nextToken() // 跳过 }
	return stmt
}

func (p *Parser) parseIfStmt(depth int) Node {
	// if_stmt : "if" expr "{" prog "}" ("elif" expr "{" prog "}")* ("else" "{" prog "}")?
	if p.Aborted {
		return nil
	}
	stmt := &IfStmt{NodeBase: NodeBase{Line_: p.CurToken.Line}, FirstProg: &Prog{}}
	p.nextToken() // 跳过 if
	stmt.Cond = p.parseExpr(PLowest, depth)
	p.nextToken() // 到达 {
	if p.CurToken.Type != TLBrace {
		p.error(p.CurToken.Line, "expected \"{\" in if statement. ")
		return stmt
	}
	p.nextToken() // 跳过 {
	stmt.FirstProg = &Prog{}
	p.parseProg(stmt.FirstProg, false, depth+1)
	if p.CurToken.Type != TRBrace {
		p.error(p.CurToken.Line, "expected \"}\" in if statement. ")
		return stmt
	}
	p.nextToken() // 跳过 }
	for p.CurToken.Type == TElif {
		// ("elif" expr "{" prog "}")*
		ei := &IfStmtElif{NodeBase: NodeBase{Line_: p.CurToken.Line}, Prog: &Prog{}}
		p.nextToken() // 跳过 elif
		ei.Cond = p.parseExpr(PLowest, depth)
		p.nextToken()
		if p.CurToken.Type != TLBrace {
			p.error(p.CurToken.Line, "expected \"{\" of elif. ")
			return stmt
		}
		p.nextToken() // 跳过 {
		ei.Prog = &Prog{}
		p.parseProg(ei.Prog, false, depth+1)
		if p.CurToken.Type != TRBrace {
			p.error(p.CurToken.Line, "expected \"}\" of elif. ")
			return stmt
		}
		p.nextToken() // 跳过 }
		stmt.Elifs = append(stmt.Elifs, ei)
	}
	if p.CurToken.Type == TElse {
		p.nextToken()
		if p.CurToken.Type != TLBrace {
			p.error(p.CurToken.Line, "expected \"{\" after else. ")
			return stmt
		}
		p.nextToken() // 跳过 {
		stmt.ElseProg = &Prog{}
		p.parseProg(stmt.ElseProg, false, depth+1)
		if p.CurToken.Type != TRBrace {
			p.error(p.CurToken.Line, "expected \"}\" in if statement. ")
			return stmt
		}
		p.nextToken() // 跳过 }
	}
	return stmt
}

func (p *Parser) parseWhileStmt(depth int) Node {
	// while_stmt : "while" expr? "{" prog "}"
	if p.Aborted {
		return nil
	}
	stmt := &WhileStmt{NodeBase: NodeBase{Line_: p.CurToken.Line}, Prog: &Prog{}}
	p.nextToken() // 跳过 while
	if p.CurToken.Type != TLBrace {
		stmt.Cond = p.parseExpr(PLowest, depth)
		p.nextToken() // 到达 {
	}
	if p.CurToken.Type != TLBrace {
		p.error(p.CurToken.Line, "expected \"{\" in while statement. ")
		return stmt
	}
	p.nextToken() // 跳过 {
	stmt.Prog = &Prog{}
	p.parseProg(stmt.Prog, false, depth+1)
	if p.CurToken.Type != TRBrace {
		p.error(p.CurToken.Line, "expected \"}\" at end of while statement. ")
		return stmt
	}
	p.nextToken()
	return stmt
}

func (p *Parser) parseBreakStmt(depth int) Node {
	stmt := &BreakStmt{NodeBase{p.CurToken.Line}}
	p.nextToken() // 跳过 break
	if p.CurToken.Type != TSemi {
		p.error(p.CurToken.Line, "expected \";\" in break statement. ")
	} else {
		p.nextToken()
	}
	return stmt
}

func (p *Parser) parseContinueStmt(depth int) Node {
	stmt := &ContinueStmt{NodeBase{p.CurToken.Line}}
	p.nextToken() // 跳过 continue
	if p.CurToken.Type != TSemi {
		p.error(p.CurToken.Line, "expected \";\" in continue statement. ")
	} else {
		p.nextToken()
	}
	return stmt
}

func (p *Parser) parseExprOrAssignStmt(depth int) Node {
	leftExpr := p.parseExpr(PLowest, depth)
	if leftExpr == nil {
		return nil // 超限中止：下面要读 leftExpr.Line
	}
	p.nextToken() // 到达 = 或 ;
	if p.CurToken.Type == TSemi {
		p.nextToken() // 跳过 ;
		return &ExprStmt{NodeBase{leftExpr.Line()}, leftExpr}
	} else if p.CurToken.Type == TAssign {
		p.nextToken() // 跳过 =
		a := &AssignStmt{NodeBase{leftExpr.Line()}, leftExpr, nil}
		a.RightExpr = p.parseExpr(PLowest, depth)
		p.nextToken() // 到达 ;
		if p.CurToken.Type != TSemi {
			p.error(p.CurToken.Line, "expected \";\" at end of assign statement. ")
		}
		p.nextToken()
		return a
	}
	p.error(p.CurToken.Line, "expected \";\" or \"=\". ")
	// 不推进：当前 token 不是合法的语句边界，留给下一轮语句解析。
	return &ExprStmt{NodeBase{leftExpr.Line()}, leftExpr}
}

// ================================ 表达式主循环 ================================

func (p *Parser) parseExpr(precedence int, depth int) Node {
	// 深度检查只在这里和 parseProg 做 —— 只有这两处会递归。
	if p.Aborted {
		return nil
	}
	if p.MaxDepth > 0 && depth > p.MaxDepth {
		p.abortTooDeep(p.CurToken.Line)
		return nil
	}
	prefix, ok := prefixFns[p.CurToken.Type]
	if !ok {
		p.error(p.CurToken.Line, "no prefix parse function for token type. ")
		return &BareExpr{NodeBase{p.CurToken.Line}} // 失败路径返回裸节点 Err(L行号)
	}
	leftExpr := prefix(p, depth)
	if leftExpr == nil {
		return nil // 子表达式已中止（括号会原样透出）
	}
	for !p.Aborted && p.PeekToken.Type != TSemi && precedence < p.peekPrecedence() {
		infix, ok := infixFns[p.PeekToken.Type]
		if !ok {
			p.error(p.PeekToken.Line, "no infix parse function for token type. ")
			return leftExpr
		}
		p.nextToken()
		leftExpr = infix(p, leftExpr, depth)
		if leftExpr == nil {
			return nil
		}
	}
	return leftExpr
}

func (p *Parser) curPrecedence() int {
	if v, ok := BinopPrec[p.CurToken.Type]; ok {
		return v
	}
	return PLowest
}

func (p *Parser) peekPrecedence() int {
	if v, ok := BinopPrec[p.PeekToken.Type]; ok {
		return v
	}
	return PLowest
}

func (p *Parser) optimizeInPlace(e Node) Node {
	if !p.ConstFolding {
		return e
	}
	return Optimize(e)
}

// ================================ 基础设施 ================================

func (p *Parser) nextToken() {
	p.CurToken = p.PeekToken
	p.PeekToken = p.Lexer.NextToken(p.Custom)
}

func (p *Parser) error(line int, msg string) {
	// 嵌套超限中止之后的一切错误都是连锁反应，不再记账。
	if p.Aborted {
		return
	}
	p.Errors = append(p.Errors, "line "+strconv.Itoa(line)+": "+msg)
}

func (p *Parser) abortTooDeep(line int) {
	p.error(line, "nesting too deep (max "+strconv.Itoa(p.MaxDepth)+"). ") // 必须在置位之前记账
	p.Aborted = true
}

// ================================ 前缀 ================================

func parseIdentExpr(p *Parser, depth int) Node {
	return &IdentExpr{NodeBase{p.CurToken.Line}, p.CurToken.Parsed}
}

func parseNullExpr(p *Parser, depth int) Node {
	return &NullExpr{NodeBase{p.CurToken.Line}}
}

func parseBoolExpr(p *Parser, depth int) Node {
	return &BoolExpr{NodeBase{p.CurToken.Line}, p.CurToken.Type == TTrue}
}

func parseIntExpr(p *Parser, depth int) Node {
	return &IntExpr{NodeBase{p.CurToken.Line}, p.CurToken.IVal}
}

func parseFloatExpr(p *Parser, depth int) Node {
	return &FloatExpr{NodeBase{p.CurToken.Line}, p.CurToken.FVal}
}

func parseStringExpr(p *Parser, depth int) Node {
	// 取 Parsed：转义已完成（Lexeme 是未转义的原文）
	return &StringExpr{NodeBase{p.CurToken.Line}, p.CurToken.Parsed}
}

func parseBinarrExpr(p *Parser, depth int) Node {
	e := &BinArrExpr{NodeBase{p.CurToken.Line}, nil}
	// 取 Lexeme：二进制数组不做转义，解析到一半失败也要保留前半段（报错但继续）
	var buf []byte
	if rc := p.BinArrParser.ParseBinaryArray(p.CurToken.Lexeme, &buf); rc != RSuccess {
		p.error(p.CurToken.Line, "invalid binary array. ")
	}
	e.Value = buf
	return e
}

func parseArgcExpr(p *Parser, depth int) Node {
	return &ArgcExpr{NodeBase{p.CurToken.Line}}
}

func parseUnaryOpExpr(p *Parser, depth int) Node {
	e := &UnaryOpExpr{NodeBase{p.CurToken.Line}, p.CurToken.Type, nil}
	p.nextToken()
	e.Expr = p.parseExpr(PPrefix, depth+1)
	return p.optimizeInPlace(e) // 自底向上：子表达式已折好，这里折自己
}

func parseParenExpr(p *Parser, depth int) Node {
	p.nextToken()
	e := p.parseExpr(PLowest, depth+1)
	p.nextToken()
	if p.CurToken.Type != TRParen {
		p.error(p.CurToken.Line, "expected \")\". ")
	}
	return e // 停在 )
}

func parseCustomOpcodeExpr(p *Parser, depth int) Node {
	e := &CustomOpcodeExpr{NodeBase{p.CurToken.Line}, p.CurToken.Parsed, nil}
	p.nextToken() // 到达 (
	if p.CurToken.Type != TLParen {
		p.error(p.CurToken.Line, "expected \"(\" after custom opcode. ")
		p.nextToken()
		return e
	}
	p.nextToken()
	if p.CurToken.Type == TRParen {
		// 空参数表，cur 停在 )
	} else {
		// expr ("," expr)*
		e.Args = append(e.Args, p.parseExpr(PLowest, depth+1))
		for p.PeekToken.Type == TComma {
			p.nextToken()
			p.nextToken()
			e.Args = append(e.Args, p.parseExpr(PLowest, depth+1))
		}
		if p.PeekToken.Type != TRParen {
			p.error(p.CurToken.Line, "expected \")\". ")
		}
		p.nextToken() // 到达 )
	}
	return e
}

func parseArgsExpr(p *Parser, depth int) Node {
	e := &ArgsExpr{NodeBase{p.CurToken.Line}, nil}
	if p.PeekToken.Type != TLBrack {
		// 不推进（cur 停在 "args"）：把后续 token 留给下一条语句，避免吞掉
		p.error(p.PeekToken.Line, "expected \"[\" after \"args\". ")
		return e
	}
	p.nextToken() // 到达 [
	p.nextToken()
	e.KeyExpr = p.parseExpr(PLowest, depth+1)
	p.nextToken()
	if p.CurToken.Type != TRBrack {
		p.error(p.CurToken.Line, "expected \"]\". ")
	}
	return e
}

// ================================ 中缀 ================================

func parseBinaryOpExpr(p *Parser, leftExpr Node, depth int) Node {
	if leftExpr == nil {
		return nil // 左操作数已中止（正常路径进不来）
	}
	e := &BinaryOpExpr{NodeBase{leftExpr.Line()}, leftExpr, p.CurToken.Type, nil}
	prec := p.curPrecedence()
	// ^ 右结合：优先级 -1 让右侧继续吃同级的 ^（2^3^2 = 2^(3^2)）。
	if e.Op == TPow {
		prec--
	}
	p.nextToken()
	e.RightExpr = p.parseExpr(prec, depth+1)
	return p.optimizeInPlace(e) // 两侧都已折好，折叠只在最深的节点先发生
}

func parseCallExpr(p *Parser, callee Node, depth int) Node {
	if callee == nil {
		return nil
	}
	e := &CallExpr{NodeBase{callee.Line()}, callee, nil}
	// 外层已保证此处是 (
	if p.PeekToken.Type != TRParen {
		// expr ("," expr)*
		p.nextToken() // 到达第一个表达式
		e.Args = append(e.Args, p.parseExpr(PLowest, depth+1))
		for p.PeekToken.Type == TComma {
			p.nextToken() // 到达 ","
			p.nextToken() // 到达下一个表达式
			e.Args = append(e.Args, p.parseExpr(PLowest, depth+1))
		}
	}
	if p.PeekToken.Type == TRParen {
		p.nextToken() // 跳过 )
	} else {
		// 缺 ")" 时不推进，避免吞掉后面的 token
		p.error(p.PeekToken.Line, "expected \")\". ")
	}
	return e
}

func parseAtExpr(p *Parser, container Node, depth int) Node {
	if container == nil {
		return nil
	}
	e := &AtExpr{NodeBase{container.Line()}, container, nil}
	if p.PeekToken.Type != TRBrack {
		// expr ("," expr)*
		p.nextToken() // 到达第一个表达式
		e.KeyExprs = append(e.KeyExprs, p.parseExpr(PLowest, depth+1))
		for p.PeekToken.Type == TComma {
			p.nextToken() // 到达 ","
			p.nextToken() // 到达下一个表达式
			e.KeyExprs = append(e.KeyExprs, p.parseExpr(PLowest, depth+1))
		}
	}
	if p.PeekToken.Type == TRBrack {
		p.nextToken() // 跳过 ]
	} else {
		// 缺 "]" 时不推进，避免吞掉后面的 token
		p.error(p.PeekToken.Line, "expected \"]\". ")
	}
	return e
}

type prefixFn func(p *Parser, depth int) Node
type infixFn func(p *Parser, left Node, depth int) Node

var prefixFns map[TokenType]prefixFn
var infixFns map[TokenType]infixFn

func init() {
	prefixFns = map[TokenType]prefixFn{
		TIdent:   parseIdentExpr,
		TNull:    parseNullExpr,
		TFalse:   parseBoolExpr,
		TTrue:    parseBoolExpr,
		TInteger: parseIntExpr,
		TFloat:   parseFloatExpr,
		TString:  parseStringExpr,
		TBinArr:  parseBinarrExpr,
		TArgc:    parseArgcExpr,
		TSub:     parseUnaryOpExpr,
		TNot:     parseUnaryOpExpr,
		TLParen:  parseParenExpr,
		TCustom:  parseCustomOpcodeExpr,
		TArgs:    parseArgsExpr,
	}
	infixFns = make(map[TokenType]infixFn)
	for _, t := range []TokenType{
		TOr, TAnd, TEQ, TNE, TLT, TLE, TGT, TGE,
		TAdd, TSub, TMul, TDiv, TIDiv, TMod, TPow,
	} {
		infixFns[t] = parseBinaryOpExpr
	}
	infixFns[TLParen] = parseCallExpr // () 函数调用
	infixFns[TLBrack] = parseAtExpr   // [] 取元素
}
