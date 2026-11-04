package stope

import (
	"sort"
	"strconv"
)

// 编译器：把 AST 编译成 Program（指令流 + 常量池 + 变量表）—— 端口 cpp/src/compiler.cpp。
//
// 【PushValue 与 PushId 的分工】PushId 压的是槽位引用（左值），只有两处产生：
// 「有赋值的 let」左侧、Assign 左端是裸标识符时。其余读变量一律 PushValue（压值）。
//
// 【遍历骨架】与 C++ 的 ASTVisitor + visitMap 对齐：visit() 按 NodeType 分派，
// 语义动作全在 visitXxx 里；需要发指令的整段重写，其余按源码顺序递归子节点。
// curLine 由 visit() 维护，没有专属行号的错误就用它。

// ---------------- 作用域 ----------------

// Scope 作用域接口。
type Scope interface{ isScope() }

// BlockScope 名字作用域：标识符 → 变量总表中的索引。
type BlockScope struct {
	IdMap map[string]int
}

func (*BlockScope) isScope() {}

// NewBlockScope 构造。
func NewBlockScope() *BlockScope { return &BlockScope{IdMap: make(map[string]int)} }

// FileScope 文件作用域。export 与「未声明就使用的标识符」都落到这里。
type FileScope struct{ BlockScope }

// WhileScope 循环作用域：不参与名字查找（findIdentHost 只认 BlockScope）。
type WhileScope struct {
	StartIndex   int   // continue 跳回这里（循环开头）
	BreakIndices []int // 待回填的 break 跳转目标（code 中的操作数位置）
}

func (*WhileScope) isScope() {}

// ---------------- 最小堆：变量索引回收 ----------------

type minHeap struct{ data []int }

func (h *minHeap) isEmpty() bool { return len(h.data) == 0 }

func (h *minHeap) push(v int) {
	h.data = append(h.data, v)
	i := len(h.data) - 1
	for i > 0 {
		parent := (i - 1) / 2
		if h.data[parent] <= h.data[i] {
			break
		}
		h.data[parent], h.data[i] = h.data[i], h.data[parent]
		i = parent
	}
}

func (h *minHeap) pop() int {
	top := h.data[0]
	last := len(h.data) - 1
	h.data[0] = h.data[last]
	h.data = h.data[:last]
	i := 0
	for {
		l, r := 2*i+1, 2*i+2
		sm := i
		if l < len(h.data) && h.data[l] < h.data[sm] {
			sm = l
		}
		if r < len(h.data) && h.data[r] < h.data[sm] {
			sm = r
		}
		if sm == i {
			break
		}
		h.data[sm], h.data[i] = h.data[i], h.data[sm]
		i = sm
	}
	return top
}

func (h *minHeap) has(v int) bool {
	for _, x := range h.data {
		if x == v {
			return true
		}
	}
	return false
}

// VariableAllocator 变量分配器：所有变量统一编号；块结束时索引进入回收堆复用。
//
// NewUniqueVar 不参与回收 —— 它给 export 与「未声明就使用的标识符」用，
// 变量名非空正是 Program.Exports 的判据。
type VariableAllocator struct {
	Vars     []string
	recycled minHeap
}

func (va *VariableAllocator) num() int { return len(va.Vars) }

func (va *VariableAllocator) newVar() int {
	if !va.recycled.isEmpty() {
		idx := va.recycled.pop()
		va.Vars[idx] = ""
		return idx
	}
	i := len(va.Vars)
	va.Vars = append(va.Vars, "")
	return i
}

func (va *VariableAllocator) newUniqueVar(name string) int {
	i := len(va.Vars)
	va.Vars = append(va.Vars, name) // 不回收：导出变量必须一直占着一个位置
	return i
}

func (va *VariableAllocator) freeVar(idx int) {
	if va.recycled.has(idx) {
		return // 同一索引不重复回收
	}
	va.recycled.push(idx)
}

// StackSizeManager 只记「相对变化」，最大值最后落到 Program.RequiredStackSize。
type StackSizeManager struct {
	size    int
	maxSize int
}

func (m *StackSizeManager) inc(n int) {
	m.size += n
	if m.size > m.maxSize {
		m.maxSize = m.size
	}
}

func (m *StackSizeManager) dec(n int) { m.size -= n }

