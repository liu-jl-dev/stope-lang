#include <stope/parser.hpp>

#include <array>
#include <map>

namespace Stope {

Parser::Parser(Lexer& lexer, CustomOpcodeConfig* customOpcodeConfig) {
  Reset(lexer, customOpcodeConfig);
}

void Parser::Reset(Lexer& lexer, CustomOpcodeConfig* customOpcodeConfig) {
  errors.clear();
  this->lexer = &lexer;  // 借用：Parser 不拥有词法器
  this->customOpcodeConfig = customOpcodeConfig;
  nextToken();
  nextToken();
}

void Parser::ParseProgram(AST::Prog& prog) {
  parseProg(prog, true);
}

void Parser::parseProg(AST::Prog& prog, bool isTopLevel) {
  for (; curToken().type != TokenType::Eof;) {
    if (curToken().type == TokenType::RBrace) {
      if (!isTopLevel) {  // 块内：正常结束，不跳过，交给外层处理。
        break;
      }
      // 顶层：孤立 "}" 没有配对，是错误
      error(curToken().line, "unexpected \"}\" at top level. ");
      nextToken();
      continue;
    }
    if (curToken().type == TokenType::Semi) {  // 空语句
      nextToken();
      continue;
    } else if (curToken().type == TokenType::Let) {  // let
      prog.stmts.emplace_back(std::unique_ptr<AST::Stmt>(parseLetStmt()));
    } else if (curToken().type == TokenType::Export) {  // export
      prog.stmts.emplace_back(std::unique_ptr<AST::Stmt>(parseExportStmt()));
    } else if (curToken().type == TokenType::Return) {  // return
      prog.stmts.emplace_back(std::unique_ptr<AST::Stmt>(parseReturnStmt()));
    } else if (curToken().type == TokenType::LBrace) {  // { ... }
      prog.stmts.emplace_back(std::unique_ptr<AST::Stmt>(parseBlockStmt()));
    } else if (curToken().type == TokenType::If) {  // if
      prog.stmts.emplace_back(std::unique_ptr<AST::Stmt>(parseIfStmt()));
    } else if (curToken().type == TokenType::While) {  // while
      prog.stmts.emplace_back(std::unique_ptr<AST::Stmt>(parseWhileStmt()));
    } else if (curToken().type == TokenType::Break) {  // break
      prog.stmts.emplace_back(std::unique_ptr<AST::Stmt>(parseBreakStmt()));
    } else if (curToken().type == TokenType::Continue) {  // continue
      prog.stmts.emplace_back(std::unique_ptr<AST::Stmt>(parseContinueStmt()));
    }

    else {  // 表达式语句或赋值语句
      prog.stmts.emplace_back(
          std::unique_ptr<AST::Stmt>(parseExprOrAssignStmt()));
    }
  }
}

AST::LetStmt* Parser::parseLetStmt() {
  AST::LetStmt* stmt = new AST::LetStmt();
  stmt->line = curToken().line;
  stmt->hasAssign = false;
  nextToken();  // 跳过 let
  if (curToken().type != TokenType::Ident) {
    error(curToken().line, "expected identifier after \"let\". ");
    nextToken();
    return stmt;
  }
  stmt->idents.emplace_back(curToken().parsed);
  nextToken();
  if (curToken().type == TokenType::Semi) {  // 单个标识符且不赋值
    nextToken();
  } else if (curToken().type == TokenType::Comma) {  // 多个标识符，禁止赋值。
    for (;;) {
      if (curToken().type == TokenType::Comma &&
          peekToken().type == TokenType::Ident) {
        stmt->idents.emplace_back(peekToken().parsed);
        nextToken();
        nextToken();
      } else if (curToken().type == TokenType::Semi) {
        nextToken();
        break;
      } else if (curToken().type == TokenType::Eof ||
                 curToken().type == TokenType::RBrace) {
        // 缺 ";"。此处不能再推进：Eof 上 nextToken() 不前进会死循环，
        // 前进又会吞掉外层块的 "}" 导致解析错位。
        error(curToken().line, "expected \";\" in let statement. ");
        break;
      } else {
        error(curToken().line,
              "failed to parse let statement with multiple identifiers. ");
        nextToken();
      }
    }
  } else if (curToken().type == TokenType::Assign) {  // 有赋值
    stmt->hasAssign = true;
    nextToken();
    stmt->expr.reset(parseExpr(OpPrecedence::Lowest));
    nextToken();
  } else {  // 其它
    error(curToken().line, "unexpected token in let statement. ");
    nextToken();
  }
  return stmt;
}

AST::ExportStmt* Parser::parseExportStmt() {
  AST::ExportStmt* stmt = new AST::ExportStmt();
  stmt->line = curToken().line;
  nextToken();  // 跳过 export
  if (curToken().type != TokenType::Ident) {
    error(curToken().line, "expected identifier after \"export\". ");
    nextToken();
    return stmt;
  }
  stmt->idents.emplace_back(curToken().parsed);
  nextToken();
  if (curToken().type == TokenType::Semi) {  // 单个标识符
    nextToken();
  } else if (curToken().type == TokenType::Comma) {
    for (;;) {
      if (curToken().type == TokenType::Comma &&
          peekToken().type == TokenType::Ident) {
        stmt->idents.emplace_back(peekToken().parsed);
        nextToken();
        nextToken();
      } else if (curToken().type == TokenType::Semi) {
        nextToken();
        break;
      } else if (curToken().type == TokenType::Eof ||
                 curToken().type == TokenType::RBrace) {
        // 缺 ";"。此处不能再推进：Eof 上 nextToken() 不前进会死循环，
        // 前进又会吞掉外层块的 "}" 导致解析错位。
        error(curToken().line, "expected \";\" in export statement. ");
        break;
      } else {
        error(curToken().line,
              "failed to parse export statement with multiple identifiers. ");
        nextToken();
      }
    }
  } else {  // 其它
    error(curToken().line, "unexpected token in export statement. ");
    nextToken();
  }
  return stmt;
}

AST::ReturnStmt* Parser::parseReturnStmt() {
  AST::ReturnStmt* stmt = new AST::ReturnStmt();
  stmt->line = curToken().line;
  nextToken();                               // 跳过 return
  if (curToken().type == TokenType::Semi) {  // 无返回值，exprs 为空
    nextToken();                             // 跳过 ;
    return stmt;
  }
  if (curToken().type == TokenType::Eof ||  // 缺 ";"，此时不能吞掉 } 或 Eof，
      curToken().type == TokenType::RBrace) {  // 否则外层块会解析错位
    error(curToken().line, "expected \";\" in return statement. ");
    return stmt;
  }
  stmt->exprs.emplace_back(  // 第一个表达式
      std::unique_ptr<AST::Expr>(parseExpr(OpPrecedence::Lowest)));
  nextToken();  // 到达 , 或 ;
  for (;;) {    // ("," expr)*
    if (curToken().type == TokenType::Semi) {
      nextToken();
      break;
    } else if (curToken().type == TokenType::Comma) {
      nextToken();
      stmt->exprs.emplace_back(
          std::unique_ptr<AST::Expr>(parseExpr(OpPrecedence::Lowest)));
      nextToken();
    } else {
      error(curToken().line, "expected \";\" or \",\" in return statement. ");
      nextToken();
      break;
    }
  }
  return stmt;
}

AST::BlockStmt* Parser::parseBlockStmt() {
  AST::BlockStmt* stmt = new AST::BlockStmt();
  stmt->line = curToken().line;
  nextToken();  // 跳过 {
  parseProg(stmt->prog, false);
  if (curToken().type != TokenType::RBrace) {
    error(curToken().line, "expected \"}\" at end of block statement. ");
  }
  nextToken();  // 跳过 }
  return stmt;
}

AST::IfStmt* Parser::parseIfStmt() {
  AST::IfStmt* stmt = new AST::IfStmt();
  stmt->line = curToken().line;
  nextToken();  // 跳过 if
  stmt->cond.reset(parseExpr(OpPrecedence::Lowest));
  nextToken();  // 到达 {
  if (curToken().type != TokenType::LBrace) {
    error(curToken().line, "expected \"{\" in if statement. ");
    return stmt;
  }
  nextToken();  // 跳过 {
  parseProg(stmt->firstProg, false);
  if (curToken().type != TokenType::RBrace) {
    error(curToken().line, "expected \"}\" in if statement. ");
    return stmt;
  }
  nextToken();                                  // 跳过 }
  while (curToken().type == TokenType::Elif) {  // ("elif" expr "{" prog "}")*
    stmt->elifs.emplace_back(AST::IfStmtElif{});
    AST::IfStmtElif& elif = stmt->elifs.back();
    elif.line = curToken().line;
    nextToken();  // 跳过 elif
    elif.cond.reset(parseExpr(OpPrecedence::Lowest));
    nextToken();
    if (curToken().type != TokenType::LBrace) {
      error(curToken().line, "expected \"{\" of elif. ");
      return stmt;
    }
    nextToken();  // 跳过 {
    parseProg(elif.prog, false);
    if (curToken().type != TokenType::RBrace) {
      error(curToken().line, "expected \"}\" of elif. ");
      return stmt;
    }
    nextToken();  // 跳过 }
  }
  if (curToken().type == TokenType::Else) {  // ("else" "{" prog "}")?
    stmt->elseProg.emplace();
    nextToken();
    if (curToken().type != TokenType::LBrace) {
      error(curToken().line, "expected \"{\" after else. ");
      return stmt;
    }
    nextToken();  // 跳过 {
    parseProg(stmt->elseProg.value(), false);
    if (curToken().type != TokenType::RBrace) {
      error(curToken().line, "expected \"}\" in if statement. ");
      return stmt;
    }
    nextToken();  // 跳过 }
  }
  return stmt;
}

AST::WhileStmt* Parser::parseWhileStmt() {
  AST::WhileStmt* stmt = new AST::WhileStmt();
  stmt->line = curToken().line;
  nextToken();                                 // 跳过 while
  if (curToken().type != TokenType::LBrace) {  // expr?
    stmt->cond.reset(parseExpr(OpPrecedence::Lowest));
    nextToken();  // 到达 {
  }
  if (curToken().type != TokenType::LBrace) {
    error(curToken().line, "expected \"{\" in while statement. ");
    return stmt;
  }
  nextToken();  // 跳过 {
  parseProg(stmt->prog, false);
  if (curToken().type != TokenType::RBrace) {
    error(curToken().line, "expected \"}\" at end of while statement. ");
    return stmt;
  }
  nextToken();
  return stmt;
}

AST::BreakStmt* Parser::parseBreakStmt() {
  AST::BreakStmt* stmt = new AST::BreakStmt();
  stmt->line = curToken().line;
  nextToken();  // 跳过 break
  if (curToken().type != TokenType::Semi) {
    error(curToken().line, "expected \";\" in break statement. ");
  } else {
    nextToken();
  }
  return stmt;
}

AST::ContinueStmt* Parser::parseContinueStmt() {
  AST::ContinueStmt* stmt = new AST::ContinueStmt();
  stmt->line = curToken().line;
  nextToken();  // 跳过 continue
  if (curToken().type != TokenType::Semi) {
    error(curToken().line, "expected \";\" in continue statement. ");
  } else {
    nextToken();
  }
  return stmt;
}

AST::Stmt* Parser::parseExprOrAssignStmt() {
  AST::Stmt* stmt;
  AST::Expr* leftExpr = parseExpr(OpPrecedence::Lowest);
  nextToken();  // 到达 = 或 ;
  if (curToken().type == TokenType::Semi) {
    nextToken();  // 跳过 ;
    AST::ExprStmt* s = new AST::ExprStmt();
    s->expr.reset(leftExpr);
    s->line = leftExpr->line;
    stmt = s;
  } else if (curToken().type == TokenType::Assign) {
    nextToken();  // 跳过 =
    AST::AssignStmt* s = new AST::AssignStmt();
    s->line = leftExpr->line;
    s->leftExpr.reset(leftExpr);
    s->rightExpr.reset(parseExpr(OpPrecedence::Lowest));
    stmt = s;
    nextToken();  // 到达 ;
    if (curToken().type != TokenType::Semi) {
      error(curToken().line, "expected \";\" at end of assign statement. ");
    }
    nextToken();
  } else {
    error(curToken().line, "expected \";\" or \"=\". ");
    // 不推进：当前 token 不是合法的语句边界，留给下一轮语句解析。
    // 否则会吞掉后续语句（PD-4d：f(1, 2 x; y; 里的 x; 被吞）。
    AST::ExprStmt* s = new AST::ExprStmt();
    s->line = leftExpr->line;
    s->expr.reset(leftExpr);
    stmt = s;
  }
  return stmt;
}

OpPrecedence Parser::curPrecedence() {
  if (binopPrecMap().find(curToken().type) != binopPrecMap().end()) {
    return binopPrecMap().at(curToken().type);
  }
  return OpPrecedence::Lowest;
}

OpPrecedence Parser::peekPrecedence() {
  if (binopPrecMap().find(peekToken().type) != binopPrecMap().end()) {
    return binopPrecMap().at(peekToken().type);
  }
  return OpPrecedence::Lowest;
}

void Parser::optimizeInPlace(AST::Expr*& e) {
  if (constFolding)
    exprOptimizer.OptimizeInPlace(e);
}

AST::Expr* Parser::parseExpr(OpPrecedence prec) {
  if (prefixParseFns.find(curToken().type) == prefixParseFns.end()) {
    error(curToken().line, "no prefix parse function for token type. ");
    AST::Expr* e = new AST::Expr();
    e->line = curToken().line;
    return e;
  }
  AST::Expr* leftExpr = prefixParseFns.at(curToken().type)(*this);
  while (peekToken().type != TokenType::Semi && prec < peekPrecedence()) {
    if (infixParseFns.find(peekToken().type) == infixParseFns.end()) {
      error(peekToken().line, "no infix parse function for token type. ");
      return leftExpr;
    }
    nextToken();
    leftExpr = infixParseFns.at(curToken().type)(*this, leftExpr);
  }
  return leftExpr;
}

void Parser::error(int line, const char* msg) {
  // if (line == lastErrorLine)
  //   return;
  // lastErrorLine = line;
  std::stringstream ss;
  ss << "line " << line << ": " << msg;
  errors.emplace_back(ss.str());
}

Token& Parser::curToken() {
  return tokens[curTokenIdx];
}

Token& Parser::peekToken() {
  return tokens[(curTokenIdx + 1) % 2];
}

void Parser::nextToken() {
  curTokenIdx = (curTokenIdx + 1) % 2;
  lexer->NextToken(peekToken(), customOpcodeConfig);
}

AST::Expr* Parser::parseIdentExpr(Parser& p) {
  AST::IdentExpr* expr = new AST::IdentExpr();
  expr->line = p.curToken().line;
  expr->ident = p.curToken().parsed;
  return expr;
}

AST::Expr* Parser::parseNullExpr(Parser& p) {
  AST::NullExpr* expr = new AST::NullExpr();
  expr->line = p.curToken().line;
  return expr;
}

AST::Expr* Parser::parseBoolExpr(Parser& p) {
  AST::BoolExpr* expr = new AST::BoolExpr();
  expr->line = p.curToken().line;
  expr->value = p.curToken().type == TokenType::True;
  return expr;
}

AST::Expr* Parser::parseIntExpr(Parser& p) {
  AST::IntExpr* expr = new AST::IntExpr();
  expr->line = p.curToken().line;
  expr->value = p.curToken().numberValue.integer;
  return expr;
}

AST::Expr* Parser::parseFloatExpr(Parser& p) {
  AST::FloatExpr* expr = new AST::FloatExpr();
  expr->line = p.curToken().line;
  expr->value = p.curToken().numberValue.floating;
  return expr;
}

AST::Expr* Parser::parseStringExpr(Parser& p) {
  AST::StringExpr* expr = new AST::StringExpr();
  expr->line = p.curToken().line;
  expr->value = p.curToken().parsed;
  return expr;
}

AST::Expr* Parser::parseBinaryArray(Parser& p) {
  AST::BinArrExpr* expr = new AST::BinArrExpr();
  expr->line = p.curToken().line;
  Result res =
      p.binaryArrayParser.parseBinaryArray(p.curToken().lexeme, expr->value);
  if (res != Result::Success) {
    p.error(p.curToken().line, "invalid binary array. ");
  }
  return expr;
}

AST::Expr* Parser::parseArgcExpr(Parser& p) {
  AST::ArgcExpr* expr = new AST::ArgcExpr();
  expr->line = p.curToken().line;
  return expr;
}

AST::Expr* Parser::parseUnaryOpExpr(Parser& p) {
  AST::UnaryOpExpr* expr = new AST::UnaryOpExpr();
  expr->line = p.curToken().line;
  expr->op = p.curToken().type;
  p.nextToken();
  expr->expr.reset(p.parseExpr(OpPrecedence::Prefix));
  AST::Expr* out = expr;  // 自底向上：子表达式已折好，这里折自己
  p.optimizeInPlace(out);
  return out;
}

AST::Expr* Parser::parseParenExpr(Parser& p) {
  p.nextToken();
  AST::Expr* expr = p.parseExpr(OpPrecedence::Lowest);
  p.nextToken();
  if (p.curToken().type != TokenType::RParen) {
    p.error(p.curToken().line, "expected \")\". ");  // 不必 nextToken() ？
  }
  return expr;  // 停在 )
}

AST::Expr* Parser::parseCustomOpcodeExpr(Parser& p) {
  AST::CustomOpcodeExpr* expr = new AST::CustomOpcodeExpr();
  expr->line = p.curToken().line;
  expr->opcodeName = p.curToken().parsed;
  p.nextToken();  // 到达 (
  if (p.curToken().type != TokenType::LParen) {
    p.error(p.curToken().line, "expected \"(\" after custom opcode. ");
    p.nextToken();
    return expr;
  }
  p.nextToken();
  if (p.curToken().type == TokenType::RParen) {
  } else {  // expr ("," expr)*
    expr->args.emplace_back(p.parseExpr(OpPrecedence::Lowest));
    for (; p.peekToken().type == TokenType::Comma;) {  // ("," expr)*
      p.nextToken();
      p.nextToken();
      expr->args.emplace_back(p.parseExpr(OpPrecedence::Lowest));
    }
    if (p.peekToken().type != TokenType::RParen) {
      p.error(p.curToken().line, "expected \")\". ");
    }
    p.nextToken();  // 到达 )
  }
  return expr;
}

AST::Expr* Parser::parseArgsExpr(Parser& p) {
  AST::ArgsExpr* expr = new AST::ArgsExpr();
  expr->line = p.curToken().line;
  if (p.peekToken().type != TokenType::LBrack) {
    // 不推进（cur 停在 "args"）：把后续 token
    // 留给下一条语句，避免吞掉（PD-4c）。
    p.error(p.peekToken().line, "expected \"[\" after \"args\". ");
    return expr;
  }
  p.nextToken();  // 到达 [
  p.nextToken();
  expr->keyExpr.reset(p.parseExpr(OpPrecedence::Lowest));
  p.nextToken();
  if (p.curToken().type != TokenType::RBrack) {
    p.error(p.curToken().line, "expected \"]\". ");
  }
  return expr;
}

AST::Expr* Parser::parseBinaryOpExpr(Parser& p, AST::Expr* leftExpr) {
  AST::BinaryOpExpr* expr = new AST::BinaryOpExpr();
  expr->leftExpr.reset(leftExpr);
  expr->line = leftExpr->line;
  expr->op = p.curToken().type;
  OpPrecedence prec = p.curPrecedence();
  // 右结合，优先级 -1
  if (expr->op == TokenType::Pow) {
    prec = OpPrecedence(int(prec) - 1);
  }
  p.nextToken();
  expr->rightExpr.reset(p.parseExpr(prec));
  AST::Expr* out = expr;  // 两侧都已折好，折叠只在最深的节点先发生
  p.optimizeInPlace(out);
  return out;
}

AST::Expr* Parser::parseCallExpr(Parser& p, AST::Expr* calle) {
  AST::CallExpr* e = new AST::CallExpr();
  e->line = calle->line;
  e->callee.reset(calle);
  // 外层已保证此处是 (
  if (p.peekToken().type != TokenType::RParen) {  // expr ("," expr)*
    p.nextToken();                                // 到达第一个表达式
    e->args.emplace_back(p.parseExpr(OpPrecedence::Lowest));
    while (p.peekToken().type == TokenType::Comma) {  // ("," expr)*
      p.nextToken();                                  // 到达 ","
      p.nextToken();                                  // 到达下一个表达式
      e->args.emplace_back(p.parseExpr(OpPrecedence::Lowest));
    }
  }
  if (p.peekToken().type == TokenType::RParen) {
    p.nextToken();  // 跳过 )
  } else {          // 缺 ")" 时不推进，避免吞掉后面的 token
    p.error(p.peekToken().line, "expected \")\". ");
  }
  return e;
}

AST::Expr* Parser::parseAtExpr(Parser& p, AST::Expr* container) {
  AST::AtExpr* e = new AST::AtExpr();
  e->line = container->line;
  e->container.reset(container);
  if (p.peekToken().type != TokenType::RBrack) {  // expr ("," expr)*
    p.nextToken();                                // 到达第一个表达式
    e->keyExprs.emplace_back(p.parseExpr(OpPrecedence::Lowest));
    while (p.peekToken().type == TokenType::Comma) {  // ("," expr)*
      p.nextToken();                                  // 到达 ","
      p.nextToken();                                  // 到达下一个表达式
      e->keyExprs.emplace_back(p.parseExpr(OpPrecedence::Lowest));
    }
  }
  if (p.peekToken().type == TokenType::RBrack) {
    p.nextToken();  // 跳过 ]
  } else {          // 缺 "]" 时不推进，避免吞掉后面的 token
    p.error(p.peekToken().line, "expected \"]\". ");
  }
  return e;
}

const std::map<TokenType, Parser::PrefixParseFn> Parser::prefixParseFns{
    {TokenType::Ident, parseIdentExpr},
    {TokenType::Null, parseNullExpr},
    {TokenType::False, parseBoolExpr},
    {TokenType::True, parseBoolExpr},
    {TokenType::Integer, parseIntExpr},
    {TokenType::Float, parseFloatExpr},
    {TokenType::String, parseStringExpr},
    {TokenType::BinArr, parseBinaryArray},
    {TokenType::Argc, parseArgcExpr},

    {TokenType::Sub, parseUnaryOpExpr},
    {TokenType::Not, parseUnaryOpExpr},
    {TokenType::LParen, parseParenExpr},
    {TokenType::Custom, parseCustomOpcodeExpr},
    {TokenType::Args, parseArgsExpr},
};

const std::map<TokenType, Parser::InfixParseFn> Parser::infixParseFns{
    {TokenType::Or, parseBinaryOpExpr},   {TokenType::And, parseBinaryOpExpr},
    {TokenType::EQ, parseBinaryOpExpr},   {TokenType::NE, parseBinaryOpExpr},
    {TokenType::LT, parseBinaryOpExpr},   {TokenType::LE, parseBinaryOpExpr},
    {TokenType::GT, parseBinaryOpExpr},   {TokenType::GE, parseBinaryOpExpr},
    {TokenType::Add, parseBinaryOpExpr},  {TokenType::Sub, parseBinaryOpExpr},
    {TokenType::Mul, parseBinaryOpExpr},  {TokenType::Div, parseBinaryOpExpr},
    {TokenType::IDiv, parseBinaryOpExpr}, {TokenType::Mod, parseBinaryOpExpr},
    {TokenType::Pow, parseBinaryOpExpr},

    {TokenType::LParen, parseCallExpr},   {TokenType::LBrack, parseAtExpr},
};

}  // namespace Stope
