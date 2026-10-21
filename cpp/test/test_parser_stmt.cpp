// parser 语句层用例（测试计划 §5.1，S-01…S-45）
// 覆盖：let / export / return / block / if / while / break / continue /
//       表达式语句 / 赋值语句 + 空语句，共 11 类语句节点。
#include "test_common.hpp"

namespace Stope {
namespace Test {

void runStmtTests() {
  section("S 语句层 (P-STMT)");

  // ---- S-01/S-02 空程序与空语句 ----
  {
    auto r = parseAll(u"");
    EXPECT_PSTMTS(r, 0, "S-01");
    EXPECT_PERR_COUNT(r, 0, "S-01");
  }
  {
    auto r = parseAll(u";;;");
    EXPECT_PSTMTS(r, 0, "S-02");
    EXPECT_PERR_COUNT(r, 0, "S-02");
  }

  // ---- S-03…S-10 let ----
  {
    auto r = parseAll(u"let a;");
    EXPECT_PSTMT_SHAPE(r, 0, "Let[a]", "S-03");
    EXPECT_PERR_COUNT(r, 0, "S-03");
  }
  {
    auto r = parseAll(u"let a = 1;");
    EXPECT_PSTMT_SHAPE(r, 0, "Let[a]=Int(1)", "S-04");
    EXPECT_PERR_COUNT(r, 0, "S-04");
  }
  {
    auto r = parseAll(u"let a, b, c;");
    EXPECT_PSTMT_SHAPE(r, 0, "Let[a,b,c]", "S-05");
    EXPECT_PERR_COUNT(r, 0, "S-05");
  }
  {  // S-06 多标识符禁止赋值：idents 收下 a,b，= 1 报错丢弃（PD-4 同族）
    auto r = parseAll(u"let a, b = 1;");
    EXPECT_PSTMT_SHAPE(r, 0, "Let[a,b]", "S-06");
    EXPECT_PERR_COUNT(r, 2, "S-06");  // 去重移除后：= 与 1 各报一次
    EXPECT_PERR_HAS(r, "failed to parse let statement with multiple identifiers. ", "S-06");
  }
  {
    auto r = parseAll(u"let 1;");
    EXPECT_PSTMT_SHAPE(r, 0, "Let[]", "S-07");
    EXPECT_PERR_HAS(r, "expected identifier after \"let\". ", "S-07");
  }
  {  // S-08 let 后直接 EOF：不得挂死（2026-10-15 修复的回归保护）
    auto r = parseAll(u"let");
    EXPECT_PSTMT_SHAPE(r, 0, "Let[]", "S-08");
    EXPECT_PERR_HAS(r, "expected identifier after \"let\". ", "S-08");
  }
  {  // S-09 多标识符缺 ;：报错且不推进 Eof/RBrace（约定 1）
    auto r = parseAll(u"let a, b");
    EXPECT_PSTMT_SHAPE(r, 0, "Let[a,b]", "S-09");
    EXPECT_PERR_HAS(r, "expected \";\" in let statement. ", "S-09");
  }
  {  // S-10 块内缺 ; 不得吞掉 } 与后续语句
    auto r = parseAll(u"{ let a, b } x;");
    EXPECT_PSTMTS(r, 2, "S-10");
    EXPECT_PSTMT_SHAPE(r, 0, "Block{Let[a,b]}", "S-10");
    EXPECT_PSTMT_SHAPE(r, 1, "ExprStmt(Ident(x))", "S-10");
    EXPECT_PERR_HAS(r, "expected \";\" in let statement. ", "S-10");
  }

  // ---- S-11…S-13 export ----
  {
    auto r = parseAll(u"export a;");
    EXPECT_PSTMT_SHAPE(r, 0, "Export[a]", "S-11");
    EXPECT_PERR_COUNT(r, 0, "S-11");
  }
  {
    auto r = parseAll(u"export a, b;");
    EXPECT_PSTMT_SHAPE(r, 0, "Export[a,b]", "S-11");
    EXPECT_PERR_COUNT(r, 0, "S-11");
  }
  {  // S-12 export 不支持赋值：= 1 变成独立表达式语句 + 1 error
    auto r = parseAll(u"export a = 1;");
    EXPECT_PSTMTS(r, 2, "S-12");
    EXPECT_PSTMT_SHAPE(r, 0, "Export[a]", "S-12");
    EXPECT_PSTMT_SHAPE(r, 1, "ExprStmt(Int(1))", "S-12");
    EXPECT_PERR_COUNT(r, 1, "S-12");
  }
  {
    auto r = parseAll(u"export ;");
    EXPECT_PSTMT_SHAPE(r, 0, "Export[]", "S-13");
    EXPECT_PERR_HAS(r, "expected identifier after \"export\". ", "S-13");
  }
  {
    auto r = parseAll(u"export");
    EXPECT_PSTMT_SHAPE(r, 0, "Export[]", "S-13");
    EXPECT_PERR_HAS(r, "expected identifier after \"export\". ", "S-13");
  }

  // ---- S-14…S-18 return ----
  {
    auto r = parseAll(u"return;");
    EXPECT_PSTMT_SHAPE(r, 0, "Return()", "S-14");
    EXPECT_PERR_COUNT(r, 0, "S-14");
  }
  {
    auto r = parseAll(u"return 1;");
    EXPECT_PSTMT_SHAPE(r, 0, "Return(Int(1))", "S-15");
    EXPECT_PERR_COUNT(r, 0, "S-15");
  }
  {
    auto r = parseAll(u"return 1, 2, 3;");
    EXPECT_PSTMT_SHAPE(r, 0, "Return(Int(1), Int(2), Int(3))", "S-15");
    EXPECT_PERR_COUNT(r, 0, "S-15");
  }
  {  // S-16 return 后 EOF：exprs 为空 + 报错，不挂死
    auto r = parseAll(u"return");
    EXPECT_PSTMT_SHAPE(r, 0, "Return()", "S-16");
    EXPECT_PERR_HAS(r, "expected \";\" in return statement. ", "S-16");
  }
  {  // S-17 return x; y; 是两条合法语句（return 带值是合法的）
    auto r = parseAll(u"return x; y;");
    EXPECT_PSTMTS(r, 2, "S-17");
    EXPECT_PERR_COUNT(r, 0, "S-17");
  }
  {  // S-18 return 1 2; 缺 ,/;，2 被吞（PD-4 同族）
    auto r = parseAll(u"return 1 2;");
    EXPECT_PSTMTS(r, 1, "S-18");
    EXPECT_PSTMT_SHAPE(r, 0, "Return(Int(1))", "S-18");
    EXPECT_PERR_HAS(r, "expected \";\" or \",\" in return statement. ", "S-18");
  }

  // ---- S-19…S-21 block ----
  {
    auto r = parseAll(u"{ a; b; }");
    EXPECT_PSTMT_SHAPE(r, 0, "Block{ExprStmt(Ident(a)) ; ExprStmt(Ident(b))}", "S-19");
    EXPECT_PERR_COUNT(r, 0, "S-19");
  }
  {
    auto r = parseAll(u"{}");
    EXPECT_PSTMT_SHAPE(r, 0, "Block{}", "S-19");
    EXPECT_PERR_COUNT(r, 0, "S-19");
  }
  {
    auto r = parseAll(u"{ { a; } b; }");
    EXPECT_PSTMT_SHAPE(r, 0, "Block{Block{ExprStmt(Ident(a))} ; ExprStmt(Ident(b))}", "S-19");
    EXPECT_PERR_COUNT(r, 0, "S-19");
  }
  {
    auto r = parseAll(u"{ a;");
    EXPECT_PERR_HAS(r, "expected \"}\" at end of block statement. ", "S-20");
  }
  {
    auto r = parseAll(u"{ a; x;");
    EXPECT_PSTMT_SHAPE(r, 0, "Block{ExprStmt(Ident(a)) ; ExprStmt(Ident(x))}", "S-20");
    EXPECT_PERR_HAS(r, "expected \"}\" at end of block statement. ", "S-20");
  }
  {  // S-21 顶层孤立 }：报错、跳过、后续语句保留（PD-6 已修 2026-10-16）
    auto r = parseAll(u"} x;");
    EXPECT_PSTMTS(r, 1, "S-21");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Ident(x))", "S-21");
    EXPECT_PERR_COUNT(r, 1, "S-21");
    EXPECT_PERR_HAS(r, "unexpected \"}\" at top level. ", "S-21");

    auto r2 = parseAll(u"a; } b;");
    EXPECT_PSTMTS(r2, 2, "S-21");
    EXPECT_PSTMT_SHAPE(r2, 0, "ExprStmt(Ident(a))", "S-21");
    EXPECT_PSTMT_SHAPE(r2, 1, "ExprStmt(Ident(b))", "S-21");
    EXPECT_PERR_COUNT(r2, 1, "S-21");
    EXPECT_PERR_HAS(r2, "unexpected \"}\" at top level. ", "S-21");

    // 多个孤立 } 逐个报错（每个 } 一条，不再按行去重）
    auto r3 = parseAll(u"} } x;");
    EXPECT_PSTMTS(r3, 1, "S-21");
    EXPECT_PERR_COUNT(r3, 2, "S-21");

    // 对照组：块内的 } 仍由块自己消费，不能报顶层错误
    auto r4 = parseAll(u"{ a; } b;");
    EXPECT_PSTMTS(r4, 2, "S-21");
    EXPECT_PSTMT_SHAPE(r4, 0, "Block{ExprStmt(Ident(a))}", "S-21");
    EXPECT_PSTMT_SHAPE(r4, 1, "ExprStmt(Ident(b))", "S-21");
    EXPECT_PERR_COUNT(r4, 0, "S-21");
  }