// converge 分支汇合：某条路径被 GoTo 送走以后，把 size 扳回到「从别处跳到这里」
// 时应有的深度，否则 if / 短路运算符会把容量算成各分支深度之和。
func (m *StackSizeManager) converge(depth int) { m.size = depth }

// ---------------- 编译器 ----------------

// Compiler Compiler(custom) → Compile 把 AST 写进一个 Program。
type Compiler struct {
	prog          *Program
	CustomOpcodes *CustomOpcodeConfig
	Errors        []string
	varAlloc      *VariableAllocator
	stackSizeMgr  *StackSizeManager
	scopeStack    []Scope
	curLine       int
}

// NewCompiler 构造。
func NewCompiler(custom *CustomOpcodeConfig) *Compiler {
	return &Compiler{CustomOpcodes: custom, curLine: -1}
}

// Reset 与 C++ 的 Compiler::Reset 一致：清错误、换自定义指令表。
func (c *Compiler) Reset(custom *CustomOpcodeConfig) {
	c.Errors = nil
	c.CustomOpcodes = custom
}

// Compile 编译 ast，结果直接写进 out。
//
// 有错误时返回 RError 并把 out 复原为空 —— 半成品 Program 跑不了。
//
// preExports：遍历 AST 之前先导出的标识符（宿主注入的全局）。每个名字按给定顺序占
// 一个「永不回收」的槽位；名字进了文件作用域，源码里再 export 同名、或顶层 let 同名，
// 都会报 duplicate。空名字与重名都是编译错误（行号记 0：这些名字不来自源码）。
func (c *Compiler) Compile(ast Node, out *Program, preExports []string) Result {
	c.resetCompile(out)
	c.exportPreExports(preExports)
	c.visit(ast)
	if len(c.Errors) > 0 {
		c.prog.Clear()
		return RError
	}
	out.VariableNum = c.varAlloc.num()
	out.RequiredStackSize = c.stackSizeMgr.maxSize
	return RSuccess
}

func (c *Compiler) exportPreExports(names []string) {
	fs := c.fileScope()
	for _, n := range names {
		// 行号记 0：这些名字不来自源码，硬套 curLine（此刻是 -1）只会误导
		if n == "" {
			c.error(0, "empty name in pre-exports. ")
			continue
		}
		if _, ok := fs.IdMap[n]; ok {
			c.error(0, "duplicate export of \""+n+"\". ")
			continue
		}
		c.declareExported(n, c.varAlloc.newUniqueVar(n))
	}
}

func (c *Compiler) resetCompile(out *Program) {
	c.Errors = nil
	c.varAlloc = &VariableAllocator{}
	c.stackSizeMgr = &StackSizeManager{}
	c.scopeStack = nil
	c.curLine = -1
	c.prog = out
	out.Clear()
	c.scopeStack = append(c.scopeStack, &FileScope{BlockScope{make(map[string]int)}})
}

// ---------------- 指令输出 ----------------

func (c *Compiler) codeSize() int { return len(c.prog.Opcodes) }

func (c *Compiler) emitOp(op Opcode) {
	c.prog.Opcodes = append(c.prog.Opcodes, int(op))
}

func (c *Compiler) emitIndex(idx int) {
	// 写一个操作数（索引 / 跳转目标）。超出 int16 要报错，否则回绕出来的跳转目标
	// 会把 VM 带飞。
	if idx < -32768 || idx > 32767 {
		c.error(c.curLine, "compile output too large: index exceeds int16. ")
		idx = 0
	}
	c.prog.Opcodes = append(c.prog.Opcodes, idx)
}

func (c *Compiler) emitPlaceholder() int {
	// 占位：先写 -1，回填时才知道目标。
	c.prog.Opcodes = append(c.prog.Opcodes, -1)
	return c.codeSize() - 1
}

func (c *Compiler) patchIndex(pos, target int) {
	if target < -32768 || target > 32767 {
		c.error(c.curLine, "compile output too large: jump target exceeds int16. ")
		target = 0
	}
	c.prog.Opcodes[pos] = target
}

// constIndex 常量入池：相同的值只存一份，返回索引。
func (c *Compiler) constIndex(pool []string, v string) int {
	for i, cur := range pool {
		if cur == v {
			return i
		}
	}
	c.prog.StringConsts = append(c.prog.StringConsts, v)
	return len(c.prog.StringConsts) - 1
}

