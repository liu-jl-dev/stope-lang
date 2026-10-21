#include <stope/ast_visitor.hpp>

#include <unordered_map>

namespace Stope {

void ASTVisitor::Visit(AST::Node* n) {
  if (n == nullptr)
    return;
  curLine = n->line;
  if (visitMap.find(n->type) != visitMap.end()) {
    visitMap.at(n->type)(*this, n);
  }
}

const std::unordered_map<AST::NodeType, ASTVisitor::VisitNodeFunc>
    ASTVisitor::visitMap{
        {AST::NodeType::Prog, visitProg},

        {AST::NodeType::ExprStmt, visitExprStmt},
        {AST::NodeType::LetStmt, visitLetStmt},
        {AST::NodeType::ReturnStmt, visitReturnStmt},
        {AST::NodeType::ExportStmt, visitExportStmt},
        {AST::NodeType::BlockStmt, visitBlockStmt},
        {AST::NodeType::IfStmt, visitIfStmt},
        {AST::NodeType::WhileStmt, visitWhileStmt},
        {AST::NodeType::AssignStmt, visitAssignStmt},
        {AST::NodeType::BreakStmt, visitBreakStmt},
        {AST::NodeType::ContinueStmt, visitContinueStmt},

        {AST::NodeType::NullExpr, visitNullExpr},
        {AST::NodeType::BoolExpr, visitBoolExpr},
        {AST::NodeType::IntExpr, visitIntExpr},
        {AST::NodeType::FloatExpr, visitFloatExpr},
        {AST::NodeType::BinArrExpr, visitBinArrExpr},
        {AST::NodeType::StringExpr, visitStringExpr},
        {AST::NodeType::IdentExpr, visitIdentExpr},
        {AST::NodeType::ArgcExpr, visitArgcExpr},
        {AST::NodeType::ArgsExpr, visitArgsExpr},
        {AST::NodeType::UnaryOpExpr, visitUnaryOpExpr},
        {AST::NodeType::BinaryOpExpr, visitBinaryOpExpr},
        {AST::NodeType::CallExpr, visitCallExpr},
        {AST::NodeType::AtExpr, visitAtExpr},
        {AST::NodeType::CustomOpcodeExpr, visitCustomOpcodeExpr},
        // Node / Stmt / Expr 三个裸基类没有槽位 → visit() 跳过（见文件头）
    };

void ASTVisitor::visitProg(ASTVisitor& visitor, AST::Node* n) {
  visitor.onVisitProg((AST::Prog*)n);
}

void ASTVisitor::visitExprStmt(ASTVisitor& visitor, AST::Node* n) {
  visitor.onVisitExprStmt((AST::ExprStmt*)n);
}

void ASTVisitor::visitLetStmt(ASTVisitor& visitor, AST::Node* n) {
  visitor.onVisitLetStmt((AST::LetStmt*)n);
}

void ASTVisitor::visitReturnStmt(ASTVisitor& visitor, AST::Node* n) {
  visitor.onVisitReturnStmt((AST::ReturnStmt*)n);
}

void ASTVisitor::visitExportStmt(ASTVisitor& visitor, AST::Node* n) {
  visitor.onVisitExportStmt((AST::ExportStmt*)n);
}

void ASTVisitor::visitBlockStmt(ASTVisitor& visitor, AST::Node* n) {
  visitor.onVisitBlockStmt((AST::BlockStmt*)n);
}

void ASTVisitor::visitIfStmt(ASTVisitor& visitor, AST::Node* n) {
  visitor.onVisitIfStmt((AST::IfStmt*)n);
}

void ASTVisitor::visitWhileStmt(ASTVisitor& visitor, AST::Node* n) {
  visitor.onVisitWhileStmt((AST::WhileStmt*)n);
}

void ASTVisitor::visitAssignStmt(ASTVisitor& visitor, AST::Node* n) {
  visitor.onVisitAssignStmt((AST::AssignStmt*)n);
}

void ASTVisitor::visitBreakStmt(ASTVisitor& visitor, AST::Node* n) {
  visitor.onVisitBreakStmt((AST::BreakStmt*)n);
}

void ASTVisitor::visitContinueStmt(ASTVisitor& visitor, AST::Node* n) {
  visitor.onVisitContinueStmt((AST::ContinueStmt*)n);
}

void ASTVisitor::visitNullExpr(ASTVisitor& visitor, AST::Node* n) {
  (void)n;
  visitor.onVisitNullExpr();
}

void ASTVisitor::visitBoolExpr(ASTVisitor& visitor, AST::Node* n) {
  visitor.onVisitBoolExpr((AST::BoolExpr*)n);
}

void ASTVisitor::visitIntExpr(ASTVisitor& visitor, AST::Node* n) {
  visitor.onVisitIntExpr((AST::IntExpr*)n);
}

void ASTVisitor::visitFloatExpr(ASTVisitor& visitor, AST::Node* n) {
  visitor.onVisitFloatExpr((AST::FloatExpr*)n);
}

void ASTVisitor::visitBinArrExpr(ASTVisitor& visitor, AST::Node* n) {
  visitor.onVisitBinArrExpr((AST::BinArrExpr*)n);
}

void ASTVisitor::visitStringExpr(ASTVisitor& visitor, AST::Node* n) {
  visitor.onVisitStringExpr((AST::StringExpr*)n);
}

void ASTVisitor::visitIdentExpr(ASTVisitor& visitor, AST::Node* n) {
  visitor.onVisitIdentExpr((AST::IdentExpr*)n);
}

void ASTVisitor::visitArgcExpr(ASTVisitor& visitor, AST::Node* n) {
  (void)n;
  visitor.onVisitArgcExpr();
}

void ASTVisitor::visitArgsExpr(ASTVisitor& visitor, AST::Node* n) {
  visitor.onVisitArgsExpr((AST::ArgsExpr*)n);
}

void ASTVisitor::visitUnaryOpExpr(ASTVisitor& visitor, AST::Node* n) {
  visitor.onVisitUnaryOpExpr((AST::UnaryOpExpr*)n);
}

void ASTVisitor::visitBinaryOpExpr(ASTVisitor& visitor, AST::Node* n) {
  visitor.onVisitBinaryOpExpr((AST::BinaryOpExpr*)n);
}

void ASTVisitor::visitCallExpr(ASTVisitor& visitor, AST::Node* n) {
  visitor.onVisitCallExpr((AST::CallExpr*)n);
}

void ASTVisitor::visitAtExpr(ASTVisitor& visitor, AST::Node* n) {
  visitor.onVisitAtExpr((AST::AtExpr*)n);
}

void ASTVisitor::visitCustomOpcodeExpr(ASTVisitor& visitor, AST::Node* n) {
  visitor.onVisitCustomOpcodeExpr((AST::CustomOpcodeExpr*)n);
}

}  // namespace Stope
