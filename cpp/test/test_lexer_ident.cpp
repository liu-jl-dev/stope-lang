#include "test_common.hpp"

namespace Stope {
namespace Test {

// T5 标识符与 ':' 命名空间 + T6 关键字
void runIdentTests() {
  section("T5 标识符与 ':' 命名空间 (LEX-I)");

  {  // D-01 合法标识符
    auto r = lexAll(u"abc _x A9 _ __9");
    EXPECT_COUNT(r, 6, "D-01");
    for (int i = 0; i < 5; ++i) EXPECT_TYPE(r, i, TokenType::Ident, "D-01");
    EXPECT_PARSED(r, 0, u"abc", "D-01");
    EXPECT_PARSED(r, 3, u"_", "D-01");
    EXPECT_PARSED(r, 4, u"__9", "D-01");
    EXPECT_ERR_COUNT(r, 0, "D-01");
  }
  {  // D-02 数字开头不是标识符
    auto r = lexAll(u"9a");
    EXPECT_SEQ(r, "Integer Ident Eof", "D-02");
  }
  {  // D-03/D-04 ':' 分组
    auto r = lexAll(u"a:b");
    EXPECT_COUNT(r, 2, "D-03");
    EXPECT_PARSED(r, 0, u"a:b", "D-03");
    auto r2 = lexAll(u"a:b:c");
    EXPECT_PARSED(r2, 0, u"a:b:c", "D-04");
  }
  {  // D-05 ':' 前后允许空白、换行、注释
    auto r1 = lexAll(u"a : b");
    EXPECT_PARSED(r1, 0, u"a:b", "D-05");
    auto r2 = lexAll(u"a\n:b");
    EXPECT_COUNT(r2, 2, "D-05");
    EXPECT_PARSED(r2, 0, u"a:b", "D-05");
    auto r3 = lexAll(u"a // c\n:b");
    EXPECT_PARSED(r3, 0, u"a:b", "D-05");
    auto r4 = lexAll(u"a :/*x*/ b");
    EXPECT_PARSED(r4, 0, u"a:b", "D-05");
  }
  {  // D-06 a::b 的错误恢复
    auto r = lexAll(u"a::b");
    EXPECT_SEQ(r, "Invalid Invalid Ident Eof", "D-06");
    EXPECT_PARSED(r, 0, u"a:", "D-06");
    EXPECT_ERR_HAS(r, "unclosed identifier.", "D-06");
    EXPECT_ERR_HAS(r, "unknown token.", "D-06");
  }
  {  // D-07 a:1
    auto r = lexAll(u"a:1");
    EXPECT_SEQ(r, "Invalid Integer Eof", "D-07");
    EXPECT_ERR_HAS(r, "unclosed identifier.", "D-07");
  }
  {  // D-08 输入末尾的 ':'
    auto r = lexAll(u"a:");
    EXPECT_TYPE(r, 0, TokenType::Invalid, "D-08");
    EXPECT_ERR_HAS(r, "unclosed identifier.", "D-08");
  }
  {  // D-09 标识符 lexeme 恒为空（D-8 未修）
    auto r = lexAll(u"abc");
    EXPECT(r.at(0).lexeme.empty(), "D-09-current");
    KNOWN("D-8", r.at(0).lexeme == u"abc", "D-09");
  }

  section("T6 关键字 (LEX-K)");

  {  // K-01 全部关键字映射
    struct { const char16_t* text; TokenType type; } cases[] = {
        {u"idiv", TokenType::IDiv},         {u"not", TokenType::Not},
        {u"and", TokenType::And},           {u"or", TokenType::Or},
        {u"if", TokenType::If},             {u"elif", TokenType::Elif},
        {u"else", TokenType::Else},         {u"let", TokenType::Let},
        {u"return", TokenType::Return},     {u"while", TokenType::While},
        {u"break", TokenType::Break},       {u"continue", TokenType::Continue},
        {u"null", TokenType::Null},         {u"false", TokenType::False},
        {u"true", TokenType::True},         {u"args", TokenType::Args},
        {u"argc", TokenType::Argc},         {u"export", TokenType::Export},
    };
    for (const auto& c : cases) {
      auto r = lexAll(std::u16string(c.text));
      EXPECT_TYPE(r, 0, c.type, "K-01");
    }
  }
  {  // K-02 大小写敏感、全字匹配
    auto r = lexAll(u"IF If iff if2");
    EXPECT_COUNT(r, 5, "K-02");
    for (int i = 0; i < 4; ++i) EXPECT_TYPE(r, i, TokenType::Ident, "K-02");
  }
  {  // K-03 关键字与符号写法同类型
    auto kw = lexAll(u"not and or");
    auto sym = lexAll(u"! && ||");
    EXPECT_TYPE(kw, 0, TokenType::Not, "K-03");
    EXPECT_TYPE(kw, 1, TokenType::And, "K-03");
    EXPECT_TYPE(kw, 2, TokenType::Or, "K-03");
    EXPECT_TYPE(sym, 0, TokenType::Not, "K-03");
    EXPECT_TYPE(sym, 1, TokenType::And, "K-03");
    EXPECT_TYPE(sym, 2, TokenType::Or, "K-03");
  }
}

}  // namespace Test
}  // namespace Stope