func (c *Compiler) error(line int, msg string) {
	c.Errors = append(c.Errors, "line "+strconv.Itoa(line)+": "+msg)
}

// ---------------- 作用域 ----------------

func (c *Compiler) pushBlockScope() *BlockScope {
	s := NewBlockScope()
	c.scopeStack = append(c.scopeStack, s)
	return s
}

func (c *Compiler) pushWhileScope() *WhileScope {
	s := &WhileScope{}
	c.scopeStack = append(c.scopeStack, s)
	return s
}

func (c *Compiler) popScope() {
	c.scopeStack = c.scopeStack[:len(c.scopeStack)-1]
}

func (c *Compiler) topBlockScope() *BlockScope {
	// 由内向外找最近的名字作用域（FileScope 也算，它继承 BlockScope）。
	for i := len(c.scopeStack) - 1; i >= 0; i-- {
		switch s := c.scopeStack[i].(type) {
		case *FileScope:
			return &s.BlockScope
		case *BlockScope:
			return s
		}
	}
	return nil
}

func (c *Compiler) topWhileScope() *WhileScope {
	for i := len(c.scopeStack) - 1; i >= 0; i-- {
		if ws, ok := c.scopeStack[i].(*WhileScope); ok {
			return ws
		}
	}
	return nil
}

func (c *Compiler) findIdentHost(name string) *BlockScope {
	for i := len(c.scopeStack) - 1; i >= 0; i-- {
		var bs *BlockScope
		switch s := c.scopeStack[i].(type) {
		case *FileScope:
			bs = &s.BlockScope
		case *BlockScope:
			bs = s
		}
		if bs != nil {
			if _, ok := bs.IdMap[name]; ok {
				return bs
			}
		}
	}
	return nil
}

func (c *Compiler) fileScope() *FileScope {
	return c.scopeStack[0].(*FileScope)
}

// ---------------- 遍历 ----------------

func (c *Compiler) visit(n Node) {
	if n == nil {
		return
	}
	c.curLine = n.Line()
	switch e := n.(type) {
	case *Prog:
		c.visitProg(e)
	case *ExprStmt:
		c.visitExprStmt(e)
	case *LetStmt:
		c.visitLetStmt(e)
	case *ReturnStmt:
		c.visitReturnStmt(e)
	case *ExportStmt:
		c.visitExportStmt(e)
	case *BlockStmt:
		c.visitBlockStmt(e)
	case *IfStmt:
		c.visitIfStmt(e)
	case *WhileStmt:
		c.visitWhileStmt(e)
	case *AssignStmt:
		c.visitAssignStmt(e)
	case *BreakStmt:
		c.visitBreakStmt(e)
	case *ContinueStmt:
		c.visitContinueStmt(e)
	case *NullExpr:
		c.emitOp(OpPushNull)
		c.stackSizeMgr.inc(1)
	case *BoolExpr:
		if e.Value {
			c.emitOp(OpPushTrue)
		} else {
			c.emitOp(OpPushFalse)
		}
		c.stackSizeMgr.inc(1)
	case *IntExpr:
		c.emitOp(OpPushInt)
		c.emitIndex(c.strConstIndex(e.Value))
		c.stackSizeMgr.inc(1)
	case *FloatExpr:
		c.emitOp(OpPushFloat)
		c.emitIndex(c.fConstIndex(e.Value))
		c.stackSizeMgr.inc(1)
	case *StringExpr:
		c.emitOp(OpPushString)
		c.emitIndex(c.constIndex(c.prog.StringConsts, e.Value))
		c.stackSizeMgr.inc(1)
	case *BinArrExpr:
		c.emitOp(OpPushBinArr)
		c.emitIndex(c.bConstIndex(e.Value))
		c.stackSizeMgr.inc(1)
	case *IdentExpr:
		idx := c.identSlot(e.Ident)
		c.emitOp(OpPushValue) // 压的是变量的【值】；要槽位请用 PushId
		c.emitIndex(idx)
		c.stackSizeMgr.inc(1)
	case *ArgcExpr:
		c.emitOp(OpArgNum)
		c.stackSizeMgr.inc(1)
	case *ArgsExpr:
		c.visit(e.KeyExpr)
		c.emitOp(OpGetArg) // 弹下标、压结果，栈大小不变
	case *UnaryOpExpr:
		c.visit(e.Expr)
		if e.Op == TNot {
			c.emitOp(OpNot)
		} else if e.Op == TSub {
			c.emitOp(OpMinus)
		}
		// 一元指令：弹 1 压 1，栈大小不变
	case *BinaryOpExpr:
		if e.Op == TOr {
			c.visitOrExpr(e)
			return
		}
		if e.Op == TAnd {
			c.visitAndExpr(e)
			return
		}
		c.visit(e.LeftExpr)
		c.visit(e.RightExpr)
		c.emitOp(binaryOpcode(e.Op))
		c.stackSizeMgr.dec(1) // 弹 2 压 1
	case *CallExpr:
		c.visit(e.Callee)
		for _, a := range e.Args {
			c.visit(a)
		}
		c.emitOp(OpCall)
		c.emitIndex(len(e.Args))
		c.stackSizeMgr.dec(len(e.Args)) // callee + args 换成 1 个返回值
	case *AtExpr:
		c.visit(e.Container)
		for _, k := range e.KeyExprs {
			c.visit(k)
		}
		c.emitOp(OpAt)
		c.emitIndex(len(e.KeyExprs))
		c.stackSizeMgr.dec(len(e.KeyExprs))
	case *CustomOpcodeExpr:
		c.visitCustomOpcodeExpr(e)
	}
}

