// parser 表达式与字面量用例（测试计划 §5.2，X-01…X-13）
// 覆盖：Int/Float/Str/BinArr/Null/Bool/Argc/Ident/一元/括号/args。
#include "test_common.hpp"

namespace Stope {
namespace Test {

void runExprTests() {
  section("X 表达式与字面量 (P-EXPR)");

  {  // X-01 各字面量都产生 ExprStmt，节点类型正确
    auto r = parseAll(u"1; 1.5; \"s\"; 'x ff'; null; true; false; argc; a;");
    EXPECT_PSTMTS(r, 9, "X-01");
    EXPECT_PEXPR(r, 0, AST::NodeType::IntExpr, "X-01");
    EXPECT_PEXPR(r, 1, AST::NodeType::FloatExpr, "X-01");
    EXPECT_PEXPR(r, 2, AST::NodeType::StringExpr, "X-01");
    EXPECT_PEXPR(r, 3, AST::NodeType::BinArrExpr, "X-01");
    EXPECT_PEXPR(r, 4, AST::NodeType::NullExpr, "X-01");
    EXPECT_PEXPR(r, 5, AST::NodeType::BoolExpr, "X-01");
    EXPECT_PEXPR(r, 6, AST::NodeType::BoolExpr, "X-01");
    EXPECT_PEXPR(r, 7, AST::NodeType::ArgcExpr, "X-01");
    EXPECT_PEXPR(r, 8, AST::NodeType::IdentExpr, "X-01");
    EXPECT_PERR_COUNT(r, 0, "X-01");
  }
  {  // X-02 十六进制二进制数组：每空白分隔段一个字节
    auto r = parseAll(u"'x ff 0a';");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(BinArr[ff,0a])", "X-02");
    EXPECT_PERR_COUNT(r, 0, "X-02");
  }
  {  // X-03 二进制数组
    auto r = parseAll(u"'b 1010 1111';");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(BinArr[0a,0f])", "X-03");
    EXPECT_PERR_COUNT(r, 0, "X-03");
  }
  {  // X-04 空二进制数组合法
    auto r = parseAll(u"'';");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(BinArr[])", "X-04");
    EXPECT_PERR_COUNT(r, 0, "X-04");
  }
  {  // X-05 非法二进制数组：报 invalid binary array.（parse_binarr.hpp 的回归）
    auto r = parseAll(u"'x zz';");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(BinArr[])", "X-05");
    EXPECT_PERR_HAS(r, "invalid binary array. ", "X-05");
    auto r2 = parseAll(u"'b _';");
    EXPECT_PSTMT_SHAPE(r2, 0, "ExprStmt(BinArr[])", "X-05");
    EXPECT_PERR_HAS(r2, "invalid binary array. ", "X-05");
  }
  {  // X-06 字符串转义在 lexer 层解码，value 含真实换行
    auto r = parseAll(u"\"a\\nb\";");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Str(\"a\\nb\"))", "X-06");
    EXPECT_PERR_COUNT(r, 0, "X-06");
    auto* s = static_cast<const AST::ExprStmt*>(r.stmt(0));
    EXPECT(s->expr && static_cast<const AST::StringExpr*>(s->expr.get())->value ==
                         std::u16string(u"a\nb"),
           "X-06");
  }
  {  // X-07 负号是一元运算符
    auto r = parseAll(u"let x = -a;");
    EXPECT_PSTMT_SHAPE(r, 0, "Let[x]=Unary(Sub, Ident(a))", "X-07");
    EXPECT_PERR_COUNT(r, 0, "X-07");
  }
  {  // X-08 not / ! 都是 Not
    auto r = parseAll(u"not a;");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Unary(Not, Ident(a)))", "X-08");
    auto r2 = parseAll(u"!a;");
    EXPECT_PSTMT_SHAPE(r2, 0, "ExprStmt(Unary(Not, Ident(a)))", "X-08");
    EXPECT_PERR_COUNT(r, 0, "X-08");
    EXPECT_PERR_COUNT(r2, 0, "X-08");
  }
  {  // X-09 一元可叠层
    auto r = parseAll(u"- - a;");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Unary(Sub, Unary(Sub, Ident(a))))", "X-09");
    auto r2 = parseAll(u"not not a;");
    EXPECT_PSTMT_SHAPE(r2, 0, "ExprStmt(Unary(Not, Unary(Not, Ident(a))))", "X-09");
    EXPECT_PERR_COUNT(r, 0, "X-09");
    EXPECT_PERR_COUNT(r2, 0, "X-09");
  }
  {  // X-10 argc / args[0]
    auto r = parseAll(u"argc;");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Argc)", "X-10");
    EXPECT_PERR_COUNT(r, 0, "X-10");
    auto r2 = parseAll(u"args[0];");
    EXPECT_PSTMT_SHAPE(r2, 0, "ExprStmt(Args(Int(0)))", "X-10");
    EXPECT_PERR_COUNT(r2, 0, "X-10");
  }
  {  // X-11 args 的键是完整表达式
    auto r = parseAll(u"args[a + 1];");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Args(Bin(Add, Ident(a), Int(1))))", "X-11");
    EXPECT_PERR_COUNT(r, 0, "X-11");
  }
  {  // X-12 args 0; 缺 [：keyExpr 为 null，0; 保留为下一条语句（PD-4c 已修 2026-10-16）
    auto r = parseAll(u"args 0;");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Args(null))", "X-12");
    EXPECT_PERR_HAS(r, "expected \"[\" after \"args\". ", "X-12");
    EXPECT_PSTMTS(r, 2, "X-12");
    EXPECT_PSTMT_SHAPE(r, 1, "ExprStmt(Int(0))", "X-12");
  }
  {  // X-13 args[0; 缺 ]
    auto r = parseAll(u"args[0;");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Args(Int(0)))", "X-13");
    EXPECT_PERR_HAS(r, "expected \"]\". ", "X-13");
  }
}

}  // namespace Test
}  // namespace Stope
