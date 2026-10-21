// parser 深嵌套探测（测试计划 §5.8 B-03…B-06，独立进程）
//
// 用法：test_parser_depth <kind> <depth>
//   kind ∈ paren | block | unary | at
//
// 这些用例会真的栈溢出崩溃，不能放在主测试二进制里（会连带后面的用例全看不到），
// 因此单独编译、由 CMake/ctest 以不同深度多次调用；崩溃深度用 WILL_FAIL 登记。
// 输出 DEPTH-OK 表示该深度下解析与析构都成功。
#include <cstdio>
#include <cstdlib>
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
    for (int i = 0; i < n; ++i) s += u"a[";
    s += u"0";
    s.append(n, u']');
    s += u";";
  }
  return s;
}

// 输出分两段，用于区分崩在解析还是崩在析构（PD-13 vs PD-13b）：
//   PARSE-OK  —— 解析完成（AST 已建好）
//   DESTROY-OK —— AST::Prog 也已析构完成
static int parseDepth(const std::string& kind, int depth) {
  std::u16string src = build(kind, depth);
  auto holder = std::make_shared<std::u16string>(src);
  Lexer lx(*holder);
  Parser p(lx);
  AST::Prog prog;
  p.ParseProgram(prog);
  printf("PARSE-OK kind=%s depth=%d stmts=%zu errs=%zu\n", kind.c_str(), depth,
         prog.stmts.size(), p.errors.size());
  return 0;  // prog / p / lx 在此函数返回时析构（析构同样递归，PD-13b）
}

int main(int argc, char** argv) {
  setvbuf(stdout, nullptr, _IONBF, 0);
  if (argc < 3) {
    printf("usage: %s <paren|block|unary|at> <depth>\n", argv[0]);
    return 64;
  }
  std::string kind = argv[1];
  int depth = std::atoi(argv[2]);
  parseDepth(kind, depth);
  printf("DESTROY-OK kind=%s depth=%d\n", kind.c_str(), depth);
  return 0;
}
