#include <stope/compiler.hpp>

#include <algorithm>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace Stope {

int VariableAllocator::newVar(const std::u16string& name) {
  if (!recycled.empty()) {
    std::pop_heap(recycled.begin(), recycled.end(), std::greater<int>());
    int idx = recycled.back();
    recycled.pop_back();
    vars[idx] = name;
    return idx;
  }
  vars.push_back(name);
  return static_cast<int>(vars.size()) - 1;
}

int VariableAllocator::newUniqueVar(const std::u16string& name) {
  vars.push_back(name);  // 不回收：导出变量必须一直占着一个位置
  return static_cast<int>(vars.size()) - 1;
}

void VariableAllocator::freeVar(int idx) {
  if (std::find(recycled.begin(), recycled.end(), idx) != recycled.end())
    return;  // 同一索引不会被重复回收（理论上不会发生，保险起见）
  recycled.push_back(idx);
  std::push_heap(recycled.begin(), recycled.end(), std::greater<int>());
}

Result Compiler::Compile(AST::Prog& ast, Program& out,
                         const std::vector<std::u16string>& preExports) {
  reset(out);
  exportPreExports(preExports);
  Visit(&ast);
  // 顶层 defer：程序尾结算。程序以终止语句（return / 死循环等）结尾时
  // 这里不可达（return 出口已在 onVisitReturnStmt 结算过），再拼就是
  // Return 之后的死代码——跳过；自然结束（fall-through）才需要这份结算。
  if (!stmtTerminates)
    spliceDefers(fileScope());
  fileScope()->defers.clear();
  if (!errors.empty()) {
    clearOutput();
    return Result::Error;
  }
  out.variableNum = varAlloc.num();
  out.requiredStackSize = stackSize.maxSize;
  return Result::Success;
}

// 预导出的名字走 newUniqueVar（不回收），并且先于源码里的任何变量分配 ——
// 这一步定了整个程序的槽位编号，所以顺序必须固定在 Visit 之前。
void Compiler::exportPreExports(const std::vector<std::u16string>& names) {
  FileScope* fs = fileScope();
  for (const auto& name : names) {
    // 行号记 0：这些名字不来自源码，硬套 curLine（此刻是 -1）只会误导。
    if (name.empty()) {
      error(0, "empty name in pre-exports. ");
      continue;
    }
    if (fs->idMap.find(name) != fs->idMap.end()) {
      error(0, "duplicate export of \"" + narrowAscii(name) + "\". ");
      continue;
    }
    declareExported(name, varAlloc.newUniqueVar(name));
  }
}

void Compiler::reset(Program& out) {
  errors.clear();
  varAlloc = VariableAllocator();
  stackSize = StackSizeManager();
  declCounter = 0;
  deferOrderFloor = -1;
  deferErrLine = -1;
  stmtTerminates = false;
  sawBreak = false;
  ownedScopes.clear();
  scopeStack.clear();
  curLine = -1;
  prog = &out;
  // customOpcodeConfig 由构造器决定，reset 不再覆盖它。
  clearOutput();
  auto* file = new FileScope();
  ownedScopes.emplace_back(file);
  scopeStack.push_back(file);
}

void Compiler::clearOutput() {
  prog->opcodes.clear();
  prog->intConsts.clear();
  prog->floatConsts.clear();
  prog->binArrConsts.clear();
  prog->stringConsts.clear();
  prog->exports.clear();
  prog->variableNum = 0;
  prog->maxReturnNum = 0;
  prog->requiredStackSize = 0;
}

int Compiler::codeSize() const {
  return static_cast<int>(prog->opcodes.size());
}

void Compiler::emitOp(Opcode op) {
  prog->opcodes.push_back(static_cast<short>(op));
}

void Compiler::emitIndex(int idx) {
  if (idx < INT16_MIN || idx > INT16_MAX) {
    error(curLine, "compile output too large: index exceeds int16. ");
    idx = 0;
  }
  prog->opcodes.push_back(static_cast<short>(idx));
}

