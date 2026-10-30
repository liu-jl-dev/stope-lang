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
  // 嵌套深度上限。depth 由调用链显式传递（每个 parseXxx 一个形参），不存成员：
  // 哪一层递归、离上限还有多远，看签名就知道。0 = 不限制。
  // 超限时报一条错、置 aborted，此后不再解析（返回 nullptr）。
  //
  // 默认 256 是对齐 GDScript 实现的值，不是 C++ 的能力上限：C++ 在 8 MB 栈下
  // 能撑到 1 万层括号，但 GDScript 每层嵌套要吃 2 个 GDScript 栈帧，Godot 的
  // max_call_stack 默认 1024（实测 480 层正常、512 层开始刷
  // "Stack underflow! (Engine Bug)"）。
  int maxDepth = 256;
  // 词法器是必填依赖，传引用；只有可空的 config 用指针（见 development.md §7）。
  // 构造体内会立刻调用两次 nextToken()，所以 lexer 必须已经就绪。
  Parser(Lexer& lexer, CustomOpcodeConfig* customOpcodeConfig = nullptr);
  void Reset(Lexer& lexer, CustomOpcodeConfig* customOpcodeConfig = nullptr);
  void ParseProgram(AST::Prog& prog);

 private:
  CustomOpcodeConfig* customOpcodeConfig = 0;
  BinaryArrayParser binaryArrayParser;
  ExpressionOptimizer exprOptimizer;
  // 已因「嵌套太深」中止。作用是让整段解析立刻收摊：没有它的话，块嵌套超限后
  // 外层每一层都会继续按语句解析，一个 12000 层的输入能刷出上万条
  // "expected "}"..."。error() 见到它为真就不再记账，Reset 清零。
  bool aborted = false;

  // ── 深度计数约定（改任何 parseXxx 都要守）──────────────────────────────
  // 1. depth 只在**真正的递归**处 +1：表达式进子表达式、语句块进子块。
  //    parseProg → parseLetStmt → parseExpr 这种线性下降是原值传递，不算嵌套，
  //    否则 `let a = 1;` 这种平铺代码会凭空吃掉好几层额度。
  // 2. 检查只做在 parseExpr / parseProg 两个入口 —— 只有它们会递归。其余函数
  //    拿到的 depth 一定已过检，不重复判。
  // 3. 超限返回 nullptr，**不做逐层传染**：语义层已经用 errors 表达了失败，
  //    调用方（Compiler）只要见到 errors 非空就不该继续 visit。AST 里个别子
  //    节点为空是允许的（AstVisitor::Visit / ExpressionOptimizer 都判空）。
  // 4. 但**直接用子节点指针之前**必须自己判空：parseExprOrAssignStmt 拿
  //    leftExpr->line、parseBinaryOpExpr 拿 leftExpr->line 都属于这种，见各函数。
  // ─────────────────────────────────────────────────────────────────────

  // isTopLevel=true 只有 ParseProgram 用。块/if/while 内部的 prog 都是 false：
  // 它们的 "}" 属于外层语句，必须由外层自己消费。
  void parseProg(AST::Prog& prog, bool isTopLevel, int depth);
  AST::LetStmt* parseLetStmt(int depth);
  AST::ExportStmt* parseExportStmt(int depth);
  AST::ReturnStmt* parseReturnStmt(int depth);
  AST::BlockStmt* parseBlockStmt(int depth);
  // "if" expr "{" prog "}" ("elif" expr "{" prog "}")* ("else" "{" prog "}")?
  AST::IfStmt* parseIfStmt(int depth);
  AST::WhileStmt* parseWhileStmt(int depth);
  AST::BreakStmt* parseBreakStmt(int depth);
  AST::ContinueStmt* parseContinueStmt(int depth);

  AST::Stmt* parseExprOrAssignStmt(int depth);
  OpPrecedence curPrecedence();
  OpPrecedence peekPrecedence();
  // 常量折叠的单一入口。挂在 parseUnaryOpExpr / parseBinaryOpExpr 的构造末尾
  // （见那两处），**不要**改成把 parseExpr 包一层：那样每层递归会多一个常驻
  // 栈帧，栈用量约 +50%。有 maxDepth 兜着不会真崩，但把上限调大时这 50% 仍然
  // 决定你能撑到第几层。折叠成功时入参会被 delete
  // → 必须走引用版的 OptimizeInPlace。
  void optimizeInPlace(AST::Expr*& e);
  AST::Expr* parseExpr(OpPrecedence prec, int depth);

  void error(int line, const char* msg);
  void abortTooDeep(int line);

  std::array<Token, 2> tokens;
  int curTokenIdx = 0;
  Token& curToken();
  Token& peekToken();
  void nextToken();

  using PrefixParseFn = AST::Expr* (*)(Parser&, int depth);
  using InfixParseFn = AST::Expr* (*)(Parser&, AST::Expr*, int depth);
  static AST::Expr* parseIdentExpr(Parser& p, int depth);
  static AST::Expr* parseNullExpr(Parser& p, int depth);
  static AST::Expr* parseBoolExpr(Parser& p, int depth);
  static AST::Expr* parseIntExpr(Parser& p, int depth);
  static AST::Expr* parseFloatExpr(Parser& p, int depth);
  static AST::Expr* parseStringExpr(Parser& p, int depth);
  static AST::Expr* parseBinaryArray(Parser& p, int depth);
  static AST::Expr* parseArgcExpr(Parser& p, int depth);
  static AST::Expr* parseUnaryOpExpr(Parser& p, int depth);
  static AST::Expr* parseParenExpr(Parser& p, int depth);
  static AST::Expr* parseCustomOpcodeExpr(Parser& p, int depth);
  static AST::Expr* parseArgsExpr(Parser& p, int depth);

  static AST::Expr* parseBinaryOpExpr(Parser& p,
                                      AST::Expr* leftExpr,
                                      int depth);
  static AST::Expr* parseCallExpr(Parser& p, AST::Expr* calle, int depth);
  static AST::Expr* parseAtExpr(Parser& p, AST::Expr* container, int depth);

  static const std::map<TokenType, PrefixParseFn> prefixParseFns;
  static const std::map<TokenType, InfixParseFn> infixParseFns;
};
}  // namespace Stope
