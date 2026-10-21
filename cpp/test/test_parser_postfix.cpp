// parser 后缀与前缀用例（测试计划 §5.4，F-01…F-18）
// 覆盖：Call / At / 括号，以及"缺右括号不吞 token"的项目约定。
#include "test_common.hpp"

namespace Stope {
namespace Test {

void runPostfixTests() {
  section("F 后缀与前缀：调用/索引/括号 (P-POST)");

  {  // F-01 空参数表合法
    auto r = parseAll(u"f();");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Call(Ident(f)))", "F-01");
    EXPECT_PERR_COUNT(r, 0, "F-01");
  }
  {  // F-02 参数个数
    auto r = parseAll(u"f(1);");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Call(Ident(f); Int(1)))", "F-02");
    EXPECT_PERR_COUNT(r, 0, "F-02");
    auto r2 = parseAll(u"f(1, 2, 3);");
    EXPECT_PSTMT_SHAPE(r2, 0, "ExprStmt(Call(Ident(f); Int(1); Int(2); Int(3)))", "F-02");
    EXPECT_PERR_COUNT(r2, 0, "F-02");
  }
  {  // F-03 参数是完整表达式
    auto r = parseAll(u"f(a + 1, b * 2);");
    EXPECT_PSTMT_SHAPE(r, 0,
                       "ExprStmt(Call(Ident(f); Bin(Add, Ident(a), Int(1)); Bin(Mul, Ident(b), Int(2))))",
                       "F-03");
    EXPECT_PERR_COUNT(r, 0, "F-03");
  }
  {  // F-04 嵌套 Call
    auto r = parseAll(u"f(g(1), h(2));");
    EXPECT_PSTMT_SHAPE(r, 0,
                       "ExprStmt(Call(Ident(f); Call(Ident(g); Int(1)); Call(Ident(h); Int(2))))",
                       "F-04");
    EXPECT_PERR_COUNT(r, 0, "F-04");
  }
  {  // F-05 调用结果再调用
    auto r = parseAll(u"f()();");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Call(Call(Ident(f))))", "F-05");
    EXPECT_PERR_COUNT(r, 0, "F-05");
  }
  {  // F-06 链式后缀左结合
    auto r = parseAll(u"f(a)(b)[c];");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(At(Call(Call(Ident(f); Ident(a)); Ident(b)); Ident(c)))", "F-06");
    EXPECT_PERR_COUNT(r, 0, "F-06");
  }
  {  // F-07 空索引合法
    auto r = parseAll(u"a[];");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(At(Ident(a)))", "F-07");
    EXPECT_PERR_COUNT(r, 0, "F-07");
  }
  {  // F-08 索引个数
    auto r = parseAll(u"a[1];");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(At(Ident(a); Int(1)))", "F-08");
    EXPECT_PERR_COUNT(r, 0, "F-08");
    auto r2 = parseAll(u"a[1, 2];");
    EXPECT_PSTMT_SHAPE(r2, 0, "ExprStmt(At(Ident(a); Int(1); Int(2)))", "F-08");
    EXPECT_PERR_COUNT(r2, 0, "F-08");
  }
  {  // F-09 嵌套/链式 At
    auto r = parseAll(u"a[b[1]];");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(At(Ident(a); At(Ident(b); Int(1))))", "F-09");
    EXPECT_PERR_COUNT(r, 0, "F-09");
    auto r2 = parseAll(u"a[1][2];");
    EXPECT_PSTMT_SHAPE(r2, 0, "ExprStmt(At(At(Ident(a); Int(1)); Int(2)))", "F-09");
    EXPECT_PERR_COUNT(r2, 0, "F-09");
    auto r3 = parseAll(u"f(1)[2];");
    EXPECT_PSTMT_SHAPE(r3, 0, "ExprStmt(At(Call(Ident(f); Int(1)); Int(2)))", "F-09");
    EXPECT_PERR_COUNT(r3, 0, "F-09");
  }
  {  // F-10 后缀优先级高于一元
    auto r = parseAll(u"-f(1);");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Unary(Sub, Call(Ident(f); Int(1))))", "F-10");
    EXPECT_PERR_COUNT(r, 0, "F-10");
    auto r2 = parseAll(u"- a[1];");
    EXPECT_PSTMT_SHAPE(r2, 0, "ExprStmt(Unary(Sub, At(Ident(a); Int(1))))", "F-10");
    EXPECT_PERR_COUNT(r2, 0, "F-10");
  }
  {  // F-11 括号不产生节点
    auto r = parseAll(u"(1);");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Int(1))", "F-11");
    EXPECT_PERR_COUNT(r, 0, "F-11");
    auto r2 = parseAll(u"((2));");
    EXPECT_PSTMT_SHAPE(r2, 0, "ExprStmt(Int(2))", "F-11");
    EXPECT_PERR_COUNT(r2, 0, "F-11");
  }
  {  // F-12 (1; 缺 )：报错但不吞 ;（约定 1）
    auto r = parseAll(u"(1;");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Int(1))", "F-12");
    EXPECT_PERR_COUNT(r, 2, "F-12");  // 缺 ) + 缺 ;
    EXPECT_PERR_HAS(r, "expected \")\". ", "F-12");
  }
  {  // F-13 f(1; 缺 )
    auto r = parseAll(u"f(1;");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Call(Ident(f); Int(1)))", "F-13");
    EXPECT_PERR_COUNT(r, 1, "F-13");
    EXPECT_PERR_HAS(r, "expected \")\". ", "F-13");
  }
  {  // F-14 a[1; 缺 ]
    auto r = parseAll(u"a[1;");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(At(Ident(a); Int(1)))", "F-14");
    EXPECT_PERR_COUNT(r, 1, "F-14");
    EXPECT_PERR_HAS(r, "expected \"]\". ", "F-14");
  }
  {  // F-15/F-16 参数表中途坏掉：x; 保留为独立语句（PD-4d 已修 2026-10-16）
    auto r = parseAll(u"f(1, 2 x; y;");
    EXPECT_PERR_HAS(r, "expected \")\". ", "F-15");
    EXPECT_PSTMTS(r, 3, "F-15");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Call(Ident(f); Int(1); Int(2)))", "F-15");
    EXPECT_PSTMT_SHAPE(r, 1, "ExprStmt(Ident(x))", "F-15");
    EXPECT_PSTMT_SHAPE(r, 2, "ExprStmt(Ident(y))", "F-15");
    auto r2 = parseAll(u"a[1, 2 x; y;");
    EXPECT_PERR_HAS(r2, "expected \"]\". ", "F-16");
    EXPECT_PSTMTS(r2, 3, "F-16");
    EXPECT_PSTMT_SHAPE(r2, 0, "ExprStmt(At(Ident(a); Int(1); Int(2)))", "F-16");
    EXPECT_PSTMT_SHAPE(r2, 1, "ExprStmt(Ident(x))", "F-16");
    EXPECT_PSTMT_SHAPE(r2, 2, "ExprStmt(Ident(y))", "F-16");
  }
  {  // F-17 (); 空括号：裸 Expr + 3 errors。
    // PD-11 已修（2026-10-16）：失败节点的 line 取自当前 token，不再恒为 -1，
    // 因此 ExprStmt.line 也不再被传染。剩下的 PD-8 是"失败处不该返回裸 Expr"。
    auto r = parseAll(u"();");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Err(L1))", "F-17");
    EXPECT_PERR_COUNT(r, 3, "F-17");  // 无前缀解析函数 + 缺 ) + 缺 ;
    EXPECT_PLINE(r, 0, 1, "F-17");  // PD-11：语句 line 正常
  }
  {  // F-18 右操作数缺失：树上出现裸 Expr 节点（PD-8 未修）。
    // 用整树形状里是否含 "Err(" 来判断，比逐语句找 ExprStmt 更可靠
    // （Err 可能出现在 LetStmt.expr、Call.args、At.keyExprs 等位置）。
    const char* ids[] = {"F-18a", "F-18b", "F-18c", "F-18d", "F-18e", "F-18f"};
    std::u16string srcs[] = {u"let a = 1 +", u"f(1,", u"a[1,", u"(1 +", u"args[", u"a = ;"};
    // 去重移除后同一行的级联错误都会上报：无前缀解析函数 + 缺 )/] + 缺 ;
    const int errs[] = {1, 3, 3, 3, 3, 2};
    for (int i = 0; i < 6; ++i) {
      auto r = parseAll(srcs[i]);
      EXPECT_PERR_COUNT(r, errs[i], ids[i]);
      bool hasErrNode = shapeProg(r.prog).find("Err(") != std::string::npos;
      EXPECT(hasErrNode, ids[i]);
      KNOWN("PD-8", !hasErrNode, ids[i]);
    }
  }
}

}  // namespace Test
}  // namespace Stope
