// parser 行号 / 错误恢复 / 健壮性与内存用例（测试计划 §5.6-§5.8）
// L-01…L-05 行号；R-01…R-07 错误恢复；B-01/B-02/B-07…B-10 健壮性与内存。
// B-03…B-06（深嵌套崩溃阈值）在 test_parser_depth.cpp 单独进程跑，见 CMakeLists。
#include <cstdlib>

#include "test_common.hpp"

namespace Stope {
namespace Test {

// ---- 全局分配计数（B-07/B-08）----
// 坑（已记入测试计划 §10.5）：必须同时重载 sized delete（C++14 起析构路径优先选
// operator delete(void*, size_t)），否则计数永远不配平、得出假泄漏结论。
// 另一个坑：每次 error() 里的 std::stringstream 会让 del 比 new 多 1（PD-12，
// 根因是该工具链上 stringstream 的内部分配不走可替换的全局 operator new，
// 释放却走 —— 已实测隔离复现，不是双重释放也不是 AST 泄漏）。
// 注意：operator new/delete 只能声明在全局作用域，不能放进 namespace。
static long long g_allocNew = 0, g_allocDel = 0;
static bool g_allocOn = false;

}  // namespace Test
}  // namespace Stope

void* operator new(size_t sz) {
  if (Stope::Test::g_allocOn) ++Stope::Test::g_allocNew;
  return std::malloc(sz ? sz : 1);
}
void operator delete(void* p) noexcept {
  if (Stope::Test::g_allocOn) ++Stope::Test::g_allocDel;
  std::free(p);
}
void operator delete(void* p, size_t) noexcept {
  if (Stope::Test::g_allocOn) ++Stope::Test::g_allocDel;
  std::free(p);
}
void* operator new[](size_t sz) {
  if (Stope::Test::g_allocOn) ++Stope::Test::g_allocNew;
  return std::malloc(sz ? sz : 1);
}
void operator delete[](void* p) noexcept {
  if (Stope::Test::g_allocOn) ++Stope::Test::g_allocDel;
  std::free(p);
}
void operator delete[](void* p, size_t) noexcept {
  if (Stope::Test::g_allocOn) ++Stope::Test::g_allocDel;
  std::free(p);
}

namespace Stope {
namespace Test {

// 在窗口内构造 Lexer/Parser/Prog 并解析、析构，返回 (new, del)。
// 输入 string 由调用方在窗口外构造（shared_ptr 持有），避免其缓冲被算进窗口。
inline void measureParse(const std::shared_ptr<std::u16string>& holder, long long& n,
                         long long& d, CustomOpcodeConfig* cfg = nullptr) {
  g_allocNew = g_allocDel = 0;
  g_allocOn = true;
  {
    Lexer lx(*holder);
    Parser p(lx, cfg);
    AST::Prog prog;
    p.ParseProgram(prog);
  }  // prog / p / lx 在此析构
  g_allocOn = false;
  n = g_allocNew;
  d = g_allocDel;
}

void runFlowTests() {
  section("L 行号与位置 (P-LINE)");

  {  // L-01 单行程序所有节点 line=1
    auto r = parseAll(u"let a = 1;");
    EXPECT_PLINE(r, 0, 1, "L-01");
    auto* ls = static_cast<const AST::LetStmt*>(r.stmt(0));
    EXPECT(ls && ls->expr && ls->expr->line == 1, "L-01");
  }
  {  // L-02 表达式跨行：左右操作数行号各自正确
    // 关折叠：`1 + 2` 会被折成 Int(3)，也就没有 left/right 可查（见 P 组同样处理）。
    auto r = parseAll(u"1 +\n2;\na;", nullptr, false);
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Bin(Add, Int(1), Int(2)))", "L-02");
    auto* es = static_cast<const AST::ExprStmt*>(r.stmt(0));
    // 先判类型再下转：折叠开着时这里会是 IntExpr，直接 static_cast 是未定义行为。
    bool ok = es && es->expr && es->expr->type == AST::NodeType::BinaryOpExpr;
    auto* b = ok ? static_cast<const AST::BinaryOpExpr*>(es->expr.get()) : nullptr;
    EXPECT(b && b->leftExpr->line == 1 && b->rightExpr->line == 2, "L-02");
    EXPECT_PLINE(r, 1, 3, "L-02");
  }
  {  // L-03 if 的条件可以换行
    auto r = parseAll(u"if a\n{ b; }");
    EXPECT_PLINE(r, 0, 1, "L-03");
    auto* is = static_cast<const AST::IfStmt*>(r.stmt(0));
    EXPECT(is && is->cond && is->cond->line == 1, "L-03");
  }
  {  // L-04 错误行号与 token 行号一致
    auto r = parseAll(u"a\n@");
    EXPECT_PERR_HAS(r, "line 2: ", "L-04");
    EXPECT_PERR_ANY(r, "unknown token. ", "L-04");
  }
  {  // L-05 失败表达式的 line 取自当前 token（2026-10-16 起不再是 -1）；
  // 语句自身的 line 取自左式/关键字，不受影响。
  auto r = parseAll(u"a = ;");
  EXPECT_PLINE(r, 0, 1, "L-05");
  auto* as = static_cast<const AST::AssignStmt*>(r.stmt(0));
  EXPECT(as && as->rightExpr && as->rightExpr->line == 1, "L-05");
  KNOWN("PD-8", as && as->rightExpr && as->rightExpr->type != AST::NodeType::Expr,
        "L-05 失败处不该返回裸 Expr 节点");
  }

