// golden 数据生成器：把 include/stope/parse_binarr.hpp 在 C++ 侧的事实行为 dump 成
// 机器可读文本，供 GDScript 侧（stope_parse_binarr.gd）逐条比对 —— 期望值不手推。
// 同时 dump 一批常量折叠用例：完整的 AST 形状串走 shapeExpr。
//
// 重生成（在 cpp/ 下）：cmake --build build --target gen-golden
#include <cstdio>
#include <string>
#include <vector>

#include "ast.hpp"
#include "expr_optim.hpp"
#include "parse_binarr.hpp"

using namespace Stope;

static std::u16string U(const char* s) {
  std::u16string o;
  for (const char* p = s; *p; ++p) o += char16_t((unsigned char)*p);
  return o;
}
static std::string Hex(const std::vector<char>& v) {
  std::string s = "[";
  for (size_t i = 0; i < v.size(); ++i) {
    if (i) s += ",";
    char b[8];
    snprintf(b, sizeof(b), "%02x", (unsigned char)v[i]);
    s += b;
  }
  return s + "]";
}

static void binArr(const char* text) {
  BinaryArrayParser p;
  std::vector<char> out;
  Result r = p.parseBinaryArray(U(text), out);
  printf("BA\t%s\t%s\t%s\n", text, r == Result::Success ? "ok" : "err",
         Hex(out).c_str());
}

// 一元 / 二元折罍：直接用 AST 节点构造，走 ExpressionOptimizer
static std::string Shape(AST::Expr* e) {
  std::string s;
  if (!e) return "null";
  switch (e->type) {
    case AST::NodeType::NullExpr: s = "Null"; break;
    case AST::NodeType::BoolExpr:
      s = static_cast<AST::BoolExpr*>(e)->value ? "true" : "false";
      break;
    case AST::NodeType::IntExpr:
      s = std::to_string(static_cast<AST::IntExpr*>(e)->value);
      break;
    case AST::NodeType::FloatExpr: {
      char b[64];
      snprintf(b, sizeof(b), "%g", static_cast<AST::FloatExpr*>(e)->value);
      s = b;
      break;
    }
    case AST::NodeType::BinArrExpr:
      s = Hex(static_cast<AST::BinArrExpr*>(e)->value);
      break;
    case AST::NodeType::StringExpr:
      s = "\"" + std::string(static_cast<AST::StringExpr*>(e)->value.begin(),
                             static_cast<AST::StringExpr*>(e)->value.end()) + "\"";
      break;
    default: s = "?";
  }
  return s;
}
static AST::Expr* mkInt(int64_t v) { auto* e = new AST::IntExpr(); e->value = v; return e; }
static AST::Expr* mkFloat(double v) { auto* e = new AST::FloatExpr(); e->value = v; return e; }
static AST::Expr* mkBool(bool v) { auto* e = new AST::BoolExpr(); e->value = v; return e; }
static AST::Expr* mkNull() { return new AST::NullExpr(); }
static AST::Expr* mkStr(const char* v) { auto* e = new AST::StringExpr(); e->value = U(v); return e; }
static AST::Expr* mkBin(const std::vector<char>& v) {
  auto* e = new AST::BinArrExpr(); e->value = v; return e;
}

static void foldBin(const char* opName, TokenType op, AST::Expr* l, AST::Expr* r) {
  AST::BinaryOpExpr* e = new AST::BinaryOpExpr();
  e->op = op; e->leftExpr.reset(l); e->rightExpr.reset(r);
  ExpressionOptimizer o;
  AST::Expr* out = o.Optimize(e);
  printf("FB\t%s\t%d\t%s\n", opName, out->type == static_cast<AST::NodeType>(
      AST::NodeType::UnaryOpExpr) || out->type == AST::NodeType::BinaryOpExpr ? 0 : 1,
      Shape(out).c_str());
}
static void foldUn(const char* opName, TokenType op, AST::Expr* v) {
  AST::UnaryOpExpr* e = new AST::UnaryOpExpr();
  e->op = op; e->expr.reset(v);
  ExpressionOptimizer o;
  AST::Expr* out = o.Optimize(e);
  printf("FU\t%s\t%d\t%s\n", opName,
      out->type == AST::NodeType::UnaryOpExpr ? 0 : 1, Shape(out).c_str());
}

