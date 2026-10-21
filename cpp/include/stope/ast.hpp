#pragma once
#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>
#include <stope/common.hpp>
#include <stope/token.hpp>

namespace Stope::AST {
enum class NodeType {
  Node,
  Prog,
  Stmt,
  Expr,

  ExprStmt,
  LetStmt,
  ReturnStmt,
  ExportStmt,
  BlockStmt,
  IfStmt,
  WhileStmt,
  AssignStmt,
  BreakStmt,
  ContinueStmt,

  NullExpr,
  BoolExpr,
  IntExpr,
  FloatExpr,
  BinArrExpr,
  StringExpr,
  IdentExpr,
  ArgcExpr,
  ArgsExpr,
  UnaryOpExpr,
  BinaryOpExpr,
  CallExpr,
  AtExpr,
  CustomOpcodeExpr,
};

struct Node {
  NodeType type = NodeType::Node;
  int line = -1;

  Node() = default;
  virtual ~Node() =
      default;  // 多态删除：通过 Stmt*/Node* 销毁派生对象时必须有虚析构

  Node(const Node&) = delete;  // 禁止拷贝，避免对象切片
  Node& operator=(const Node&) = delete;
  Node(Node&&) = default;  // 声明析构后隐式移动会被抑制，需显式补回
  Node& operator=(Node&&) = default;
};
struct Stmt;
// prog : stmt*
struct Prog : Node {
  std::vector<std::unique_ptr<Stmt>> stmts;
  Prog() { type = NodeType::Prog; }
};
struct Stmt : Node {
  Stmt() { type = NodeType::Stmt; }
};
struct Expr : Node {
  Expr() { type = NodeType::Expr; }
};
// expr_stmt : expr ";"
struct ExprStmt : Stmt {
  std::unique_ptr<Expr> expr;
  ExprStmt() { type = NodeType::ExprStmt; }
};
// let_stmt : "let" ident ( ("," ident)* | ("=" expr) )? ";"
struct LetStmt : Stmt {
  bool hasAssign = false;
  std::vector<std::u16string> idents;
  std::unique_ptr<Expr> expr;
  LetStmt() { type = NodeType::LetStmt; }
};
// return_stmt : "return" ( expr ( "," expr )* )? ";"
struct ReturnStmt : Stmt {
  std::vector<std::unique_ptr<Expr>> exprs;
  ReturnStmt() { type = NodeType::ReturnStmt; }
};
// export_stmt : "export" ident ( "," ident )* ";"
struct ExportStmt : Stmt {
  std::vector<std::u16string> idents;
  ExportStmt() { type = NodeType::ExportStmt; }
};
// block_stmt : "{" prog "}"
struct BlockStmt : Stmt {
  Prog prog;  // Prog 没有子类，不用指针
  BlockStmt() { type = NodeType::BlockStmt; }
};
struct IfStmtElif {
  int line = -1;
  std::unique_ptr<Expr> cond;
  Prog prog;
};
// if_stmt : "if" expr "{" prog "}" ( "elif" expr "{" prog "}" )*
// ( "else" "{" prog "}" )?
struct IfStmt : Stmt {
  std::unique_ptr<Expr> cond;
  Prog firstProg;
  std::vector<IfStmtElif> elifs;
  std::optional<Prog> elseProg = std::nullopt;
  IfStmt() { type = NodeType::IfStmt; }
};
// while_stmt : "while" expr? "{" prog "}"
struct WhileStmt : Stmt {
  std::unique_ptr<Expr> cond;
  Prog prog;
  WhileStmt() { type = NodeType::WhileStmt; }
};
// assign_stmt : expr "=" expr ";"
struct AssignStmt : Stmt {
  std::unique_ptr<Expr> leftExpr;
  std::unique_ptr<Expr> rightExpr;
  AssignStmt() { type = NodeType::AssignStmt; }
};
// break_stmt : "break" ";"
struct BreakStmt : Stmt {
  BreakStmt() { type = NodeType::BreakStmt; }
};
// continue_stmt : "continue" ";"
struct ContinueStmt : Stmt {
  ContinueStmt() { type = NodeType::ContinueStmt; }
};

struct NullExpr : Expr {
  NullExpr() { type = NodeType::NullExpr; }
};
struct BoolExpr : Expr {
  bool value = 0;
  BoolExpr() { type = NodeType::BoolExpr; }
};
struct IntExpr : Expr {
  int64_t value = 0;
  IntExpr() { type = NodeType::IntExpr; }
};
struct FloatExpr : Expr {
  double value = 0;
  FloatExpr() { type = NodeType::FloatExpr; }
};
struct BinArrExpr : Expr {
  std::vector<char> value;
  BinArrExpr() { type = NodeType::BinArrExpr; }
};
struct StringExpr : Expr {
  std::u16string value;
  StringExpr() { type = NodeType::StringExpr; }
};
struct IdentExpr : Expr {
  std::u16string ident;
  IdentExpr() { type = NodeType::IdentExpr; }
};
struct ArgcExpr : Expr {
  ArgcExpr() { type = NodeType::ArgcExpr; }
};
struct ArgsExpr : Expr {
  std::unique_ptr<Expr> keyExpr;
  ArgsExpr() { type = NodeType::ArgsExpr; }
};
struct UnaryOpExpr : Expr {
  TokenType op;
  std::unique_ptr<Expr> expr;
  UnaryOpExpr() { type = NodeType::UnaryOpExpr; }
};
struct BinaryOpExpr : Expr {
  std::unique_ptr<Expr> leftExpr;
  TokenType op;
  std::unique_ptr<Expr> rightExpr;
  BinaryOpExpr() { type = NodeType::BinaryOpExpr; }
};
struct CallExpr : Expr {
  std::unique_ptr<Expr> callee;
  std::vector<std::unique_ptr<Expr>> args;
  CallExpr() { type = NodeType::CallExpr; }
};
struct AtExpr : Expr {
  std::unique_ptr<Expr> container;
  std::vector<std::unique_ptr<Expr>> keyExprs;
  AtExpr() { type = NodeType::AtExpr; }
};
// custom_expr : custom "(" ( expr ( "," expr )* )? ")"
struct CustomOpcodeExpr : Expr {
  std::u16string opcodeName;
  std::vector<std::unique_ptr<Expr>> args;
  CustomOpcodeExpr() { type = NodeType::CustomOpcodeExpr; }
};

}  // namespace Stope::AST
namespace Stope {
// 二元运算符 → 优先级。定义见 src/ast.cpp。
//
// 做成「函数 + 函数内 static」而不是头部的 static 常量，有两个原因：
// ① 原来写法（`static const` 放在头文件里）会让每个包含它的 TU 各自构造一份
//    std::map；搬到 src/ast.cpp 后全局只有一份。
// ② 用函数封装可以避免「静态初始化顺序」问题：即便有全局对象在 main 之前访问，
//    首次调用时才构造，一定来得及。
const std::map<TokenType, OpPrecedence>& binopPrecMap();
}
