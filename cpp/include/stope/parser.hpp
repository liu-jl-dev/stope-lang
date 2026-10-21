#pragma once
#include <array>
#include <map>
#include <stope/ast.hpp>
#include <stope/common.hpp>
#include <stope/expr_optim.hpp>
#include <stope/lexer.hpp>
#include <stope/parse_binarr.hpp>

namespace Stope {

struct Parser {
 public:
  Lexer* lexer;
  std::vector<std::string> errors;
  bool constFolding = true;  // 表达式常量求值

 public:
  // 词法器是必填依赖，传引用；只有可空的 config 用指针（见 development.md §7）。
  // 构造体内会立刻调用两次 nextToken()，所以 lexer 必须已经就绪。
  Parser(Lexer& lexer, CustomOpcodeConfig* customOpcodeConfig = nullptr);
  void ParseProgram(AST::Prog& prog);

 private:
  CustomOpcodeConfig* customOpcodeConfig = 0;
  BinaryArrayParser binaryArrayParser;
  ExpressionOptimizer exprOptimizer;

  // isTopLevel=true 只有 ParseProgram 用。块/if/while 内部的 prog 都是 false：
  // 它们的 "}" 属于外层语句，必须由外层自己消费。
  void parseProg(AST::Prog& prog, bool isTopLevel);
  AST::LetStmt* parseLetStmt();
  AST::ExportStmt* parseExportStmt();
  AST::ReturnStmt* parseReturnStmt();
  AST::BlockStmt* parseBlockStmt();
  // "if" expr "{" prog "}" ("elif" expr "{" prog "}")* ("else" "{" prog "}")?
  AST::IfStmt* parseIfStmt();
  AST::WhileStmt* parseWhileStmt();
  AST::BreakStmt* parseBreakStmt();
  AST::ContinueStmt* parseContinueStmt();

  AST::Stmt* parseExprOrAssignStmt();
  OpPrecedence curPrecedence();
  OpPrecedence peekPrecedence();
  // 常量折叠的单一入口。挂在 parseUnaryOpExpr / parseBinaryOpExpr 的构造末尾
  // （见那两处），**不要**改成把 parseExpr
  // 包一层：那样每层递归会多一个常驻栈帧， 栈用量约 +50%，直接把 10000
  // 层括号（B-02）打崩（paren 崩溃阈值 11000/12000）。 折叠成功时入参会被
  // delete → 必须走引用版的 OptimizeInPlace。
  void optimizeInPlace(AST::Expr*& e);
  AST::Expr* parseExpr(OpPrecedence prec);

  void error(int line, const char* msg);

  std::array<Token, 2> tokens;
  int curTokenIdx = 0;
  Token& curToken();
  Token& peekToken();
  void nextToken();

  using PrefixParseFn = AST::Expr* (*)(Parser&);
  using InfixParseFn = AST::Expr* (*)(Parser&, AST::Expr*);
  static AST::Expr* parseIdentExpr(Parser& p);
  static AST::Expr* parseNullExpr(Parser& p);
  static AST::Expr* parseBoolExpr(Parser& p);
  static AST::Expr* parseIntExpr(Parser& p);
  static AST::Expr* parseFloatExpr(Parser& p);
  static AST::Expr* parseStringExpr(Parser& p);
  static AST::Expr* parseBinaryArray(Parser& p);
  static AST::Expr* parseArgcExpr(Parser& p);
  static AST::Expr* parseUnaryOpExpr(Parser& p);
  static AST::Expr* parseParenExpr(Parser& p);
  static AST::Expr* parseCustomOpcodeExpr(Parser& p);
  static AST::Expr* parseArgsExpr(Parser& p);

  static AST::Expr* parseBinaryOpExpr(Parser& p, AST::Expr* leftExpr);
  static AST::Expr* parseCallExpr(Parser& p, AST::Expr* calle);
  static AST::Expr* parseAtExpr(Parser& p, AST::Expr* container);

  static const std::map<TokenType, PrefixParseFn> prefixParseFns;
  static const std::map<TokenType, InfixParseFn> infixParseFns;
};
}  // namespace Stope
