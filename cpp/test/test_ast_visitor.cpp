// ASTVisitor 测试：遍历骨架本身能不能独立用。
//
// 这里不测 Compiler（那 98 条在 test_compiler.cpp），只测遍历骨架本身：
//   V-01 / V-02 默认「按源码顺序递归子节点」的顺序是有定义的，逐构造锁死
//   V-03       visit(nullptr) 与三个裸基类节点要被安全忽略
//   V-04       curLine 随 visit() 更新
//   V-05       只重写一个钩子时，其余照默认往下走
//   V-06       重写后不调基类版本 = 不再下钻（契约）
//   V-07       分发表完整性：每个语法节点都必须登记，三个裸基类必须没有
//   V-02-26/27 and / or 由 onVisitBinaryOpExpr 转调 onVisitOrExpr / onVisitAndExpr
//
// 子类契约：**重写的是 onVisitXxx 系列**，不是 visitXxx —— 后者现在是静态分发函数。
// 与 lexer / parser / compiler 共用一套 g_total / g_failed 与 check()。
#include <string>
#include <vector>

#include <stope/ast.hpp>
#include <stope/ast_visitor.hpp>
#include <stope/lexer.hpp>
#include <stope/parser.hpp>
#include "test_common.hpp"

#ifdef _WIN32
#include <Windows.h>
#endif

namespace Stope {
namespace Test {

// ---------- 打辅助：把一棵树按访问顺序记成 "ExprStmt IntExpr" 这样的串 ----------
// 每个覆盖都是「先记名，再调基类版本继续下钻」。
struct Tracer : ASTVisitor {
  std::string log;
  std::vector<int> lines;  // 每次记录的节点行号

  void mark(const char* name) {
    if (!log.empty())
      log += " ";
    log += name;
    lines.push_back(curLine);
  }