  section("R 错误恢复 (P-RECOVER)");

  {  // R-01 parser.hpp 全部 33 处 error() 调用点，逐个触发并核对文案。
    // 例外：parser.hpp:347 "no infix parse function for token type. " 不可达 ——
    // while 循环条件已要求 peekPrecedence() > Lowest，而 BinopPrecMap 的 17 个键
    // 与 infixParseFns 完全一致，所以 find 必然命中（死代码，见报告）。
    struct { const char* id; std::u16string src; const char* msg; } cases[] = {
        {"R-01a", u"let 1;", "expected identifier after \"let\". "},
        {"R-01b", u"let a, b", "expected \";\" in let statement. "},
        {"R-01c", u"let a, b = 1;", "failed to parse let statement with multiple identifiers. "},
        {"R-01d", u"let a + 1;", "unexpected token in let statement. "},
        {"R-01e", u"export 1;", "expected identifier after \"export\". "},
        {"R-01f", u"export a, b", "expected \";\" in export statement. "},
        {"R-01g", u"export a, b = 1;", "failed to parse export statement with multiple identifiers. "},
        {"R-01h", u"export a + 1;", "unexpected token in export statement. "},
        {"R-01i", u"return", "expected \";\" in return statement. "},
        {"R-01j", u"return 1 2;", "expected \";\" or \",\" in return statement. "},
        {"R-01k", u"{ a;", "expected \"}\" at end of block statement. "},
        {"R-01l", u"if a b;", "expected \"{\" in if statement. "},
        {"R-01m", u"if a { b;", "expected \"}\" in if statement. "},
        {"R-01n", u"if a { b; } elif c d;", "expected \"{\" of elif. "},
        {"R-01o", u"if a { b; } elif c { d;", "expected \"}\" of elif. "},
        {"R-01p", u"if a { b; } else c;", "expected \"{\" after else. "},
        {"R-01q", u"if a { b; } else { c;", "expected \"}\" in if statement. "},
        {"R-01r", u"while a b;", "expected \"{\" in while statement. "},
        {"R-01s", u"while a { b;", "expected \"}\" at end of while statement. "},
        {"R-01t", u"break x;", "expected \";\" in break statement. "},
        {"R-01u", u"continue x;", "expected \";\" in continue statement. "},
        {"R-01v", u"a = 1 b;", "expected \";\" at end of assign statement. "},
        {"R-01w", u"a b;", "expected \";\" or \"=\". "},
        {"R-01x", u"= 1;", "no prefix parse function for token type. "},
        // parser.hpp:347 no infix parse function —— 不可达（死代码）
        {"R-01y", u"'x zz';", "invalid binary array. "},
        {"R-01z", u"(1;", "expected \")\". "},
        {"R-01ab", u"args 0;", "expected \"[\" after \"args\". "},
        {"R-01ac", u"args[0;", "expected \"]\". "},
        {"R-01ad", u"f(1;", "expected \")\". "},
        {"R-01ae", u"a[1;", "expected \"]\". "},
    };
    for (const auto& c : cases) {
      auto r = parseAll(c.src);
      EXPECT_PERR_HAS(r, c.msg, c.id);
    }
    // 自定义指令相关的两处（:449/:463）需要 config 才能走到 Custom 路径
    CustomOpcodeConfig cfg;
    std::u16string myop = u"myop";
    cfg.addCustomOpcode(myop, 1, 2);
    auto rc1 = parseAll(u"x; myop 1;", &cfg);
    EXPECT_PERR_HAS(rc1, "expected \"(\" after custom opcode. ", "R-01aa");
    auto rc2 = parseAll(u"x; myop(1;", &cfg);
    EXPECT_PERR_HAS(rc2, "expected \")\". ", "R-01af");
  }
  {  // R-02 同行两个错误：曾按 lastErrorLine 去重只剩 1 条（PD-5，2026-10-16 已除去重）
    auto r = parseAll(u"'x zz'; 'b _';");
    EXPECT_PERR_COUNT(r, 2, "R-02");
    EXPECT_PERR_HAS(r, "invalid binary array. ", "R-02");
  }
  {  // R-03 分两行则两条都报
    auto r = parseAll(u"'x zz';\n'b _';");
    EXPECT_PERR_COUNT(r, 2, "R-03");
  }
  {  // R-04 缺 ) 与缺 ; 同行，曾只剩 1 条（PD-5）
    auto r = parseAll(u"(1;");
    EXPECT_PERR_COUNT(r, 2, "R-04");
  }
  {  // R-05 两条 let 错误同行，曾只剩 1 条（PD-5）
    auto r = parseAll(u"let 1; let 2;");
    EXPECT_PERR_COUNT(r, 2, "R-05");
  }
  {  // R-06 lexer.errors 与 parser.errors 不合并，同一处报两遍（PD-14 未修）
    auto r = parseAll(u"@ a;");
    EXPECT(r.lexErrors.size() == 1, "R-06");
    EXPECT_PERR_COUNT(r, 2, "R-06");  // 无前缀解析函数 + 缺 ;
    KNOWN("PD-14", r.errors.empty(), "R-06 lexer 错误应合并进 parser.errors");
  }
  {  // R-07 每条错误后都必须能继续走到 Eof（不死循环）。
    // 进程能返回即证明终止；真正的兜底是 ctest 的 TIMEOUT（见 CMakeLists）。
    const char* ids[] = {"R-07a", "R-07b", "R-07c", "R-07d", "R-07e"};
    std::u16string srcs[] = {u"let", u"let a, b", u"return", u"{ a;", u"while a {"};
    for (int i = 0; i < 5; ++i) {
      auto r = parseAll(srcs[i]);
      EXPECT_PERR_COUNT(r, 1, ids[i]);
      EXPECT(r.stmts() <= 4, ids[i]);  // 语句数有界，不会无限追加
    }
  }