  // ---- S-22…S-29 if ----
  {
    auto r = parseAll(u"if a { b; }");
    EXPECT_PSTMT_SHAPE(r, 0, "If(Ident(a)){ExprStmt(Ident(b))}", "S-22");
    EXPECT_PERR_COUNT(r, 0, "S-22");
  }
  {
    auto r = parseAll(u"if a { b; } elif c { d; } else { e; }");
    EXPECT_PSTMT_SHAPE(
        r, 0,
        "If(Ident(a)){ExprStmt(Ident(b))}Elif(Ident(c)){ExprStmt(Ident(d))}Else{ExprStmt(Ident(e))}",
        "S-23");
    EXPECT_PERR_COUNT(r, 0, "S-23");
  }
  {
    auto r = parseAll(u"if a { b; } elif c { d; } elif e { f; }");
    EXPECT_PSTMT_SHAPE(
        r, 0,
        "If(Ident(a)){ExprStmt(Ident(b))}Elif(Ident(c)){ExprStmt(Ident(d))}Elif(Ident(e)){ExprStmt(Ident(f))}",
        "S-24");
    EXPECT_PERR_COUNT(r, 0, "S-24");
  }
  {
    auto r = parseAll(u"if a { } else { }");
    EXPECT_PSTMT_SHAPE(r, 0, "If(Ident(a)){}Else{}", "S-25");
    EXPECT_PERR_COUNT(r, 0, "S-25");
  }
  {  // S-26 if 缺 {：b; 保留为下一条语句（PD-4b 已修 2026-10-16）
    auto r = parseAll(u"if a b;");
    EXPECT_PSTMT_SHAPE(r, 0, "If(Ident(a)){}", "S-26");
    EXPECT_PERR_HAS(r, "expected \"{\" in if statement. ", "S-26");
    EXPECT_PSTMTS(r, 2, "S-26");
    EXPECT_PSTMT_SHAPE(r, 1, "ExprStmt(Ident(b))", "S-26");
  }
  {
    auto r = parseAll(u"if a { b; c;");
    EXPECT_PSTMT_SHAPE(r, 0, "If(Ident(a)){ExprStmt(Ident(b)) ; ExprStmt(Ident(c))}", "S-27");
    EXPECT_PERR_HAS(r, "expected \"}\" in if statement. ", "S-27");
  }
  {  // S-28 elif 缺 {：d; 保留为下一条语句（PD-4b 已修）
    auto r = parseAll(u"if a { b; } elif c d;");
    EXPECT_PERR_HAS(r, "expected \"{\" of elif. ", "S-28");
    EXPECT_PSTMTS(r, 2, "S-28");
    EXPECT_PSTMT_SHAPE(r, 1, "ExprStmt(Ident(d))", "S-28");
  }
  {  // S-29 else 缺 {：c; 保留为下一条语句（PD-4b 已修）
    auto r = parseAll(u"if a { b; } else c;");
    EXPECT_PERR_HAS(r, "expected \"{\" after else. ", "S-29");
    EXPECT_PSTMTS(r, 2, "S-29");
    EXPECT_PSTMT_SHAPE(r, 1, "ExprStmt(Ident(c))", "S-29");
  }

