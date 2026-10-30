// 编译器：把 AST 编译成 Program（指令流 + 常量池 + 变量表）——
// 端口 cpp/src/compiler.cpp（C++ 为权威实现）。
//
// 【指令流的形状】Program.opcodes 是 number 数组，指令与操作数混在同一个序列里。
// 带操作数的指令：
//   PushInt / PushFloat / PushString / PushBinArr / PushValue / PushId
//                                              —— 常量池或变量表的索引
//   Call / At                                  —— 参数个数
//   If / GoTo                                  —— 跳转目标（opcodes 下标）
//   Return                                     —— 返回值个数
//   custom                                     —— 变长参数时多一个参数个数
// 其余指令无操作数（见 opcode.hasAParam）。
//
// 【PushValue 与 PushId 的分工】PushId 压的是槽位引用（左值），只有两处产生：
//   「有赋值的 let」左侧、Assign 左端是裸标识符时。其余读变量一律 PushValue（压值）。
//   所以执行器【不需要】在运算指令里做解引用兜底 —— 那样只会掩盖编译器的产物错误。
//
// 【遍历骨架】继承 ASTVisitor（对齐 C++：ASTVisitor + visitMap），语义动作全在
// onVisitXxx 里。基类的默认实现只是「按源码顺序递归子节点」，这里凡是需要发指令的
// 一律整段重写（不再下钻到 super），其余靠基类递归。curLine 由基类的 visit() 维护，
// 没有专属行号的错误就用它。

import { TokenType } from './token.js'
import { Opcode, kFirstCustomOpcode } from './opcode.js'
import { Result } from './common.js'
import { ASTVisitor } from './ast_visitor.js'
import { NodeType } from './ast.js'
import { clearProgram } from './program.js'

// ====================================================================
// 作用域
class Scope {
  constructor() {
    this.type = 'scope' // 'file' / 'block' / 'while'
  }
}

// 名字作用域：标识符 -> 变量总表中的索引
class BlockScope extends Scope {
  constructor() {
    super()
    this.type = 'block'
    this.idMap = new Map()
  }
}

// 文件作用域。export 与「未声明就使用的标识符」都落到这里。
class FileScope extends BlockScope {
  constructor() {
    super()
    this.type = 'file'
  }
}

// 循环作用域：不参与名字查找（findIdentHost 只认 BlockScope）
class WhileScope extends Scope {
  constructor() {
    super()
    this.type = 'while'
    this.startIndex = 0 // continue 跳回这里（循环开头）
    this.breakIndices = [] // 待回填的 break 跳转目标（code 中的操作数位置）
  }
}

// 最小堆：变量索引回收用，保证总是复用最小的空位（与 C++ 的 std::priority_queue
// 配 greater 一样，产出的槽位编号可预测、可比对）
class MinHeap {
  constructor() {
    this.data = [0] // 1 起算，方便算父子下标
    this.count = 0
  }
  isEmpty() {
    return this.count === 0
  }
  push(v) {
    this.data.push(v)
    this.count += 1
    this.precUp(this.count)
  }
  pop() {
    const o = this.data[1]
    this.data[1] = this.data[this.count]
    this.data.pop()
    this.count -= 1
    this.precDown(1)
    return o
  }
  has(v) {
    for (let i = 1; i <= this.count; ++i) if (this.data[i] === v) return true
    return false
  }
  minChildId(i) {
    const l = i * 2
    const r = l + 1
    if (r > this.count) return l
    if (this.data[l] < this.data[r]) return l
    return r
  }
  swap(a, b) {
    const t = this.data[a]
    this.data[a] = this.data[b]
    this.data[b] = t
  }
  precUp(i) {
    let now = i
    let next = Math.floor(i / 2)
    while (next > 0) {
      if (this.data[now] < this.data[next]) this.swap(now, next)
      now = next
      next = Math.floor(next / 2)
    }
  }
  precDown(i) {
    while (i * 2 < this.count) {
      const c = this.minChildId(i)
      if (this.data[i] > this.data[c]) this.swap(i, c)
      i = c
    }
  }
}