  section("B 健壮性与内存 (P-ROBUST)");

  {  // B-01 全前缀截断：11 组合法程序 × 每一个前缀，0 挂起 / 0 崩溃 / 0 异常
    std::u16string progs[] = {
        u"let a = 1;",
        u"let a, b;",
        u"return 1, 2;",
        u"{ a; b; }",
        u"if a { b; } elif c { d; } else { e; }",
        u"while a { b; }",
        u"f(g(1), 2)[3];",
        u"a[0] = f(1,2);",
        u"'x ff 0a';",
        u"args[0] + argc;",
        u"-a * not b;",
    };
    int total = 0;
    for (const auto& src : progs) {
      for (size_t len = 0; len <= src.size(); ++len) {
        auto r = parseAll(src.substr(0, len));
        ++total;
        // 语句数不可能超过 token 数（len+1 含 Eof）；这条断言能抓住
        // "不消费 token 却不断追加语句"的死循环苗头
        check(r.stmts() <= len + 1, "B-01", "stmts <= prefix length",
              "prefix len=" + std::to_string(len));
      }
    }
    printf("     [B-01] 全前缀截断 %d 例，全部返回\n", total);
  }
  {  // B-02 10000 层括号：超过 maxDepth（默认 256）报一条错，不崩
    std::u16string src(10000, u'(');
    src += u"a";
    src.append(10000, u')');
    src += u";";
    auto r = parseAll(src);
    EXPECT_PSTMTS(r, 0, "B-02");
    EXPECT_PERR_COUNT(r, 1, "B-02");
  }
  {  // B-02b 限额之内（200 层）照常解析：防「加了限额把正常嵌套一起挡掉」
    std::u16string src(200, u'(');
    src += u"a";
    src.append(200, u')');
    src += u";";
    auto r = parseAll(src);
    EXPECT_PSTMTS(r, 1, "B-02b");
    EXPECT_PSTMT_SHAPE(r, 0, "ExprStmt(Ident(a))", "B-02b");
    EXPECT_PERR_COUNT(r, 0, "B-02b");
  }
  {  // B-07 正确路径 new == delete 完全配平（预热一次排除静态 map 惰性初始化）
    auto warm = std::make_shared<std::u16string>(u"a;");
    long long wn, wd;
    measureParse(warm, wn, wd);
    const char* ids[] = {"B-07a", "B-07b", "B-07c", "B-07d", "B-07e", "B-07f", "B-07g", "B-07h"};
    std::u16string srcs[] = {
        u"a;",
        u"return 1,2;",
        u"f(g(1),2)[3];",
        u"if a { b; } elif c { d; } else { e; }",
        u"while a { let x, y; b; }",
        u"a[0] = f(1,2);",
        u"'x ff 0a';",
        u"let a = 1 + 2 * 3;",
    };
    for (int i = 0; i < 8; ++i) {
      auto holder = std::make_shared<std::u16string>(srcs[i]);
      long long n, d;
      measureParse(holder, n, d);
      check(n == d, ids[i], "new == delete",
            "new=" + std::to_string(n) + " del=" + std::to_string(d) + " src=[" +
                escUtf8(srcs[i]) + "]");
    }
  }
  {  // B-08 有 error 的路径：del == new + error条数（PD-12 的当前表现）
    auto warm = std::make_shared<std::u16string>(u"break x;");
    long long wn, wd;
    measureParse(warm, wn, wd);
    struct { const char* id; std::u16string src; } cases[] = {
        {"B-08a", u"break x;"},
        {"B-08b", u"a = ;"},
        {"B-08c", u"'x zz';"},
        {"B-08d", u"break x;\nbreak y;"},  // 两条不同行的错误
    };
    for (const auto& c : cases) {
      auto holder = std::make_shared<std::u16string>(c.src);
      long long n, d;
      measureParse(holder, n, d);
      auto r = parseAll(c.src);
      long long want = n + static_cast<long long>(r.errors.size());
      check(d == want, c.id, "del == new + errors",
            "new=" + std::to_string(n) + " del=" + std::to_string(d) +
                " errors=" + std::to_string(r.errors.size()) + " src=[" + escUtf8(c.src) + "]");
      KNOWN("PD-12", d == n, c.id);  // 修好 error() 的计量后应配平
    }
  }
  {  // B-09 复用同一个 Lexer/Parser 跑第二条输入：明确不支持，只断言不崩
    std::u16string a = u"abc";
    std::u16string b = u"123";
    Lexer lx(a);
    Parser p(lx);
    AST::Prog p1;
    p.ParseProgram(p1);
    lx.input = b;
    AST::Prog p2;
    p.ParseProgram(p2);
    EXPECT(p2.stmts.empty(), "B-09");  // 环形缓冲里还留着上条的 Eof，直接结束
  }
  {  // B-10 空输入 / 纯空白 / 纯注释
    auto r1 = parseAll(u"");
    auto r2 = parseAll(u"   \n\t ");
    auto r3 = parseAll(u"// x\n/* y */");
    EXPECT_PSTMTS(r1, 0, "B-10");
    EXPECT_PSTMTS(r2, 0, "B-10");
    EXPECT_PSTMTS(r3, 0, "B-10");
    EXPECT_PERR_COUNT(r3, 0, "B-10");
  }
}

}  // namespace Test
}  // namespace Stope