  // ---- S-30…S-34 while ----
  {
    auto r = parseAll(u"while a { b; }");
    EXPECT_PSTMT_SHAPE(r, 0, "While(Ident(a)){ExprStmt(Ident(b))}", "S-30");
    EXPECT_PERR_COUNT(r, 0, "S-30");
  }
  {  // S-31 while 的条件是可选的（ast.hpp 文法 expr?），空 cond 合法
    auto r = parseAll(u"while { b; }");
    EXPECT_PSTMT_SHAPE(r, 0, "While(null){ExprStmt(Ident(b))}", "S-31");
    EXPECT_PERR_COUNT(r, 0, "S-31");
  }
  {  // S-32 while 缺 {：b; 保留为下一条语句（PD-4b 已修）
    auto r = parseAll(u"while a b;");
    EXPECT_PERR_HAS(r, "expected \"{\" in while statement. ", "S-32");
    EXPECT_PSTMTS(r, 2, "S-32");
    EXPECT_PSTMT_SHAPE(r, 1, "ExprStmt(Ident(b))", "S-32");
  }
  {
    auto r = parseAll(u"while a { b;");
    EXPECT_PERR_HAS(r, "expected \"}\" at end of while statement. ", "S-33");
  }
  {  // S-34 while {} x; 不得吞掉 x;（2026-10-15 修复的回归保护）
    auto r = parseAll(u"while {} x;");
    EXPECT_PSTMTS(r, 2, "S-34");
    EXPECT_PSTMT_SHAPE(r, 1, "ExprStmt(Ident(x))", "S-34");
  }