int Compiler::emitPlaceholder() {
  prog->opcodes.push_back(-1);
  return codeSize() - 1;
}

void Compiler::patchIndex(int pos, int target) {
  if (target < INT16_MIN || target > INT16_MAX) {
    error(curLine, "compile output too large: jump target exceeds int16. ");
    target = 0;
  }
  prog->opcodes[pos] = static_cast<short>(target);
}

template <class T>
int Compiler::constIndex(std::vector<T>& pool, const T& v) {
  auto it = std::find(pool.begin(), pool.end(), v);
  if (it != pool.end())
    return static_cast<int>(it - pool.begin());
  pool.push_back(v);
  return static_cast<int>(pool.size()) - 1;
}

void Compiler::error(int line, const std::string& msg) {
  errors.push_back("line " + std::to_string(line) + ": " + msg);
}

template <class T>
T* Compiler::pushScope() {
  T* s = new T();
  ownedScopes.emplace_back(s);
  scopeStack.push_back(s);
  return s;
}

void Compiler::popScope() {
  scopeStack.pop_back();
}

BlockScope* Compiler::topBlockScope() {
  for (int i = static_cast<int>(scopeStack.size()) - 1; i >= 0; --i)
    if (scopeStack[i]->type == ScopeType::Block ||
        scopeStack[i]->type == ScopeType::File)
      return static_cast<BlockScope*>(scopeStack[i]);
  return nullptr;
}

BlockScope* Compiler::findIdentHost(const std::u16string& name) {
  for (int i = static_cast<int>(scopeStack.size()) - 1; i >= 0; --i) {
    Scope* s = scopeStack[i];
    if (s->type != ScopeType::Block && s->type != ScopeType::File)
      continue;
    BlockScope* bs = static_cast<BlockScope*>(s);
    if (bs->idMap.find(name) != bs->idMap.end())
      return bs;
  }
  return nullptr;
}

FileScope* Compiler::fileScope() {
  return static_cast<FileScope*>(scopeStack.front());
}

BlockScope* Compiler::findIdentHostFrozen(const std::u16string& name,
                                          int floor) {
  // 最内层载荷根：它以内（栈中更靠内）是载荷自己的内部作用域，
  // 名字解析不过滤；它以外才应用「defer 语句处可见」的基线。
  int payloadIdx = -1;
  for (int i = static_cast<int>(scopeStack.size()) - 1; i >= 0; --i) {
    Scope* s = scopeStack[i];
    if (s->type == ScopeType::Block &&
        static_cast<BlockScope*>(s)->isDeferPayload) {
      payloadIdx = i;
      break;
    }
  }
  for (int i = static_cast<int>(scopeStack.size()) - 1; i >= 0; --i) {
    Scope* s = scopeStack[i];
    if (s->type != ScopeType::Block && s->type != ScopeType::File)
      continue;
    BlockScope* bs = static_cast<BlockScope*>(s);
    if (bs->idMap.find(name) == bs->idMap.end())
      continue;
    if (i < payloadIdx) {  // 登记 scope 一侧：跳过 defer 之后才声明的（遮蔽）
      auto o = bs->idOrder.find(name);
      // 基线 = 登记时的 declCounter（= 下一个待分配序号），所以
      // 「order >= 基线」⟺ 在 defer 之后声明。
      if (o != bs->idOrder.end() && o->second >= 0 && o->second >= floor)
        continue;
    }
    return bs;
  }
  return nullptr;
}

BlockScope* Compiler::resolveAtSplice(const std::u16string& name) {
  BlockScope* frozen = findIdentHostFrozen(name, deferOrderFloor);
  if (frozen != nullptr)
    return frozen;
  // OQ-8（2026-11-08 定夺）：defer 绑定语句及其符号——后文声明的本地名
  // 不再报错、也不被捕获，按隐式导出宿主变量处理（同未声明名字的路径）。
  // FileScope 已有同名（后文顶层 let / export 声明的文件级变量）时无法再建
  // 同名宿主变量，报重复——行号归 defer 语句（冲突在 defer 绑定符号时就
  // 已注定；若 defer 先于顶层声明结算，则由后文 declareLocal 报 duplicate
  // declaration，两处报错互斥）。
  BlockScope* fs = fileScope();
  if (fs->idMap.find(name) != fs->idMap.end()) {
    error(deferErrLine, "duplicate export of \"" + narrowAscii(name) + "\". ");
    return fs;  // 编译已失败；返回宿主避免连锁隐式导出
  }
  return nullptr;  // 调用方走隐式导出路径（新建宿主变量）
}

