// parser 测试入口：跑全部用例，统计 NodeType 覆盖，输出已知问题清单。
//
// 退出码：0 = 全部通过；1 = 有普通断言失败；2 = 全部通过但有 FIXED-PENDING-FLIP
//        （缺陷已修，需把 KNOWN 断言翻转成普通断言）
//
// 与 test_lexer 分开两个二进制：PD-1 曾是 SIGILL（现已修复），
// 但深嵌套（PD-13）会真的崩，混在一起会连带 lexer 的结论全部看不到。
#include <cstdio>
#include "test_common.hpp"

#ifdef _WIN32
#include <Windows.h>
#endif

namespace Stope {
namespace Test {

void runStmtTests();
void runExprTests();
void runPrecTests();
void runPostfixTests();
void runCustomTests();
void runFlowTests();
void runFoldTests();

}  // namespace Test
}  // namespace Stope

int main() {
  using namespace Stope::Test;
  using Stope::AST::NodeType;

#ifdef _WIN32
  SetConsoleOutputCP(CP_UTF8);
#endif
  // 无缓冲：深嵌套用例崩栈时（PD-13）已打印的进度不会随缓冲区一起丢失。
  setvbuf(stdout, nullptr, _IONBF, 0);

  printf("=== stope parser tests ===\n");
  runStmtTests();
  runExprTests();
  runPrecTests();
  runPostfixTests();
  runCustomTests();
  runFlowTests();
  runFoldTests();

  // NodeType 覆盖率：28 个枚举里 Node / Stmt 两个基类不会作为节点产生，
  // 可产生的是 26 个（含失败路径的裸 Expr 与 BlockStmt 内的 Prog）。
  const int totalTypes = 26;
  printf("\n== NodeType 覆盖: %zu/%d", g_seenNodeTypes.size(), totalTypes);
  if (g_seenNodeTypes.size() < static_cast<size_t>(totalTypes)) {
    printf("  缺失:");
    for (int i = 0; i < 28; ++i) {
      auto t = static_cast<NodeType>(i);
      if (t == NodeType::Node || t == NodeType::Stmt) continue;
      if (!g_seenNodeTypes.count(i)) printf(" %s", nodeName(t));
    }
  }
  printf("\n");

  printf("\n== 已知问题清单\n");
  printf("   PD-1  custom 缺 return 致 SIGILL            : 已修 2026-10-16（K-01 回归保护）\n");
  printf("   PD-2  CustomOpcodeExpr::args 恒空           : 已修 2026-10-16（K-01/K-02）\n");
  printf("   PD-3  输入开头两个 token 拿不到 config      : 已修 2026-10-16（K-04/K-05/K-09）\n");
  printf("   PD-4  break/continue x; 吞掉 x;             : 已修 2026-10-16（S-36）\n");
  printf("   PD-4b if/elif/else/while 缺 { 吞语句        : 已修 2026-10-16（S-26/28/29/32）\n");
  printf("   PD-4c args 0; 吞掉 0;                       : 已修 2026-10-16（X-12）\n");
  printf("   PD-4d f(1, 2 x; y; 吞掉 x;                  : 已修 2026-10-16（F-15/F-16）\n");
  printf("   PD-5  error() 按行去重吞错                  : 已修 2026-10-16（R-02/R-04/R-05）\n");
  printf("   PD-6  顶层孤立 } 静默结束                   : 已修 2026-10-16（S-21）\n");
  printf("   PD-7  ^ 结合性                              : 已改为右结合 2026-10-22（P-06）\n");
  printf("   PD-8  失败表达式返回裸 Expr 节点            : 未修（S-42/L-05/F-17/F-18）\n");
  printf("   PD-11 失败节点的 line 恒为 -1               : 已修 2026-10-16（改用当前 token 行，S-42/F-17）\n");
  printf("   PD-9  链式赋值无法表达                      : 未修（S-43）\n");
  printf("   PD-10 不校验赋值左值                        : 未修（S-44）\n");
  printf("   PD-11b 空括号 () 不支持                     : 未修（F-17）\n");
  printf("   PD-12 每发 1 条 error 计量多 1 次 delete    : 未修（B-08，根因已定位）\n");
  printf("   PD-13 递归无深度上限（解析爆栈）            : 未修（test_parser_depth）\n");
  printf("   PD-13b 析构同样递归                          : 未修（test_parser_depth unary）\n");
  printf("   PD-14 lexer.errors 不合并进 parser.errors   : 未修（R-06）\n");
  printf("   PD-15 tokens 环形缓冲未零初始化             : 未修（无直接断言）\n");
  printf("   PD-16 parseDecicalInteger 拼写              : 已修 2026-10-16（方案A 重构消解）\n");
  printf("   PD-17 x; myop(); 空参数表误报缺 ;           : 已修 2026-10-16（K-11）\n");
  printf("   PD-18 -2^2 一元 - 优先级高于 ^              : 待定（P-07，与参考实现一致）\n");
  printf("   （逐条实际状态以 KNOWN-FAIL / FIXED-PENDING-FLIP 输出为准）\n");

  printf("\n== 汇总\n");
  printf("   断言总数 %d | 失败 %d | 已知缺陷 %d | 待翻转 %d\n", g_total, g_failed,
         g_known, g_flip);

  if (g_failed > 0) {
    printf("RESULT: FAILED\n");
    return 1;
  }
  if (g_flip > 0) {
    printf("RESULT: FLIP-PENDING（缺陷已修，请翻转断言）\n");
    return 2;
  }
  printf("RESULT: PASSED\n");
  return 0;
}