// ---------------- 语句 ----------------

func (c *Compiler) visitProg(p *Prog) {
	for _, s := range p.Stmts {
		c.visit(s)
	}
}

func (c *Compiler) visitExprStmt(s *ExprStmt) {
	c.visit(s.Expr)
	c.emitOp(OpPop)
	c.stackSizeMgr.dec(1)
}

func (c *Compiler) visitLetStmt(s *LetStmt) {
	bs := c.topBlockScope()
	if bs == nil {
		return
	}
	if s.HasAssign {
		// let a = expr; —— 只有一个标识符
		if len(s.Idents) == 0 {
			return
		}
		name := s.Idents[0]
		if _, ok := bs.IdMap[name]; ok {
			c.error(s.Line_, "duplicate declaration of '"+name+"'. ")
			return
		}
		// 不要 visit 标识符本身（那会生成 PushValue 取值），这里是要绑定到新变量
		idx := c.varAlloc.newVar()
		bs.IdMap[name] = idx
		c.emitOp(OpPushId)
		c.emitIndex(idx)
		c.stackSizeMgr.inc(1)
		c.visit(s.Expr)
		c.emitOp(OpAssign)
		c.stackSizeMgr.dec(2)
	} else {
		for _, nm := range s.Idents {
			if _, ok := bs.IdMap[nm]; ok {
				c.error(s.Line_, "duplicate declaration of '"+nm+"'. ")
				continue
			}
			bs.IdMap[nm] = c.varAlloc.newVar()
		}
	}
}

func (c *Compiler) visitReturnStmt(s *ReturnStmt) {
	for _, e := range s.Exprs {
		c.visit(e)
	}
	c.emitOp(OpReturn)
	c.emitIndex(len(s.Exprs))
	if len(s.Exprs) > c.prog.MaxReturnNum {
		c.prog.MaxReturnNum = len(s.Exprs)
	}
	// Return 会让 VM 直接跳到 code 末尾，栈上的返回值不回收
}

func (c *Compiler) visitExportStmt(s *ExportStmt) {
	if len(c.scopeStack) > 1 {
		c.error(s.Line_, "\"export\" can only be used at top scope. ")
	}
	fs := c.fileScope()
	for _, name := range s.Idents {
		if _, ok := fs.IdMap[name]; ok {
			c.error(s.Line_, "duplicate export of \""+name+"\". ")
			continue
		}
		c.declareExported(name, c.varAlloc.newUniqueVar(name))
	}
}

func (c *Compiler) visitBlockStmt(s *BlockStmt) {
	bs := c.pushBlockScope()
	c.visit(s.Prog)
	c.popScope()
	for _, idx := range bs.IdMap {
		c.varAlloc.freeVar(idx) // 回收局部变量索引
	}
}

