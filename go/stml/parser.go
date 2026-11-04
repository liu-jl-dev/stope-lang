package stml

import (
	"strconv"
)

// STML 语法解析器 —— 端口 cpp/src/stml_parser.cpp。
//
// STML 比 XML 更严格：
//   - 没有字符实体；
//   - 属性可以没有值：<a flag> 等价于 flag = ""（因此属性循环不能在开头无条件
//     NextToken，否则无值属性会多吞一个 token）；
//   - 子元素与元素内文本互斥；元素内文本只有一段，由词法器一次性给出。
//
// 宿主回调 stateFunc(tag, attrs) -> LexerState 决定元素内容怎么扫（<sto> 走 Stope、
// <nev> 走 Nevext、<p> 走 Text、其余按 Xml 递归子元素）。传 nil 表示「一律 Xml」。

// Result 与语言核心的 Result 同值。
type Result int

const (
	Success Result = 0
	Error   Result = 1
)

// DefaultStateFunc 默认回调：<sto> → Stope、<nev> → Nevext、<p> → Text，其余 Xml。
func DefaultStateFunc(tag string, attrs map[string]string) LexerState {
	if tag == "sto" {
		return StopeState
	}
	if tag == "nev" {
		return NevextState
	}
	if tag == "p" {
		return TextState
	}
	return XmlState
}

// StateFunc 宿主回调：读完开始标签、还没进内容时调用一次。
type StateFunc func(tag string, attrs map[string]string) LexerState

// Parser STML 解析器。
type Parser struct {
	Lexer     *Lexer
	StateFunc StateFunc
	Errors    []string
	Token     Token
	MaxDepth  int
	Aborted   bool
}

// NewParser 构造。
func NewParser(lx *Lexer) *Parser {
	return &Parser{Lexer: lx, Token: Token{}, MaxDepth: 256}
}

// Parse 解析整篇文档，根元素写进 root。有错误返回 Error。
func (p *Parser) Parse(root *Element, stateFunc StateFunc) Result {
	p.StateFunc = stateFunc
	p.Aborted = false
	p.nextToken()
	p.parseElement(root, 1) // 根元素算第 1 层
	if len(p.Errors) > 0 {
		return Error
	}
	return Success
}

func (p *Parser) parseElement(e *Element, depth int) {
	// 深度检查：唯一递归点在子元素分支，检查放入口即可。aborted 之后逐层提前
	// return，不再消费任何 token —— 25 万层畸形输入只报一条错。
	if p.Aborted {
		return
	}
	if p.MaxDepth > 0 && depth > p.MaxDepth {
		p.abortTooDeep()
		return
	}
	// 进入元素一律先回到 Xml 状态：自闭合分支与出错提前返回的路径都走不到下面的
	// stateFunc，留着上一次的 Text / Nevext / Stope 会污染后续 token
	p.Lexer.State = XmlState
	e.Line = p.Token.Line
	if p.Token.Type != TLAngle {
		p.error("expected \"<\". ")
		return
	}
	p.nextToken()
	if p.Token.Type != TWord {
		p.error("expected tag name. ")
		return
	}
	e.Tag = p.Token.Lexeme
	p.nextToken() // 第一个属性名，或 > 或 />
	// 每个分支自己负责推进到下一个待判断的 token。
	// 不能写成「循环开头 nextToken」，否则无值属性的向前看会多吞一个 token。
	for { // (word ("=" string)?)*
		if p.Token.Type == TRAngle {
			break
		}
		if p.Token.Type == TCRAngle {
			e.SelfClosing = true
			return
		}
		if p.Token.Type == TWord {
			name := p.Token.Lexeme
			p.nextToken()
			if p.Token.Type == TEQ {
				p.nextToken()
				if p.Token.Type != TString {
					p.error("expected string. ")
					return
				}
				// C++ 用 std::map::emplace：同名属性保留【先出现的】那个
				e.setAttr(name, p.Token.Lexeme)
				p.nextToken()
			} else {
				// 无值属性：<a flag> 等价于 attrs["flag"] = ""
				// 此时 token 已经是下一个属性名 / > 或 />，不能再推进
				e.setAttr(name, "")
			}
		} else {
			p.error("expected \">\" or \"/>\" or attribute. ")
			return
		}
	}
	// 此时 e.SelfClosing 为 false，且停在 ">"
	if p.StateFunc != nil {
		m := make(map[string]string, len(e.Attrs))
		for _, a := range e.Attrs {
			m[a.Name] = a.Value
		}
		p.Lexer.State = p.StateFunc(e.Tag, m)
	} else {
		p.Lexer.State = XmlState
	}

	if p.Lexer.State == XmlState { // 递归解析子元素
		for {
			p.nextToken()
			if p.Token.Type == TCLAngle { // </>
				break
			}
			if p.Token.Type == TLAngle { // < 子元素
				child := NewElement()
				e.Children = append(e.Children, child)
				p.parseElement(child, depth+1)
				if p.Aborted {
					return // 超限的那层已报过错，逐层直接返回，不级联
				}
			} else {
				p.error("expected \"<\" or \"</\". ")
				return
			}
		}
	} else { // Text / Nevext / Stope：整段内容由词法器一次性给出
		p.nextToken() // 词法器保证只会结束在 </ ，不会结束在 <
		if p.Token.Type != TText && p.Token.Type != TNevextSrc && p.Token.Type != TStopeSrc {
			p.error("expected element content. ")
			return
		}
		e.Text = p.Token.Lexeme    // 只有一段，不拼接
		e.TextLine = p.Token.Line  // 词法器已跳过前导空白，这是内容的首行（PL-05）
		p.nextToken()              // 停在 CLAngle，与上面 Xml 分支的 break 处汇合
	}

	p.nextToken() // 结束标签名
	if p.Token.Type != TWord {
		p.error("expected tag name. ")
		return
	}
	if p.Token.Lexeme != e.Tag {
		p.error("tag name mismatch. ")
		return
	}
	p.nextToken()
	if p.Token.Type != TRAngle {
		p.error("expected \">\". ")
		return
	}
}

func (p *Parser) nextToken() {
	p.Token = p.Lexer.NextToken()
}

func (p *Parser) abortTooDeep() {
	p.error("nesting too deep (max "+strconv.Itoa(p.MaxDepth)+"). ") // 必须在置位之前记账
	p.Aborted = true
}

func (p *Parser) error(msg string) {
	// 超限中止之后的错误都是连锁反应，不再记账 —— 与 Stope 的 Parser 同款
	if p.Aborted {
		return
	}
	p.Errors = append(p.Errors, "line "+strconv.Itoa(p.Token.Line)+": "+msg)
}
