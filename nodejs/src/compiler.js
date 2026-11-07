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
    // 名字 -> 声明序号（Compiler.declCounter 的全局值，跨 scope 可比）。
    // defer 的「冻结名字绑定」靠它判定：载荷解析到的本地名字若序号晚于
    // defer 语句处的基线，报 "declared after the defer statement."。
    // 隐式导出（从未声明的宿主变量）记 -1，豁免检查。
    this.idOrder = new Map()
    // defer 语句在本 scope 的登记：载荷语句（所有权留在 AST）、defer 行号、
    // 登记时的声明序号基线。退出点（块尾 / break / continue / return）由
    // Compiler 逆序拼接 —— 运行时没有 defer 栈，顺序在编译期物化。
    this.defers = []
    // 该 scope 是否为 defer 载荷的隐式作用域：break / continue / return
    // 不得跨越它（break/continue 的目标循环在载荷外 → 报错；return 在
    // 载荷内一律报错）。
    this.isDeferPayload = false
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
    // 名字声明序号的全局计数器（跨 scope 可比）。每次向任何 BlockScope 的
    // idMap 登记一个「声明」（let / export）时递增；隐式导出不递增、记 -1。
    this.declCounter = 0
    // defer 载荷编译期状态：当前生效的声明序号基线（< 0 = 不在拼接中）与
    // 「declared after」错误的归责行号（defer 语句行）。
    this.deferOrderFloor = -1
    this.deferErrLine = -1
    // 语句终止性（组合式、逐语句局部计算，无 CFG）：return / break /
    // continue 为 true；块 = 最后一条语句终止；if = else 存在且所有分支终止；
    // 无条件 while 且体不含本层 break（死循环）= true；其余语句 false。
    // 消费点：①语句序列里终止语句之后的语句不再发射（死代码消除）；
    // ②while 体终止则省回跳 GoTo；③if 分支体终止则省分支尾 GoTo；
    // ④程序尾 / 块尾 defer 结算同理跳过（终止后无可达路径）。
    // 注意 `while true { }` 带条件，按可退出处理，不视同 `while { }`。
    this.stmtTerminates = false
    // 当前（最内层）while 的循环体里是否出现过绑定到它的 break。进入循环
    // 前保存并清零、结束后恢复——嵌套循环各算各的，只服务死循环判定。
    this.sawBreak = false
  }

  // 与 C++ 的 Compiler::Reset 一致：清错误、换自定义指令表。
  Reset(custom = null) {
    this.errors = []
    this.customOpcodes = custom
  }

  // ---------------- 对外接口 ----------------
  // 编译 ast，结果直接写进 out。有错误时返回 Result.Error 并把 out 复原为空 ——
  // 半成品 Program 跑不了，留着反而误导。
  //
  // preExports：遍历 AST 之前先导出的标识符（宿主注入的全局）。每个名字按给定顺序
  // 占一个「永不回收」的槽位，所以源码里所有变量的编号整体后移；名字进了文件作用域，
  // 源码里再 export 同名、或顶层 let 同名，都会报 duplicate —— 预导出的变量只能赋值。
  // 空名字与重名都是编译错误（行号记 0：这些名字不来自源码）。
  Compile(ast, out, preExports = []) {
    this.resetCompile(out)
    this.exportPreExports(preExports)
    this.visit(ast)
    // 顶层 defer：程序尾结算。程序以终止语句（return / 死循环等）结尾时
    // 这里不可达（return 出口已在 onVisitReturnStmt 结算过），再拼就是
    // Return 之后的死代码——跳过；自然结束（fall-through）才需要这份结算。
    if (!this.stmtTerminates) this.spliceDefers(this.fileScope())
    this.fileScope().defers.length = 0 // 最终结算：途中出口（return）已各拼过副本
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
    this.declCounter = 0
    this.deferOrderFloor = -1
    this.deferErrLine = -1
    this.stmtTerminates = false
    this.sawBreak = false
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
  // 退出点结算：逆序拼接 bs 登记的 defer 载荷（LIFO），每个载荷包一层
  // isDeferPayload 的隐式作用域，载荷 scope 自己的 defers 就地递归拼接。
  // errors 非空时直接返回（错误去重：载荷在每个退出点重编译，报一次就够）。
  // ⚠ 不清空 bs.defers：一个块可以有多个运行期出口（break / continue /
  // return 各一处 + 块尾），每个出口都要拼一份自己的副本；只有块尾 /
  // 程序尾的「最终结算」由调用方在拼接后清空。
  spliceDefers(bs) {
    if (bs.defers.length === 0 || this.errors.length > 0) return
    for (let k = bs.defers.length - 1; k >= 0; --k) {
      if (this.errors.length > 0) return // 某个载荷编译出错即停，不再拼后续
      const d = bs.defers[k]
      const savedFloor = this.deferOrderFloor
      const savedLine = this.deferErrLine
      this.deferOrderFloor = d.orderBaseline
      this.deferErrLine = d.line
      // 载荷包一层隐式作用域并打标记：break/continue/return 的越界检查
      // 靠它识别「从收尾代码里跳回主流程」。
      const ps = this.pushBlockScope()
      ps.isDeferPayload = true
      this.visit(d.stmt)
      // 载荷 scope 自己的 defers（直接嵌套 defer defer X 落在这里）：
      // 触发点 = 载荷 scope 结束 = 同一退出点，就地拼接。
      this.spliceDefers(ps)
      this.popScope()
      for (const idx of ps.idMap.values()) this.varAlloc.freeVar(idx)
      this.deferOrderFloor = savedFloor
      this.deferErrLine = savedLine
    }
  }
  findIdentHost(name) {
    for (let i = this.scopeStack.length - 1; i >= 0; --i) {
      const s = this.scopeStack[i]
      if (s instanceof BlockScope && s.idMap.has(name)) return s
    }
    return null
  }
  // 带声明序号基线的 findIdentHost：跳过序号晚于基线的条目（遮蔽情形），
  // 让解析落到 defer 处可见的外层名字上。载荷 scope 内不过滤。
  findIdentHostFrozen(name, floor) {
    // 最内层载荷根：它以内（栈中更靠内）是载荷自己的内部作用域，
    // 名字解析不过滤；它以外才应用「defer 语句处可见」的基线。
    let payloadIdx = -1
    for (let i = this.scopeStack.length - 1; i >= 0; --i) {
      const s = this.scopeStack[i]
      if (s instanceof BlockScope && s.isDeferPayload) {
        payloadIdx = i
        break
      }
    }
    for (let i = this.scopeStack.length - 1; i >= 0; --i) {
      const s = this.scopeStack[i]
      if (!(s instanceof BlockScope)) continue
      if (!s.idMap.has(name)) continue
      if (i < payloadIdx) {
        // 登记 scope 一侧：跳过 defer 之后才声明的（遮蔽）。
        // 「order >= 基线」⟺ 在 defer 之后声明。隐式导出记 -1，豁免。
        const o = s.idOrder.get(name)
        if (o !== undefined && o >= 0 && o >= floor) continue
      }
      return s
    }
    return null
  }
  // 拼接期间的名字解析（冻结绑定）：名字→槽位按 defer 语句位置的词法
  // 作用域定——冻结规则优先；冻结找不到但当前找得到 = 后文声明 → 报错
  // （行号归 defer 语句），按当前绑定继续（编译已失败）。都空 → 返回 null
  // （调用方走隐式导出路径）。
  resolveAtSplice(name) {
    const now = this.findIdentHost(name)
    const frozen = this.findIdentHostFrozen(name, this.deferOrderFloor)
    if (frozen !== null) return frozen
    if (now !== null) {
      this.error(this.deferErrLine, `"${name}" is declared after the defer statement. `)
    }
    return now
  }
  fileScope() {
    return this.scopeStack[0]
  }

  // ---------------- 语句 ----------------
  // 语句序列（顶层 Prog / 块体 / if 分支 / while 体共用）：终止语句（return /
  // break / continue / 死循环）之后的语句在语言语义下执行不到——不再发射，也
  // 不登记它们的 defer（死代码消除）。序列的终止性 = 最后一条已发射语句。
  onVisitProg(p) {
    let terminated = false
    for (const s of p.stmts) {
      if (terminated) break
      this.stmtTerminates = false // 每条语句先清零；终止语句的 visitor 置 true
      this.visit(s)
      terminated = this.stmtTerminates
    }
    this.stmtTerminates = terminated
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
      this.declareLocal(bs, name, idx)
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
        this.declareLocal(bs, nm, this.varAlloc.newVar())
      }
    }
  }
  onVisitReturnStmt(s) {
    // defer 边界：return 的终点是整个程序，在载荷内必然越界，一律报错。
    for (const sc of this.scopeStack) {
      if (sc instanceof BlockScope && sc.isDeferPayload) {
        this.error(s.line, '"return" cannot be used in a defer statement. ')
        return
      }
    }
    // 顺序：先结算，再求返回值，最后 Return（结算 → PushValue → Return）。
    // 结算先于退出动作，与块退出一致——defer 可以影响返回值。
    for (let i = this.scopeStack.length - 1; i >= 0; --i) {
      const sc = this.scopeStack[i]
      if (sc instanceof BlockScope) this.spliceDefers(sc)
    }
    for (const e of s.exprs) this.visit(e)
    this.emitOp(Opcode.Return)
    this.emitIndex(s.exprs.length)
    this.prog.maxReturnNum = Math.max(this.prog.maxReturnNum, s.exprs.length)
    this.stmtTerminates = true
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
    // 块尾结算：本 scope 的 defer 在这里执行（LIFO）。块体以终止语句结尾时
    // 这里不可达（return 出口已结算、break/continue 出口就地结算过）——
    // 跳过，避免拼出不可达的副本。
    if (!this.stmtTerminates) this.spliceDefers(bs)
    bs.defers.length = 0 // 最终结算：途中出口（break/return）已各拼过副本
    this.popScope()
    for (const idx of bs.idMap.values()) this.varAlloc.freeVar(idx) // 回收局部变量索引
  }
  onVisitIfStmt(s) {
    if (s.cond === null) return
    const gotoEndIndices = []
    let allBranchesTerminate = true
    let hasElse = false
    this.visit(s.cond)
    this.emitOp(Opcode.If)
    this.stackSizeMgr.dec()
    let lastIfPos = this.emitPlaceholder() // 条件为假时跳到这里
    this.visitBodyAsBlock(s.firstProg)
    let branchTerm = this.stmtTerminates
    allBranchesTerminate = allBranchesTerminate && branchTerm
    if (!branchTerm) {
      // 分支走完会落到这里，需要跳出整个 if；终止则死代码
      this.emitOp(Opcode.GoTo)
      gotoEndIndices.push(this.emitPlaceholder())
    }
    this.patchIndex(lastIfPos, this.codeSize())
    for (const ei of s.elifs) {
      if (ei.cond === null) continue
      this.visit(ei.cond)
      this.emitOp(Opcode.If)
      this.stackSizeMgr.dec()
      lastIfPos = this.emitPlaceholder()
      this.visitBodyAsBlock(ei.prog)
      branchTerm = this.stmtTerminates
      allBranchesTerminate = allBranchesTerminate && branchTerm
      if (!branchTerm) {
        this.emitOp(Opcode.GoTo)
        gotoEndIndices.push(this.emitPlaceholder())
      }
      this.patchIndex(lastIfPos, this.codeSize())
    }
    hasElse = s.elseProg !== null
    if (hasElse) this.visitBodyAsBlock(s.elseProg)
    else allBranchesTerminate = false // 无 else：条件全假时落到 if 之后
    for (const pos of gotoEndIndices) this.patchIndex(pos, this.codeSize())
    // if 语句的终止性：else 存在且所有分支终止（组合式，逐分支局部判断）
    this.stmtTerminates = hasElse && allBranchesTerminate
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
    // sawBreak 按 while 配对保存/恢复：嵌套循环里的 break 只算最内层的
    const savedSawBreak = this.sawBreak
    this.sawBreak = false
    this.visitBodyAsBlock(s.prog)
    const bodyTerm = this.stmtTerminates
    const bodySawBreak = this.sawBreak
    this.sawBreak = savedSawBreak
    if (!bodyTerm) {
      // 体终止（return/break/continue 收尾）则回跳是死代码
      this.emitOp(Opcode.GoTo)
      this.emitIndex(ws.startIndex)
    }
    for (const pos of ws.breakIndices) this.patchIndex(pos, this.codeSize())
    // 条件可省。无条件时必须跳过回填，否则会把第 0 条指令改成跳转目标。
    if (caseGotoEndPos >= 0) this.patchIndex(caseGotoEndPos, this.codeSize())
    // while 的终止性：只有「无条件 + 体不含本层 break」的真死循环才永不
    // 退出。`while true { }` 带条件，按可退出处理（用户明确要求），不视同
    // `while { }`。
    this.stmtTerminates = s.cond === null && !bodySawBreak
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
    // 找最内层 WhileScope。途中先撞到 defer 载荷边界 = 目标循环在载荷外：
    // 载荷在退出点才执行，break 从收尾代码里跳回主流程是灾难语义，禁。
    let wi = -1
    for (let i = this.scopeStack.length - 1; i >= 0; --i) {
      const sc = this.scopeStack[i]
      if (sc instanceof WhileScope) {
        wi = i
        break
      }
      if (sc instanceof BlockScope && sc.isDeferPayload) {
        this.error(s.line, '"break" cannot cross a defer statement. ')
        return
      }
    }
    if (wi < 0) {
      this.error(s.line, 'cannot use "break" outside of a loop. ')
      return
    }
    // 结算 break 越过的所有块：从最内层到循环体块（不含 WhileScope 本身、
    // 不含循环外的任何 scope）。运行时 break 直接跳循环尾，这些块的正常
    // 块尾拼接不会执行到，必须在跳转前就地结算。
    for (let i = this.scopeStack.length - 1; i > wi; --i) {
      if (this.scopeStack[i] instanceof BlockScope) this.spliceDefers(this.scopeStack[i])
    }
    this.emitOp(Opcode.GoTo)
    this.scopeStack[wi].breakIndices.push(this.emitPlaceholder())
    this.sawBreak = true // 告知最内层 while：本层有 break（死循环判定用）
    this.stmtTerminates = true
  }
  onVisitContinueStmt(s) {
    // 同 break：continue 也退出循环体块，体块的 defer 必须先结算。
    let wi = -1
    for (let i = this.scopeStack.length - 1; i >= 0; --i) {
      const sc = this.scopeStack[i]
      if (sc instanceof WhileScope) {
        wi = i
        break
      }
      if (sc instanceof BlockScope && sc.isDeferPayload) {
        this.error(s.line, '"continue" cannot cross a defer statement. ')
        return
      }
    }
    if (wi < 0) {
      this.error(s.line, 'cannot use "continue" outside of a loop. ')
      return
    }
    for (let i = this.scopeStack.length - 1; i > wi; --i) {
      if (this.scopeStack[i] instanceof BlockScope) this.spliceDefers(this.scopeStack[i])
    }
    this.emitOp(Opcode.GoTo)
    this.emitIndex(this.scopeStack[wi].startIndex)
    this.stmtTerminates = true
  }
  onVisitDeferStmt(s) {
    const bs = this.topBlockScope()
    if (bs === null) return // 不可能：FileScope 常驻栈底
    // 纯编译期登记，defer 语句位置零指令。载荷在退出点才编译（每个退出点
    // 各编译一次——If/GoTo 操作数是绝对下标，编译一次再拷贝会破坏跳转目标）。
    bs.defers.push({ stmt: s.stmt, line: s.line, orderBaseline: this.declCounter })
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
  // defer 载荷编译期（deferOrderFloor >= 0）走冻结名字绑定规则。
  identSlot(name) {
    const host =
      this.deferOrderFloor >= 0 ? this.resolveAtSplice(name) : this.findIdentHost(name)
    if (host !== null) return host.idMap.get(name)
    this.declareExported(name, this.varAlloc.newUniqueVar(name), /*implicitExport=*/ true)
    return this.fileScope().idMap.get(name)
  }
  // 登记一个会进 Program.exports 的变量。索引来自 newUniqueVar（不回收）。
  // implicitExport=true（defer 无关的旧调用点传 false）：名字记序号 -1，
  // 豁免 defer 的冻结绑定检查——它不是本地槽位，是宿主变量。
  declareExported(name, idx, implicitExport = false) {
    this.fileScope().idMap.set(name, idx)
    this.fileScope().idOrder.set(name, implicitExport ? -1 : this.declCounter++)
    this.prog.exports.set(name, idx)
  }
  // 向 bs 登记一个声明的名字，同时记声明序号。
  declareLocal(bs, name, idx) {
    bs.idMap.set(name, idx)
    bs.idOrder.set(name, this.declCounter++)
  }
  // 预导出：必须在 resetCompile() 之后调用（reset 会重建 varAlloc、清空 out.exports）。
  // 走 newUniqueVar，并且先于源码里任何变量分配 —— 这一步定了整个程序的槽位编号。
  exportPreExports(names) {
    const fs = this.fileScope()
    for (const n of names) {
      // 行号记 0：这些名字不来自源码，硬套 curLine（此刻是 -1）只会误导
      if (n === '') {
        this.error(0, 'empty name in pre-exports. ')
        continue
      }
      if (fs.idMap.has(n)) {
        this.error(0, `duplicate export of "${n}". `)
        continue
      }
      this.declareExported(n, this.varAlloc.newUniqueVar(n))
    }
  }
  // 块 / if 分支 / 循环体在 AST 里都是裸 Prog（没有 BlockStmt 包着），
  // 这里补一层 BlockScope，让内部 let 的变量在离开时被回收。
  visitBodyAsBlock(p) {
    const bs = this.pushBlockScope()
    this.visit(p)
    // 块尾结算（if 分支 / 循环体同普通块）。体以终止语句结尾时这里不可达，
    // 跳过——出口结算（return / break / continue）已就地拼过副本。
    if (!this.stmtTerminates) this.spliceDefers(bs)
    bs.defers.length = 0 // 最终结算
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
