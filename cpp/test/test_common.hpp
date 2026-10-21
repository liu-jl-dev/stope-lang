#pragma once
// lexer 测试框架：零第三方依赖，与 cpp/stope 的 header-only 现状一致。
//
// 用法：
//   auto r = lexAll(u"0x1F");
//   EXPECT_TYPE(r, 0, TokenType::Integer, "I-06");
//   EXPECT_INT(r, 0, 31, "I-06");
//   KNOWN("D-8", r.tokens[0].lexeme == u"abc", "D-09");   // 已知缺陷：期望但当前不成立
//
// 注意：
//   1) Token::lexeme 是指向输入的 string_view，不拥有内存。lexAll() 用 shared_ptr 持有
//      输入副本，保证返回结果在拷贝/移动后 lexeme 依然有效（string 地址不变）。
//   2) lexAll() 内置 10000 次迭代上限，兜底 NextToken 不消费字符导致的死循环。

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <memory>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include <stope/ast.hpp>
#include <stope/lexer.hpp>
#include <stope/parser.hpp>

namespace Stope {
namespace Test {

inline int g_total = 0;   // 断言总数
inline int g_failed = 0;  // 普通断言失败（会使测试失败）
inline int g_known = 0;   // 已知缺陷：期望行为尚未达成
inline int g_flip = 0;    // 已知缺陷：期望行为已达成，需把 KNOWN 翻转成普通断言
inline std::set<int> g_seenTypes;  // TokenType 覆盖统计

inline const char* tokenName(TokenType t) {
  switch (t) {
    case TokenType::Invalid:  return "Invalid";
    case TokenType::Eof:      return "Eof";
    case TokenType::Ident:    return "Ident";
    case TokenType::Integer:  return "Integer";
    case TokenType::Float:    return "Float";
    case TokenType::String:   return "String";
    case TokenType::BinArr:   return "BinArr";
    case TokenType::Comma:    return "Comma";
    case TokenType::Semi:     return "Semi";
    case TokenType::LParen:   return "LParen";
    case TokenType::RParen:   return "RParen";
    case TokenType::LBrack:   return "LBrack";
    case TokenType::RBrack:   return "RBrack";
    case TokenType::LBrace:   return "LBrace";
    case TokenType::RBrace:   return "RBrace";
    case TokenType::Assign:   return "Assign";
    case TokenType::Add:      return "Add";
    case TokenType::Sub:      return "Sub";
    case TokenType::Mul:      return "Mul";
    case TokenType::Div:      return "Div";
    case TokenType::IDiv:     return "IDiv";
    case TokenType::Mod:      return "Mod";
    case TokenType::Pow:      return "Pow";
    case TokenType::EQ:       return "EQ";
    case TokenType::NE:       return "NE";
    case TokenType::LT:       return "LT";
    case TokenType::LE:       return "LE";
    case TokenType::GT:       return "GT";
    case TokenType::GE:       return "GE";
    case TokenType::Not:      return "Not";
    case TokenType::And:      return "And";
    case TokenType::Or:       return "Or";
    case TokenType::If:       return "If";
    case TokenType::Elif:     return "Elif";
    case TokenType::Else:     return "Else";
    case TokenType::Let:      return "Let";
    case TokenType::Return:   return "Return";
    case TokenType::While:    return "While";
    case TokenType::Break:    return "Break";
    case TokenType::Continue: return "Continue";
    case TokenType::Null:     return "Null";
    case TokenType::False:    return "False";
    case TokenType::True:     return "True";
    case TokenType::Args:     return "Args";
    case TokenType::Argc:     return "Argc";
    case TokenType::Export:   return "Export";
    case TokenType::Custom:   return "Custom";
  }
  return "?";
}

// 仅用于打印：非 ASCII 码元打成 '?'
inline std::string toUtf8(std::u16string_view v) {
  std::string s;
  for (char16_t c : v) s += (c < 128) ? static_cast<char>(c) : '?';
  return s;
}

struct LexResult {
  std::shared_ptr<const std::u16string> src;  // 持有输入，保证 lexeme 有效
  std::vector<Token> tokens;
  std::vector<std::string> errors;
  size_t size() const { return tokens.size(); }
  const Token& at(size_t i) const { return tokens[i]; }
};

inline LexResult lexAll(std::u16string src, const CustomOpcodeConfig* cfg = nullptr) {
  auto holder = std::make_shared<std::u16string>(std::move(src));
  LexResult r;
  r.src = holder;
  Lexer lx(*holder);
  for (int i = 0; i < 10000; ++i) {  // 死循环保险丝
    Token t;
    lx.NextToken(t, cfg);
    g_seenTypes.insert(static_cast<int>(t.type));
    r.tokens.push_back(t);
    if (t.type == TokenType::Eof) break;
  }
  r.errors = lx.errors;
  return r;
}

// 失败时打印 token 全貌，便于定位
inline std::string tokDesc(const LexResult& r, size_t i) {
  if (i >= r.tokens.size()) return "<index out of range>";
  const Token& t = r.tokens[i];
  char buf[256];
  std::string d = "tok[" + std::to_string(i) + "] type=" + tokenName(t.type);
  d += " lex=[" + toUtf8(t.lexeme) + "]";
  d += " parsed=[" + toUtf8(t.parsed) + "]";
  d += " line=" + std::to_string(t.line);
  if (t.type == TokenType::Integer) {
    snprintf(buf, sizeof(buf), " int=%lld", t.numberValue.integer);
    d += buf;
  } else if (t.type == TokenType::Float) {
    snprintf(buf, sizeof(buf), " dbl=%g", t.numberValue.floating);
    d += buf;
  }
  return d;
}

// expr 用 std::string：调用点可以直接拼字符串（"stack size == " + to_string(n)）。
// 原来是 const char*，传 std::string 会编译不过；改成引用形式对既有 const char*
// 调用点完全兼容。
inline void check(bool ok, const char* id, const std::string& expr, const std::string& detail) {
  ++g_total;
  if (ok) return;
  ++g_failed;
  printf("  FAIL [%s] %s\n         %s\n", id, expr.c_str(), detail.c_str());
}

// 已知缺陷：expr 为"修复后应成立"的条件。
//   不成立 -> KNOWN-FAIL（不计失败）
//   成立   -> FIXED-PENDING-FLIP（提醒把断言翻成普通 EXPECT_*）
inline void knownCheck(const char* defect, bool fixedNow, const char* expr, const char* id) {
  ++g_total;
  if (fixedNow) {
    ++g_flip;
    printf("  FIXED-PENDING-FLIP [%s] %s : %s  -> 请翻转为普通断言\n", id, defect, expr);
  } else {
    ++g_known;
    printf("  KNOWN-FAIL [%s] %s : %s\n", id, defect, expr);
  }
}

inline bool errorHas(const LexResult& r, const std::string& sub) {
  for (const auto& e : r.errors)
    if (e.find(sub) != std::string::npos) return true;
  return false;
}

inline std::string errDetail(const LexResult& r) {
  std::string d = "errors=" + std::to_string(r.errors.size());
  for (const auto& e : r.errors) d += "\n         [" + e + "]";
  return d;
}

inline void section(const char* name) { printf("\n-- %s\n", name); }

// ===================== parser 测试支持（2026-10-16 新增） =====================
// 与 lexer 部分共用同一套 g_total/g_failed/g_known/g_flip 与 check()/knownCheck()。
// parser 的断言宏一律带 P 前缀（EXPECT_Pxxx），避免与上面的 lexer 宏重名。
// 注意：ast.hpp/parser.hpp 在文件顶部统一 include，不要放到 namespace 里面。

inline std::set<int> g_seenNodeTypes;  // AST::NodeType 覆盖统计

inline const char* nodeName(AST::NodeType t) {
  switch (t) {
    case AST::NodeType::Node:               return "Node";
    case AST::NodeType::Prog:               return "Prog";
    case AST::NodeType::Stmt:               return "Stmt";
    case AST::NodeType::Expr:               return "Expr";
    case AST::NodeType::ExprStmt:           return "ExprStmt";
    case AST::NodeType::LetStmt:            return "LetStmt";
    case AST::NodeType::ReturnStmt:         return "ReturnStmt";
    case AST::NodeType::ExportStmt:         return "ExportStmt";
    case AST::NodeType::BlockStmt:          return "BlockStmt";
    case AST::NodeType::IfStmt:             return "IfStmt";
    case AST::NodeType::WhileStmt:          return "WhileStmt";
    case AST::NodeType::AssignStmt:         return "AssignStmt";
    case AST::NodeType::BreakStmt:          return "BreakStmt";
    case AST::NodeType::ContinueStmt:       return "ContinueStmt";
    case AST::NodeType::NullExpr:           return "NullExpr";
    case AST::NodeType::BoolExpr:           return "BoolExpr";
    case AST::NodeType::IntExpr:            return "IntExpr";
    case AST::NodeType::FloatExpr:          return "FloatExpr";
    case AST::NodeType::BinArrExpr:         return "BinArrExpr";
    case AST::NodeType::StringExpr:         return "StringExpr";
    case AST::NodeType::IdentExpr:          return "IdentExpr";
    case AST::NodeType::ArgcExpr:           return "ArgcExpr";
    case AST::NodeType::ArgsExpr:           return "ArgsExpr";
    case AST::NodeType::UnaryOpExpr:        return "UnaryOpExpr";
    case AST::NodeType::BinaryOpExpr:       return "BinaryOpExpr";
    case AST::NodeType::CallExpr:           return "CallExpr";
    case AST::NodeType::AtExpr:             return "AtExpr";
    case AST::NodeType::CustomOpcodeExpr:   return "CustomOpcodeExpr";
  }
  return "?";
}

// 显示用：转义控制字符，非 ASCII 码元打成 '?'（与 toUtf8 一致，但可安全嵌入引号内）
inline std::string escUtf8(std::u16string_view v) {
  std::string s;
  for (char16_t c : v) {
    switch (c) {
      case u'\\': s += "\\\\"; break;
      case u'"':  s += "\\\""; break;
      case u'\n': s += "\\n";  break;
      case u'\r': s += "\\r";  break;
      case u'\t': s += "\\t";  break;
      default:    s += (c < 128) ? static_cast<char>(c) : '?';
    }
  }
  return s;
}

inline std::string shapeProg(const AST::Prog& p);

// 把表达式序列化成紧凑字符串，一条断言锁定整棵子树形状。
// 形如：Bin(Add, Int(1), Mul(Int(2), Int(3))) / Call(Ident(f); Int(1), Int(2))
//      / Custom(myop; Int(1)) / At(Ident(a); Int(1)) / Args(null) / Err(L-1)
inline std::string shapeExpr(const AST::Expr* e) {
  if (!e) return "null";
  using AST::NodeType;
  switch (e->type) {
    case NodeType::Expr:  // 失败路径返回的裸节点（PD-8）：line 恒为 -1
      return "Err(L" + std::to_string(e->line) + ")";
    case NodeType::NullExpr: return "Null";
    case NodeType::ArgcExpr: return "Argc";
    case NodeType::BoolExpr:
      return static_cast<const AST::BoolExpr*>(e)->value ? "Bool(true)" : "Bool(false)";
    case NodeType::IntExpr:
      return "Int(" + std::to_string(static_cast<const AST::IntExpr*>(e)->value) + ")";
    case NodeType::FloatExpr: {
      char b[64];
      snprintf(b, sizeof(b), "Float(%g)", static_cast<const AST::FloatExpr*>(e)->value);
      return b;
    }
    case NodeType::BinArrExpr: {
      std::string d = "BinArr[";
      bool first = true;
      for (char c : static_cast<const AST::BinArrExpr*>(e)->value) {
        if (!first) d += ",";
        first = false;
        char b[8];
        snprintf(b, sizeof(b), "%02x", static_cast<unsigned char>(c));
        d += b;
      }
      return d + "]";
    }
    case NodeType::StringExpr:
      return "Str(\"" + escUtf8(static_cast<const AST::StringExpr*>(e)->value) + "\")";
    case NodeType::IdentExpr:
      return "Ident(" + escUtf8(static_cast<const AST::IdentExpr*>(e)->ident) + ")";
    case NodeType::ArgsExpr: {
      auto* a = static_cast<const AST::ArgsExpr*>(e);
      return a->keyExpr ? "Args(" + shapeExpr(a->keyExpr.get()) + ")" : "Args(null)";
    }
    case NodeType::UnaryOpExpr: {
      auto* u = static_cast<const AST::UnaryOpExpr*>(e);
      return std::string("Unary(") + tokenName(u->op) + ", " + shapeExpr(u->expr.get()) + ")";
    }
    case NodeType::BinaryOpExpr: {
      auto* b = static_cast<const AST::BinaryOpExpr*>(e);
      return std::string("Bin(") + tokenName(b->op) + ", " + shapeExpr(b->leftExpr.get()) +
             ", " + shapeExpr(b->rightExpr.get()) + ")";
    }
    case NodeType::CallExpr: {
      auto* c = static_cast<const AST::CallExpr*>(e);
      std::string d = "Call(" + shapeExpr(c->callee.get());
      for (const auto& a : c->args) d += "; " + shapeExpr(a.get());
      return d + ")";
    }
    case NodeType::AtExpr: {
      auto* a = static_cast<const AST::AtExpr*>(e);
      std::string d = "At(" + shapeExpr(a->container.get());
      for (const auto& i : a->keyExprs) d += "; " + shapeExpr(i.get());
      return d + ")";
    }
    case NodeType::CustomOpcodeExpr: {
      auto* c = static_cast<const AST::CustomOpcodeExpr*>(e);
      std::string d = "Custom(" + escUtf8(c->opcodeName);
      for (const auto& a : c->args) d += "; " + shapeExpr(a.get());
      return d + ")";
    }
    default:
      return std::string("?") + nodeName(e->type);
  }
}

// 语句形状：ExprStmt(...) / Let[a,b]=Int(1) / Return(Int(1), Int(2)) /
//           Block{...} / If(c){...}Elif(c){...}Else{...} / While(c?){...} /
//           Assign(l, r) / Break / Continue
inline std::string shapeStmt(const AST::Stmt* s) {
  if (!s) return "null";
  using AST::NodeType;
  switch (s->type) {
    case NodeType::ExprStmt:
      return "ExprStmt(" + shapeExpr(static_cast<const AST::ExprStmt*>(s)->expr.get()) + ")";
    case NodeType::LetStmt: {
      auto* l = static_cast<const AST::LetStmt*>(s);
      std::string d = "Let[";
      for (size_t i = 0; i < l->idents.size(); ++i) {
        if (i) d += ",";
        d += escUtf8(l->idents[i]);
      }
      d += "]";
      if (l->hasAssign) d += "=" + shapeExpr(l->expr.get());
      return d;
    }
    case NodeType::ReturnStmt: {
      auto* r = static_cast<const AST::ReturnStmt*>(s);
      std::string d = "Return(";
      for (size_t i = 0; i < r->exprs.size(); ++i) {
        if (i) d += ", ";
        d += shapeExpr(r->exprs[i].get());
      }
      return d + ")";
    }
    case NodeType::ExportStmt: {
      auto* x = static_cast<const AST::ExportStmt*>(s);
      std::string d = "Export[";
      for (size_t i = 0; i < x->idents.size(); ++i) {
        if (i) d += ",";
        d += escUtf8(x->idents[i]);
      }
      return d + "]";
    }
    case NodeType::BlockStmt:
      return "Block{" + shapeProg(static_cast<const AST::BlockStmt*>(s)->prog) + "}";
    case NodeType::IfStmt: {
      auto* f = static_cast<const AST::IfStmt*>(s);
      std::string d = "If(" + shapeExpr(f->cond.get()) + "){" + shapeProg(f->firstProg) + "}";
      for (const auto& el : f->elifs)
        d += "Elif(" + shapeExpr(el.cond.get()) + "){" + shapeProg(el.prog) + "}";
      if (f->elseProg) d += "Else{" + shapeProg(*f->elseProg) + "}";
      return d;
    }
    case NodeType::WhileStmt: {
      auto* w = static_cast<const AST::WhileStmt*>(s);
      return "While(" + shapeExpr(w->cond.get()) + "){" + shapeProg(w->prog) + "}";
    }
    case NodeType::AssignStmt: {
      auto* a = static_cast<const AST::AssignStmt*>(s);
      return "Assign(" + shapeExpr(a->leftExpr.get()) + ", " + shapeExpr(a->rightExpr.get()) + ")";
    }
    case NodeType::BreakStmt:    return "Break";
    case NodeType::ContinueStmt: return "Continue";
    default:
      return std::string("?") + nodeName(s->type);
  }
}

inline std::string shapeProg(const AST::Prog& p) {
  std::string d;
  for (const auto& s : p.stmts) {
    if (!d.empty()) d += " ; ";
    d += shapeStmt(s.get());
  }
  return d;
}

struct ParseResult {
  std::shared_ptr<const std::u16string> src;  // 持有输入，保证 lexeme 有效
  AST::Prog prog;
  std::vector<std::string> errors;    // parser.errors
  std::vector<std::string> lexErrors;  // lexer.errors（PD-14：两者不合并）
  CustomOpcodeConfig* cfg = nullptr;
  size_t stmts() const { return prog.stmts.size(); }
  const AST::Stmt* stmt(size_t i) const {
    return i < prog.stmts.size() ? prog.stmts[i].get() : nullptr;
  }
};

// 一次解析到底。输入按值传入，由 shared_ptr 持有（Token::lexeme 是 string_view）。
// cfg 经 Parser 构造函数传入（PD-3 已修，2026-10-16）：构造体内的两次 nextToken()
// 此时已拿到 config，故输入开头的自定义指令同样能被识别。
inline void collectNodeTypes(const ParseResult& r);  // 定义在后面

// fold=false 关掉常量折叠（Parser::constFolding），用于锁定未折叠的树形：
// P 组优先级/结合性用例、L-02 跨行行号用例都靠它。其余用例保持默认（开）。
inline ParseResult parseAll(std::u16string src, CustomOpcodeConfig* cfg = nullptr,
                            bool fold = true) {
  auto holder = std::make_shared<std::u16string>(std::move(src));
  ParseResult r;
  r.src = holder;
  r.cfg = cfg;
  Lexer lx(*holder);
  Parser p(lx, cfg);
  p.constFolding = fold;
  p.ParseProgram(r.prog);
  r.errors = p.errors;
  r.lexErrors = lx.errors;
  collectNodeTypes(r);  // NodeType 覆盖统计（内部有 512 层深度上限）
  return r;
}

inline bool pHasErr(const ParseResult& r, const std::string& sub) {
  for (const auto& e : r.errors)
    if (e.find(sub) != std::string::npos) return true;
  return false;
}
inline bool pHasErrAny(const ParseResult& r, const std::string& sub) {
  return pHasErr(r, sub) ||
         std::any_of(r.lexErrors.begin(), r.lexErrors.end(),
                     [&](const std::string& e) {
                       return e.find(sub) != std::string::npos;
                     });
}

inline std::string pErrDetail(const ParseResult& r) {
  std::string d = "parser.errors=" + std::to_string(r.errors.size());
  for (const auto& e : r.errors) d += "\n         [" + e + "]";
  d += "\n         lexer.errors=" + std::to_string(r.lexErrors.size());
  for (const auto& e : r.lexErrors) d += "\n         [" + e + "]";
  return d;
}

// 失败时打印整棵树的形状，便于定位
inline std::string pShapeDetail(const ParseResult& r, size_t stmtIdx) {
  if (stmtIdx == static_cast<size_t>(-1))
    return "prog shape=[" + shapeProg(r.prog) + "]";
  return "stmt[" + std::to_string(stmtIdx) + "] shape=[" +
         (stmtIdx < r.prog.stmts.size() ? shapeStmt(r.prog.stmts[stmtIdx].get()) : "<oob>") + "]";
}

// NodeType 覆盖统计（深度上限 512：深嵌套用例不递归到底，避免统计本身爆栈）
inline void collectNodeTypes(const AST::Node* n, int depth) {
  if (!n || depth > 512) return;
  g_seenNodeTypes.insert(static_cast<int>(n->type));
  if (n->type == AST::NodeType::Prog) {  // Prog 不是 Stmt 子类，单列
    for (const auto& st : static_cast<const AST::Prog*>(n)->stmts)
      collectNodeTypes(st.get(), depth + 1);
  } else if (auto* s = dynamic_cast<const AST::Stmt*>(n)) {
    switch (s->type) {
      case AST::NodeType::ExprStmt:
        collectNodeTypes(static_cast<const AST::ExprStmt*>(s)->expr.get(), depth + 1);
        break;
      case AST::NodeType::LetStmt:
        collectNodeTypes(static_cast<const AST::LetStmt*>(s)->expr.get(), depth + 1);
        break;
      case AST::NodeType::ReturnStmt:
        for (auto& e : static_cast<const AST::ReturnStmt*>(s)->exprs)
          collectNodeTypes(e.get(), depth + 1);
        break;
      case AST::NodeType::BlockStmt:
        for (auto& st : static_cast<const AST::BlockStmt*>(s)->prog.stmts)
          collectNodeTypes(st.get(), depth + 1);
        break;
      case AST::NodeType::IfStmt: {
        auto* f = static_cast<const AST::IfStmt*>(s);
        collectNodeTypes(f->cond.get(), depth + 1);
        for (auto& st : f->firstProg.stmts) collectNodeTypes(st.get(), depth + 1);
        for (auto& el : f->elifs) {
          collectNodeTypes(el.cond.get(), depth + 1);
          for (auto& st : el.prog.stmts) collectNodeTypes(st.get(), depth + 1);
        }
        if (f->elseProg)
          for (auto& st : f->elseProg->stmts) collectNodeTypes(st.get(), depth + 1);
        break;
      }
      case AST::NodeType::WhileStmt: {
        auto* w = static_cast<const AST::WhileStmt*>(s);
        collectNodeTypes(w->cond.get(), depth + 1);
        for (auto& st : w->prog.stmts) collectNodeTypes(st.get(), depth + 1);
        break;
      }
      case AST::NodeType::AssignStmt: {
        auto* a = static_cast<const AST::AssignStmt*>(s);
        collectNodeTypes(a->leftExpr.get(), depth + 1);
        collectNodeTypes(a->rightExpr.get(), depth + 1);
        break;
      }
      default:
        break;
    }
  } else if (auto* e = dynamic_cast<const AST::Expr*>(n)) {
    switch (e->type) {
      case AST::NodeType::ArgsExpr:
        collectNodeTypes(static_cast<const AST::ArgsExpr*>(e)->keyExpr.get(), depth + 1);
        break;
      case AST::NodeType::UnaryOpExpr:
        collectNodeTypes(static_cast<const AST::UnaryOpExpr*>(e)->expr.get(), depth + 1);
        break;
      case AST::NodeType::BinaryOpExpr: {
        auto* b = static_cast<const AST::BinaryOpExpr*>(e);
        collectNodeTypes(b->leftExpr.get(), depth + 1);
        collectNodeTypes(b->rightExpr.get(), depth + 1);
        break;
      }
      case AST::NodeType::CallExpr: {
        auto* c = static_cast<const AST::CallExpr*>(e);
        collectNodeTypes(c->callee.get(), depth + 1);
        for (auto& a : c->args) collectNodeTypes(a.get(), depth + 1);
        break;
      }
      case AST::NodeType::AtExpr: {
        auto* a = static_cast<const AST::AtExpr*>(e);
        collectNodeTypes(a->container.get(), depth + 1);
        for (auto& i : a->keyExprs) collectNodeTypes(i.get(), depth + 1);
        break;
      }
      case AST::NodeType::CustomOpcodeExpr:
        for (auto& a : static_cast<const AST::CustomOpcodeExpr*>(e)->args)
          collectNodeTypes(a.get(), depth + 1);
        break;
      default:
        break;
    }
  }
}

inline void collectNodeTypes(const ParseResult& r) {
  collectNodeTypes(&r.prog, 0);
}

}  // namespace Test
}  // namespace Stope