// 变量分配器：所有变量统一编号；块结束时索引进入回收堆复用。
// newUniqueVar 不参与回收 —— 它给 export 与「未声明就使用的标识符」用，
// 变量名非空正是 Program.exports 的判据。
class VariableAllocator {
  constructor() {
    this.vars = []
    this.recycled = new MinHeap()
  }
  num() {
    return this.vars.length
  }
  newVar(name = '') {
    if (!this.recycled.isEmpty()) {
      const idx = this.recycled.pop()
      this.vars[idx] = name
      return idx
    }
    const i = this.vars.length
    this.vars.push(name)
    return i
  }
  newUniqueVar(name) {
    const i = this.vars.length
    this.vars.push(name) // 不回收：导出变量必须一直占着一个位置
    return i
  }
  freeVar(idx) {
    if (this.recycled.has(idx)) return // 同一索引不重复回收
    this.recycled.push(idx)
  }
}

// 只记「相对变化」，最大值最后落到 Program.requiredStackSize。
// 记账是**线性**的（按 emit 顺序走一遍），遇到分支就得手动「掰回去」——见 converge()。
class StackSizeManager {
  constructor() {
    this.size = 0
    this.maxSize = 0
  }
  inc(n = 1) {
    this.size += n
    if (this.size > this.maxSize) this.maxSize = this.size
  }
  dec(n = 1) {
    this.size -= n
  }
  // 分支汇合。线性记账只能沿一条路径走，所以某条路径被 GoTo 送走以后，
  // 要把 size 扳回到「从别处跳到这里」时应有的深度，否则 if / 短路运算符
  // 会把容量算成各分支深度之和（实测 `a or b;` 会算成 3）。
  converge(depth) {
    this.size = depth
  }
}

// 常量池里“值相等”的判据：BigInt / Number / String 用 ===；Uint8Array 逐字节比。
// （C++ 的 std::find 对 std::vector<char> 是逐元素比较，JS 的 Array.find 只有同一引用
// 才相等 —— 不特殊处理会让 'a' 与 'a' 各占一个槽位，产物与 C++ 不一致。）
function sameConst(a, b) {
  if (a instanceof Uint8Array && b instanceof Uint8Array) {
    if (a.length !== b.length) return false
    for (let i = 0; i < a.length; ++i) if (a[i] !== b[i]) return false
    return true
  }
  return a === b
}

class Compiler extends ASTVisitor {
  constructor(custom = null) {
    super()
    this.prog = null // 正在写入的 Program，不拥有
    this.customOpcodes = custom // 可空，只读（不拥有）
    this.errors = []
    this.varAlloc = null
    this.stackSizeMgr = null
    this.scopeStack = []
  }

  // 与 C++ 的 Compiler::Reset 一致：清错误、换自定义指令表。
  Reset(custom = null) {
    this.errors = []
    this.customOpcodes = custom
  }

  // ---------------- 对外接口 ----------------
  // 编译 ast，结果直接写进 out。有错误时返回 Result.Error 并把 out 复原为空 ——
  // 半成品 Program 跑不了，留着反而误导。
  Compile(ast, out) {
    this.resetCompile(out)
    this.visit(ast)
    if (this.errors.length > 0) {
      clearProgram(this.prog)
      return Result.Error
    }
    out.variableNum = this.varAlloc.num()
    out.requiredStackSize = this.stackSizeMgr.maxSize
    return Result.Success
  }

  resetCompile(out) {
    this.errors = []
    this.varAlloc = new VariableAllocator()
    this.stackSizeMgr = new StackSizeManager()
    this.scopeStack = []
    this.curLine = -1
    this.prog = out
    clearProgram(out)
    this.scopeStack.push(new FileScope())
  }

  // ---------------- 指令输出 ----------------
  codeSize() {
    return this.prog.opcodes.length
  }
  emitOp(op) {
    this.prog.opcodes.push(op)
  }
  // 写一个操作数（索引 / 跳转目标）。超出 int16 要报错，否则回绕出来的跳转目标
  // 会把 VM 带飞。
  emitIndex(idx) {
    if (idx < -32768 || idx > 32767) {
      this.error(this.curLine, 'compile output too large: index exceeds int16. ')
      idx = 0
    }
    this.prog.opcodes.push(idx)
  }
  emitPlaceholder() {
    // 占位：先写 -1，回填时才知道目标
    this.prog.opcodes.push(-1)
    return this.codeSize() - 1
  }
  patchIndex(pos, target) {
    if (target < -32768 || target > 32767) {
      this.error(this.curLine, 'compile output too large: jump target exceeds int16. ')
      target = 0
    }
    this.prog.opcodes[pos] = target
  }