  void onVisitProg(AST::Prog* prog) override {
    mark("Prog");
    ASTVisitor::onVisitProg(prog);
  }
  void onVisitExprStmt(AST::ExprStmt* s) override {
    mark("ExprStmt");
    ASTVisitor::onVisitExprStmt(s);
  }
  void onVisitLetStmt(AST::LetStmt* s) override {
    mark("LetStmt");
    ASTVisitor::onVisitLetStmt(s);
  }
  void onVisitReturnStmt(AST::ReturnStmt* s) override {
    mark("ReturnStmt");
    ASTVisitor::onVisitReturnStmt(s);
  }
  void onVisitExportStmt(AST::ExportStmt* s) override {
    mark("ExportStmt");
    ASTVisitor::onVisitExportStmt(s);
  }
  void onVisitBlockStmt(AST::BlockStmt* s) override {
    mark("BlockStmt");
    ASTVisitor::onVisitBlockStmt(s);
  }
  void onVisitIfStmt(AST::IfStmt* s) override {
    mark("IfStmt");
    ASTVisitor::onVisitIfStmt(s);
  }
  void onVisitWhileStmt(AST::WhileStmt* s) override {
    mark("WhileStmt");
    ASTVisitor::onVisitWhileStmt(s);
  }
  void onVisitAssignStmt(AST::AssignStmt* s) override {
    mark("AssignStmt");
    ASTVisitor::onVisitAssignStmt(s);
  }
  void onVisitBreakStmt(AST::BreakStmt* s) override {
    mark("BreakStmt");
    ASTVisitor::onVisitBreakStmt(s);
  }
  void onVisitContinueStmt(AST::ContinueStmt* s) override {
    mark("ContinueStmt");
    ASTVisitor::onVisitContinueStmt(s);
  }
  void onVisitNullExpr() override { mark("NullExpr"); }
  void onVisitBoolExpr(AST::BoolExpr* e) override {
    mark("BoolExpr");
    ASTVisitor::onVisitBoolExpr(e);
  }
  void onVisitIntExpr(AST::IntExpr* e) override {
    mark("IntExpr");
    ASTVisitor::onVisitIntExpr(e);
  }
  void onVisitFloatExpr(AST::FloatExpr* e) override {
    mark("FloatExpr");
    ASTVisitor::onVisitFloatExpr(e);
  }
  void onVisitStringExpr(AST::StringExpr* e) override {
    mark("StringExpr");
    ASTVisitor::onVisitStringExpr(e);
  }
  void onVisitBinArrExpr(AST::BinArrExpr* e) override {
    mark("BinArrExpr");
    ASTVisitor::onVisitBinArrExpr(e);
  }
  void onVisitIdentExpr(AST::IdentExpr* e) override {
    mark("IdentExpr");
    ASTVisitor::onVisitIdentExpr(e);
  }
  void onVisitArgcExpr() override { mark("ArgcExpr"); }
  void onVisitArgsExpr(AST::ArgsExpr* e) override {
    mark("ArgsExpr");
    ASTVisitor::onVisitArgsExpr(e);
  }
  void onVisitUnaryOpExpr(AST::UnaryOpExpr* e) override {
    mark("UnaryOpExpr");
    ASTVisitor::onVisitUnaryOpExpr(e);
  }
  void onVisitBinaryOpExpr(AST::BinaryOpExpr* e) override {
    mark("BinaryOpExpr");
    ASTVisitor::onVisitBinaryOpExpr(e);
  }
  void onVisitOrExpr(AST::BinaryOpExpr* e) override {
    mark("OrExpr");
    ASTVisitor::onVisitOrExpr(e);
  }
  void onVisitAndExpr(AST::BinaryOpExpr* e) override {
    mark("AndExpr");
    ASTVisitor::onVisitAndExpr(e);
  }
  void onVisitCallExpr(AST::CallExpr* e) override {
    mark("CallExpr");
    ASTVisitor::onVisitCallExpr(e);
  }
  void onVisitAtExpr(AST::AtExpr* e) override {
    mark("AtExpr");
    ASTVisitor::onVisitAtExpr(e);
  }
  void onVisitCustomOpcodeExpr(AST::CustomOpcodeExpr* e) override {
    mark("CustomOpcodeExpr");
    ASTVisitor::onVisitCustomOpcodeExpr(e);
  }
};

// ---------- 公共 OnlyIdent 之类的小 Visitor ----------
// 只覆盖 IdentExpr：证明「不用把所有方法都写一遍」。
struct IdentCounter : ASTVisitor {
  int n = 0;
  void onVisitIdentExpr(AST::IdentExpr* e) override { ++n; }
};
// 只覆盖 onVisitCallExpr，且不调用基类版本：子孙应该一个都不到。
struct Stopper : ASTVisitor {
  std::string log;
  void onVisitCallExpr(AST::CallExpr* e) override { log += "CallExpr "; }
};

// ---------- 驱动 ----------
struct Parsed {
  std::shared_ptr<const std::u16string> src;  // 持有输入：Token::lexeme 是 string_view
  AST::Prog prog;
  std::vector<std::string> errors;
};

inline Parsed parseSrc(std::u16string src, CustomOpcodeConfig* cfg = nullptr) {
  auto holder = std::make_shared<std::u16string>(std::move(src));
  Parsed r;
  r.src = holder;
  Lexer lx(*holder);
  Parser p(lx, cfg);
  p.constFolding = false;  // 锁完整树形
  p.ParseProgram(r.prog);
  r.errors = p.errors;
  return r;
}

// 走一遍并记录；expect 为空串表示「不应该有任何访问」
inline void expectTrace(Parsed& r, const char* want, const char* id) {
  Tracer t;
  t.Visit(&r.prog);
  std::string errDetail;
  for (const auto& e : r.errors)
    errDetail += "\n         [" + e + "]";
  check(t.log == want, id, std::string("trace == ") + want,
        "got=[" + t.log + "]" + errDetail);
}

// ===========================================================================
void runAstVisitorTests() {
  section("V ASTVisitor (V-VISITOR)");

  // ---------- V-01 空程序 ----------
  {
    auto r = parseSrc(u"");
    expectTrace(r, "Prog", "V-01");
  }

  // ---------- V-02 默认遍历顺序 ----------
  {
    struct {
      const char* id;
      std::u16string src;
      const char* want;
    } cases[] = {
        // 叶子
        {"V-02-01", u"1;", "Prog ExprStmt IntExpr"},
        {"V-02-02", u"1.5;", "Prog ExprStmt FloatExpr"},
        {"V-02-03", u"\"s\";", "Prog ExprStmt StringExpr"},
        {"V-02-04", u"'x 41';", "Prog ExprStmt BinArrExpr"},
        {"V-02-05", u"true;", "Prog ExprStmt BoolExpr"},
        {"V-02-06", u"null;", "Prog ExprStmt NullExpr"},
        {"V-02-07", u"a;", "Prog ExprStmt IdentExpr"},
        {"V-02-08", u"argc;", "Prog ExprStmt ArgcExpr"},
        {"V-02-09", u"args[0];", "Prog ExprStmt ArgsExpr IntExpr"},
        // let：idents 是名字不是 Expr，只走初值
        {"V-02-10", u"let a = 1;", "Prog LetStmt IntExpr"},
        {"V-02-11", u"let a, b;", "Prog LetStmt"},
        // 二元：左在前右在后（两个方向分开测，别让顺序漂移被用例的类型相同掩盖）
        {"V-02-12", u"1 + a;", "Prog ExprStmt BinaryOpExpr IntExpr IdentExpr"},
        {"V-02-13", u"a + 1;", "Prog ExprStmt BinaryOpExpr IdentExpr IntExpr"},
        {"V-02-14", u"-a;", "Prog ExprStmt UnaryOpExpr IdentExpr"},
        {"V-02-15", u"!a;", "Prog ExprStmt UnaryOpExpr IdentExpr"},
        // call / at：callee / container 先，参数后
        {"V-02-16", u"f(1);", "Prog ExprStmt CallExpr IdentExpr IntExpr"},
        {"V-02-17", u"a[1];", "Prog ExprStmt AtExpr IdentExpr IntExpr"},
        // assign 本身就是一个 Stmt（不是被 ExprStmt 包着的表达式）
        {"V-02-18", u"a = 1;", "Prog AssignStmt IdentExpr IntExpr"},
        {"V-02-19", u"return 1, a;", "Prog ReturnStmt IntExpr IdentExpr"},
        {"V-02-20", u"export a, b;", "Prog ExportStmt"},
        // 块：BlockStmt 里嵌的是一个裸 Prog
        {"V-02-21", u"{ 1; }", "Prog BlockStmt Prog ExprStmt IntExpr"},
        // if：cond → 首块 → 每个 elif（cond → 块）→ else 块
        {"V-02-22", u"if a { 1; }",
         "Prog IfStmt IdentExpr Prog ExprStmt IntExpr"},
        {"V-02-23", u"if a { 1; } elif b { 2; } else { 3; }",
         "Prog IfStmt IdentExpr Prog ExprStmt IntExpr IdentExpr Prog ExprStmt "
         "IntExpr Prog ExprStmt IntExpr"},
        {"V-02-24", u"while a { 1; }",
         "Prog WhileStmt IdentExpr Prog ExprStmt IntExpr"},
        {"V-02-25", u"while a { break; continue; }",
         "Prog WhileStmt IdentExpr Prog BreakStmt ContinueStmt"},
        // and / or：onVisitBinaryOpExpr 先被记到，再转调 AndExpr / OrExpr
        {"V-02-26", u"a and b;",
         "Prog ExprStmt BinaryOpExpr AndExpr IdentExpr IdentExpr"},
        {"V-02-27", u"a or b;",
         "Prog ExprStmt BinaryOpExpr OrExpr IdentExpr IdentExpr"},
    };
    for (const auto& c : cases) {
      auto r = parseSrc(c.src);
      expectTrace(r, c.want, c.id);
    }
  }

  // ---------- V-02-28 自定义指令：只走参数 ----------
  {
    CustomOpcodeConfig cfg;
    std::u16string myop = u"myop";
    cfg.addCustomOpcode(myop, 100, 1);
    auto r = parseSrc(u"myop(1);", &cfg);
    expectTrace(r, "Prog ExprStmt CustomOpcodeExpr IntExpr", "V-02-28");
  }

  // ---------- V-03 visit(nullptr) 与三个裸基类节点 ----------
  {
    Tracer t;
    t.Visit(nullptr);  // 不应崩，也不应记录
    AST::Node bareNode;
    AST::Stmt bareStmt;
    AST::Expr bareExpr;  // parser 的错误节点就是裸 Expr
    t.Visit(&bareNode);
    t.Visit(&bareStmt);
    t.Visit(&bareExpr);
    check(t.log.empty(), "V-03", "bare base nodes and nullptr ignored",
          "got=[" + t.log + "]");
  }

  // ---------- V-04 curLine 随 visit() 更新 ----------
  {
    auto r = parseSrc(u"1;\n2;\n3;\n");
    Tracer t;
    t.Visit(&r.prog);
    // 期望：Prog(-1) ExprStmt(1) IntExpr(1) ExprStmt(2) IntExpr(2) ExprStmt(3) IntExpr(3)
    std::string want = "-1 1 1 2 2 3 3";
    std::string got;
    for (int ln : t.lines) {
      if (!got.empty())
        got += " ";
      got += std::to_string(ln);
    }
    check(got == want, "V-04", "curLine per node == " + want, "got=[" + got + "]");
  }

  // ---------- V-05 只覆盖一个节点类型，其余照默认走 ----------
  {
    auto r = parseSrc(u"f(a, b); g(a); a;");
    IdentCounter c;
    c.Visit(&r.prog);
    check(c.n == 6, "V-05", "ident count == 6 (f a b | g a | a)",
          "got=" + std::to_string(c.n));
  }

  // ---------- V-06 覆盖后不调基类版本 = 不再下钻 ----------
  {
    auto r = parseSrc(u"f(1);");
    Stopper s;
    s.Visit(&r.prog);
    // Stopper 没覆盖 onVisitCallExpr 以外的任何东西，且 onVisitCallExpr 不调基类，
    // 所以 f 与 1 都不会被访问，log 里只会有这一次 CallExpr。
    // 但注意 onVisitExprStmt 走的是默认实现 → 会下钻到 CallExpr。
    check(s.log == "CallExpr ", "V-06", "override without base call stops descent",
          "got=[" + s.log + "]");
  }

  // ---------- V-07 分发表的完整性 ----------
  // 漏登记一项不会编译报错，只会让 visit() 静默跳过整类节点 —— 最早那版
  // （只登记 Prog/LetStmt/ReturnStmt）踩过这个坑，这里一次性锁死：
  // 除三个裸基类外，每个 NodeType 都必须有表项，裸基类则必须没有。
  {
    struct Entry { int type; const char* name; };
    const Entry all[] = {
        {0,"Node"},{1,"Prog"},{2,"Stmt"},{3,"Expr"},{4,"ExprStmt"},{5,"LetStmt"},
        {6,"ReturnStmt"},{7,"ExportStmt"},{8,"BlockStmt"},{9,"IfStmt"},{10,"WhileStmt"},
        {11,"AssignStmt"},{12,"BreakStmt"},{13,"ContinueStmt"},{14,"NullExpr"},
        {15,"BoolExpr"},{16,"IntExpr"},{17,"FloatExpr"},{18,"BinArrExpr"},{19,"StringExpr"},
        {20,"IdentExpr"},{21,"ArgcExpr"},{22,"ArgsExpr"},{23,"UnaryOpExpr"},
        {24,"BinaryOpExpr"},{25,"CallExpr"},{26,"AtExpr"},{27,"CustomOpcodeExpr"},
    };
    const int kLast = static_cast<int>(AST::NodeType::CustomOpcodeExpr);
    check(kLast == 27, "V-07", "NodeType 最后一项仍是 CustomOpcodeExpr(27)",
          "got=" + std::to_string(kLast) + " —— NodeType 变了要同步这张表");
    std::string missing, unexpected;
    for (const auto& e : all) {
      const bool has = ASTVisitor::visitMap.find(static_cast<AST::NodeType>(e.type)) !=
                       ASTVisitor::visitMap.end();
      const bool bareBase = (e.type == 0 || e.type == 2 || e.type == 3);
      if (!has && !bareBase) missing += std::string(" ") + e.name;
      if (has && bareBase) unexpected += std::string(" ") + e.name;
    }
    check(missing.empty(), "V-07", "每个语法节点都有表项",
          missing.empty() ? "" : "缺表项:" + missing);
    check(unexpected.empty(), "V-07", "裸基类没有表项",
          unexpected.empty() ? "" : "不该有:" + unexpected);
  }
}

}  // namespace Test
}  // namespace Stope

// 与 compiler / parser 一样自成二进制。
// 退出码：0 = 全部通过；1 = 有断言失败。
int main() {
  using namespace Stope::Test;
#ifdef _WIN32
  SetConsoleOutputCP(CP_UTF8);
#endif
  setvbuf(stdout, nullptr, _IONBF, 0);

  printf("=== stope ast_visitor tests ===\n");
  runAstVisitorTests();

  printf("\n== 汇总\n");
  printf("   断言总数 %d | 失败 %d\n", g_total, g_failed);
  if (g_failed > 0) {
    printf("RESULT: FAILED\n");
    return 1;
  }
  printf("RESULT: PASSED\n");
  return 0;
}
