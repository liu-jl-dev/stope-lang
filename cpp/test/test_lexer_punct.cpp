#include "test_common.hpp"

namespace Stope {
namespace Test {

// T9 标点与运算符
void runPunctTests() {
  section("T9 标点与运算符 (LEX-P)");

  {  // P-01 分隔符
    auto r = lexAll(u", ; ( ) [ ] { }");
    EXPECT_SEQ(r, "Comma Semi LParen RParen LBrack RBrack LBrace RBrace Eof", "P-01");
  }
  {  // P-02 算术运算符
    auto r = lexAll(u"+ - * / % ^");
    EXPECT_SEQ(r, "Add Sub Mul Div Mod Pow Eof", "P-02");
  }
  {  // P-03 赋值与相等
    auto r = lexAll(u"= == ===");
    EXPECT_SEQ(r, "Assign EQ EQ Assign Eof", "P-03");
  }
  {  // P-04 非与不等
    auto r = lexAll(u"! != !==");
    EXPECT_SEQ(r, "Not NE NE Assign Eof", "P-04");
  }
  {  // P-05 比较运算符：两字符优先
    auto r = lexAll(u"< <= > >=");
    EXPECT_SEQ(r, "LT LE GT GE Eof", "P-05");
  }
  {  // P-06 逻辑运算两种写法
    auto r = lexAll(u"&& and || or");
    EXPECT_SEQ(r, "And And Or Or Eof", "P-06");
  }
  {  // P-07 单个 & 与 | 非法
    auto r = lexAll(u"& |");
    EXPECT_SEQ(r, "Invalid Invalid Eof", "P-07");
    EXPECT_ERR_COUNT(r, 2, "P-07");
    EXPECT_ERR_HAS(r, "unknown token.", "P-07");
  }
  {  // P-08 非语言字符：每个码元一个 Invalid，且必须推进（不死循环）
    auto r = lexAll(u"@ $ # ~ ?");
    EXPECT_COUNT(r, 6, "P-08");
    for (int i = 0; i < 5; ++i) EXPECT_TYPE(r, i, TokenType::Invalid, "P-08");
    EXPECT_ERR_COUNT(r, 5, "P-08");
    auto r2 = lexAll(std::u16string(2, u'\x4E2D'));  // "中文" 两个 UTF-16 码元
    EXPECT_COUNT(r2, 3, "P-08");
    EXPECT_ERR_COUNT(r2, 2, "P-08");
  }
  {  // P-09 标点 token 的 lexeme/parsed 均为空（D-9 未修）
    auto r = lexAll(u"==");
    EXPECT(r.at(0).lexeme.empty(), "P-09-current");
    KNOWN("D-9", r.at(0).lexeme == u"==", "P-09");
  }
  {  // P-10 无空白相邻标点不粘连
    auto r = lexAll(u"()");
    EXPECT_COUNT(r, 3, "P-10");
    EXPECT_TYPE(r, 0, TokenType::LParen, "P-10");
    EXPECT_TYPE(r, 1, TokenType::RParen, "P-10");
  }
}

}  // namespace Test
}  // namespace Stope