  // 常量入池：相同的值只存一份，返回索引。直接写 Program 里那个池子，
  // 不给编译器再留一份副本。
  constIndex(pool, v) {
    for (let i = 0; i < pool.length; ++i) if (sameConst(pool[i], v)) return i
    pool.push(v)
    return pool.length - 1
  }

  error(line, msg) {
    this.errors.push(`line ${line}: ${msg}`)
  }

  // ---------------- 作用域 ----------------
  pushBlockScope() {
    const s = new BlockScope()
    this.scopeStack.push(s)
    return s
  }
  pushWhileScope() {
    const s = new WhileScope()
    this.scopeStack.push(s)
    return s
  }
  popScope() {
    this.scopeStack.pop()
  }
  // 由内向外找最近的名字作用域（FileScope 也算，它继承 BlockScope）
  topBlockScope() {
    for (let i = this.scopeStack.length - 1; i >= 0; --i) {
      const s = this.scopeStack[i]
      if (s instanceof BlockScope) return s
    }
    return null
  }
  topWhileScope() {
    for (let i = this.scopeStack.length - 1; i >= 0; --i) {
      const s = this.scopeStack[i]
      if (s instanceof WhileScope) return s
    }
    return null
  }
  findIdentHost(name) {
    for (let i = this.scopeStack.length - 1; i >= 0; --i) {
      const s = this.scopeStack[i]
      if (s instanceof BlockScope && s.idMap.has(name)) return s
    }
    return null
  }
  fileScope() {
    return this.scopeStack[0]
  }

