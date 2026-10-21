// parser 自定义指令用例（测试计划 §5.5，K-01…K-12）
// PD-3 已修（2026-10-16）：customOpcodeConfig 由 Parser 构造函数传入，
//       构造体内的两次 nextToken() 已能拿到 config，故"位于输入最开头"的自定义指令
//       同样识别为 Custom（K-04/K-05/K-06/K-07/K-09 的开头用例）。
#include "test_common.hpp"

namespace Stope {
namespace Test {

// 注册两个自定义指令：myop（定长 2 参）与 a:b（命名空间形式，变长参数）
inline CustomOpcodeConfig* testConfig() {
  static CustomOpcodeConfig cfg;
  static bool init = [] {
    std::u16string myop = u"myop", ns = u"a:b";
    cfg.addCustomOpcode(myop, 1, 2);
    cfg.addCustomOpcode(ns, 2, -1);
    return true;
  }();
  (void)init;
  return &cfg;
}

void runCustomTests() {
  section("K 自定义指令 (P-CUSTOM)");
  CustomOpcodeConfig* cfg = testConfig();

  {  // K-01 x; myop(1, 2); → Custom(myop; Int(1); Int(2))，0 errors
    // （PD-1 SIGILL / PD-2 args 丢失均已于 2026-10-16 修复，此处为回归保护）
    auto r = parseAll(u"x; myop(1, 2);", cfg);
    EXPECT_PSTMTS(r, 2, "K-01");
    EXPECT_PSTMT_SHAPE(r, 1, "ExprStmt(Custom(myop; Int(1); Int(2)))", "K-01");
    EXPECT_PERR_COUNT(r, 0, "K-01");
  }
  {  // K-02 let x = myop(1, 2);
    auto r = parseAll(u"let x = myop(1, 2);", cfg);
    EXPECT_PSTMT_SHAPE(r, 0, "Let[x]=Custom(myop; Int(1); Int(2))", "K-02");
    EXPECT_PERR_COUNT(r, 0, "K-02");
  }
  {  // K-03 自定义指令作参数
    auto r = parseAll(u"f(myop(1,2));", cfg);
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Call(Ident(f); Custom(myop; Int(1); Int(2))))", "K-03");
    EXPECT_PERR_COUNT(r, 0, "K-03");
  }
  {  // K-04 myop 位于输入最开头：config 已由构造函数传入，识别为 Custom
    // （PD-3 已修 2026-10-16：原先 config 只能在构造后设置，前两个 token 拿不到）
    auto r = parseAll(u"myop(1, 2);", cfg);
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Custom(myop; Int(1); Int(2)))", "K-04");
    EXPECT_PERR_COUNT(r, 0, "K-04");
  }
  {  // K-05 第 2 个 token（`;myop`）同样能识别为 Custom（PD-3 已修）
    auto r = parseAll(u";myop(1);", cfg);
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Custom(myop; Int(1)))", "K-05");
    EXPECT_PERR_COUNT(r, 0, "K-05");
  }
  {  // K-06 myop(1; 缺 )（开头与 x; 之后都走 Custom 路径，PD-3 已修）
    auto r = parseAll(u"myop(1;", cfg);
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Custom(myop; Int(1)))", "K-06");
    EXPECT_PERR_HAS(r, "expected \")\". ", "K-06");
    // 同一输入放在 x; 之后 → 同样 Custom 路径
    auto r2 = parseAll(u"x; myop(1;", cfg);
    EXPECT_PSTMT_SHAPE(r2, 1, "ExprStmt(Custom(myop; Int(1)))", "K-06");
    EXPECT_PERR_HAS(r2, "expected \")\". ", "K-06");
  }
  {  // K-07 myop 1; 缺 (（开头与 x; 之后都走 Custom 路径，PD-3 已修）
    auto r = parseAll(u"myop 1;", cfg);
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Custom(myop))", "K-07");
    EXPECT_PERR_HAS(r, "expected \"(\" after custom opcode. ", "K-07");
    // 同一输入放在 x; 之后 → Custom 路径报同样的 expected "("
    auto r2 = parseAll(u"x; myop 1;", cfg);
    EXPECT_PSTMT_SHAPE(r2, 1, "ExprStmt(Custom(myop))", "K-07");
    EXPECT_PERR_HAS(r2, "expected \"(\" after custom opcode. ", "K-07");
  }
  {  // K-08 未注册的标识符就是普通 Call
    auto r = parseAll(u"other(1);", cfg);
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Call(Ident(other); Int(1)))", "K-08");
    EXPECT_PERR_COUNT(r, 0, "K-08");
  }
  {  // K-09 命名空间自定义指令：a:b(1)（开头亦识别为 Custom，PD-3 已修）
    auto r = parseAll(u"a:b(1);", cfg);
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Custom(a:b; Int(1)))", "K-09");
    EXPECT_PERR_COUNT(r, 0, "K-09");
    auto r2 = parseAll(u"x; a:b(1);", cfg);
    EXPECT_PSTMT_SHAPE(r2, 1, "ExprStmt(Custom(a:b; Int(1)))", "K-09");
    EXPECT_PERR_COUNT(r2, 0, "K-09");
  }
  {  // K-10 config 为 nullptr：全部走 Ident 路径
    auto r = parseAll(u"myop(1, 2);", nullptr);
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Call(Ident(myop); Int(1); Int(2)))", "K-10");
    EXPECT_PERR_COUNT(r, 0, "K-10");
  }
  {  // K-11 x; myop(); 空参数表：文法允许 ( expr ("," expr)* )?，应 0 errors。
    // PD-17 已修（2026-10-16）：原空参数分支多走一次 nextToken()，越过 ")" 导致语句层误报。
    auto r = parseAll(u"x; myop();", cfg);
    EXPECT_PSTMT_SHAPE(r, 1, "ExprStmt(Custom(myop))", "K-11");
    EXPECT_PERR_COUNT(r, 0, "K-11");
    // 对照组：普通函数调用的空参数表是好的
    auto r2 = parseAll(u"x; f();", cfg);
    EXPECT_PSTMT_SHAPE(r2, 1, "ExprStmt(Call(Ident(f)))", "K-11");
    EXPECT_PERR_COUNT(r2, 0, "K-11");
  }
  {  // 附加：自定义指令的其它位置（均为 OK，防止将来改坏）
    auto r = parseAll(u"x; myop(1, 2, 3);", cfg);  // parser 不校验参数个数
    EXPECT_PSTMT_SHAPE(r, 1, "ExprStmt(Custom(myop; Int(1); Int(2); Int(3)))", "K-12");
    EXPECT_PERR_COUNT(r, 0, "K-12");
    auto r2 = parseAll(u"a; if myop(1) { b; }", cfg);  // if 条件里的 custom（PD-3 已修，无需躲开头）
    EXPECT_PSTMTS(r2, 2, "K-12");
    EXPECT_PSTMT_SHAPE(r2, 1, "If(Custom(myop; Int(1))){ExprStmt(Ident(b))}", "K-12");
    EXPECT_PERR_COUNT(r2, 0, "K-12");
    auto r3 = parseAll(u"x; myop(1)(2);", cfg);  // custom 的结果还能再调用
    EXPECT_PSTMT_SHAPE(r3, 1, "ExprStmt(Call(Custom(myop; Int(1)); Int(2)))", "K-12");
    EXPECT_PERR_COUNT(r3, 0, "K-12");
    auto r4 = parseAll(u"x; a[myop(1)];", cfg);
    EXPECT_PSTMT_SHAPE(r4, 1, "ExprStmt(At(Ident(a); Custom(myop; Int(1))))", "K-12");
    EXPECT_PERR_COUNT(r4, 0, "K-12");
  }
}

}  // namespace Test
}  // namespace Stope
