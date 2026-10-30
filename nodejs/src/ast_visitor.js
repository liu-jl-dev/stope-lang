// 遍历骨架 —— 逐项对齐 cpp/include/stope/ast_visitor.hpp（+ .cpp 里的分发表）。
//
// 用法：继承 ASTVisitor，按需重写 onVisitXxx。默认实现一律「按源码顺序递归子节点」，
// 子类重写后若要继续下钻，调 super.onVisitXxx(...) 即可。
//
// 分发表存的是**方法名字符串**（GD 侧同形），visit() 用 this[fn] 派发 —— 与 C++ 存
// 强转函数指针的分发表等价，因为 JS 的节点本来就是具体类的实例，不需要强转。
//
// 表要能被测试看见：漏一项不会报错、只会静默跳过整类节点（Node / Stmt / Expr
// 三个裸基类本来就没有表项，它们在错误恢复路径上出现，visit() 直接跳过）。

import { TokenType } from './token.js'
import { NodeType } from './ast.js'

// NodeType -> 方法名，等价于 C++ 的 ASTVisitor::visitMap
const visitMap = {
  [NodeType.Prog]: 'onVisitProg',

  [NodeType.ExprStmt]: 'onVisitExprStmt',
  [NodeType.LetStmt]: 'onVisitLetStmt',
  [NodeType.ReturnStmt]: 'onVisitReturnStmt',
  [NodeType.ExportStmt]: 'onVisitExportStmt',
  [NodeType.BlockStmt]: 'onVisitBlockStmt',
  [NodeType.IfStmt]: 'onVisitIfStmt',
  [NodeType.WhileStmt]: 'onVisitWhileStmt',
  [NodeType.AssignStmt]: 'onVisitAssignStmt',
  [NodeType.BreakStmt]: 'onVisitBreakStmt',
  [NodeType.ContinueStmt]: 'onVisitContinueStmt',

  [NodeType.NullExpr]: 'onVisitNullExpr',
  [NodeType.BoolExpr]: 'onVisitBoolExpr',
  [NodeType.IntExpr]: 'onVisitIntExpr',
  [NodeType.FloatExpr]: 'onVisitFloatExpr',
  [NodeType.BinArrExpr]: 'onVisitBinArrExpr',
  [NodeType.StringExpr]: 'onVisitStringExpr',
  [NodeType.IdentExpr]: 'onVisitIdentExpr',
  [NodeType.ArgcExpr]: 'onVisitArgcExpr',
  [NodeType.ArgsExpr]: 'onVisitArgsExpr',
  [NodeType.UnaryOpExpr]: 'onVisitUnaryOpExpr',
  [NodeType.BinaryOpExpr]: 'onVisitBinaryOpExpr',
  [NodeType.CallExpr]: 'onVisitCallExpr',
  [NodeType.AtExpr]: 'onVisitAtExpr',
  [NodeType.CustomOpcodeExpr]: 'onVisitCustomOpcodeExpr',
}

class ASTVisitor {
  constructor() {
    // 当前正在访问的节点行号，由 visit() 顺带更新。基类自己不用，留给要报诊断的
    // 子类（编译器那些没有专属行号的错误就取它）。
    this.curLine = -1
  }

  get visitMap() {
    return visitMap
  }

  visit(n) {
    if (n === null || n === undefined) return
    this.curLine = n.line
    const fn = visitMap[n.nodeType]
    if (fn !== undefined) this[fn](n)
  }

  // ==================== 子类要重写的钩子 ====================
  // 只有 NullExpr / ArgcExpr 没有子节点，它们的参数写成可选的，这样 visit()
  // 能对所有钩子统一 this[fn](n)，不必为「无参钩子」单开一条分支。

  onVisitProg(p) {
    for (const s of p.stmts) this.visit(s)
  }

  // ---------------- 语句 ----------------
  onVisitExprStmt(s) {
    this.visit(s.expr)
  }
  // 只走初值：idents 是名字（String 列表），不是 Expr
  onVisitLetStmt(s) {
    if (s.hasAssign) this.visit(s.expr)
  }
  onVisitReturnStmt(s) {
    for (const e of s.exprs) this.visit(e)
  }
  onVisitExportStmt(_s) {}
  onVisitBlockStmt(s) {
    this.visit(s.prog)
  }
  // 顺序：条件 -> 首分支 -> 每个 elif（条件 -> 块）-> else 块
  onVisitIfStmt(s) {
    this.visit(s.cond)
    this.visit(s.firstProg)
    for (const ei of s.elifs) {
      this.visit(ei.cond)
      this.visit(ei.prog)
    }
    if (s.elseProg !== null) this.visit(s.elseProg)
  }
  onVisitWhileStmt(s) {
    this.visit(s.cond) // 条件可省（while { }），visit(null) 自己会返回
    this.visit(s.prog)
  }
  onVisitAssignStmt(s) {
    this.visit(s.leftExpr)
    this.visit(s.rightExpr)
  }
  onVisitBreakStmt(_s) {}
  onVisitContinueStmt(_s) {}

  // ---------------- 表达式 ----------------
  onVisitNullExpr(_n = null) {}
  onVisitBoolExpr(_e) {}
  onVisitIntExpr(_e) {}
  onVisitFloatExpr(_e) {}
  onVisitBinArrExpr(_e) {}
  onVisitStringExpr(_e) {}
  onVisitIdentExpr(_e) {}
  onVisitArgcExpr(_n = null) {}
  onVisitArgsExpr(e) {
    this.visit(e.keyExpr) // args[] 的下标缺失时为 null
  }
  onVisitUnaryOpExpr(e) {
    this.visit(e.expr)
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
  }
  // 短路语义的钩子：默认实现与上面的普通路径等价，需要特判的后端（编译器）自行重写
  onVisitOrExpr(e) {
    this.visit(e.leftExpr)
    this.visit(e.rightExpr)
  }
  onVisitAndExpr(e) {
    this.visit(e.leftExpr)
    this.visit(e.rightExpr)
  }
  onVisitCallExpr(e) {
    this.visit(e.callee)
    for (const a of e.args) this.visit(a)
  }
  onVisitAtExpr(e) {
    this.visit(e.container)
    for (const k of e.keyExprs) this.visit(k)
  }
  onVisitCustomOpcodeExpr(e) {
    for (const a of e.args) this.visit(a)
  }
}

export { ASTVisitor, visitMap }