void Compiler::spliceDefers(BlockScope* bs) {
  if (bs->defers.empty() || !errors.empty())
    return;  // 错误去重：载荷在每个退出点重编译，报一次就够
  // 逆序发射：后登记先执行（LIFO，与 Go / Swift 的直觉一致）。
  // ⚠ 不清空 bs->defers：一个块可以有多个运行期出口（break / continue /
  // return 各一处 + 块尾），每个出口都要拼一份自己的副本；只有块尾 /
  // 程序尾的「最终结算」由调用方在拼接后清空。
  for (size_t k = bs->defers.size(); k-- > 0;) {
    if (!errors.empty())
      return;  // 某个载荷编译出错即停，不再拼后续
    const BlockScope::Deferred& d = bs->defers[k];
    int savedFloor = deferOrderFloor;
    int savedLine = deferErrLine;
    deferOrderFloor = d.orderBaseline;
    deferErrLine = d.line;
    // 载荷包一层隐式作用域并打标记：break/continue/return 的越界检查
    // 靠它识别「从收尾代码里跳回主流程」。
    BlockScope* ps = pushScope<BlockScope>();
    ps->isDeferPayload = true;
    Visit(d.stmt);
    // 载荷 scope 自己的 defers（直接嵌套 defer defer X 落在这里）：
    // 触发点 = 载荷 scope 结束 = 同一退出点，就地拼接。
    spliceDefers(ps);
    popScope();
    for (auto& kv : ps->idMap)
      varAlloc.freeVar(kv.second);
    deferOrderFloor = savedFloor;
    deferErrLine = savedLine;
  }
}

void Compiler::onVisitProg(AST::Prog* prog) {
  // 语句序列：终止语句（return / break / continue / 死循环）之后的语句
  // 在语言语义下执行不到——不再发射，也不登记它们的 defer（死代码消除）。
  // 序列的终止性 = 最后一条已发射语句。
  bool terminated = false;
  for (auto& s : prog->stmts) {
    if (terminated)
      break;
    stmtTerminates = false;  // 每条语句先清零；终止语句的 visitor 置 true
    Visit((AST::Node*)s.get());
    terminated = stmtTerminates;
  }
  stmtTerminates = terminated;
}

void Compiler::onVisitExprStmt(AST::ExprStmt* s) {
  Visit(s->expr.get());
  emitOp(Opcode::Pop);
  stackSize.dec();
}

void Compiler::onVisitLetStmt(AST::LetStmt* s) {
  BlockScope* bs = topBlockScope();
  if (bs == nullptr)
    return;
  if (!s->hasAssign) {
    for (const auto& name : s->idents) {
      if (bs->idMap.find(name) != bs->idMap.end()) {
        error(s->line,
              "duplicate declaration of '" + narrowAscii(name) + "'. ");
        continue;
      }
      declareLocal(bs, name, varAlloc.newVar());
    }
    return;
  }
  if (s->idents.empty())
    return;
  // 一个标识符，赋值
  const std::u16string& name = s->idents[0];
  if (bs->idMap.find(name) != bs->idMap.end()) {
    error(s->line, "duplicate declaration of '" + narrowAscii(name) + "'. ");
    return;
  }
  // 不要 Visit 标识符本身（那会生成 PushId 取值），这里是要绑定到新变量
  int idx = varAlloc.newVar();
  declareLocal(bs, name, idx);
  emitOp(Opcode::PushId);
  emitIndex(idx);
  stackSize.inc();
  Visit(s->expr.get());
  emitOp(Opcode::Assign);
  stackSize.dec(2);
}