// ---- parser 断言宏（失败时打印树形状 / 错误详情） ----
#define EXPECT_PSTMTS(r, N, id)                                              \
  Stope::Test::check((r).stmts() == static_cast<size_t>(N), (id),            \
                     "stmts == " #N,                                         \
                     "actual=" + std::to_string((r).stmts()) + "\n         " + \
                         Stope::Test::shapeProg((r).prog))
#define EXPECT_PSTMT(r, I, T, id)                                            \
  Stope::Test::check((r).stmt(I) && (r).stmt(I)->type == (T), (id),          \
                     "stmt[" #I "] is " #T, Stope::Test::pShapeDetail((r), (I)))
#define EXPECT_PEXPR(r, I, T, id)                                            \
  Stope::Test::check((r).stmt(I) &&                                          \
                         (r).stmt(I)->type == AST::NodeType::ExprStmt &&     \
                         static_cast<const AST::ExprStmt*>((r).stmt(I))->expr && \
                         static_cast<const AST::ExprStmt*>((r).stmt(I))->expr->type == (T), \
                     (id), "stmt[" #I "] expr is " #T,                       \
                     Stope::Test::pShapeDetail((r), (I)))
#define EXPECT_PLINE(r, I, N, id)                                            \
  Stope::Test::check((r).stmt(I) && (r).stmt(I)->line == (N), (id),          \
                     "stmt[" #I "].line == " #N, Stope::Test::pShapeDetail((r), (I)))
#define EXPECT_PSTMT_SHAPE(r, I, SH, id)                                     \
  Stope::Test::check((r).stmt(I) &&                                          \
                         Stope::Test::shapeStmt((r).stmt(I)) == (SH), (id),  \
                     "stmt[" #I "] shape == " #SH, Stope::Test::pShapeDetail((r), (I)))
#define EXPECT_PROG_SHAPE(r, SH, id)                                         \
  Stope::Test::check(Stope::Test::shapeProg((r).prog) == (SH), (id),         \
                     "prog shape == " #SH, Stope::Test::pShapeDetail((r), static_cast<size_t>(-1)))
#define EXPECT_PERR_COUNT(r, N, id)                                          \
  Stope::Test::check((r).errors.size() == static_cast<size_t>(N), (id),      \
                     "parser error count == " #N, Stope::Test::pErrDetail(r))
#define EXPECT_PERR_HAS(r, SUB, id)                                          \
  Stope::Test::check(Stope::Test::pHasErr((r), SUB), (id),                   \
                     "parser errors contains " #SUB, Stope::Test::pErrDetail(r))
#define EXPECT_PERR_ANY(r, SUB, id)                                          \
  Stope::Test::check(Stope::Test::pHasErrAny((r), SUB), (id),                \
                     "any errors contains " #SUB, Stope::Test::pErrDetail(r))

#define EXPECT(cond, id) Stope::Test::check((cond), (id), #cond, "")
#define EXPECT_TYPE(r, i, T, id) \
  Stope::Test::check(static_cast<size_t>(i) < (r).size() && (r).at(i).type == (T), (id), \
                     "type == " #T, Stope::Test::tokDesc(r, i))
#define EXPECT_LEX(r, i, U16, id)                                        \
  Stope::Test::check(static_cast<size_t>(i) < (r).size() && (r).at(i).lexeme == (U16), (id), \
                     "lexeme == " #U16, Stope::Test::tokDesc(r, i))
#define EXPECT_PARSED(r, i, U16, id)                                     \
  Stope::Test::check(static_cast<size_t>(i) < (r).size() && (r).at(i).parsed == (U16), (id), \
                     "parsed == " #U16, Stope::Test::tokDesc(r, i))
#define EXPECT_INT(r, i, V, id)                                              \
  Stope::Test::check(static_cast<size_t>(i) < (r).size() && (r).at(i).type == TokenType::Integer && \
                         (r).at(i).numberValue.integer == (V),               \
                     (id), "integer == " #V, Stope::Test::tokDesc(r, i))
#define EXPECT_DBL(r, i, V, id)                                              \
  Stope::Test::check(static_cast<size_t>(i) < (r).size() && (r).at(i).type == TokenType::Float && \
                         std::fabs((r).at(i).numberValue.floating - (V)) < 1e-9, \
                     (id), "floating == " #V, Stope::Test::tokDesc(r, i))
#define EXPECT_LINE(r, i, N, id)                                        \
  Stope::Test::check(static_cast<size_t>(i) < (r).size() && (r).at(i).line == (N), (id),    \
                     "line == " #N, Stope::Test::tokDesc(r, i))
#define EXPECT_COUNT(r, N, id)                                                  \
  Stope::Test::check((r).size() == static_cast<size_t>(N), (id), "token count == " #N, \
                     "actual=" + std::to_string((r).size()))
#define EXPECT_ERR_COUNT(r, N, id)                                     \
  Stope::Test::check((r).errors.size() == static_cast<size_t>(N), (id), \
                     "error count == " #N, Stope::Test::errDetail(r))
#define EXPECT_ERR_HAS(r, SUB, id) \
  Stope::Test::check(Stope::Test::errorHas(r, SUB), (id), "errors contains " #SUB, "")
// 类型序列整体比对，如 EXPECT_SEQ(r, "Let Ident Assign Integer Eof", "G-01")
#define EXPECT_SEQ(r, SEQ, id)                                                       \
  do {                                                                               \
    std::string got;                                                                 \
    for (const auto& t : (r).tokens) {                                               \
      got += Stope::Test::tokenName(t.type);                                         \
      got += " ";                                                                    \
    }                                                                                \
    if (!got.empty()) got.pop_back();                                                \
    Stope::Test::check(got == (SEQ), (id), "sequence == " #SEQ, "got=[" + got + "]"); \
  } while (0)
#define KNOWN(defect, cond, id) Stope::Test::knownCheck(defect, (cond), #cond, id)
