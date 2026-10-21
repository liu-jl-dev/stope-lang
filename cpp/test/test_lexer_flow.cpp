#include "test_common.hpp"

namespace Stope {
namespace Test {

// T1 空白与注释 + T2 行号 + T11 错误处理 + T12 状态生命周期 + T14 健壮性
void runFlowTests() {
  section("T1 空白字符与注释 (LEX-W)");

  {  // W-01 空输入
    auto r = lexAll(u"");
    EXPECT_COUNT(r, 1, "W-01");
    EXPECT_TYPE(r, 0, TokenType::Eof, "W-01");
    EXPECT_ERR_COUNT(r, 0, "W-01");
  }
  {  // W-02 纯空白（含 \v \f \r）
    auto r = lexAll(u"   \t\v\f\r\n  ");
    EXPECT_COUNT(r, 1, "W-02");
    EXPECT_TYPE(r, 0, TokenType::Eof, "W-02");
  }
  {  // W-03/W-04 单行注释
    auto r = lexAll(u"a // c\nb");
    EXPECT_SEQ(r, "Ident Ident Eof", "W-03");
    EXPECT_LINE(r, 0, 1, "W-03");
    EXPECT_LINE(r, 1, 2, "W-03");
    auto r2 = lexAll(u"a // c");
    EXPECT_SEQ(r2, "Ident Eof", "W-04");
  }
  {  // W-05/W-06 多行注释
    auto r = lexAll(u"a /* x */ b");
    EXPECT_SEQ(r, "Ident Ident Eof", "W-05");
    auto r2 = lexAll(u"a /*\nx\n*/ b");
    EXPECT_SEQ(r2, "Ident Ident Eof", "W-06");
    EXPECT_LINE(r2, 1, 3, "W-06");
  }
  {  // W-07 块注释不嵌套
    auto r = lexAll(u"/* a /* b */ c");
    EXPECT_SEQ(r, "Ident Eof", "W-07");
  }
  {  // W-08 未闭合块注释：当前静默到 EOF（D-6 未修）
    auto r = lexAll(u"/* abc");
    EXPECT_COUNT(r, 1, "W-08-current");
    EXPECT_TYPE(r, 0, TokenType::Eof, "W-08-current");
    KNOWN("D-6", !r.errors.empty(), "W-08");
  }
  {  // W-09/W-10 退化注释
    auto r = lexAll(u"//");
    EXPECT_COUNT(r, 1, "W-09");
    auto r2 = lexAll(u"/*/");
    EXPECT_COUNT(r2, 1, "W-10");
    EXPECT_TYPE(r2, 0, TokenType::Eof, "W-10");
  }

  section("T2 行号 (LEX-L)");

  {  // L-01 只有 \n 计数（\r 不计数）
    auto r = lexAll(u"1\n2\n\n3\r\n4");
    EXPECT_COUNT(r, 5, "L-01");
    EXPECT_LINE(r, 0, 1, "L-01");
    EXPECT_LINE(r, 1, 2, "L-01");
    EXPECT_LINE(r, 2, 4, "L-01");
    EXPECT_LINE(r, 3, 5, "L-01");
  }
  {  // L-02 尾部换行
    auto r = lexAll(u"a\nb\n");
    EXPECT_LINE(r, 2, 3, "L-02");
  }
  {  // L-03 跨行 BinArr 累加行
    auto r = lexAll(u"'a\nb' c");
    EXPECT_LINE(r, 1, 2, "L-03");
  }
  {  // L-04 跨行字符串不累加行（D-13 未修）
    auto r = lexAll(u"\"a\nb\" c");
    EXPECT_LINE(r, 1, 1, "L-04-current");
    KNOWN("D-13", r.at(1).line == 2, "L-04");
  }
  {  // L-05 跨行标识符
    auto r = lexAll(u"a\n:b c");
    EXPECT_PARSED(r, 0, u"a:b", "L-05");
    EXPECT_LINE(r, 1, 2, "L-05");
  }
  {  // L-06 错误行号
    auto r = lexAll(u"1\n@");
    EXPECT_LINE(r, 1, 2, "L-06");
    EXPECT_ERR_HAS(r, "line 2: unknown token.", "L-06");
  }

  section("T11 错误处理与恢复 (LEX-E)");

  {  // E-01 七条 error 文案全覆盖
    struct { std::u16string src; const char* msg; } cases[] = {
        {u"@", "unknown token."},
        {u"\"abc", "unclosed string literal."},
        {u"'abc", "unclosed binary array."},
        {u"9223372036854775808", "invalid integer."},
        {u".", "invalid float."},
        {u"a:", "unclosed identifier."},
        {u"\"a\\qb\"", "invalid escape character."},
    };
    for (const auto& c : cases) {
      auto r = lexAll(c.src);
      EXPECT_ERR_HAS(r, c.msg, "E-01");
    }
  }
  {  // E-02 错误累加且带行号前缀
    auto r = lexAll(u"@ @ @");
    EXPECT_ERR_COUNT(r, 3, "E-02");
    EXPECT(r.errors[0].find("line 1: ") == 0, "E-02");
  }
  {  // E-03 出错后必须继续推进到 Eof（不死循环）
    auto r = lexAll(u"@$#~?@$#");
    EXPECT_TYPE(r, r.size() - 1, TokenType::Eof, "E-03");
  }
  {  // E-04 代理对（emoji）按 UTF-16 码元计数
    std::u16string emoji = u"\U0001F600";  // 一对代理项
    auto r = lexAll(emoji);
    EXPECT_ERR_COUNT(r, 2, "E-04");
  }

  section("T12 Token 状态与生命周期 (LEX-T)");

  {  // T12-1 复用同一个 Token 变量（parser 的环形缓冲用法）不得串味
    std::u16string src = u"alpha beta gamma";
    Lexer lx(src);
    Token t;
    lx.NextToken(t);
    EXPECT(t.parsed == u"alpha", "T12-1");
    lx.NextToken(t);
    EXPECT(t.parsed == u"beta", "T12-1");
    lx.NextToken(t);
    EXPECT(t.parsed == u"gamma", "T12-1");
    lx.NextToken(t);
    EXPECT(t.parsed.empty() && t.type == TokenType::Eof, "T12-1");
  }
  {  // T12-2 复用 Lexer 实例跑第二条输入：不崩即可（不重置状态，非支持用法）
    std::u16string a = u"abc";
    std::u16string b = u"123";
    Lexer lx(a);
    Token t;
    lx.NextToken(t);
    lx.input = b;
    lx.NextToken(t);
    EXPECT(t.type != TokenType::Invalid, "T12-2");
  }
  {  // T12-4 Token 值初始化
    Token t{};
    EXPECT(t.type == TokenType::Invalid && t.line == 0 && t.lexeme.empty(), "T12-4");
  }
  {  // T12-3 lexeme 在输入存活期内可读
    std::u16string src = u"abc";
    auto r = lexAll(src);
    EXPECT(r.at(0).parsed == u"abc", "T12-3");
  }

  section("T14 健壮性下限 (LEX-R)");

  {  // R-01 空/空白/纯注释
    auto r1 = lexAll(u"");
    auto r2 = lexAll(u"   ");
    auto r3 = lexAll(u"// x\n/* y */");
    EXPECT_TYPE(r1, 0, TokenType::Eof, "R-01");
    EXPECT_TYPE(r2, 0, TokenType::Eof, "R-01");
    EXPECT_TYPE(r3, 0, TokenType::Eof, "R-01");
    EXPECT_ERR_COUNT(r3, 0, "R-01");
  }
  {  // R-02 超长标识符
    auto r = lexAll(std::u16string(10000, u'a'));
    EXPECT_COUNT(r, 2, "R-02");
    EXPECT_TYPE(r, 0, TokenType::Ident, "R-02");
  }
  {  // R-03 深嵌套括号不栈溢出
    auto r = lexAll(std::u16string(1000, u'('));
    EXPECT_COUNT(r, 1001, "R-03");
    EXPECT_ERR_COUNT(r, 0, "R-03");
  }
  {  // R-04 未闭合引号交替：不死循环、error 数有限
    std::u16string s;
    for (int i = 0; i < 100; ++i) {
      s += u"\"";
      s += u"'";
    }
    auto r = lexAll(s);
    EXPECT_TYPE(r, r.size() - 1, TokenType::Eof, "R-04");
    EXPECT(r.errors.size() < 500, "R-04");
  }
  {  // R-05 孤立 ':'
    auto r = lexAll(u":");
    EXPECT_TYPE(r, 0, TokenType::Invalid, "R-05");
    EXPECT_ERR_HAS(r, "unknown token.", "R-05");
  }
}

}  // namespace Test
}  // namespace Stope