void Compiler::onVisitReturnStmt(AST::ReturnStmt* s) {
  // defer 边界：return 的终点是整个程序，在载荷内必然越界，一律报错。
  for (Scope* sc : scopeStack) {
    if (sc->type == ScopeType::Block &&
        static_cast<BlockScope*>(sc)->isDeferPayload) {
      error(s->line, "\"return\" cannot be used in a defer statement. ");
      return;
    }
  }
  // 顺序：先结算，再求返回值，最后 Return（结算 → PushValue → Return）。
  // 结算先于退出动作，与块退出一致——defer 可以影响返回值。
  for (int i = static_cast<int>(scopeStack.size()) - 1; i >= 0; --i) {
    ScopeType t = scopeStack[i]->type;
    if (t == ScopeType::Block || t == ScopeType::File)
      spliceDefers(static_cast<BlockScope*>(scopeStack[i]));
  }
  for (auto& e : s->exprs)
    Visit(e.get());
  emitOp(Opcode::Return);
  emitIndex(static_cast<int>(s->exprs.size()));
  prog->maxReturnNum =
      std::max(prog->maxReturnNum, static_cast<int>(s->exprs.size()));
  stmtTerminates = true;
  // Return 会让 VM 直接跳到 code 末尾，栈上的返回值不回收
}

void Compiler::onVisitExportStmt(AST::ExportStmt* s) {
  if (scopeStack.size() > 1)
    error(s->line, "\"export\" can only be used at top scope. ");
  FileScope* fs = fileScope();
  for (const auto& id : s->idents) {
    if (fs->idMap.find(id) != fs->idMap.end()) {
      error(s->line, "duplicate export of \"" + narrowAscii(id) + "\". ");
      continue;
    }
    declareExported(id, varAlloc.newUniqueVar(id));
  }
}

void Compiler::onVisitBlockStmt(AST::BlockStmt* s) {
  BlockScope* bs = pushScope<BlockScope>();
  Visit(&s->prog);
  // 块尾结算：本 scope 的 defer 在这里执行（LIFO）。块体以终止语句结尾时
  // 这里不可达（return 出口已结算、break/continue 出口就地结算过）——
  // 跳过，避免拼出不可达的副本。
  if (!stmtTerminates)
    spliceDefers(bs);
  bs->defers.clear();  // 最终结算：途中出口（break/return）已各拼过副本
  popScope();
  for (auto& kv : bs->idMap)  // 回收局部变量索引
    varAlloc.freeVar(kv.second);
}

void Compiler::onVisitIfStmt(AST::IfStmt* s) {
  if (s->cond == nullptr)
    return;
  std::vector<int> gotoEndIndices;
  bool allBranchesTerminate = true;
  bool hasElse = false;
  Visit(s->cond.get());
  emitOp(Opcode::If);
  stackSize.dec();
  int lastIfPos = emitPlaceholder();  // 条件为假时跳到这里
  visitBodyAsBlock(s->firstProg);
  bool branchTerm = stmtTerminates;
  allBranchesTerminate = allBranchesTerminate && branchTerm;
  if (!branchTerm) {  // 分支走完会落到这里，需要跳出整个 if；终止则死代码
    emitOp(Opcode::GoTo);
    gotoEndIndices.push_back(emitPlaceholder());
  }
  patchIndex(lastIfPos, codeSize());
  for (auto& elif : s->elifs) {
    if (elif.cond == nullptr)
      continue;
    Visit(elif.cond.get());
    emitOp(Opcode::If);
    stackSize.dec();
    lastIfPos = emitPlaceholder();
    visitBodyAsBlock(elif.prog);
    branchTerm = stmtTerminates;
    allBranchesTerminate = allBranchesTerminate && branchTerm;
    if (!branchTerm) {
      emitOp(Opcode::GoTo);
      gotoEndIndices.push_back(emitPlaceholder());
    }
    patchIndex(lastIfPos, codeSize());
  }
  hasElse = s->elseProg.has_value();
  if (hasElse)
    visitBodyAsBlock(*s->elseProg);
  else
    allBranchesTerminate = false;  // 无 else：条件全假时落到 if 之后
  for (int pos : gotoEndIndices)
    patchIndex(pos, codeSize());
  // if 语句的终止性：else 存在且所有分支终止（组合式，逐分支局部判断）
  stmtTerminates = hasElse && allBranchesTerminate;
}

