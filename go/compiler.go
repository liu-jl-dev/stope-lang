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
//
// IdOrder：名字 → 声明序号（Compiler.declCounter 的全局值，跨 scope 可比）。
// defer 的「冻结名字绑定」靠它判定：载荷解析到的本地名字若序号晚于 defer 语句处
// 的基线，视为不可见——不被捕获，按隐式导出宿主变量处理（OQ-8）。隐式导出
// （从未声明的宿主变量）记 -1，豁免检查。
//
// Defers：defer 语句在本 scope 的登记（载荷节点、defer 行号、登记时的声明序号
// 基线）。退出点（块尾 / break / continue / return）由 Compiler 逆序拼接 ——
// 运行时没有 defer 栈，顺序在编译期物化。
//
// IsDeferPayload：该 scope 是否为 defer 载荷的隐式作用域。break / continue /
// return 不得跨越它（break/continue 的目标循环在载荷外 → 报错；return 在
// 载荷内一律报错）。
type BlockScope struct {
	IdMap          map[string]int
	IdOrder        map[string]int
	Defers         []deferredEntry
	IsDeferPayload bool
}

// deferredEntry 一个 defer 登记：载荷、defer 行号、登记时的声明序号基线。
type deferredEntry struct {
	stmt          Node
	line          int
	orderBaseline int
}

func (*BlockScope) isScope() {}

// NewBlockScope 构造。
func NewBlockScope() *BlockScope {
	return &BlockScope{IdMap: make(map[string]int), IdOrder: make(map[string]int)}
}

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
	// 声明序号：declareLocal / declareExported（非隐式）时递增，跨 scope 可比。
	// defer 的冻结名字绑定靠它判定「在 defer 之后才声明」。
	declCounter int
	// defer 载荷编译期状态：当前生效的声明序号基线（-1 = 不在拼接中）与
	// 载荷编译期报错（duplicate export）的归责行号（defer 语句行）。
	deferOrderFloor int
	deferErrLine    int
	// 死代码消除：终止语句之后的语句不再发射，defer 也不再登记。
	stmtTerminates bool
	// 最内层 while 体里有没有 break（死循环判定用），按 while 保存/恢复。
	sawBreak bool
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
	// 顶层 defer：程序尾结算。程序以终止语句（return / 死循环等）结尾时
	// 这里不可达（return 出口已在 visitReturnStmt 结算过），再拼就是
	// Return 之后的死代码——跳过；自然结束（fall-through）才需要这份结算。
	if !c.stmtTerminates {
		c.spliceDefers(&c.fileScope().BlockScope)
	}
	c.fileScope().Defers = nil
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
		c.declareExported(n, c.varAlloc.newUniqueVar(n), false)
	}
}