func (c *Compiler) visitIfStmt(s *IfStmt) {
	if s.Cond == nil {
		return
	}
	var gotoEndIndices []int
	c.visit(s.Cond)
	c.emitOp(OpIf)
	c.stackSizeMgr.dec(1)
	lastIfPos := c.emitPlaceholder() // 条件为假时跳到这里
	c.visitBodyAsBlock(s.FirstProg)
	c.emitOp(OpGoTo) // 分支走完，跳出整个 if
	gotoEndIndices = append(gotoEndIndices, c.emitPlaceholder())
	c.patchIndex(lastIfPos, c.codeSize())
	for _, ei := range s.Elifs {
		if ei.Cond == nil {
			continue
		}
		c.visit(ei.Cond)
		c.emitOp(OpIf)
		c.stackSizeMgr.dec(1)
		lastIfPos = c.emitPlaceholder()
		c.visitBodyAsBlock(ei.Prog)
		c.emitOp(OpGoTo)
		gotoEndIndices = append(gotoEndIndices, c.emitPlaceholder())
		c.patchIndex(lastIfPos, c.codeSize())
	}
	if s.ElseProg != nil {
		c.visitBodyAsBlock(s.ElseProg)
	}
	for _, pos := range gotoEndIndices {
		c.patchIndex(pos, c.codeSize())
	}
}

func (c *Compiler) visitWhileStmt(s *WhileStmt) {
	ws := c.pushWhileScope()
	ws.StartIndex = c.codeSize() // continue 回到这里
	caseGotoEndPos := -1
	if s.Cond != nil {
		// while cond { } —— cond 可省
		c.visit(s.Cond)
		c.emitOp(OpIf)
		c.stackSizeMgr.dec(1)
		caseGotoEndPos = c.emitPlaceholder()
	}
	c.visitBodyAsBlock(s.Prog)
	c.emitOp(OpGoTo)
	c.emitIndex(ws.StartIndex)
	for _, pos := range ws.BreakIndices {
		c.patchIndex(pos, c.codeSize())
	}
	// 条件可省。无条件时必须跳过回填，否则会把第 0 条指令改成跳转目标。
	if caseGotoEndPos >= 0 {
		c.patchIndex(caseGotoEndPos, c.codeSize())
	}
	c.popScope()
}

func (c *Compiler) visitAssignStmt(s *AssignStmt) {
	if ie, ok := s.LeftExpr.(*IdentExpr); ok {
		// 赋值左端的裸标识符要压【槽位】而不是值，否则 Assign 无处可存。
		idx := c.identSlot(ie.Ident)
		c.emitOp(OpPushId)
		c.emitIndex(idx)
		c.stackSizeMgr.inc(1)
	} else {
		// 可能是使用者设计的数组元素引用、对象成员引用等。压入值。
		c.visit(s.LeftExpr)
	}
	c.visit(s.RightExpr)
	c.emitOp(OpAssign)
	c.stackSizeMgr.dec(2)
}

func (c *Compiler) visitBreakStmt(s *BreakStmt) {
	ws := c.topWhileScope()
	if ws == nil {
		c.error(s.Line_, "cannot use \"break\" outside of a loop. ")
		return
	}
	c.emitOp(OpGoTo)
	ws.BreakIndices = append(ws.BreakIndices, c.emitPlaceholder())
}

func (c *Compiler) visitContinueStmt(s *ContinueStmt) {
	ws := c.topWhileScope()
	if ws == nil {
		c.error(s.Line_, "cannot use \"continue\" outside of a loop. ")
		return
	}
	c.emitOp(OpGoTo)
	c.emitIndex(ws.StartIndex)
}

// ---------------- 表达式：短路 ----------------

func (c *Compiler) visitOrExpr(e *BinaryOpExpr) {
	// 短路或：任一侧为真就 PushTrue，两条路径都在栈上留下恰好 1 个结果。
	c.visit(e.LeftExpr)
	c.emitOp(OpIf)
	c.stackSizeMgr.dec(1)
	firstIfPos := c.emitPlaceholder()
	depthAtIfTarget := c.stackSizeMgr.size // If 已弹掉条件 = 汇合点深度
	c.emitOp(OpPushTrue)
	c.stackSizeMgr.inc(1)
	c.emitOp(OpGoTo)
	gotoEnd1 := c.emitPlaceholder()
	c.patchIndex(firstIfPos, c.codeSize())
	c.stackSizeMgr.converge(depthAtIfTarget) // 后面接的是「左侧为假」这条路径

	c.visit(e.RightExpr)
	c.emitOp(OpIf)
	c.stackSizeMgr.dec(1)
	secondIfPos := c.emitPlaceholder()
	depthAtIfTarget = c.stackSizeMgr.size
	c.emitOp(OpPushTrue)
	c.stackSizeMgr.inc(1)
	c.emitOp(OpGoTo)
	gotoEnd2 := c.emitPlaceholder()
	c.patchIndex(secondIfPos, c.codeSize())
	c.stackSizeMgr.converge(depthAtIfTarget)

	c.emitOp(OpPushFalse) // 两侧都不成立
	c.stackSizeMgr.inc(1)
	c.patchIndex(gotoEnd1, c.codeSize())
	c.patchIndex(gotoEnd2, c.codeSize())
}

