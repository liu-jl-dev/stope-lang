#include "test_common.hpp"

namespace Stope {
namespace Test {

// T7 字符串 + T8 二进制数组
void runStringTests() {
  section("T7 字符串 (LEX-S)");

  {  // S-01/S-02 基本与空串
    auto r = lexAll(u"\"abc\"");
    EXPECT_COUNT(r, 2, "S-01");
    EXPECT_TYPE(r, 0, TokenType::String, "S-01");
    EXPECT_LEX(r, 0, u"abc", "S-01");
    auto r2 = lexAll(u"\"\"");
    EXPECT_TYPE(r2, 0, TokenType::String, "S-02");
    EXPECT_LEX(r2, 0, u"", "S-02");
  }
  {  // S-03/S-04 转义引号与反斜杠不终止字符串
    auto r = lexAll(u"\"a\\\"b\"");
    EXPECT_COUNT(r, 2, "S-03");
    EXPECT_TYPE(r, 0, TokenType::String, "S-03");
    EXPECT_LEX(r, 0, u"a\\\"b", "S-03");
    auto r2 = lexAll(u"\"a\\\\b\"");
    EXPECT_TYPE(r2, 0, TokenType::String, "S-04");
  }
  {  // S-05 未闭合字符串（D-10 已修：改判 Invalid，与 BinArr 一致）
    auto r = lexAll(u"\"abc");
    EXPECT_TYPE(r, 0, TokenType::Invalid, "S-05");
    EXPECT_ERR_HAS(r, "unclosed string literal.", "S-05");
  }
  {  // S-06 反斜杠结尾：只报一次
    auto r = lexAll(u"\"abc\\");
    EXPECT_ERR_COUNT(r, 1, "S-06");
    EXPECT_ERR_HAS(r, "unclosed string literal.", "S-06");
  }
  {  // S-07/S-08 转义解码（escapeString 已接线）
    auto r = lexAll(u"\"a\\nb\"");
    EXPECT_PARSED(r, 0, u"a\nb", "S-08");
    auto r2 = lexAll(u"\"a\\qb\"");
    EXPECT_ERR_HAS(r2, "invalid escape character.", "S-07");
  }
  {  // S-09 非法转义后 parsed 截断且未置 Invalid（D-14 未修）
    auto r = lexAll(u"\"a\\qb\"");
    EXPECT_TYPE(r, 0, TokenType::String, "S-09-current");
    KNOWN("D-14", r.at(0).type == TokenType::Invalid, "S-09");
  }

  section("T8 二进制数组 '...' (LEX-B)");

  {  // B-01/B-02
    auto r = lexAll(u"'abc'");
    EXPECT_TYPE(r, 0, TokenType::BinArr, "B-01");
    EXPECT_LEX(r, 0, u"abc", "B-01");
    auto r2 = lexAll(u"''");
    EXPECT_TYPE(r2, 0, TokenType::BinArr, "B-02");
    EXPECT_LEX(r2, 0, u"", "B-02");
  }
  {  // B-03 相邻两个不合并
    auto r = lexAll(u"'a' 'b'");
    EXPECT_SEQ(r, "BinArr BinArr Eof", "B-03");
  }
  {  // B-04 未闭合
    auto r = lexAll(u"'abc");
    EXPECT_TYPE(r, 0, TokenType::Invalid, "B-04");
    EXPECT_ERR_HAS(r, "unclosed binary array.", "B-04");
    EXPECT_TYPE(r, 1, TokenType::Eof, "B-04");
  }
  {  // B-05 跨行累加 line
    auto r = lexAll(u"'a\nb' c");
    EXPECT_TYPE(r, 0, TokenType::BinArr, "B-05");
    EXPECT_LINE(r, 1, 2, "B-05");
  }
  {  // B-06 单引号内无转义机制
    auto r = lexAll(u"'\\'' x");
    EXPECT_TYPE(r, 0, TokenType::BinArr, "B-06");
    EXPECT_LEX(r, 0, u"\\", "B-06");
    EXPECT_TYPE(r, 1, TokenType::Invalid, "B-06");
    EXPECT_ERR_HAS(r, "unclosed binary array.", "B-06");
  }
}

}  // namespace Test
}  // namespace Stope