func (c *Compiler) resetCompile(out *Program) {
	c.Errors = nil
	c.varAlloc = &VariableAllocator{}
	c.stackSizeMgr = &StackSizeManager{}
	c.scopeStack = nil
	c.curLine = -1
	c.declCounter = 0
	c.deferOrderFloor = -1
	c.deferErrLine = -1
	c.stmtTerminates = false
	c.sawBreak = false
	c.prog = out
	out.Clear()
	c.scopeStack = append(c.scopeStack,
		&FileScope{BlockScope{make(map[string]int), make(map[string]int), nil, false}})
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

// findIdentHostFrozen 冻结名字绑定下的宿主查找（仅在拼接 defer 载荷时使用）。
//
// 最内层载荷根（栈中最靠内的 IsDeferPayload 块）以内是载荷自己的内部作用域，
// 名字解析不过滤；它以外才应用「defer 语句处可见」的基线 —— 跳过声明序号 >=
// floor 的本地名（那些在 defer 之后才声明，对载荷不可见）。
func (c *Compiler) findIdentHostFrozen(name string, floor int) *BlockScope {
	payloadIdx := -1
	for i := len(c.scopeStack) - 1; i >= 0; i-- {
		if bs, ok := c.scopeStack[i].(*BlockScope); ok && bs.IsDeferPayload {
			payloadIdx = i
			break
		}
	}
	for i := len(c.scopeStack) - 1; i >= 0; i-- {
		var bs *BlockScope
		switch s := c.scopeStack[i].(type) {
		case *FileScope:
			bs = &s.BlockScope
		case *BlockScope:
			bs = s
		}
		if bs == nil {
			continue
		}
		if _, ok := bs.IdMap[name]; !ok {
			continue
		}
		if i < payloadIdx { // 登记 scope 一侧：跳过 defer 之后才声明的（遮蔽）
			// 基线 = 登记时的 declCounter（= 下一个待分配序号），所以
			// 「order >= 基线」⟺ 在 defer 之后声明。
			if order, ok := bs.IdOrder[name]; ok && order >= 0 && order >= floor {
				continue
			}
		}
		return bs
	}
	return nil
}

// resolveAtSplice 拼接期间的名字解析（冻结绑定）。冻结查找命中 → 用冻结规则
// （名字→槽位按 defer 语句位置定）。未命中 → 不再查 now、不再报 declared
// after（OQ-8，2026-11-08 定夺：后文声明的本地名不被捕获，按隐式导出宿主变量
// 处理，同未声明名字的路径）。FileScope 已有同名（后文顶层 let / export 声明
// 的文件级变量）时无法再建同名宿主变量，报重复——行号归 defer 语句（冲突在
// defer 绑定符号时就已注定；若 defer 先于顶层声明结算，则由后文 declareLocal
// 报 duplicate declaration，两处报错互斥）。返回 FileScope：编译已失败，避免
// 连锁隐式导出。都空 → 返回 nil，调用方走隐式导出路径（新建宿主变量）。
// 与 cpp/src/compiler.cpp 的 resolveAtSplice 一致。
func (c *Compiler) resolveAtSplice(name string) *BlockScope {
	frozen := c.findIdentHostFrozen(name, c.deferOrderFloor)
	if frozen != nil {
		return frozen
	}
	fs := c.fileScope()
	if _, ok := fs.IdMap[name]; ok {
		c.error(c.deferErrLine, "duplicate export of \""+name+"\". ")
		return &fs.BlockScope // 编译已失败；返回宿主避免连锁隐式导出
	}
	return nil // 调用方走隐式导出路径（新建宿主变量）
}

// spliceDefers 退出点结算：逆序拼接 bs 登记的 defer 载荷（LIFO，后登记先执行）。
//
// ⚠ 不清空 bs.Defers：一个块可以有多个运行期出口（break / continue / return
// 各一处 + 块尾），每个出口都要拼一份自己的副本；只有块尾 / 程序尾的「最终结算」
// 由调用方在拼接后清空。某个载荷编译出错即停（错误去重：载荷在每个退出点重编译，
// 报一次就够）。
func (c *Compiler) spliceDefers(bs *BlockScope) {
	if len(bs.Defers) == 0 || len(c.Errors) > 0 {
		return
	}
	for k := len(bs.Defers) - 1; k >= 0; k-- {
		if len(c.Errors) > 0 {
			return
		}
		d := bs.Defers[k]
		savedFloor := c.deferOrderFloor
		savedLine := c.deferErrLine
		c.deferOrderFloor = d.orderBaseline
		c.deferErrLine = d.line
		// 载荷包一层隐式作用域并打标记：break/continue/return 的越界检查
		// 靠它识别「从收尾代码里跳回主流程」。
		ps := c.pushBlockScope()
		ps.IsDeferPayload = true
		c.visit(d.stmt)
		// 载荷 scope 自己的 defers（直接嵌套 defer defer X 落在这里）：
		// 触发点 = 载荷 scope 结束 = 同一退出点，就地拼接。
		c.spliceDefers(ps)
		c.popScope()
		for _, idx := range ps.IdMap {
			c.varAlloc.freeVar(idx)
		}
		c.deferOrderFloor = savedFloor
		c.deferErrLine = savedLine
	}
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
	case *DeferStmt:
		c.visitDeferStmt(e)
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
	// 语句序列：终止语句（return / break / continue / 死循环）之后的语句
	// 在语言语义下执行不到——不再发射，也不登记它们的 defer（死代码消除）。
	// 序列的终止性 = 最后一条已发射语句。
	terminated := false
	for _, s := range p.Stmts {
		if terminated {
			break
		}
		c.stmtTerminates = false // 每条语句先清零；终止语句的 visitor 置 true
		c.visit(s)
		terminated = c.stmtTerminates
	}
	c.stmtTerminates = terminated
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
		c.declareLocal(bs, name, idx)
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
			c.declareLocal(bs, nm, c.varAlloc.newVar())
		}
	}
}

