// 常量折叠用例（O-01…）：ExpressionOptimizer 已挂在 Parser::parseExpr 出口，
// 默认开启（Parser::constFolding = true）。本文件锁定「折叠后」的树形。
//
// 与之对应：P 组与 L-02 用 parseAll(..., nullptr, false) 关折叠，锁定「未折叠」树形。
// 行为矩阵与「一律不折叠」清单见 cpp/stope/expr-optim.md §4 / §5 / §8。
#include "test_common.hpp"

namespace Stope {
namespace Test {

void runFoldTests() {
  section("O 常量折叠 (O-FOLD)");

  struct {
    const char* id;
    std::u16string src;
    const char* shape;
  } cases[] = {
      // ---- 算术：自底向上，整棵子树折成一个字面量 ----
      {"O-01", u"1 + 2 * 3;", "ExprStmt(Int(7))"},
      {"O-02", u"(1 + 2) * 3;", "ExprStmt(Int(9))"},
      {"O-03", u"2 ^ 3 ^ 2;", "ExprStmt(Int(512))"},         // 右结合 + 折叠：2^(3^2)
      {"O-04", u"7 / 2;", "ExprStmt(Float(3.5))"},           // 不整除 → Float
      {"O-05", u"8 / 4 / 2;", "ExprStmt(Int(1))"},           // 整除保 Int
      {"O-06", u"7 idiv 2 % 3;", "ExprStmt(Int(0))"},
      {"O-07", u"7 % 2.5;", "ExprStmt(Float(2))"},
      {"O-08", u"-2 ^ 2;", "ExprStmt(Int(4))"},
      // ---- 比较：内层折掉，外层因跨类型停住（仍可见结合性）----
      {"O-09", u"1 == 2 != 3;", "ExprStmt(Bin(NE, Bool(false), Int(3)))"},
      {"O-10", u"1 < 2 < 3;", "ExprStmt(Bin(LT, Bool(true), Int(3)))"},
      // ---- 字符串 / 二进制数组（本项目自定规则，见 expr-optim.md §4.9）----
      {"O-11", u"\"ab\" + \"cd\";", "ExprStmt(Str(\"abcd\"))"},
      {"O-12", u"\"ab\" * 3;", "ExprStmt(Str(\"ababab\"))"},
      {"O-13", u"3 * \"ab\";", "ExprStmt(Str(\"ababab\"))"},  // 双向都支持
      {"O-14", u"'x 41' + 'x 42';", "ExprStmt(BinArr[41,42])"},  // 字节连接
      {"O-15", u"'x 41' * 3;", "ExprStmt(BinArr[41,41,41])"},
      {"O-16", u"\"ab\" * 0;", "ExprStmt(Str(\"\"))"},
      // ---- Bool 在算术上下文里当 0 / 1 ----
      {"O-17", u"true + 1;", "ExprStmt(Int(2))"},
      {"O-18", u"true * 2.5;", "ExprStmt(Float(2.5))"},
      {"O-19", u"-true;", "ExprStmt(Int(-1))"},
      {"O-20", u"not true;", "ExprStmt(Bool(false))"},
      {"O-21", u"true == 1;", "ExprStmt(Bin(EQ, Bool(true), Int(1)))"},  // 不折
      // ---- null：不参与算术（交给后端报错），只有 == / != 有结论 ----
      {"O-22", u"null + 5;", "ExprStmt(Bin(Add, Null, Int(5)))"},
      {"O-23", u"null == null;", "ExprStmt(Bool(true))"},
      {"O-24", u"null * 5;", "ExprStmt(Bin(Mul, Null, Int(5)))"},
      {"O-24b", u"null - 5;", "ExprStmt(Bin(Sub, Null, Int(5)))"},
      {"O-24c", u"null != 5;", "ExprStmt(Bool(true))"},
      // ---- 一律不折叠的边界（expr-optim.md §5 / §6）----
      {"O-25", u"1 / 0;", "ExprStmt(Bin(Div, Int(1), Int(0)))"},
      // 整数溢出**不检查**：按 64 位补码回绕，仍然折叠（与参考实现一致）
      {"O-26", u"9223372036854775807 + 1;", "ExprStmt(Int(-9223372036854775808))"},
      {"O-27", u"1 idiv 2.0;", "ExprStmt(Bin(IDiv, Int(1), Float(2)))"},
      {"O-28", u"\"ab\" * -1;", "ExprStmt(Bin(Mul, Str(\"ab\"), Int(-1)))"},
      {"O-29", u"0 ^ -1;", "ExprStmt(Bin(Pow, Int(0), Int(-1)))"},  // 得 inf → 不折
      {"O-29c", u"2 ^ (0 - 1);", "ExprStmt(Float(0.5))"},  // 负指数 → 浮点
      {"O-29b", u"\"ab\" * 2.5;", "ExprStmt(Bin(Mul, Str(\"ab\"), Float(2.5)))"},  // 次数非整数
      // ---- 副作用保护：任一侧不是字面量就不折 ----
      {"O-30", u"x + 1;", "ExprStmt(Bin(Add, Ident(x), Int(1)))"},
      {"O-31", u"false and f();", "ExprStmt(Bin(And, Bool(false), Call(Ident(f))))"},
      {"O-32", u"a[1 + 2];", "ExprStmt(At(Ident(a); Int(3)))"},
      {"O-33", u"args[1 + 2];", "ExprStmt(Args(Int(3)))"},
  };
  for (const auto& c : cases) {
    auto r = parseAll(c.src);
    EXPECT_PSTMT_SHAPE(r, 0, c.shape, c.id);
    EXPECT_PERR_COUNT(r, 0, c.id);
  }

  // O-34 折叠节点的 line 沿用运算符节点的 line（= 左操作数的行）
  {
    auto r = parseAll(u"1 +\n2;");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Int(3))", "O-34");
    EXPECT_PLINE(r, 0, 1, "O-34");  // 语句行号不变（ExprStmt.line = 左操作数行）
    EXPECT_PERR_COUNT(r, 0, "O-34");
  }

  // O-35 折叠与不折叠：同一输入两种形态都要成立
  {
    auto on = parseAll(u"1 + 2 * 3;", nullptr, true);
    auto off = parseAll(u"1 + 2 * 3;", nullptr, false);
    EXPECT_PSTMT_SHAPE(on, 0, "ExprStmt(Int(7))", "O-35");
    EXPECT_PSTMT_SHAPE(off, 0, "ExprStmt(Bin(Add, Int(1), Bin(Mul, Int(2), Int(3))))", "O-35");
  }

  // O-36 折叠开关不影响错误计数
  {
    auto on = parseAll(u"1 + ;", nullptr, true);
    auto off = parseAll(u"1 + ;", nullptr, false);
    EXPECT(on.errors.size() == off.errors.size(), "O-36");
  }
}

}  // namespace Test
}  // namespace Stope