func (c *Compiler) visitAndExpr(e *BinaryOpExpr) {
	c.visit(e.LeftExpr)
	c.emitOp(OpIf)
	c.stackSizeMgr.dec(1)
	firstIfPos := c.emitPlaceholder()
	c.visit(e.RightExpr)
	c.emitOp(OpIf)
	c.stackSizeMgr.dec(1)
	secondIfPos := c.emitPlaceholder()
	depthAtIfTarget := c.stackSizeMgr.size // 两侧都为真才落到这里
	c.emitOp(OpPushTrue)
	c.stackSizeMgr.inc(1)
	c.emitOp(OpGoTo)
	gotoEnd := c.emitPlaceholder()
	c.patchIndex(firstIfPos, c.codeSize())
	c.patchIndex(secondIfPos, c.codeSize())
	c.stackSizeMgr.converge(depthAtIfTarget)
	c.emitOp(OpPushFalse)
	c.stackSizeMgr.inc(1)
	c.patchIndex(gotoEnd, c.codeSize())
}

func (c *Compiler) visitCustomOpcodeExpr(e *CustomOpcodeExpr) {
	if c.CustomOpcodes == nil {
		c.error(e.Line_, "undefined custom opcode \""+e.OpcodeName+"\". ")
		return
	}
	info, ok := c.CustomOpcodes.Opcodes[e.OpcodeName]
	if !ok {
		c.error(e.Line_, "undefined custom opcode \""+e.OpcodeName+"\". ")
		return
	}
	isVarArg := info.ArgNum < 0 // 与 C++ 的 isVarArg 同一判据
	if !isVarArg && info.ArgNum != len(e.Args) {
		c.error(e.Line_, "custom opcode \""+e.OpcodeName+"\" expected "+
			strconv.Itoa(info.ArgNum)+" args, but got "+strconv.Itoa(len(e.Args))+". ")
	}
	for _, a := range e.Args {
		c.visit(a)
	}
	c.emitOp(Opcode(info.Opcode))
	if isVarArg {
		c.emitIndex(len(e.Args))
	}
	// 自定义指令没有 callee 入栈，结果仍占 1 格 => dec(参数个数 - 1)
	c.stackSizeMgr.dec(len(e.Args) - 1)
}

// ---------------- 小工具 ----------------

// identSlot 标识符 → 变量槽位索引。没声明过就当作外部变量，登记到文件作用域。
func (c *Compiler) identSlot(name string) int {
	if host := c.findIdentHost(name); host != nil {
		return host.IdMap[name]
	}
	c.declareExported(name, c.varAlloc.newUniqueVar(name))
	return c.fileScope().IdMap[name]
}

func (c *Compiler) declareExported(name string, idx int) {
	// 登记一个会进 Program.Exports 的变量。索引来自 newUniqueVar（不回收）。
	c.fileScope().IdMap[name] = idx
	c.prog.SetExport(name, idx)
}

// visitBodyAsBlock 块 / if 分支 / 循环体在 AST 里都是裸 Prog（没有 BlockStmt 包着），
// 这里补一层 BlockScope，让内部 let 的变量在离开时被回收。
func (c *Compiler) visitBodyAsBlock(p *Prog) {
	bs := c.pushBlockScope()
	if p != nil {
		c.visit(p)
	}
	c.popScope()
	for _, idx := range bs.IdMap {
		c.varAlloc.freeVar(idx)
	}
}

// ---------------- 常量池 ----------------

func (c *Compiler) strConstIndex(v int64) int {
	for i, cur := range c.prog.IntConsts {
		if cur == v {
			return i
		}
	}
	c.prog.IntConsts = append(c.prog.IntConsts, v)
	return len(c.prog.IntConsts) - 1
}

