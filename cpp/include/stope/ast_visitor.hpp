#pragma once
#include <unordered_map>

#include <stope/ast.hpp>

namespace Stope {

struct ASTVisitor {
  virtual ~ASTVisitor() = default;

  // 当前正在访问的节点行号，由 visit() 顺带更新。基类自己不用，留给要报诊断的
  // 子类（Compiler 那些没有专属行号的错误就取它）。
  int curLine = -1;

  using VisitNodeFunc = void (*)(ASTVisitor&, AST::Node*);

  void Visit(AST::Node* n);

  // 分发表：NodeType -> 分发函数。测试要断言「每个语法节点都有表项」，
  // 漏一项不会编译报错、只会静默跳过整类节点，所以这张表要能被测试看见。
  static const std::unordered_map<AST::NodeType, VisitNodeFunc> visitMap;

 private:
  // ==================== 分发函数 ====================
  // 每个函数做一件事：把 Node* 转成具体类型，交给对应的 onVisitXxx 钩子。
  static void visitProg(ASTVisitor& visitor, AST::Node* n);
  static void visitExprStmt(ASTVisitor& visitor, AST::Node* n);
  static void visitLetStmt(ASTVisitor& visitor, AST::Node* n);
  static void visitReturnStmt(ASTVisitor& visitor, AST::Node* n);
  static void visitExportStmt(ASTVisitor& visitor, AST::Node* n);
  static void visitBlockStmt(ASTVisitor& visitor, AST::Node* n);
  static void visitIfStmt(ASTVisitor& visitor, AST::Node* n);
  static void visitWhileStmt(ASTVisitor& visitor, AST::Node* n);
  static void visitAssignStmt(ASTVisitor& visitor, AST::Node* n);
  static void visitBreakStmt(ASTVisitor& visitor, AST::Node* n);
  static void visitContinueStmt(ASTVisitor& visitor, AST::Node* n);
  static void visitNullExpr(ASTVisitor& visitor, AST::Node* n);
  static void visitBoolExpr(ASTVisitor& visitor, AST::Node* n);
  static void visitIntExpr(ASTVisitor& visitor, AST::Node* n);
  static void visitFloatExpr(ASTVisitor& visitor, AST::Node* n);
  static void visitBinArrExpr(ASTVisitor& visitor, AST::Node* n);
  static void visitStringExpr(ASTVisitor& visitor, AST::Node* n);
  static void visitIdentExpr(ASTVisitor& visitor, AST::Node* n);
  static void visitArgcExpr(ASTVisitor& visitor, AST::Node* n);
  static void visitArgsExpr(ASTVisitor& visitor, AST::Node* n);
  static void visitUnaryOpExpr(ASTVisitor& visitor, AST::Node* n);
  static void visitBinaryOpExpr(ASTVisitor& visitor, AST::Node* n);
  static void visitCallExpr(ASTVisitor& visitor, AST::Node* n);
  static void visitAtExpr(ASTVisitor& visitor, AST::Node* n);
  static void visitCustomOpcodeExpr(ASTVisitor& visitor, AST::Node* n);

 protected:
  // ==================== 子类要重写的钩子 ====================
  // 默认实现一律「按源码顺序递归子节点」。
  // 子类重写后要接着下钻，就得调基类版本，所以必须是 protected 而不是 private。

  virtual void onVisitProg(AST::Prog* prog) {
    for (auto& s : prog->stmts)
      Visit((AST::Node*)s.get());
  }

  // ---------------- 语句 ----------------
  virtual void onVisitExprStmt(AST::ExprStmt* s) { Visit(s->expr.get()); }
  // 只走初值：idents 是名字（u16string 列表），不是 Expr
  virtual void onVisitLetStmt(AST::LetStmt* s) {
    if (s->hasAssign) {
      Visit(s->expr.get());
    }
  }
  virtual void onVisitReturnStmt(AST::ReturnStmt* s) {
    for (auto& e : s->exprs)
      Visit(e.get());
  }
  virtual void onVisitExportStmt(AST::ExportStmt* s) { (void)s; }
  // 块里嵌的是裸 Prog，递归回 visitMap 的 Prog 表项即可，不必 dispatch 两遍
  virtual void onVisitBlockStmt(AST::BlockStmt* s) { Visit(&s->prog); }
  // 顺序：条件 → 首分支 → 每个 elif（条件 → 块）→ else 块
  virtual void onVisitIfStmt(AST::IfStmt* s) {
    Visit(s->cond.get());
    Visit(&s->firstProg);
    for (auto& elif : s->elifs) {
      Visit(elif.cond.get());
      Visit(&elif.prog);
    }
    if (s->elseProg)
      Visit(&*s->elseProg);
  }
  virtual void onVisitWhileStmt(AST::WhileStmt* s) {
    Visit(s->cond.get());  // 条件可省（while { }）
    Visit(&s->prog);
  }
  virtual void onVisitAssignStmt(AST::AssignStmt* s) {
    Visit(s->leftExpr.get());
    Visit(s->rightExpr.get());
  }
  virtual void onVisitBreakStmt(AST::BreakStmt* s) { (void)s; }
  virtual void onVisitContinueStmt(AST::ContinueStmt* s) { (void)s; }

  // ---------------- 表达式 ----------------
  // 叶子：没有子节点
  virtual void onVisitNullExpr() {}
  virtual void onVisitBoolExpr(AST::BoolExpr* e) { (void)e; }
  virtual void onVisitIntExpr(AST::IntExpr* e) { (void)e; }
  virtual void onVisitFloatExpr(AST::FloatExpr* e) { (void)e; }
  virtual void onVisitBinArrExpr(AST::BinArrExpr* e) { (void)e; }
  virtual void onVisitStringExpr(AST::StringExpr* e) { (void)e; }
  virtual void onVisitIdentExpr(AST::IdentExpr* e) { (void)e; }
  virtual void onVisitArgcExpr() {}
  virtual void onVisitArgsExpr(AST::ArgsExpr* e) { Visit(e->keyExpr.get()); }
  virtual void onVisitUnaryOpExpr(AST::UnaryOpExpr* e) { Visit(e->expr.get()); }
  virtual void onVisitBinaryOpExpr(AST::BinaryOpExpr* e) {
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
  }
  // 短路语义的钩子：默认实现与上面的普通路径等价，需要特判的后端自行重写
  virtual void onVisitOrExpr(AST::BinaryOpExpr* e) {
    Visit(e->leftExpr.get());
    Visit(e->rightExpr.get());
  }
  virtual void onVisitAndExpr(AST::BinaryOpExpr* e) {
    Visit(e->leftExpr.get());
    Visit(e->rightExpr.get());
  }
  virtual void onVisitCallExpr(AST::CallExpr* e) {
    Visit(e->callee.get());
    for (auto& a : e->args)
      Visit(a.get());
  }
  virtual void onVisitAtExpr(AST::AtExpr* e) {
    Visit(e->container.get());
    for (auto& k : e->keyExprs)
      Visit(k.get());
  }
  virtual void onVisitCustomOpcodeExpr(AST::CustomOpcodeExpr* e) {
    for (auto& a : e->args)
      Visit(a.get());
  }
};
}  // namespace Stope
