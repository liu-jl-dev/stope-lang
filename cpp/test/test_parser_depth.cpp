// parser 深嵌套用例（测试计划 §5.8 B-03…B-06，独立进程）
//
// 用法：test_parser_depth <kind> <depth> <ok|deep>
//   kind  ∈ paren | block | unary | at
//   ok    —— 该深度在 maxDepth 之内：应当 0 条错误、解析并析构成功
//   deep  —— 该深度超限：应当**恰好 1 条** "nesting too deep" 错误，且不崩
//
// 为什么还单独编一个二进制：这些用例要跑 12000 层的输入，和主测试放一起会让
// 一个用例的回归连带遮住其它用例的结论；而且历史上它们是真的栈溢出崩溃点。
// 现在有 maxDepth 兜着不会崩，但「超限后是否干净地停」仍然值得独立验证。
//
// 退出码：0 = 符合预期；1 = 不符合（ctest 直接判失败）。
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <stope/parser.hpp>

using namespace Stope;

static std::u16string build(const std::string& kind, int n) {
  std::u16string s;
  if (kind == "paren") {
    s.append(n, u'(');
    s += u"a";
    s.append(n, u')');
    s += u";";
  } else if (kind == "block") {
    s.append(n, u'{');
    s += u"a;";
    s.append(n, u'}');
  } else if (kind == "unary") {
    s.append(n, u'-');
    s += u"a;";
  } else if (kind == "at") {
    for (int i = 0; i < n; ++i)
      s += u"a[";
    s += u"0";
    s.append(n, u']');
    s += u";";
  }
  return s;
}

// 输出分两段，用于区分崩在解析还是崩在析构（曾经的 PD-13 vs PD-13b）：
//   PARSE-OK   —— 解析完成
//   DESTROY-OK —— AST::Prog 也已析构完成
static int runCase(const std::string& kind, int depth, bool wantDeep) {
  std::u16string src = build(kind, depth);
  auto holder =
      std::make_shared<std::u16string>(src);  // Lexer 借用 view，必须托住
  Lexer lx(*holder);
  Parser p(lx);
  AST::Prog prog;
  p.ParseProgram(prog);
  const size_t errs = p.errors.size();
  printf("PARSE-OK kind=%s depth=%d stmts=%zu errs=%zu\n", kind.c_str(), depth,
         prog.stmts.size(), errs);
  if (errs)
    printf("  first: %s\n", p.errors[0].c_str());

  bool ok = wantDeep ? (errs == 1 && p.errors[0].find("nesting too deep") !=
                                         std::string::npos)
                     : (errs == 0);
  if (!ok) {
    printf("MISMATCH kind=%s depth=%d expect=%s\n", kind.c_str(), depth,
           wantDeep ? "deep" : "ok");
  }
  return ok ? 0 : 1;
}

int main(int argc, char** argv) {
  setvbuf(stdout, nullptr, _IONBF, 0);
  if (argc < 4) {
    printf("usage: %s <paren|block|unary|at> <depth> <ok|deep>\n", argv[0]);
    return 64;
  }
  int rc =
      runCase(argv[1], std::atoi(argv[2]), std::strcmp(argv[3], "deep") == 0);
  printf("DESTROY-OK kind=%s depth=%d\n", argv[1], std::atoi(argv[2]));
  return rc;
}