void Compiler::onVisitWhileStmt(AST::WhileStmt* s) {
  WhileScope* ws = pushScope<WhileScope>();
  ws->startIndex = codeSize();  // continue 回到这里
  int caseGotoEndPos = -1;
  if (s->cond != nullptr) {  // while cond { } —— cond 可省
    Visit(s->cond.get());
    emitOp(Opcode::If);
    stackSize.dec();
    caseGotoEndPos = emitPlaceholder();
  }
  // sawBreak 按 while 配对保存/恢复：嵌套循环里的 break 只算最内层的
  bool savedSawBreak = sawBreak;
  sawBreak = false;
  visitBodyAsBlock(s->prog);
  bool bodyTerm = stmtTerminates;
  bool bodySawBreak = sawBreak;
  sawBreak = savedSawBreak;
  if (!bodyTerm) {  // 体终止（return/break/continue 收尾）则回跳是死代码
    emitOp(Opcode::GoTo);
    emitIndex(ws->startIndex);
  }
  for (int pos : ws->breakIndices)
    patchIndex(pos, codeSize());
  // [偏离参考实现 4] 条件可省。参考实现这里无条件回填 case_goto_end_idx，
  // 无条件 while 时它会写成 code[0] = len(code)，把第一条指令改成跳转目标。
  if (caseGotoEndPos >= 0)
    patchIndex(caseGotoEndPos, codeSize());
  // while 的终止性：只有「无条件 + 体不含本层 break」的真死循环才永不
  // 退出。`while true { }` 带条件，按可退出处理（用户明确要求），不视同
  // `while { }`。
  stmtTerminates = (s->cond == nullptr) && !bodySawBreak;
  popScope();
}

void Compiler::onVisitAssignStmt(AST::AssignStmt* s) {
  // 解析因「嵌套太深」中止时，子表达式可能为空（Parser 已把错误记进 errors，
  // 调用方见错就不该再 Compile）。这里只兜住崩溃，不做语义修正。
  if (s == nullptr || s->leftExpr == nullptr)
    return;
  if (s->leftExpr->type == AST::NodeType::IdentExpr) {
    AST::IdentExpr& e = *static_cast<AST::IdentExpr*>(s->leftExpr.get());
    BlockScope* host = deferOrderFloor >= 0 ? resolveAtSplice(e.ident)
                                            : findIdentHost(e.ident);
    int idx = 0;
    if (host != nullptr) {
      idx = host->idMap[e.ident];
    } else {  // 未声明，当作 export 变量，登记到文件作用域。
      declareExported(e.ident, varAlloc.newUniqueVar(e.ident),
                      /*implicitExport=*/true);
      idx = fileScope()->idMap[e.ident];
    }
    emitOp(Opcode::PushId);  // 压的是变量本身，不是值，否则无法赋值
    emitIndex(idx);
    stackSize.inc();
  } else {  // 可能是使用者设计的数组元素引用、对象成员引用等。压入值。
    Visit(s->leftExpr.get());
  }
  Visit(s->rightExpr.get());
  emitOp(Opcode::Assign);
  stackSize.dec(2);
}