func (c *Compiler) fConstIndex(v float64) int {
	for i, cur := range c.prog.FloatConsts {
		if cur == v {
			return i
		}
	}
	c.prog.FloatConsts = append(c.prog.FloatConsts, v)
	return len(c.prog.FloatConsts) - 1
}

func (c *Compiler) bConstIndex(v []byte) int {
	for i, cur := range c.prog.BinarrConsts {
		if bytesEqual(cur, v) {
			return i
		}
	}
	cp := make([]byte, len(v))
	copy(cp, v)
	c.prog.BinarrConsts = append(c.prog.BinarrConsts, cp)
	return len(c.prog.BinarrConsts) - 1
}

func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func binaryOpcode(op TokenType) Opcode {
	// 二元运算符 → 指令。注意二元 - 是 Sub 而不是 Minus。
	switch op {
	case TEQ:
		return OpEQ
	case TNE:
		return OpNE
	case TLT:
		return OpLT
	case TLE:
		return OpLE
	case TGT:
		return OpGT
	case TGE:
		return OpGE
	case TAdd:
		return OpAdd
	case TSub:
		return OpSub
	case TMul:
		return OpMul
	case TDiv:
		return OpDiv
	case TIDiv:
		return OpIDiv
	case TMod:
		return OpMod
	case TPow:
		return OpPow
	}
	return OpPop // 到不了：parser 只会用上面这些 op 构造 BinaryOpExpr
}

// DumpProgram 「单行产物格式」（docs/zh-cn/compiler-test-plan.md §2.3）。
// 对应 C++ 的私有 dumpLine、GD 的 dump_program、nodejs 的 dumpProgram、
// Python tests/golden.py 的 dump_program —— 不进库，只在测试里用。
func DumpProgram(prog *Program, custom *CustomOpcodeConfig) string {
	hasArg := func(op int) bool {
		if op > int(OpReturn) {
			if custom == nil {
				return false
			}
			for _, info := range custom.Opcodes {
				if info.Opcode == op {
					return info.IsVarArg
				}
			}
			return false
		}
		if op <= int(OpPushTrue) {
			return false
		}
		if op <= int(OpAt) {
			return true
		}
		if op <= int(OpGE) {
			return false
		}
		if op <= int(OpGoTo) {
			return true
		}
		if op <= int(OpArgNum) {
			return false
		}
		return true
	}

	out := "code["
	ops := prog.Opcodes
	i := 0
	for i < len(ops) {
		if i > 0 {
			out += " "
		}
		op := ops[i]
		i++
		if op > int(OpReturn) {
			out += "Opcode(" + strconv.Itoa(op) + ")"
		} else {
			out += OpcodeName[op]
		}
		if hasArg(op) && i < len(ops) {
			out += "(" + strconv.Itoa(ops[i]) + ")"
			i++
		}
	}
	out += "]"

	out += " vars=" + strconv.Itoa(prog.VariableNum)
	out += " stack=" + strconv.Itoa(prog.RequiredStackSize)
	out += " maxRet=" + strconv.Itoa(prog.MaxReturnNum)
	out += " ints=["
	for j, x := range prog.IntConsts {
		if j > 0 {
			out += ","
		}
		out += strconv.FormatInt(x, 10)
	}
	out += "]"
	out += " floats=["
	for j, x := range prog.FloatConsts {
		if j > 0 {
			out += ","
		}
		out += FmtG(x)
	}
	out += "]"
	out += " strs=["
	for j, s := range prog.StringConsts {
		if j > 0 {
			out += ","
		}
		out += Esc(s)
	}
	out += "]"
	out += " binarrs=["
	for j, b := range prog.BinarrConsts {
		if j > 0 {
			out += " "
		}
		out += "[" + FmtBytes(b) + "]"
	}
	out += "]"
	// C++ 的 exports 是 std::map：按名字排序打印（不是插入序）
	names := make([]string, len(prog.Exports))
	for j, e := range prog.Exports {
		names[j] = e.Name
	}
	sort.Strings(names)
	out += " exports=["
	for j, name := range names {
		if j > 0 {
			out += ","
		}
		idx, _ := prog.ExportOf(name)
		out += Esc(name) + ":" + strconv.Itoa(idx)
	}
	out += "]"
	return out
}