func (c *Compiler) visitReturnStmt(s *ReturnStmt) {
	// defer 边界：return 的终点是整个程序，在载荷内必然越界，一律报错。
	for _, sc := range c.scopeStack {
		if bs, ok := sc.(*BlockScope); ok && bs.IsDeferPayload {
			c.error(s.Line_, "\"return\" cannot be used in a defer statement. ")
			return
		}
	}
	// 顺序：先结算，再求返回值，最后 Return（结算 → PushValue → Return）。
	// 结算先于退出动作，与块退出一致——defer 可以影响返回值。
	for i := len(c.scopeStack) - 1; i >= 0; i-- {
		switch b := c.scopeStack[i].(type) {
		case *FileScope:
			c.spliceDefers(&b.BlockScope)
		case *BlockScope:
			c.spliceDefers(b)
		}
	}
	for _, e := range s.Exprs {
		c.visit(e)
	}
	c.emitOp(OpReturn)
	c.emitIndex(len(s.Exprs))
	if len(s.Exprs) > c.prog.MaxReturnNum {
		c.prog.MaxReturnNum = len(s.Exprs)
	}
	c.stmtTerminates = true
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
		c.declareExported(name, c.varAlloc.newUniqueVar(name), false)
	}
}

func (c *Compiler) visitBlockStmt(s *BlockStmt) {
	bs := c.pushBlockScope()
	c.visit(s.Prog)
	// 块尾结算：本 scope 的 defer 在这里执行（LIFO）。块体以终止语句结尾时
	// 这里不可达（return 出口已结算、break/continue 出口就地结算过）——
	// 跳过，避免拼出不可达的副本。
	if !c.stmtTerminates {
		c.spliceDefers(bs)
	}
	bs.Defers = nil // 最终结算：途中出口（break/return）已各拼过副本
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
	allBranchesTerminate := true
	c.visit(s.Cond)
	c.emitOp(OpIf)
	c.stackSizeMgr.dec(1)
	lastIfPos := c.emitPlaceholder() // 条件为假时跳到这里
	c.visitBodyAsBlock(s.FirstProg)
	branchTerm := c.stmtTerminates
	allBranchesTerminate = allBranchesTerminate && branchTerm
	if !branchTerm { // 分支走完会落到这里，需要跳出整个 if；终止则死代码
		c.emitOp(OpGoTo)
		gotoEndIndices = append(gotoEndIndices, c.emitPlaceholder())
	}
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
		branchTerm = c.stmtTerminates
		allBranchesTerminate = allBranchesTerminate && branchTerm
		if !branchTerm {
			c.emitOp(OpGoTo)
			gotoEndIndices = append(gotoEndIndices, c.emitPlaceholder())
		}
		c.patchIndex(lastIfPos, c.codeSize())
	}
	hasElse := s.ElseProg != nil
	if hasElse {
		c.visitBodyAsBlock(s.ElseProg)
	} else {
		allBranchesTerminate = false // 无 else：条件全假时落到 if 之后
	}
	for _, pos := range gotoEndIndices {
		c.patchIndex(pos, c.codeSize())
	}
	// if 语句的终止性：else 存在且所有分支终止（组合式，逐分支局部判断）
	c.stmtTerminates = hasElse && allBranchesTerminate
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
	// sawBreak 按 while 配对保存/恢复：嵌套循环里的 break 只算最内层的
	savedSawBreak := c.sawBreak
	c.sawBreak = false
	c.visitBodyAsBlock(s.Prog)
	bodyTerm := c.stmtTerminates
	bodySawBreak := c.sawBreak
	c.sawBreak = savedSawBreak
	if !bodyTerm { // 体终止（return/break/continue 收尾）则回跳是死代码
		c.emitOp(OpGoTo)
		c.emitIndex(ws.StartIndex)
	}
	for _, pos := range ws.BreakIndices {
		c.patchIndex(pos, c.codeSize())
	}
	// 条件可省。无条件时必须跳过回填，否则会把第 0 条指令改成跳转目标。
	if caseGotoEndPos >= 0 {
		c.patchIndex(caseGotoEndPos, c.codeSize())
	}
	// while 的终止性：只有「无条件 + 体不含本层 break」的真死循环才永不
	// 退出。`while true { }` 带条件，按可退出处理（用户明确要求），不视同
	// `while { }`，不做字面量折叠。
	c.stmtTerminates = s.Cond == nil && !bodySawBreak
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
	// 找最内层 WhileScope。途中先撞到 defer 载荷边界 = 目标循环在载荷外：
	// 载荷在退出点才执行，break 从收尾代码里跳回主流程是灾难语义，禁。
	wi := -1
	for i := len(c.scopeStack) - 1; i >= 0; i-- {
		if _, ok := c.scopeStack[i].(*WhileScope); ok {
			wi = i
			break
		}
		if bs, ok := c.scopeStack[i].(*BlockScope); ok && bs.IsDeferPayload {
			c.error(s.Line_, "\"break\" cannot cross a defer statement. ")
			return
		}
	}
	if wi < 0 {
		c.error(s.Line_, "cannot use \"break\" outside of a loop. ")
		return
	}
	// 结算 break 越过的所有块：从最内层到循环体块（不含 WhileScope 本身、
	// 不含循环外的任何 scope）。运行时 break 直接跳循环尾，这些块的正常
	// 块尾拼接不会执行到，必须在跳转前就地结算。
	for i := len(c.scopeStack) - 1; i > wi; i-- {
		if bs, ok := c.scopeStack[i].(*BlockScope); ok {
			c.spliceDefers(bs)
		}
	}
	c.emitOp(OpGoTo)
	ws := c.scopeStack[wi].(*WhileScope)
	ws.BreakIndices = append(ws.BreakIndices, c.emitPlaceholder())
	c.sawBreak = true // 告知最内层 while：本层有 break（死循环判定用）
	c.stmtTerminates = true
}