  // ---- S-35…S-37 break / continue ----
  {
    auto r = parseAll(u"break;");
    EXPECT_PSTMT_SHAPE(r, 0, "Break", "S-35");
    EXPECT_PERR_COUNT(r, 0, "S-35");
  }
  {
    auto r = parseAll(u"continue;");
    EXPECT_PSTMT_SHAPE(r, 0, "Continue", "S-35");
    EXPECT_PERR_COUNT(r, 0, "S-35");
  }
  {  // S-36 break x; / continue x;：x; 保留为下一条语句（PD-4 已修 2026-10-16）
    auto r = parseAll(u"break x;");
    EXPECT_PSTMT_SHAPE(r, 0, "Break", "S-36");
    EXPECT_PERR_HAS(r, "expected \";\" in break statement. ", "S-36");
    EXPECT_PSTMTS(r, 2, "S-36");
    EXPECT_PSTMT_SHAPE(r, 1, "ExprStmt(Ident(x))", "S-36");
    auto r2 = parseAll(u"continue x;");
    EXPECT_PSTMT_SHAPE(r2, 0, "Continue", "S-36");
    EXPECT_PERR_HAS(r2, "expected \";\" in continue statement. ", "S-36");
    EXPECT_PSTMTS(r2, 2, "S-36");
    EXPECT_PSTMT_SHAPE(r2, 1, "ExprStmt(Ident(x))", "S-36");
  }
  {  // S-37 break 后 EOF：不挂死
    auto r = parseAll(u"break");
    EXPECT_PSTMT_SHAPE(r, 0, "Break", "S-37");
    EXPECT_PERR_COUNT(r, 1, "S-37");
  }

