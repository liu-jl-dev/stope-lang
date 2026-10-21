#include "test_common.hpp"

namespace Stope {
namespace Test {

// T3 整数 + T4 浮点
void runNumberTests() {
  section("T3 整数 (LEX-N-I)");

  {  // I-01 十进制与前导零
    auto r = lexAll(u"0 00 0009");
    EXPECT_COUNT(r, 4, "I-01");
    EXPECT_INT(r, 0, 0, "I-01");
    EXPECT_INT(r, 1, 0, "I-01");
    EXPECT_INT(r, 2, 9, "I-01");
    EXPECT_PARSED(r, 2, u"0009", "I-01");
    EXPECT_ERR_COUNT(r, 0, "I-01");
  }
  {  // I-02 下划线
    auto r = lexAll(u"1_000 1_ 0_1");
    EXPECT_COUNT(r, 4, "I-02");
    EXPECT_INT(r, 0, 1000, "I-02");
    EXPECT_PARSED(r, 0, u"1000", "I-02");
    EXPECT_INT(r, 1, 1, "I-02");
    EXPECT_PARSED(r, 1, u"1", "I-02");
    EXPECT_INT(r, 2, 1, "I-02");
    EXPECT_PARSED(r, 2, u"01", "I-02");
  }
  {  // I-03 数字紧跟标识符
    auto r = lexAll(u"123abc");
    EXPECT_SEQ(r, "Integer Ident Eof", "I-03");
    EXPECT_INT(r, 0, 123, "I-03");
    EXPECT_PARSED(r, 1, u"abc", "I-03");
  }
  {  // I-04 十进制边界值
    auto r = lexAll(u"9223372036854775807");
    EXPECT_INT(r, 0, 9223372036854775807LL, "I-04");
    EXPECT_ERR_COUNT(r, 0, "I-04");
  }
  {  // I-05 十进制溢出
    auto r = lexAll(u"9223372036854775808");
    EXPECT_TYPE(r, 0, TokenType::Invalid, "I-05");
    EXPECT_ERR_HAS(r, "invalid integer.", "I-05");
  }
  {  // I-06 各进制取值（D-1 修复点）
    auto r = lexAll(u"0x1F 0X1f 0b101 0B101 0o17 0O17 0xFF");
    EXPECT_COUNT(r, 8, "I-06");
    EXPECT_INT(r, 0, 31, "I-06");
    EXPECT_INT(r, 1, 31, "I-06");
    EXPECT_INT(r, 2, 5, "I-06");
    EXPECT_INT(r, 3, 5, "I-06");
    EXPECT_INT(r, 4, 15, "I-06");
    EXPECT_INT(r, 5, 15, "I-06");
    EXPECT_INT(r, 6, 255, "I-06");
    EXPECT_LEX(r, 0, u"0x1F", "I-06");
    EXPECT_ERR_COUNT(r, 0, "I-06");
  }
  {  // I-07 各进制溢出（D-2 修复点）
    auto r = lexAll(u"0x7FFFFFFFFFFFFFFF");
    EXPECT_INT(r, 0, 9223372036854775807LL, "I-07");
    auto r2 = lexAll(u"0xFFFFFFFFFFFFFFFF");
    EXPECT_TYPE(r2, 0, TokenType::Invalid, "I-07");
    EXPECT_ERR_HAS(r2, "invalid integer.", "I-07");
    auto r3 = lexAll(u"0xFFFFFFFFFFFFFFFFF");
    EXPECT_TYPE(r3, 0, TokenType::Invalid, "I-07");
  }
  {  // I-08 空前缀（D-4 修复点）
    auto r = lexAll(u"0b 0x 0o 0b_ 0x_ 0o_");
    EXPECT_COUNT(r, 7, "I-08");
    for (int i = 0; i < 6; ++i) EXPECT_TYPE(r, i, TokenType::Invalid, "I-08");
    EXPECT_ERR_COUNT(r, 6, "I-08");
    EXPECT_ERR_HAS(r, "invalid integer.", "I-08");
  }
  {  // I-09 前缀后仅下划线（按笔记取舍：延后到转换阶段判定，属合法）
    auto r = lexAll(u"0b_1 0x_1 0o_7");
    EXPECT_COUNT(r, 4, "I-09");
    EXPECT_INT(r, 0, 1, "I-09");
    EXPECT_INT(r, 1, 1, "I-09");
    EXPECT_INT(r, 2, 7, "I-09");
    EXPECT_ERR_COUNT(r, 0, "I-09");
  }
  {  // I-10 前缀后非法字符：分词边界
    auto r = lexAll(u"0xG");
    EXPECT_SEQ(r, "Invalid Ident Eof", "I-10");
    auto r2 = lexAll(u"0b2");
    EXPECT_SEQ(r2, "Invalid Integer Eof", "I-10");
    auto r3 = lexAll(u"0o8");
    EXPECT_SEQ(r3, "Invalid Integer Eof", "I-10");
  }

  section("T4 浮点 (LEX-N-F)");

  {  // F-01 基本小数
    auto r = lexAll(u"1.0 1.5 .5 0.0");
    EXPECT_COUNT(r, 5, "F-01");
    EXPECT_DBL(r, 0, 1.0, "F-01");
    EXPECT_DBL(r, 1, 1.5, "F-01");
    EXPECT_DBL(r, 2, 0.5, "F-01");
    EXPECT_DBL(r, 3, 0.0, "F-01");
    EXPECT_ERR_COUNT(r, 0, "F-01");
  }
  {  // F-02 指数（含指数一律浮点）
    auto r = lexAll(u"1e5 1E5 1e+3 1E-3 .5e3");
    EXPECT_COUNT(r, 6, "F-02");
    for (int i = 0; i < 5; ++i) EXPECT_TYPE(r, i, TokenType::Float, "F-02");
    EXPECT_DBL(r, 0, 100000.0, "F-02");
    EXPECT_DBL(r, 1, 100000.0, "F-02");
    EXPECT_DBL(r, 2, 1000.0, "F-02");
    EXPECT_DBL(r, 3, 0.001, "F-02");
    EXPECT_DBL(r, 4, 500.0, "F-02");
  }
  {  // F-03 小数部分下划线
    auto r = lexAll(u"1_.5");
    EXPECT_DBL(r, 0, 1.5, "F-03");
    EXPECT_PARSED(r, 0, u"1.5", "F-03");
  }
  {  // F-04 1..2 切成两个浮点
    auto r = lexAll(u"1..2");
    EXPECT_COUNT(r, 3, "F-04");
    EXPECT_DBL(r, 0, 1.0, "F-04");
    EXPECT_DBL(r, 1, 0.2, "F-04");
  }
  {  // F-05 1.5.5 切成两个浮点
    auto r = lexAll(u"1.5.5");
    EXPECT_COUNT(r, 3, "F-05");
    EXPECT_DBL(r, 0, 1.5, "F-05");
    EXPECT_DBL(r, 1, 0.5, "F-05");
  }
  {  // F-06 指数后无数字（D-3 修复点）
    auto r = lexAll(u"1e 1e+ .5e 1ex");
    EXPECT_COUNT(r, 6, "F-06");
    for (int i = 0; i < 4; ++i) EXPECT_TYPE(r, i, TokenType::Invalid, "F-06");
    EXPECT_TYPE(r, 4, TokenType::Ident, "F-06");
    EXPECT_ERR_COUNT(r, 4, "F-06");
    EXPECT_ERR_HAS(r, "invalid float.", "F-06");
  }
  {  // F-07 非法浮点
    auto r = lexAll(u". .e5 ._");
    EXPECT_COUNT(r, 4, "F-07");
    for (int i = 0; i < 3; ++i) EXPECT_TYPE(r, i, TokenType::Invalid, "F-07");
    EXPECT_ERR_COUNT(r, 3, "F-07");
  }
  {  // F-08 小数部分以 _ 结尾：当前仍接受（D-7 未修）
    auto r = lexAll(u"1._");
    EXPECT_DBL(r, 0, 1.0, "F-08-current");
    KNOWN("D-7", r.at(0).type == TokenType::Invalid, "F-08");
  }
  {  // F-09 浮点上溢/下溢
    auto r = lexAll(u"1e999 1e-999");
    EXPECT_COUNT(r, 3, "F-09");
    EXPECT_TYPE(r, 0, TokenType::Invalid, "F-09");
    EXPECT_TYPE(r, 1, TokenType::Invalid, "F-09");
    EXPECT_ERR_COUNT(r, 2, "F-09");
  }
}

}  // namespace Test
}  // namespace Stope
