#include "test_common.hpp"

namespace Stope {
namespace Test {

// T10 自定义指令 + T13 端到端 token 流
void runMiscTests() {
  section("T10 自定义指令 (LEX-C)");

  {  // C-01 不传配置也能正常工作
    auto r = lexAll(u"myop");
    EXPECT_TYPE(r, 0, TokenType::Ident, "C-01");
    EXPECT_ERR_COUNT(r, 0, "C-01");
  }
  {
    CustomOpcodeConfig cfg;
    std::u16string n1 = u"myop";
    EXPECT(cfg.addCustomOpcode(n1, 100, 2) == Result::Success, "C-02");
    {  // C-02 命中自定义指令
      auto r = lexAll(u"myop", &cfg);
      EXPECT_TYPE(r, 0, TokenType::Custom, "C-02");
      EXPECT_PARSED(r, 0, u"myop", "C-02");
    }
    {  // C-04 未注册仍是标识符
      auto r = lexAll(u"other", &cfg);
      EXPECT_TYPE(r, 0, TokenType::Ident, "C-04");
    }
    {  // C-05 关键字优先于自定义指令
      std::u16string nIf = u"if";
      cfg.addCustomOpcode(nIf, 101, 1);
      auto r = lexAll(u"if", &cfg);
      EXPECT_TYPE(r, 0, TokenType::If, "C-05");
    }
    {  // C-06 重复注册
      std::u16string dup = u"myop";
      EXPECT(cfg.addCustomOpcode(dup, 102, 1) == Result::DuplicateWithBuiltinOpcode, "C-06");
    }
  }
  {  // C-03 含 ':' 的自定义指令名（含空白写法）
    CustomOpcodeConfig cfg;
    std::u16string n = u"a:b";
    cfg.addCustomOpcode(n, 103, 1);
    auto r1 = lexAll(u"a:b", &cfg);
    EXPECT_TYPE(r1, 0, TokenType::Custom, "C-03");
    auto r2 = lexAll(u"a : b", &cfg);
    EXPECT_TYPE(r2, 0, TokenType::Custom, "C-03");
  }

  section("T13 端到端 token 流 (LEX-E2E)");

  {  // G-01
    auto r = lexAll(u"let a = 1 + 2 * 3;");
    EXPECT_SEQ(r, "Let Ident Assign Integer Add Integer Mul Integer Semi Eof", "G-01");
    EXPECT_ERR_COUNT(r, 0, "G-01");
  }
  {  // G-02
    auto r = lexAll(u"if a >= 1 and b != 2 { return; } elif c { } else { }");
    EXPECT_SEQ(r,
               "If Ident GE Integer And Ident NE Integer LBrace Return Semi RBrace "
               "Elif Ident LBrace RBrace Else LBrace RBrace Eof",
               "G-02");
  }
  {  // G-03
    auto r = lexAll(u"while true { break; continue; }");
    EXPECT_SEQ(r, "While True LBrace Break Semi Continue Semi RBrace Eof", "G-03");
  }
  {  // G-04 各进制与字面量混排
    auto r = lexAll(u"export foo:bar = \"s\", 'x', null, argc, args;");
    EXPECT_SEQ(r,
               "Export Ident Assign String Comma BinArr Comma Null Comma Argc Comma Args Semi Eof",
               "G-04");
    EXPECT_PARSED(r, 0, u"export", "G-04");
    EXPECT_PARSED(r, 1, u"foo:bar", "G-04");
  }
  {  // G-05 混合片段：注释、空行、跨行标识符、行号
    auto r = lexAll(u"// head\nlet a\n:b = 0x10;\n\n/* mid */ return .5e2;");
    EXPECT_SEQ(r, "Let Ident Assign Integer Semi Return Float Semi Eof", "G-05");
    EXPECT_PARSED(r, 1, u"a:b", "G-05");
    EXPECT_INT(r, 3, 16, "G-05");
    EXPECT_DBL(r, 6, 50.0, "G-05");
    EXPECT_LINE(r, 6, 5, "G-05");
    EXPECT_ERR_COUNT(r, 0, "G-05");
  }
}

}  // namespace Test
}  // namespace Stope
