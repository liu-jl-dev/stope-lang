// lexer 测试入口：跑全部用例，统计 TokenType 覆盖，输出已知问题清单。
//
// 退出码：0 = 全部通过；1 = 有普通断言失败；2 = 全部通过但有 FIXED-PENDING-FLIP
//        （缺陷已修，需把 KNOWN 断言翻转成普通断言）
#include <cstdio>
#include "test_common.hpp"

#ifdef _WIN32
#include <Windows.h>
#endif

namespace Stope {
namespace Test {

void runNumberTests();
void runIdentTests();
void runStringTests();
void runPunctTests();
void runFlowTests();
void runMiscTests();

}  // namespace Test
}  // namespace Stope

int main() {
  using namespace Stope::Test;

#ifdef _WIN32
  SetConsoleOutputCP(CP_UTF8);
#endif

  printf("=== stope lexer tests ===\n");
  runNumberTests();
  runIdentTests();
  runStringTests();
  runPunctTests();
  runFlowTests();
  runMiscTests();

  // TokenType 覆盖率：47 个类型每个至少被产生过一次
  const int totalTypes = 47;
  printf("\n== TokenType 覆盖: %zu/%d", g_seenTypes.size(), totalTypes);
  if (g_seenTypes.size() < static_cast<size_t>(totalTypes)) {
    printf("  缺失:");
    for (int i = 0; i < totalTypes; ++i)
      if (!g_seenTypes.count(i))
        printf(" %s", tokenName(static_cast<Stope::TokenType>(i)));
  }
  printf("\n");

  printf("\n== 已知问题清单\n");
  printf("   D-6  未闭合块注释静默到 EOF          : %s\n",
         g_seenTypes.count(static_cast<int>(Stope::TokenType::Eof))
             ? "见上方 KNOWN-FAIL"
             : "");
  printf("   D-7  1._ 小数部分以 _ 结尾仍接受     : 见上方 KNOWN-FAIL\n");
  printf("   D-8  标识符/关键字 lexeme 恒空       : 见上方 KNOWN-FAIL\n");
  printf("   D-9  标点 token lexeme/parsed 恒空   : 见上方 KNOWN-FAIL\n");
  printf("   D-13 跨行字符串不累加 line           : 见上方 KNOWN-FAIL\n");
  printf("   D-14 非法转义后未置 Invalid          : 见上方 KNOWN-FAIL\n");
  printf("   （逐条实际状态以 KNOWN-FAIL / FIXED-PENDING-FLIP 输出为准）\n");

  printf("\n== 汇总\n");
  printf("   断言总数 %d | 失败 %d | 已知缺陷 %d | 待翻转 %d\n", g_total,
         g_failed, g_known, g_flip);

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
