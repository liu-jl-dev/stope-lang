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

Result Compiler::Compile(AST::Prog& ast, Program& out) {
  reset(out);
  Visit(&ast);
  if (!errors.empty()) {
    clearOutput();
    return Result::Error;
  }
  out.variableNum = varAlloc.num();
  out.requiredStackSize = stackSize.maxSize;
  return Result::Success;
}

void Compiler::reset(Program& out) {
  errors.clear();
  varAlloc = VariableAllocator();
  stackSize = StackSizeManager();
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

WhileScope* Compiler::topWhileScope() {
  for (int i = static_cast<int>(scopeStack.size()) - 1; i >= 0; --i)
    if (scopeStack[i]->type == ScopeType::While)
      return static_cast<WhileScope*>(scopeStack[i]);
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

void Compiler::onVisitExprStmt(AST::ExprStmt* s) {
  Visit(s->expr.get());
  emitOp(Opcode::Pop);
  stackSize.dec();
}

void Compiler::onVisitLetStmt(AST::LetStmt* s) {
  BlockScope* bs = topBlockScope();
  if (bs == nullptr)
    return;
  if (s->hasAssign) {  // let a = expr; —— 只有一个标识符
    if (s->idents.empty())
      return;
    const std::u16string& name = s->idents[0];
    if (bs->idMap.find(name) != bs->idMap.end()) {
      error(s->line, "duplicate declaration of '" + narrowAscii(name) + "'. ");
      return;
    }
    // 不要 Visit 标识符本身（那会生成 PushId 取值），这里是要绑定到新变量
    int idx = varAlloc.newVar();
    bs->idMap[name] = idx;
    emitOp(Opcode::PushId);
    emitIndex(idx);
    stackSize.inc();
    Visit(s->expr.get());
    emitOp(Opcode::Assign);
    stackSize.dec(2);
  } else {
    for (const auto& name : s->idents) {
      if (bs->idMap.find(name) != bs->idMap.end()) {
        error(s->line,
              "duplicate declaration of '" + narrowAscii(name) + "'. ");
        continue;
      }
      bs->idMap[name] = varAlloc.newVar();
    }
  }
}

void Compiler::onVisitReturnStmt(AST::ReturnStmt* s) {
  for (auto& e : s->exprs)
    Visit(e.get());
  emitOp(Opcode::Return);
  emitIndex(static_cast<int>(s->exprs.size()));
  prog->maxReturnNum =
      std::max(prog->maxReturnNum, static_cast<int>(s->exprs.size()));
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
  popScope();
  for (auto& kv : bs->idMap)  // 回收局部变量索引
    varAlloc.freeVar(kv.second);
}

void Compiler::onVisitIfStmt(AST::IfStmt* s) {
  if (s->cond == nullptr)
    return;
  std::vector<int> gotoEndIndices;
  Visit(s->cond.get());
  emitOp(Opcode::If);
  stackSize.dec();
  int lastIfPos = emitPlaceholder();  // 条件为假时跳到这里
  visitBodyAsBlock(s->firstProg);
  emitOp(Opcode::GoTo);  // 分支走完，跳出整个 if
  gotoEndIndices.push_back(emitPlaceholder());
  patchIndex(lastIfPos, codeSize());
  for (auto& elif : s->elifs) {
    if (elif.cond == nullptr)
      continue;
    Visit(elif.cond.get());
    emitOp(Opcode::If);
    stackSize.dec();
    lastIfPos = emitPlaceholder();
    visitBodyAsBlock(elif.prog);
    emitOp(Opcode::GoTo);
    gotoEndIndices.push_back(emitPlaceholder());
    patchIndex(lastIfPos, codeSize());
  }
  if (s->elseProg)
    visitBodyAsBlock(*s->elseProg);
  for (int pos : gotoEndIndices)
    patchIndex(pos, codeSize());
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
  visitBodyAsBlock(s->prog);
  emitOp(Opcode::GoTo);
  emitIndex(ws->startIndex);
  for (int pos : ws->breakIndices)
    patchIndex(pos, codeSize());
  // [偏离参考实现 4] 条件可省。参考实现这里无条件回填 case_goto_end_idx，
  // 无条件 while 时它会写成 code[0] = len(code)，把第一条指令改成跳转目标。
  if (caseGotoEndPos >= 0)
    patchIndex(caseGotoEndPos, codeSize());
  popScope();
}

void Compiler::onVisitAssignStmt(AST::AssignStmt* s) {
  Visit(s->leftExpr.get());  // 左值必须是 PushId / At 之类能接赋值的位置
  Visit(s->rightExpr.get());
  emitOp(Opcode::Assign);
  stackSize.dec(2);
}

void Compiler::onVisitBreakStmt(AST::BreakStmt* s) {
  WhileScope* ws = topWhileScope();
  if (ws == nullptr) {
    error(s->line, "cannot use \"break\" outside of a loop. ");
    return;
  }
  emitOp(Opcode::GoTo);
  ws->breakIndices.push_back(emitPlaceholder());
}

void Compiler::onVisitContinueStmt(AST::ContinueStmt* s) {
  WhileScope* ws = topWhileScope();
  if (ws == nullptr) {
    error(s->line, "cannot use \"continue\" outside of a loop. ");
    return;
  }
  emitOp(Opcode::GoTo);
  emitIndex(ws->startIndex);
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
  BlockScope* host = findIdentHost(e->ident);
  int idx = 0;
  if (host != nullptr) {
    idx = host->idMap[e->ident];
  } else {
    // 未声明就使用：当作外部变量，登记到文件作用域。
    // 名字非空 → 会出现在 Program.exports 里（与参考实现一致）。
    declareExported(e->ident, varAlloc.newUniqueVar(e->ident));
    idx = fileScope()->idMap[e->ident];
  }
  emitOp(Opcode::PushId);  // 压的是变量本身，不是值，否则无法赋值
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
    error(e->line, "undefined custom opcode \"" +
                       narrowAscii(e->opcodeName) + "\". ");
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

void Compiler::declareExported(const std::u16string& name, int idx) {
  fileScope()->idMap[name] = idx;
  prog->exports[name] = idx;
}

void Compiler::visitBodyAsBlock(AST::Prog& prog) {
  BlockScope* bs = pushScope<BlockScope>();
  Visit(&prog);
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