func (c *Compiler) visitContinueStmt(s *ContinueStmt) {
	// 同 break：continue 也退出循环体块，体块的 defer 必须先结算。
	wi := -1
	for i := len(c.scopeStack) - 1; i >= 0; i-- {
		if _, ok := c.scopeStack[i].(*WhileScope); ok {
			wi = i
			break
		}
		if bs, ok := c.scopeStack[i].(*BlockScope); ok && bs.IsDeferPayload {
			c.error(s.Line_, "\"continue\" cannot cross a defer statement. ")
			return
		}
	}
	if wi < 0 {
		c.error(s.Line_, "cannot use \"continue\" outside of a loop. ")
		return
	}
	for i := len(c.scopeStack) - 1; i > wi; i-- {
		if bs, ok := c.scopeStack[i].(*BlockScope); ok {
			c.spliceDefers(bs)
		}
	}
	c.emitOp(OpGoTo)
	c.emitIndex(c.scopeStack[wi].(*WhileScope).StartIndex)
	c.stmtTerminates = true
}

func (c *Compiler) visitDeferStmt(s *DeferStmt) {
	bs := c.topBlockScope()
	if bs == nil {
		return // 不可能：FileScope 常驻栈底
	}
	// 纯编译期登记，defer 语句位置零指令。载荷在退出点才编译（每个退出点
	// 各编译一次——If/GoTo 操作数是绝对下标，编译一次再拷贝会破坏跳转目标）。
	// 死代码里的 defer 到不了这里：visitProg 在终止语句后停止访问。
	bs.Defers = append(bs.Defers, deferredEntry{s.Stmt, s.Line_, c.declCounter})
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

// identSlot 标识符 → 变量槽位索引。没声明过就当作外部变量，登记到文件作用域
// （名字非空正是 Program.Exports 的判据）。PushValue / PushId 共用这一处查找；
// 拼接 defer 载荷时走冻结名字绑定（resolveAtSplice）。
func (c *Compiler) identSlot(name string) int {
	var host *BlockScope
	if c.deferOrderFloor >= 0 {
		host = c.resolveAtSplice(name)
	} else {
		host = c.findIdentHost(name)
	}
	if host != nil {
		return host.IdMap[name]
	}
	c.declareExported(name, c.varAlloc.newUniqueVar(name), true)
	return c.fileScope().IdMap[name]
}

// declareExported 登记一个会进 Program.Exports 的变量。索引来自 newUniqueVar
// （不回收）。implicitExport：隐式导出（从未声明的宿主变量）记序号 -1，豁免
// defer 冻结绑定检查——它不是本地槽位，是宿主变量。
func (c *Compiler) declareExported(name string, idx int, implicitExport bool) {
	c.fileScope().IdMap[name] = idx
	if implicitExport {
		c.fileScope().IdOrder[name] = -1
	} else {
		c.fileScope().IdOrder[name] = c.declCounter
		c.declCounter++
	}
	c.prog.SetExport(name, idx)
}

// declareLocal 登记一个局部变量：名字只进块作用域（宿主看不到），声明序号取
// declCounter 的全局当前值。
func (c *Compiler) declareLocal(bs *BlockScope, name string, idx int) {
	bs.IdMap[name] = idx
	bs.IdOrder[name] = c.declCounter
	c.declCounter++
}

// visitBodyAsBlock 块 / if 分支 / 循环体在 AST 里都是裸 Prog（没有 BlockStmt 包着），
// 这里补一层 BlockScope，让内部 let 的变量在离开时被回收。
func (c *Compiler) visitBodyAsBlock(p *Prog) {
	bs := c.pushBlockScope()
	if p != nil {
		c.visit(p)
	}
	// 块尾结算（if 分支 / 循环体同普通块）。体以终止语句结尾时这里不可达，
	// 跳过——出口结算（return / break / continue）已就地拼过副本。
	if !c.stmtTerminates {
		c.spliceDefers(bs)
	}
	bs.Defers = nil // 最终结算
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