  // ---------------- 语句 ----------------
  onVisitProg(p) {
    for (const s of p.stmts) this.visit(s)
  }
  onVisitExprStmt(s) {
    this.visit(s.expr)
    this.emitOp(Opcode.Pop)
    this.stackSizeMgr.dec()
  }
  onVisitLetStmt(s) {
    const bs = this.topBlockScope()
    if (bs === null) return
    if (s.hasAssign) {
      // let a = expr; —— 只有一个标识符
      if (s.idents.length === 0) return
      const name = s.idents[0]
      if (bs.idMap.has(name)) {
        this.error(s.line, `duplicate declaration of '${name}'. `)
        return
      }
      // 不要 visit 标识符本身（那会生成 PushValue 取值），这里是要绑定到新变量
      const idx = this.varAlloc.newVar()
      bs.idMap.set(name, idx)
      this.emitOp(Opcode.PushId)
      this.emitIndex(idx)
      this.stackSizeMgr.inc()
      this.visit(s.expr)
      this.emitOp(Opcode.Assign)
      this.stackSizeMgr.dec(2)
    } else {
      for (const nm of s.idents) {
        if (bs.idMap.has(nm)) {
          this.error(s.line, `duplicate declaration of '${nm}'. `)
          continue
        }
        bs.idMap.set(nm, this.varAlloc.newVar())
      }
    }
  }
  onVisitReturnStmt(s) {
    for (const e of s.exprs) this.visit(e)
    this.emitOp(Opcode.Return)
    this.emitIndex(s.exprs.length)
    this.prog.maxReturnNum = Math.max(this.prog.maxReturnNum, s.exprs.length)
    // Return 会让 VM 直接跳到 code 末尾，栈上的返回值不回收
  }
  onVisitExportStmt(s) {
    if (this.scopeStack.length > 1) {
      this.error(s.line, '"export" can only be used at top scope. ')
    }
    const fs = this.fileScope()
    for (const id of s.idents) {
      if (fs.idMap.has(id)) {
        this.error(s.line, `duplicate export of "${id}". `)
        continue
      }
      this.declareExported(id, this.varAlloc.newUniqueVar(id))
    }
  }
  onVisitBlockStmt(s) {
    const bs = this.pushBlockScope()
    this.visit(s.prog)
    this.popScope()
    for (const idx of bs.idMap.values()) this.varAlloc.freeVar(idx) // 回收局部变量索引
  }
  onVisitIfStmt(s) {
    if (s.cond === null) return
    const gotoEndIndices = []
    this.visit(s.cond)
    this.emitOp(Opcode.If)
    this.stackSizeMgr.dec()
    let lastIfPos = this.emitPlaceholder() // 条件为假时跳到这里
    this.visitBodyAsBlock(s.firstProg)
    this.emitOp(Opcode.GoTo) // 分支走完，跳出整个 if
    gotoEndIndices.push(this.emitPlaceholder())
    this.patchIndex(lastIfPos, this.codeSize())
    for (const ei of s.elifs) {
      if (ei.cond === null) continue
      this.visit(ei.cond)
      this.emitOp(Opcode.If)
      this.stackSizeMgr.dec()
      lastIfPos = this.emitPlaceholder()
      this.visitBodyAsBlock(ei.prog)
      this.emitOp(Opcode.GoTo)
      gotoEndIndices.push(this.emitPlaceholder())
      this.patchIndex(lastIfPos, this.codeSize())
    }
    if (s.elseProg !== null) this.visitBodyAsBlock(s.elseProg)
    for (const pos of gotoEndIndices) this.patchIndex(pos, this.codeSize())
  }
  onVisitWhileStmt(s) {
    const ws = this.pushWhileScope()
    ws.startIndex = this.codeSize() // continue 回到这里
    let caseGotoEndPos = -1
    if (s.cond !== null) {
      // while cond { } —— cond 可省
      this.visit(s.cond)
      this.emitOp(Opcode.If)
      this.stackSizeMgr.dec()
      caseGotoEndPos = this.emitPlaceholder()
    }
    this.visitBodyAsBlock(s.prog)
    this.emitOp(Opcode.GoTo)
    this.emitIndex(ws.startIndex)
    for (const pos of ws.breakIndices) this.patchIndex(pos, this.codeSize())
    // 条件可省。无条件时必须跳过回填，否则会把第 0 条指令改成跳转目标。
    if (caseGotoEndPos >= 0) this.patchIndex(caseGotoEndPos, this.codeSize())
    this.popScope()
  }
  onVisitAssignStmt(s) {
    if (s.leftExpr.nodeType === NodeType.IdentExpr) {
      // 赋值左端的裸标识符要压【槽位】而不是值，否则 Assign 无处可存。
      // 这条与 onVisitIdentExpr 的 PushValue 是一对：只有这里和
      // 「有赋值的 let」会产生 PushId。
      const idx = this.identSlot(s.leftExpr.ident)
      this.emitOp(Opcode.PushId)
      this.emitIndex(idx)
      this.stackSizeMgr.inc()
    } else {
      // 可能是使用者设计的数组元素引用、对象成员引用等。压入值。
      this.visit(s.leftExpr)
    }
    this.visit(s.rightExpr)
    this.emitOp(Opcode.Assign)
    this.stackSizeMgr.dec(2)
  }
  onVisitBreakStmt(s) {
    const ws = this.topWhileScope()
    if (ws === null) {
      this.error(s.line, 'cannot use "break" outside of a loop. ')
      return
    }
    this.emitOp(Opcode.GoTo)
    ws.breakIndices.push(this.emitPlaceholder())
  }
  onVisitContinueStmt(s) {
    const ws = this.topWhileScope()
    if (ws === null) {
      this.error(s.line, 'cannot use "continue" outside of a loop. ')
      return
    }
    this.emitOp(Opcode.GoTo)
    this.emitIndex(ws.startIndex)
  }

