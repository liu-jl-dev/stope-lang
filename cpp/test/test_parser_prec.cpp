// parser 优先级与结合性用例（测试计划 §5.3，P-01…P-20）
// 覆盖：15 个二元运算符的优先级/结合性、一元与二元的相互作用。
//
// 【本文件整体关闭常量折叠】P 组靠整数字面量验证树形，一旦开启折叠，
// `1 + 2 * 3` 会直接变成 `Int(7)`，形状断言既会失败也失去验优先级的意义。
// 折叠后的期望由 test_parser_fold.cpp 单独锁定。
#include "test_common.hpp"

namespace Stope {
namespace Test {

void runPrecTests() {
  section("P 优先级与结合性 (P-PREC)");

  struct {
    const char* id;
    std::u16string src;
    const char* shape;
  } cases[] = {
      // P-01…P-05 优先级与左结合
      {"P-01", u"1 + 2 * 3;", "ExprStmt(Bin(Add, Int(1), Bin(Mul, Int(2), Int(3))))"},
      {"P-02", u"(1 + 2) * 3;", "ExprStmt(Bin(Mul, Bin(Add, Int(1), Int(2)), Int(3)))"},
      {"P-03", u"1 * 2 + 3;", "ExprStmt(Bin(Add, Bin(Mul, Int(1), Int(2)), Int(3)))"},
      {"P-04", u"1 - 2 - 3;", "ExprStmt(Bin(Sub, Bin(Sub, Int(1), Int(2)), Int(3)))"},
      {"P-05", u"8 / 4 / 2;", "ExprStmt(Bin(Div, Bin(Div, Int(8), Int(4)), Int(2)))"},
      // P-08/P-09 ^ 的优先级介于乘除与一元之间
      {"P-08", u"2 * 3 ^ 2;", "ExprStmt(Bin(Mul, Int(2), Bin(Pow, Int(3), Int(2))))"},
      {"P-09", u"3 ^ 2 * 2;", "ExprStmt(Bin(Mul, Bin(Pow, Int(3), Int(2)), Int(2)))"},
      // P-10…P-12 逻辑运算
      {"P-10", u"a and b or c;", "ExprStmt(Bin(Or, Bin(And, Ident(a), Ident(b)), Ident(c)))"},
      {"P-11", u"a or b and c;", "ExprStmt(Bin(Or, Ident(a), Bin(And, Ident(b), Ident(c))))"},
      {"P-12", u"a or b or c and d and e;",
       "ExprStmt(Bin(Or, Bin(Or, Ident(a), Ident(b)), Bin(And, Bin(And, Ident(c), Ident(d)), Ident(e))))"},
      // P-13…P-15 比较、整除/取模同级左结合
      {"P-13", u"1 == 2 != 3;", "ExprStmt(Bin(NE, Bin(EQ, Int(1), Int(2)), Int(3)))"},
      {"P-14", u"1 < 2 < 3;", "ExprStmt(Bin(LT, Bin(LT, Int(1), Int(2)), Int(3)))"},
      {"P-15", u"7 idiv 2 % 3;", "ExprStmt(Bin(Mod, Bin(IDiv, Int(7), Int(2)), Int(3)))"},
      // P-16/P-17 一元与二元
      {"P-16a", u"-a * b;", "ExprStmt(Bin(Mul, Unary(Sub, Ident(a)), Ident(b)))"},
      {"P-16b", u"-(a * b);", "ExprStmt(Unary(Sub, Bin(Mul, Ident(a), Ident(b))))"},
      {"P-17", u"not a and b;", "ExprStmt(Bin(And, Unary(Not, Ident(a)), Ident(b)))"},
  };
  for (const auto& c : cases) {
    auto r = parseAll(c.src, nullptr, false);
    EXPECT_PSTMT_SHAPE(r, 0, c.shape, c.id);
    EXPECT_PERR_COUNT(r, 0, c.id);
  }

  {  // P-06 ^ 左结合：项目已定夺左结合（2026-10-16），即规范行为，转普通断言。
    auto r = parseAll(u"2 ^ 3 ^ 2;", nullptr, false);
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Bin(Pow, Bin(Pow, Int(2), Int(3)), Int(2)))", "P-06");
    EXPECT_PERR_COUNT(r, 0, "P-06");
    auto r2 = parseAll(u"2 ^ 3 ^ 2 ^ 4;", nullptr, false);
    EXPECT_PSTMT_SHAPE(r2, 0,
                       "ExprStmt(Bin(Pow, Bin(Pow, Bin(Pow, Int(2), Int(3)), Int(2)), Int(4)))",
                       "P-06");
    EXPECT_PERR_COUNT(r2, 0, "P-06");
  }
  {  // P-07 -2 ^ 2：不是结合性问题，而是"一元 - 与 ^ 的优先级"待定（PD-18）
    auto r2 = parseAll(u"-2 ^ 2;", nullptr, false);
    EXPECT_PSTMT_SHAPE(r2, 0, "ExprStmt(Bin(Pow, Unary(Sub, Int(2)), Int(2)))", "P-07");
    KNOWN("PD-18",
          shapeStmt(r2.stmt(0)) == "ExprStmt(Unary(Sub, Bin(Pow, Int(2), Int(2))))",
          "P-07 -2^2 应为 -(2^2)（一元优先级待定）");
  }
  {  // P-18 条件表达式里优先级正常
    auto r = parseAll(u"if a + 1 > 2 { b; }", nullptr, false);
    EXPECT_PSTMT_SHAPE(r, 0, "If(Bin(GT, Bin(Add, Ident(a), Int(1)), Int(2))){ExprStmt(Ident(b))}",
                       "P-18");
    EXPECT_PERR_COUNT(r, 0, "P-18");
  }
  {  // P-19 15 个二元运算符逐个：都产生 BinaryOpExpr 且 op 字段正确
    struct { const char* op; std::u16string src; } ops[] = {
        {"Or", u"a or b;"},    {"And", u"a and b;"},   {"EQ", u"a == b;"},
        {"NE", u"a != b;"},    {"LT", u"a < b;"},      {"LE", u"a <= b;"},
        {"GT", u"a > b;"},     {"GE", u"a >= b;"},     {"Add", u"a + b;"},
        {"Sub", u"a - b;"},    {"Mul", u"a * b;"},     {"Div", u"a / b;"},
        {"IDiv", u"a idiv b;"}, {"Mod", u"a % b;"},    {"Pow", u"a ^ b;"},
    };
    for (const auto& o : ops) {
      auto r = parseAll(o.src, nullptr, false);
      std::string want = std::string("ExprStmt(Bin(") + o.op + ", Ident(a), Ident(b)))";
      EXPECT_PSTMT_SHAPE(r, 0, want.c_str(), "P-19");
      EXPECT_PERR_COUNT(r, 0, "P-19");
    }
  }
  {  // P-20 一元运算符逐个：- / ! / not
    struct { const char* op; std::u16string src; } ops[] = {
        {"Sub", u"-a;"}, {"Not", u"!a;"}, {"Not", u"not a;"},
    };
    for (const auto& o : ops) {
      auto r = parseAll(o.src, nullptr, false);
      std::string want = std::string("ExprStmt(Unary(") + o.op + ", Ident(a)))";
      EXPECT_PSTMT_SHAPE(r, 0, want.c_str(), "P-20");
      EXPECT_PERR_COUNT(r, 0, "P-20");
    }
  }
}

}  // namespace Test
}  // namespace Stope
