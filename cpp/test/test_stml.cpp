// STML 测试入口：词法 + 语法跑在一起，统计 TokenType 覆盖，输出已知问题清单。
//
// 退出码：0 = 全部通过；1 = 有普通断言失败；2 = 全部通过但有 FIXED-PENDING-FLIP
//        （缺陷已修，需把 KNOWN 断言翻转成普通断言）
//
// 自成二进制的理由：STML 与 Stope 主语言是两套独立的 Lexer/Parser，
// 只有 Result / 断言框架共用。混进 test_parser 会让两边的失败信息互相干扰。
#include <cstdio>
#include "test_stml_common.hpp"

#ifdef _WIN32
#include <Windows.h>
#endif

namespace Stope::STML::Test {
void runSTMLexerTests();
void runSTMLParserTests();
}

int main() {
  using namespace Stope::Test;
  using namespace Stope::STML::Test;

#ifdef _WIN32
  SetConsoleOutputCP(CP_UTF8);
#endif
  setvbuf(stdout, nullptr, _IONBF, 0);

  printf("=== stml tests (lexer + parser) ===\n");
  runSTMLexerTests();
  runSTMLParserTests();

  printf("\n== 覆盖统计\n");
  const int missingTypes = stmlTypeCoverage();
  printf("   缺失 TokenType %d 种\n", missingTypes);

  printf("\n== 已知问题清单（TD = STML 缺陷/偏离，详见 cpp/docs/stml-test-plan.md §3）\n");
  printf("   TD-1  Word 字符集注释含 '.' 但实现不支持    : 已修（2026-10-18 改注释，SW-04/SW-08）\n");
  printf("   TD-2  属性装在 std::map 里，顺序不保证      : 定夺（PB-06/PB-07 锁字典序）\n");
  printf("   TD-3  元素内文本只有一段，不做多段拼接      : 定夺（PC-01/PC-09）\n");
  printf("   TD-4  Text 状态只认 </ ，<b/> 会被当文本    : 未修（ST-05/PC-09）\n");
  printf("   TD-5  顶层只解析一个元素，忽略尾部内容      : 未修（PA-09）\n");
  printf("   TD-6  lexer.errors 不合并进 parser.errors   : 未修（PE-06/PE-11 分别断言）\n");
  printf("   TD-7  子元素出错后父元素继续解析 → 级联报错 : 未修（PE-12，建议 parseElement 返回 bool）\n");
  printf("   TD-8  scanString 与 scanNevextString 文案差一个句号 : 未修（SS-06/PE-11）\n");
  printf("   TD-9  Xml 属性字符串不做转义                 : 未修（SS-08）\n");
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