  // ---------------- 表达式 ----------------
  onVisitNullExpr(_n = null) {
    this.emitOp(Opcode.PushNull)
    this.stackSizeMgr.inc()
  }
  onVisitBoolExpr(e) {
    this.emitOp(e.value ? Opcode.PushTrue : Opcode.PushFalse)
    this.stackSizeMgr.inc()
  }
  onVisitIntExpr(e) {
    this.emitOp(Opcode.PushInt)
    this.emitIndex(this.constIndex(this.prog.intConsts, e.value))
    this.stackSizeMgr.inc()
  }
  onVisitFloatExpr(e) {
    this.emitOp(Opcode.PushFloat)
    this.emitIndex(this.constIndex(this.prog.floatConsts, e.value))
    this.stackSizeMgr.inc()
  }
  onVisitStringExpr(e) {
    this.emitOp(Opcode.PushString)
    this.emitIndex(this.constIndex(this.prog.stringConsts, e.value))
    this.stackSizeMgr.inc()
  }
  onVisitBinArrExpr(e) {
    this.emitOp(Opcode.PushBinArr)
    this.emitIndex(this.constIndex(this.prog.binArrConsts, e.value))
    this.stackSizeMgr.inc()
  }
  onVisitIdentExpr(e) {
    const idx = this.identSlot(e.ident)
    this.emitOp(Opcode.PushValue) // 压的是变量的【值】；要槽位请用 PushId
    this.emitIndex(idx)
    this.stackSizeMgr.inc()
  }
  onVisitArgcExpr(_n = null) {
    this.emitOp(Opcode.ArgNum)
    this.stackSizeMgr.inc()
  }
  onVisitArgsExpr(e) {
    this.visit(e.keyExpr)
    this.emitOp(Opcode.GetArg) // 弹下标、压结果，栈大小不变
  }
  onVisitUnaryOpExpr(e) {
    this.visit(e.expr)
    if (e.op === TokenType.Not) this.emitOp(Opcode.Not)
    else if (e.op === TokenType.Sub) this.emitOp(Opcode.Minus)
    // 一元指令：弹 1 压 1，栈大小不变
  }
  onVisitBinaryOpExpr(e) {
    if (e.op === TokenType.Or) {
      this.onVisitOrExpr(e)
      return
    }
    if (e.op === TokenType.And) {
      this.onVisitAndExpr(e)
      return
    }
    this.visit(e.leftExpr)
    this.visit(e.rightExpr)
    this.emitOp(binaryOpcode(e.op))
    this.stackSizeMgr.dec() // 弹 2 压 1
  }
  // 短路或：任一侧为真就 PushTrue，两条路径都在栈上留下恰好 1 个结果。
  onVisitOrExpr(e) {
    this.visit(e.leftExpr)
    this.emitOp(Opcode.If)
    this.stackSizeMgr.dec()
    const firstIfPos = this.emitPlaceholder()
    let depthAtIfTarget = this.stackSizeMgr.size // If 已弹掉条件 = 汇合点深度
    this.emitOp(Opcode.PushTrue)
    this.stackSizeMgr.inc()
    this.emitOp(Opcode.GoTo)
    const gotoEnd1 = this.emitPlaceholder()
    this.patchIndex(firstIfPos, this.codeSize())
    this.stackSizeMgr.converge(depthAtIfTarget) // 后面接的是「左侧为假」这条路径

    this.visit(e.rightExpr)
    this.emitOp(Opcode.If)
    this.stackSizeMgr.dec()
    const secondIfPos = this.emitPlaceholder()
    depthAtIfTarget = this.stackSizeMgr.size
    this.emitOp(Opcode.PushTrue)
    this.stackSizeMgr.inc()
    this.emitOp(Opcode.GoTo)
    const gotoEnd2 = this.emitPlaceholder()
    this.patchIndex(secondIfPos, this.codeSize())
    this.stackSizeMgr.converge(depthAtIfTarget)

    this.emitOp(Opcode.PushFalse) // 两侧都不成立
    this.stackSizeMgr.inc()
    this.patchIndex(gotoEnd1, this.codeSize())
    this.patchIndex(gotoEnd2, this.codeSize())
  }
  onVisitAndExpr(e) {
    this.visit(e.leftExpr)
    this.emitOp(Opcode.If)
    this.stackSizeMgr.dec()
    const firstIfPos = this.emitPlaceholder()
    this.visit(e.rightExpr)
    this.emitOp(Opcode.If)
    this.stackSizeMgr.dec()
    const secondIfPos = this.emitPlaceholder()
    const depthAtIfTarget = this.stackSizeMgr.size // 两侧都为真才落到这里
    this.emitOp(Opcode.PushTrue)
    this.stackSizeMgr.inc()
    this.emitOp(Opcode.GoTo)
    const gotoEnd = this.emitPlaceholder()
    this.patchIndex(firstIfPos, this.codeSize())
    this.patchIndex(secondIfPos, this.codeSize())
    this.stackSizeMgr.converge(depthAtIfTarget)
    this.emitOp(Opcode.PushFalse)
    this.stackSizeMgr.inc()
    this.patchIndex(gotoEnd, this.codeSize())
  }
  onVisitCallExpr(e) {
    this.visit(e.callee)
    for (const a of e.args) this.visit(a)
    this.emitOp(Opcode.Call)
    this.emitIndex(e.args.length)
    this.stackSizeMgr.dec(e.args.length) // callee + args 换成 1 个返回值
  }
  onVisitAtExpr(e) {
    this.visit(e.container)
    for (const k of e.keyExprs) this.visit(k)
    this.emitOp(Opcode.At)
    this.emitIndex(e.keyExprs.length)
    this.stackSizeMgr.dec(e.keyExprs.length)
  }
  onVisitCustomOpcodeExpr(e) {
    if (this.customOpcodes === null || !this.customOpcodes.opcodes.has(e.opcodeName)) {
      this.error(e.line, `undefined custom opcode "${e.opcodeName}". `)
      return
    }
    const info = this.customOpcodes.opcodes.get(e.opcodeName)
    const isVarArg = info.argNum < 0 // 与 C++ 的 isVarArg 同一判据
    if (!isVarArg && info.argNum !== e.args.length) {
      this.error(
        e.line,
        `custom opcode "${e.opcodeName}" expected ${info.argNum} args, but got ${e.args.length}. `,
      )
    }
    for (const a of e.args) this.visit(a)
    this.emitOp(info.opcode)
    if (isVarArg) this.emitIndex(e.args.length)
    // 自定义指令没有 callee 入栈，结果仍占 1 格 => dec(参数个数 - 1)
    this.stackSizeMgr.dec(e.args.length - 1)
  }