void Compiler::onVisitBreakStmt(AST::BreakStmt* s) {
  // 找最内层 WhileScope。途中先撞到 defer 载荷边界 = 目标循环在载荷外：
  // 载荷在退出点才执行，break 从收尾代码里跳回主流程是灾难语义，禁。
  int wi = -1;
  for (int i = static_cast<int>(scopeStack.size()) - 1; i >= 0; --i) {
    Scope* sc = scopeStack[i];
    if (sc->type == ScopeType::While) {
      wi = i;
      break;
    }
    if (sc->type == ScopeType::Block &&
        static_cast<BlockScope*>(sc)->isDeferPayload) {
      error(s->line, "\"break\" cannot cross a defer statement. ");
      return;
    }
  }
  if (wi < 0) {
    error(s->line, "cannot use \"break\" outside of a loop. ");
    return;
  }
  // 结算 break 越过的所有块：从最内层到循环体块（不含 WhileScope 本身、
  // 不含循环外的任何 scope）。运行时 break 直接跳循环尾，这些块的正常
  // 块尾拼接不会执行到，必须在跳转前就地结算。
  for (int i = static_cast<int>(scopeStack.size()) - 1; i > wi; --i) {
    if (scopeStack[i]->type == ScopeType::Block)
      spliceDefers(static_cast<BlockScope*>(scopeStack[i]));
  }
  emitOp(Opcode::GoTo);
  static_cast<WhileScope*>(scopeStack[wi])->breakIndices.push_back(
      emitPlaceholder());
  sawBreak = true;  // 告知最内层 while：本层有 break（死循环判定用）
  stmtTerminates = true;
}

void Compiler::onVisitContinueStmt(AST::ContinueStmt* s) {
  // 同 break：continue 也退出循环体块，体块的 defer 必须先结算。
  int wi = -1;
  for (int i = static_cast<int>(scopeStack.size()) - 1; i >= 0; --i) {
    Scope* sc = scopeStack[i];
    if (sc->type == ScopeType::While) {
      wi = i;
      break;
    }
    if (sc->type == ScopeType::Block &&
        static_cast<BlockScope*>(sc)->isDeferPayload) {
      error(s->line, "\"continue\" cannot cross a defer statement. ");
      return;
    }
  }
  if (wi < 0) {
    error(s->line, "cannot use \"continue\" outside of a loop. ");
    return;
  }
  for (int i = static_cast<int>(scopeStack.size()) - 1; i > wi; --i) {
    if (scopeStack[i]->type == ScopeType::Block)
      spliceDefers(static_cast<BlockScope*>(scopeStack[i]));
  }
  emitOp(Opcode::GoTo);
  emitIndex(static_cast<WhileScope*>(scopeStack[wi])->startIndex);
  stmtTerminates = true;
}

void Compiler::onVisitDeferStmt(AST::DeferStmt* s) {
  BlockScope* bs = topBlockScope();
  if (bs == nullptr)
    return;  // 不可能：FileScope 常驻栈底
  // 纯编译期登记，defer 语句位置零指令。载荷在退出点才编译（每个退出点
  // 各编译一次——If/GoTo 操作数是绝对下标，编译一次再拷贝会破坏跳转目标）。
  bs->defers.push_back({s->stmt.get(), s->line, declCounter});
}

void Compiler::onVisitNullExpr() {
  emitOp(Opcode::PushNull);
  stackSize.inc();
}

void Compiler::onVisitBoolExpr(AST::BoolExpr* e) {
  emitOp(e->value ? Opcode::PushTrue : Opcode::PushFalse);
  stackSize.inc();
}

void Compiler::onVisitIntExpr(AST::IntExpr* e) {
  emitOp(Opcode::PushInt);
  emitIndex(constIndex(prog->intConsts, e->value));
  stackSize.inc();
}

void Compiler::onVisitFloatExpr(AST::FloatExpr* e) {
  emitOp(Opcode::PushFloat);
  emitIndex(constIndex(prog->floatConsts, e->value));
  stackSize.inc();
}

void Compiler::onVisitStringExpr(AST::StringExpr* e) {
  emitOp(Opcode::PushString);
  emitIndex(constIndex(prog->stringConsts, e->value));
  stackSize.inc();
}

void Compiler::onVisitBinArrExpr(AST::BinArrExpr* e) {
  emitOp(Opcode::PushBinArr);
  emitIndex(constIndex(prog->binArrConsts, e->value));
  stackSize.inc();
}