  // ---- S-38…S-45 表达式语句与赋值语句 ----
  {
    auto r = parseAll(u"a;");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Ident(a))", "S-38");
    EXPECT_PERR_COUNT(r, 0, "S-38");
  }
  {
    auto r = parseAll(u"a = 1;");
    EXPECT_PSTMT_SHAPE(r, 0, "Assign(Ident(a), Int(1))", "S-39");
    EXPECT_PERR_COUNT(r, 0, "S-39");
  }
  {
    auto r = parseAll(u"a[0] = 1;");
    EXPECT_PSTMT_SHAPE(r, 0, "Assign(At(Ident(a); Int(0)), Int(1))", "S-40");
    EXPECT_PERR_COUNT(r, 0, "S-40");
  }
  {
    auto r = parseAll(u"a = 1 b;");
    EXPECT_PERR_HAS(r, "expected \";\" at end of assign statement. ", "S-41");
  }
  {  // S-42 a = ; 右侧是裸 Expr（PD-8 未修：失败处不该返回裸 Expr）。
    // 失败节点的 line 自 2026-10-16 起取自当前 token（PD-11 已修），不再是 -1。
    // AssignStmt.line 取自左式（Ident(a) 在第 1 行）所以是 1。
    auto r = parseAll(u"a = ;");
    EXPECT_PSTMT_SHAPE(r, 0, "Assign(Ident(a), Err(L1))", "S-42");
    EXPECT_PLINE(r, 0, 1, "S-42");
  }
  {  // S-43 a = b = 1; 赋值不是表达式（PD-9 未修）
    auto r = parseAll(u"a = b = 1;");
    EXPECT_PSTMTS(r, 2, "S-43");
    EXPECT_PSTMT_SHAPE(r, 0, "Assign(Ident(a), Ident(b))", "S-43");
    EXPECT_PSTMT_SHAPE(r, 1, "ExprStmt(Int(1))", "S-43");
    EXPECT_PERR_COUNT(r, 1, "S-43");
    KNOWN("PD-9", r.stmts() == 1, "S-43 链式赋值应是一条 Assign");
  }
  {  // S-44 1 = 2; / f() = 1; 不校验左值，0 errors（PD-10 未修）
    auto r = parseAll(u"1 = 2;");
    EXPECT_PSTMTS(r, 1, "S-44");
    EXPECT_PERR_COUNT(r, 0, "S-44");
    KNOWN("PD-10", r.errors.size() == 1, "S-44 字面量不能作左值，应报错");
    auto r2 = parseAll(u"f() = 1;");
    EXPECT_PSTMTS(r2, 1, "S-44");
    EXPECT_PERR_COUNT(r2, 0, "S-44");
    KNOWN("PD-10", r2.errors.size() == 1, "S-44 调用结果不能作左值，应报错");
  }
  {  // S-45 顶层 return/break/continue 也被接受（无语境检查）
    auto r = parseAll(u"return; break; continue;");
    EXPECT_PSTMTS(r, 3, "S-45");
    EXPECT_PERR_COUNT(r, 0, "S-45");
  }
}

}  // namespace Test
}  // namespace Stope