  // ---------------- 小工具 ----------------
  // 标识符 -> 变量槽位索引。没声明过就当作外部变量，登记到文件作用域
  // （名字非空正是 Program.exports 的判据）。PushValue / PushId 共用这一处查找。
  identSlot(name) {
    const host = this.findIdentHost(name)
    if (host !== null) return host.idMap.get(name)
    this.declareExported(name, this.varAlloc.newUniqueVar(name))
    return this.fileScope().idMap.get(name)
  }
  // 登记一个会进 Program.exports 的变量。索引来自 newUniqueVar（不回收）。
  declareExported(name, idx) {
    this.fileScope().idMap.set(name, idx)
    this.prog.exports.set(name, idx)
  }
  // 块 / if 分支 / 循环体在 AST 里都是裸 Prog（没有 BlockStmt 包着），
  // 这里补一层 BlockScope，让内部 let 的变量在离开时被回收。
  visitBodyAsBlock(p) {
    const bs = this.pushBlockScope()
    this.visit(p)
    this.popScope()
    for (const idx of bs.idMap.values()) this.varAlloc.freeVar(idx)
  }
}

// 二元运算符 -> 指令。注意二元 `-` 是 Sub 而不是 Minus。
function binaryOpcode(op) {
  const T = TokenType
  if (op === T.EQ) return Opcode.EQ
  if (op === T.NE) return Opcode.NE
  if (op === T.LT) return Opcode.LT
  if (op === T.LE) return Opcode.LE
  if (op === T.GT) return Opcode.GT
  if (op === T.GE) return Opcode.GE
  if (op === T.Add) return Opcode.Add
  if (op === T.Sub) return Opcode.Sub
  if (op === T.Mul) return Opcode.Mul
  if (op === T.Div) return Opcode.Div
  if (op === T.IDiv) return Opcode.IDiv
  if (op === T.Mod) return Opcode.Mod
  if (op === T.Pow) return Opcode.Pow
  return Opcode.Pop // 到不了：parser 只会用上面这些 op 构造 BinaryOpExpr
}

export {
  Compiler,
  VariableAllocator,
  StackSizeManager,
  MinHeap,
  FileScope,
  BlockScope,
  WhileScope,
  kFirstCustomOpcode,
}