void Compiler::onVisitIdentExpr(AST::IdentExpr* e) {
  BlockScope* host = deferOrderFloor >= 0 ? resolveAtSplice(e->ident)
                                          : findIdentHost(e->ident);
  int idx = 0;
  if (host != nullptr) {
    idx = host->idMap[e->ident];
  } else {  // 未声明，当作 export 变量，登记到文件作用域。
    declareExported(e->ident, varAlloc.newUniqueVar(e->ident),
                    /*implicitExport=*/true);
    idx = fileScope()->idMap[e->ident];
  }
  emitOp(Opcode::PushValue);
  emitIndex(idx);
  stackSize.inc();
}

void Compiler::onVisitArgcExpr() {
  emitOp(Opcode::ArgNum);
  stackSize.inc();
}

void Compiler::onVisitArgsExpr(AST::ArgsExpr* e) {
  Visit(e->keyExpr.get());
  emitOp(Opcode::GetArg);  // 弹下标、压结果，栈大小不变
}

void Compiler::onVisitUnaryOpExpr(AST::UnaryOpExpr* e) {
  Visit(e->expr.get());
  if (e->op == TokenType::Not)
    emitOp(Opcode::Not);
  else if (e->op == TokenType::Sub)
    emitOp(Opcode::Minus);
  // 一元指令：弹 1 压 1，栈大小不变
}

void Compiler::onVisitBinaryOpExpr(AST::BinaryOpExpr* e) {
  if (e->op == TokenType::Or) {
    onVisitOrExpr(e);
    return;
  }
  if (e->op == TokenType::And) {
    onVisitAndExpr(e);
    return;
  }
  Visit(e->leftExpr.get());
  Visit(e->rightExpr.get());
  emitOp(binaryOpcode(e->op));
  stackSize.dec();  // 弹 2 压 1
}

void Compiler::onVisitOrExpr(AST::BinaryOpExpr* e) {
  Visit(e->leftExpr.get());
  emitOp(Opcode::If);
  stackSize.dec();
  int firstIfPos = emitPlaceholder();
  int depthAtIfTarget = stackSize.size;  // If 已弹掉条件，这就是汇合点深度
  emitOp(Opcode::PushTrue);
  stackSize.inc();
  emitOp(Opcode::GoTo);
  int gotoEnd1 = emitPlaceholder();
  patchIndex(firstIfPos, codeSize());
  stackSize.converge(depthAtIfTarget);  // 后面接的是「左侧为假」这条路径

  Visit(e->rightExpr.get());
  emitOp(Opcode::If);
  stackSize.dec();
  int secondIfPos = emitPlaceholder();
  depthAtIfTarget = stackSize.size;
  emitOp(Opcode::PushTrue);
  stackSize.inc();
  emitOp(Opcode::GoTo);
  int gotoEnd2 = emitPlaceholder();
  patchIndex(secondIfPos, codeSize());
  stackSize.converge(depthAtIfTarget);

  emitOp(Opcode::PushFalse);  // 两侧都不成立
  stackSize.inc();
  patchIndex(gotoEnd1, codeSize());
  patchIndex(gotoEnd2, codeSize());
}

void Compiler::onVisitAndExpr(AST::BinaryOpExpr* e) {
  Visit(e->leftExpr.get());
  emitOp(Opcode::If);
  stackSize.dec();
  int firstIfPos = emitPlaceholder();
  Visit(e->rightExpr.get());
  emitOp(Opcode::If);
  stackSize.dec();
  int secondIfPos = emitPlaceholder();
  int depthAtIfTarget = stackSize.size;  // 两侧都为真才落下 false 的那条路径
  emitOp(Opcode::PushTrue);
  stackSize.inc();
  emitOp(Opcode::GoTo);
  int gotoEnd = emitPlaceholder();
  patchIndex(firstIfPos, codeSize());
  patchIndex(secondIfPos, codeSize());
  stackSize.converge(depthAtIfTarget);
  emitOp(Opcode::PushFalse);
  stackSize.inc();
  patchIndex(gotoEnd, codeSize());
}