int main() {
  // ---- 二进制数组 ----
  binArr("");
  binArr(" ");
  binArr("a");
  binArr("ab");
  binArr("b 0100 0001");
  binArr("b 01000001");
  binArr("B 1");
  binArr("o 101");
  binArr("O 7");
  binArr("d 65");
  binArr("d 300");
  binArr("D 255 0");
  binArr("x 41");
  binArr("x ff FF");
  binArr("X 0f");
  binArr("41");
  binArr("4_1");
  binArr("_41");
  binArr("01 02");
  binArr("  01   02  ");
  binArr("x zz");
  binArr("z");
  binArr("b");
  binArr("d");
  binArr("b 2");
  binArr("o 8");
  binArr("0 1");
  binArr("9999999999999999999999");
  binArr("d 2147483647");
  binArr("d 2147483648");
  binArr("ff");

  // ---- 折叠：Smoke（与 golden.txt 的 O 组一致，外加边界） ----
  foldBin("+", TokenType::Add, mkInt(1), mkInt(2));
  foldBin("-", TokenType::Sub, mkInt(5), mkInt(3));
  foldBin("*", TokenType::Mul, mkInt(2), mkInt(3));
  foldBin("/", TokenType::Div, mkInt(7), mkInt(2));
  foldBin("/", TokenType::Div, mkInt(6), mkInt(3));
  foldBin("/", TokenType::Div, mkInt(1), mkInt(0));
  foldBin("idiv", TokenType::IDiv, mkInt(7), mkInt(2));
  foldBin("%", TokenType::Mod, mkInt(7), mkInt(2));
  foldBin("^", TokenType::Pow, mkInt(2), mkInt(10));
  foldBin("^", TokenType::Pow, mkInt(2), mkInt(-1));
  foldBin("+", TokenType::Add, mkFloat(1.5), mkInt(1));
  foldBin("+", TokenType::Add, mkInt(9223372036854775807LL), mkInt(1));
  foldBin("*", TokenType::Mul, mkInt(9223372036854775807LL), mkInt(2));
  foldBin("+", TokenType::Add, mkBool(true), mkBool(true));
  foldBin("+", TokenType::Add, mkStr("ab"), mkStr("cd"));
  foldBin("*", TokenType::Mul, mkStr("ab"), mkInt(3));
  foldBin("*", TokenType::Mul, mkInt(3), mkStr("ab"));
  foldBin("*", TokenType::Mul, mkStr(""), mkInt(1000000));
  foldBin("*", TokenType::Mul, mkStr("ab"), mkInt(-1));
  foldBin("*", TokenType::Mul, mkFloat(1.5), mkStr("ab"));
  foldBin("+", TokenType::Add, mkBin(std::vector<char>{1}), mkBin(std::vector<char>{2}));
  foldBin("*", TokenType::Mul, mkBin(std::vector<char>{1}), mkInt(3));
  foldBin("+", TokenType::Add, mkNull(), mkInt(5));
  foldBin("+", TokenType::Add, mkInt(5), mkNull());
  foldBin("+", TokenType::Add, mkNull(), mkNull());
  foldBin("-", TokenType::Sub, mkNull(), mkInt(5));
  foldBin("-", TokenType::Sub, mkInt(5), mkNull());
  foldBin("-", TokenType::Sub, mkNull(), mkNull());
  foldBin("*", TokenType::Mul, mkNull(), mkInt(5));
  foldBin("^", TokenType::Pow, mkNull(), mkInt(5));
  foldBin("==", TokenType::EQ, mkNull(), mkNull());
  foldBin("==", TokenType::EQ, mkNull(), mkInt(1));
  foldBin("!=", TokenType::NE, mkNull(), mkInt(1));
  foldBin("<", TokenType::LT, mkNull(), mkInt(1));
  foldBin("==", TokenType::EQ, mkBool(true), mkBool(true));
  foldBin("==", TokenType::EQ, mkBool(true), mkInt(1));
  foldBin("==", TokenType::EQ, mkInt(1), mkFloat(1.0));
  foldBin("==", TokenType::EQ, mkStr("a"), mkStr("a"));
  foldBin("<", TokenType::LT, mkInt(1), mkInt(2));
  foldBin("<", TokenType::LT, mkBool(true), mkInt(2));
  foldBin("<=", TokenType::LE, mkFloat(1.5), mkFloat(1.5));
  foldBin(">", TokenType::GT, mkInt(2), mkInt(1));
  foldBin(">=", TokenType::GE, mkInt(2), mkInt(2));
  foldBin("and", TokenType::And, mkInt(1), mkInt(0));
  foldBin("or", TokenType::Or, mkInt(0), mkStr("a"));
  foldUn("-", TokenType::Sub, mkBool(true));
  foldUn("-", TokenType::Sub, mkBool(false));
  foldUn("-", TokenType::Sub, mkInt(5));
  foldUn("-", TokenType::Sub, mkFloat(1.5));
  foldUn("-", TokenType::Sub, mkInt(-9223372036854775807LL - 1));
  foldUn("!", TokenType::Not, mkNull());
  foldUn("!", TokenType::Not, mkInt(0));
  foldUn("!", TokenType::Not, mkFloat(0.0));
  foldUn("!", TokenType::Not, mkInt(5));
  foldUn("!", TokenType::Not, mkStr(""));
  return 0;
}