void Compiler::onVisitCallExpr(AST::CallExpr* e) {
  Visit(e->callee.get());
  for (auto& a : e->args)
    Visit(a.get());
  emitOp(Opcode::Call);
  emitIndex(static_cast<int>(e->args.size()));
  stackSize.dec(
      static_cast<int>(e->args.size()));  // callee+args 换成 1 个返回值
}

void Compiler::onVisitAtExpr(AST::AtExpr* e) {
  Visit(e->container.get());
  for (auto& k : e->keyExprs)
    Visit(k.get());
  emitOp(Opcode::At);
  emitIndex(static_cast<int>(e->keyExprs.size()));
  stackSize.dec(static_cast<int>(e->keyExprs.size()));
}

void Compiler::onVisitCustomOpcodeExpr(AST::CustomOpcodeExpr* e) {
  if (customOpcodeConfig == nullptr ||
      customOpcodeConfig->opcodes.find(e->opcodeName) ==
          customOpcodeConfig->opcodes.end()) {
    error(e->line,
          "undefined custom opcode \"" + narrowAscii(e->opcodeName) + "\". ");
    return;
  }
  const CustomOpcode& info = customOpcodeConfig->opcodes.at(e->opcodeName);
  if (!info.isVarArg && info.argNum != static_cast<short>(e->args.size())) {
    error(e->line, "custom opcode \"" + narrowAscii(e->opcodeName) +
                       "\" expected " + std::to_string(info.argNum) +
                       " args, but got " + std::to_string(e->args.size()) +
                       ". ");
  }
  for (auto& a : e->args)
    Visit(a.get());
  emitOp(static_cast<Opcode>(info.opcode));
  if (info.isVarArg)
    emitIndex(static_cast<int>(e->args.size()));
  // [偏离参考实现 3] 自定义指令没有 callee 入栈，结果仍占 1 格，
  //                  所以这里 dec(参数个数 - 1)，参考实现写的是
  //                  dec(参数个数)。
  stackSize.dec(static_cast<int>(e->args.size()) - 1);
}

void Compiler::declareExported(const std::u16string& name, int idx,
                               bool implicitExport) {
  fileScope()->idMap[name] = idx;
  // 隐式导出（从未声明的宿主变量）记 -1：豁免 defer 冻结绑定检查。
  fileScope()->idOrder[name] = implicitExport ? -1 : declCounter++;
  prog->exports[name] = idx;
}

void Compiler::declareLocal(BlockScope* bs, const std::u16string& name,
                            int idx) {
  bs->idMap[name] = idx;
  bs->idOrder[name] = declCounter++;
}

void Compiler::visitBodyAsBlock(AST::Prog& prog) {
  BlockScope* bs = pushScope<BlockScope>();
  Visit(&prog);
  // 块尾结算（if 分支 / 循环体同普通块）。体以终止语句结尾时这里不可达，
  // 跳过——出口结算（return / break / continue）已就地拼过副本。
  if (!stmtTerminates)
    spliceDefers(bs);
  bs->defers.clear();  // 最终结算
  popScope();
  for (auto& kv : bs->idMap)
    varAlloc.freeVar(kv.second);
}

Opcode Compiler::binaryOpcode(TokenType op) {
  if (op == TokenType::EQ)
    return Opcode::EQ;
  if (op == TokenType::NE)
    return Opcode::NE;
  if (op == TokenType::LT)
    return Opcode::LT;
  if (op == TokenType::LE)
    return Opcode::LE;
  if (op == TokenType::GT)
    return Opcode::GT;
  if (op == TokenType::GE)
    return Opcode::GE;
  if (op == TokenType::Add)
    return Opcode::Add;
  if (op == TokenType::Sub)
    return Opcode::Sub;
  if (op == TokenType::Mul)
    return Opcode::Mul;
  if (op == TokenType::Div)
    return Opcode::Div;
  if (op == TokenType::IDiv)
    return Opcode::IDiv;
  if (op == TokenType::Mod)
    return Opcode::Mod;
  if (op == TokenType::Pow)
    return Opcode::Pow;
  return Opcode::Pop;  // 到不了：parser 只会用上面这些 op 构造 BinaryOpExpr
}

}  // namespace Stope
