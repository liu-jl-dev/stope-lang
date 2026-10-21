// STML 词法分析用例（STML-LEX）
//
// 用例 ID 前缀：SX = Xml 状态、SW = Word 边界、SS = 字符串、ST = Text 状态、
//               SN = Nevext 状态、SP = Stope 状态、SL = 行号、SE = 错误、SR = 健壮性。
// 期望值一律来自 C++ 侧实测（权威实现），不手推。

#include "test_stml_common.hpp"

namespace Stope::STML::Test {

// ---------------------------------------------------------------- SX Xml 状态
static void testXml() {
  Stope::Test::section("SX Xml 状态：标签骨架与标点");

  auto r = slexAll(u"<a>");
  EXPECT_SSEQ(r, "LAngle Word RAngle Eof", "SX-01");
  EXPECT_STOK_LEX(r, 1, u"a", "SX-01");

  r = slexAll(u"</a>");
  EXPECT_SSEQ(r, "CLAngle Word RAngle Eof", "SX-02");

  r = slexAll(u"<a/>");
  EXPECT_SSEQ(r, "LAngle Word CRAngle Eof", "SX-03");

  r = slexAll(u"<a id=\"x\">");
  EXPECT_SSEQ(r, "LAngle Word Word EQ String RAngle Eof", "SX-04");
  EXPECT_STOK_LEX(r, 4, u"x", "SX-04");

  r = slexAll(u"<a id='x'>");
  EXPECT_SSEQ(r, "LAngle Word Word EQ String RAngle Eof", "SX-05");
  EXPECT_STOK_LEX(r, 4, u"x", "SX-05");

  r = slexAll(u"<!-- 注释 --><a>");
  EXPECT_SSEQ(r, "LAngle Word RAngle Eof", "SX-06");
  EXPECT_SERR_COUNT(r, 0, "SX-06");

  r = slexAll(u"<!--\n跨行\n--><a>");
  EXPECT_SSEQ(r, "LAngle Word RAngle Eof", "SX-07");
  EXPECT_STOK_LINE(r, 0, 3, "SX-07");

  // Xml 状态下的裸文本会被切成 Word（元素内文本要切到 Text 状态才对）
  r = slexAll(u"hello");
  EXPECT_SSEQ(r, "Word Eof", "SX-08");
  EXPECT_STOK_LEX(r, 0, u"hello", "SX-08");

  // 意外字符：报错并消费 1 个码元（防死循环的硬保障）
  r = slexAll(u"@");
  EXPECT_SSEQ(r, "Invalid Eof", "SX-09");
  EXPECT_SERR_COUNT(r, 1, "SX-09");
  EXPECT_SERR_HAS(r, "unexpected character.", "SX-09");

  // '1' 不是 Word 首字符 → 1 个 Invalid（只消费 1 个码元）
  r = slexAll(u"<1>");
  EXPECT_SSEQ(r, "LAngle Invalid RAngle Eof", "SX-10");
  EXPECT_SERR_COUNT(r, 1, "SX-10");
}

// ---------------------------------------------------------------- SW Word
static void testWord() {
  Stope::Test::section("SW Word 边界：^[a-zA-Z_:][a-zA-Z0-9_:-]*$");

  auto r = slexAll(u"abc");
  EXPECT_STOK_LEX(r, 0, u"abc", "SW-01");

  r = slexAll(u"_x");
  EXPECT_STOK_TYPE(r, 0, TokenType::Word, "SW-02");
  EXPECT_STOK_LEX(r, 0, u"_x", "SW-02");

  r = slexAll(u":ns");
  EXPECT_STOK_LEX(r, 0, u":ns", "SW-03");

  // 续字符集 = [a-zA-Z0-9_:-]（注意不含 '.'，见 SW-08 与 TD-1）
  r = slexAll(u"a-b:c_9");
  EXPECT_STOK_LEX(r, 0, u"a-b:c_9", "SW-04");

  r = slexAll(u"9a");  // 数字开头不是 Word
  EXPECT_STOK_TYPE(r, 0, TokenType::Invalid, "SW-05");

  r = slexAll(u"a>b");  // > 截断
  EXPECT_SSEQ(r, "Word RAngle Word Eof", "SW-06");

  r = slexAll(u"a=b");  // = 截断
  EXPECT_SSEQ(r, "Word EQ Word Eof", "SW-07");

  // '.' 会截断 Word 并被当成意外字符（既有实现，两侧一致）
  r = slexAll(u"a.b");
  EXPECT_SSEQ(r, "Word Invalid Word Eof", "SW-08");
  EXPECT_SERR_COUNT(r, 1, "SW-08");
}

// ---------------------------------------------------------------- SS 字符串
static void testString() {
  Stope::Test::section("SS Xml 属性字符串");

  auto r = slexAll(u"\"abc\"");
  EXPECT_STOK_TYPE(r, 0, TokenType::String, "SS-01");
  EXPECT_STOK_LEX(r, 0, u"abc", "SS-01");  // 不含引号

  r = slexAll(u"''");
  EXPECT_STOK_TYPE(r, 0, TokenType::String, "SS-02");
  EXPECT_STOK_LEX(r, 0, u"", "SS-02");

  r = slexAll(u"\"a b\"");
  EXPECT_STOK_LEX(r, 0, u"a b", "SS-03");  // 空格不截断

  r = slexAll(u"\"a>b\"");  // > 在串内不截断
  EXPECT_SSEQ(r, "String Eof", "SS-04");
  EXPECT_STOK_LEX(r, 0, u"a>b", "SS-04");

  r = slexAll(u"\"a\nb\"");  // 跨行：换行计入行号，后续 token line 跟着走
  EXPECT_STOK_LEX(r, 0, u"a\nb", "SS-05");
  EXPECT_STOK_LINE(r, 1, 2, "SS-05");

  r = slexAll(u"\"abc");  // 未闭合
  EXPECT_STOK_TYPE(r, 0, TokenType::Invalid, "SS-06");
  EXPECT_SERR_COUNT(r, 1, "SS-06");
  EXPECT_SERR_HAS(r, "unclosed string literal", "SS-06");

  r = slexAll(u"'abc");  // 单引号未闭合，同样报错
  EXPECT_STOK_TYPE(r, 0, TokenType::Invalid, "SS-07");
  EXPECT_SERR_COUNT(r, 1, "SS-07");

  // Xml 属性字符串**不做转义**：\" 里的引号就是结束引号（既有实现，TD-9）。
  // 于是 "a\"b" 被切成 串"a\" + 词 b + 一个未闭合串。
  r = slexAll(u"\"a\\\"b\"");
  EXPECT_SSEQ(r, "String Word Invalid Eof", "SS-08");
  EXPECT_STOK_LEX(r, 0, u"a\\", "SS-08");
  EXPECT_STOK_LEX(r, 1, u"b", "SS-08");
  EXPECT_SERR_COUNT(r, 1, "SS-08");
}

// ---------------------------------------------------------------- ST Text
static void testText() {
  Stope::Test::section("ST Text 状态：元素内文本");

  auto r = slexAll(u"hello world</a>", LexerState::Text);
  EXPECT_SSEQ(r, "Text CLAngle Word RAngle Eof", "ST-01");
  EXPECT_STOK_LEX(r, 0, u"hello world", "ST-01");
  EXPECT_STOK_STATE(r, 0, LexerState::Xml, "ST-01");  // 扫到 </ 后交还 Xml

  r = slexAll(u"hello world  \n  </a>", LexerState::Text);
  EXPECT_STOK_LEX(r, 0, u"hello world", "ST-02");  // 尾部空白被裁掉

  r = slexAll(u"a\nb</a>", LexerState::Text);
  EXPECT_STOK_LINE(r, 0, 1, "ST-03");
  EXPECT_STOK_LINE(r, 1, 2, "ST-03");  // CLAngle 在第 2 行

  r = slexAll(u"</a>", LexerState::Text);  // 空文本
  EXPECT_SSEQ(r, "Text CLAngle Word RAngle Eof", "ST-04");
  EXPECT_STOK_LEX(r, 0, u"", "ST-04");

  // Text 状态只认 </ 不认 < ：子元素标签会被当文本吃掉（既有设计，见文档 §3）
  r = slexAll(u"text<b/>more</a>", LexerState::Text);
  EXPECT_SSEQ(r, "Text CLAngle Word RAngle Eof", "ST-05");
  EXPECT_STOK_LEX(r, 0, u"text<b/>more", "ST-05");

  r = slexAll(u"没有结束标签", LexerState::Text);
  EXPECT_SSEQ(r, "Text Eof", "ST-06");
  EXPECT_STOK_LEX(r, 0, u"没有结束标签", "ST-06");
  EXPECT_SERR_COUNT(r, 0, "ST-06");  // 吃到 EOF 不是错误
}

// ---------------------------------------------------------------- SN Nevext
static void testNevext() {
  Stope::Test::section("SN Nevext 状态：代码段整段给出");

  auto r = slexAll(u"windowSize 1280, 720;</nev>", LexerState::Nevext);
  EXPECT_SSEQ(r, "NevextSrc CLAngle Word RAngle Eof", "SN-01");
  EXPECT_STOK_LEX(r, 0, u"windowSize 1280, 720;", "SN-01");
  EXPECT_STOK_STATE(r, 0, LexerState::Xml, "SN-01");

  r = slexAll(u"a // 注释\nb;</n>", LexerState::Nevext);
  EXPECT_STOK_LEX(r, 0, u"a // 注释\nb;", "SN-02");
  EXPECT_STOK_LINE(r, 1, 2, "SN-02");  // CLAngle 在第 2 行

  r = slexAll(u"a /* 跨\n行 */ b;</n>", LexerState::Nevext);
  EXPECT_STOK_LEX(r, 0, u"a /* 跨\n行 */ b;", "SN-03");
  EXPECT_STOK_LINE(r, 1, 2, "SN-03");

  r = slexAll(u"a /* 未闭合", LexerState::Nevext);  // 未闭合不是错误
  EXPECT_SSEQ(r, "NevextSrc Eof", "SN-04");
  EXPECT_SERR_COUNT(r, 0, "SN-04");

  // 引号串里的 </ 不能被当成结束标签
  r = slexAll(u"x \"a</b\" 'p</q';</n>", LexerState::Nevext);
  EXPECT_STOK_LEX(r, 0, u"x \"a</b\" 'p</q';", "SN-05");
  EXPECT_STOK_TYPE(r, 1, TokenType::CLAngle, "SN-05");

  // Nevext 的两种引号都支持转义
  r = slexAll(u"x \"a\\\"b\" 'c\\'d';</n>", LexerState::Nevext);
  EXPECT_STOK_LEX(r, 0, u"x \"a\\\"b\" 'c\\'d';", "SN-06");
  EXPECT_STOK_TYPE(r, 1, TokenType::CLAngle, "SN-06");

  // 未闭合字符串：报错 + 吃到末尾（不得死循环）
  r = slexAll(u"x \"abc;</n>", LexerState::Nevext);
  EXPECT_SSEQ(r, "NevextSrc Eof", "SN-07");
  EXPECT_SERR_COUNT(r, 1, "SN-07");
  EXPECT_SERR_HAS(r, "unclosed string literal", "SN-07");
  EXPECT_SERR_HAS(r, "line 1", "SN-07");  // 报的是字符串起始行

  // 引号串跨行：行号跟着走
  r = slexAll(u"x \"a\nb\" c;</n>", LexerState::Nevext);
  EXPECT_STOK_LEX(r, 0, u"x \"a\nb\" c;", "SN-08");
  EXPECT_STOK_LINE(r, 1, 2, "SN-08");
}

// ---------------------------------------------------------------- SP Stope
static void testStope() {
  Stope::Test::section("SP Stope 状态：代码段整段给出");

  auto r = slexAll(u"let a = 1;</sto>", LexerState::Stope);
  EXPECT_SSEQ(r, "StopeSrc CLAngle Word RAngle Eof", "SP-01");
  EXPECT_STOK_LEX(r, 0, u"let a = 1;", "SP-01");
  EXPECT_STOK_STATE(r, 0, LexerState::Xml, "SP-01");

  // 小于号不会误判成结束标签
  r = slexAll(u"if a < b { c(); }</sto>", LexerState::Stope);
  EXPECT_STOK_LEX(r, 0, u"if a < b { c(); }", "SP-02");

  // 双引号字符串里的 </ 不误判
  r = slexAll(u"let s = \"a</b\";</sto>", LexerState::Stope);
  EXPECT_STOK_LEX(r, 0, u"let s = \"a</b\";", "SP-03");

  // 单引号是 BinArr 字面量，不参与转义、也不误判
  r = slexAll(u"let t = '01 02';</sto>", LexerState::Stope);
  EXPECT_STOK_LEX(r, 0, u"let t = '01 02';", "SP-04");

  // 双引号支持转义
  r = slexAll(u"let s = \"a\\\"b\\n\";</sto>", LexerState::Stope);
  EXPECT_STOK_LEX(r, 0, u"let s = \"a\\\"b\\n\";", "SP-05");
  EXPECT_STOK_TYPE(r, 1, TokenType::CLAngle, "SP-05");

  r = slexAll(u"a // c\nb;</sto>", LexerState::Stope);
  EXPECT_STOK_LEX(r, 0, u"a // c\nb;", "SP-06");
  EXPECT_STOK_LINE(r, 1, 2, "SP-06");

  r = slexAll(u"a /* 未闭合", LexerState::Stope);  // 未闭合不是错误
  EXPECT_SSEQ(r, "StopeSrc Eof", "SP-07");
  EXPECT_SERR_COUNT(r, 0, "SP-07");

  // 未闭合字符串
  r = slexAll(u"let s = \"abc;</sto>", LexerState::Stope);
  EXPECT_SERR_COUNT(r, 1, "SP-08");
  EXPECT_SERR_HAS(r, "unclosed string literal", "SP-08");

  // <!-- 在 Stope 里不是注释：< 是小于号
  r = slexAll(u"a < !- b;</sto>", LexerState::Stope);
  EXPECT_STOK_LEX(r, 0, u"a < !- b;", "SP-09");

  // 多行
  r = slexAll(u"let a = 1;\nlet b = 2;\n</sto>", LexerState::Stope);
  EXPECT_STOK_LEX(r, 0, u"let a = 1;\nlet b = 2;", "SP-10");
  EXPECT_STOK_LINE(r, 1, 3, "SP-10");
}

// ---------------------------------------------------------------- SL 行号
static void testLine() {
  Stope::Test::section("SL 行号");

  auto r = slexAll(u"<a>\n<b>\n</b>\n</a>");
  EXPECT_SSEQ(r, "LAngle Word RAngle LAngle Word RAngle CLAngle Word RAngle "
                 "CLAngle Word RAngle Eof",
              "SL-01");
  EXPECT_STOK_LINE(r, 0, 1, "SL-01");
  EXPECT_STOK_LINE(r, 3, 2, "SL-01");
  EXPECT_STOK_LINE(r, 6, 3, "SL-01");
  EXPECT_STOK_LINE(r, 9, 4, "SL-01");

  r = slexAll(u"a\n\nb", LexerState::Text);
  EXPECT_STOK_LINE(r, 1, 3, "SL-02");  // Eof 在最后一行之后

  // \r 不计数
  r = slexAll(u"a\r\nb", LexerState::Text);
  EXPECT_STOK_LINE(r, 0, 1, "SL-03");
  EXPECT_STOK_LINE(r, 1, 2, "SL-03");
}

// ---------------------------------------------------------------- SE 错误
static void testError() {
  Stope::Test::section("SE 错误：文案、行号、累加");

  auto r = slexAll(u"@ $");
  EXPECT_SSEQ(r, "Invalid Invalid Eof", "SE-01");
  EXPECT_SERR_COUNT(r, 2, "SE-01");

  r = slexAll(u"a\n@");
  EXPECT_SERR_HAS(r, "line 2", "SE-02");  // 错误行号跟着走

  // 错误文案统一格式 "line N: msg"
  r = slexAll(u"@");
  EXPECT_SERR_HAS(r, "line 1: unexpected character. ", "SE-03");
}

// ---------------------------------------------------------------- SR 健壮性
static void testRobust() {
  Stope::Test::section("SR 健壮性下限：不得死循环、不得崩");

  auto r = slexAll(u"");
  EXPECT_SSEQ(r, "Eof", "SR-01");
  EXPECT_SERR_COUNT(r, 0, "SR-01");

  r = slexAll(u"   \t\n  ");
  EXPECT_SSEQ(r, "Eof", "SR-02");

  r = slexAll(u"<!-- 未闭合的 xml 注释");
  EXPECT_SSEQ(r, "Eof", "SR-03");  // 吃到末尾，不死循环

  // 超长输入：仅断言能扫完
  std::u16string big;
  for (int i = 0; i < 5000; ++i) big += u"a";
  r = slexAll(big);
  EXPECT_SSEQ(r, "Word Eof", "SR-04");

  // 200 个引号 = 100 对空串：必须全部产出，不能死循环、不能崩
  std::u16string q;
  for (int i = 0; i < 200; ++i) q += u"\"";
  r = slexAll(q);
  EXPECT_SCOUNT(r, 101, "SR-05");
  EXPECT_STOK_TYPE(r, 0, TokenType::String, "SR-05");
  EXPECT_STOK_TYPE(r, 99, TokenType::String, "SR-05");
  EXPECT_STOK_TYPE(r, 100, TokenType::EndOfFile, "SR-05");
  EXPECT_SERR_COUNT(r, 0, "SR-05");

  // 只有 <!-- 而无 -->
  r = slexAll(u"<!--");
  EXPECT_SSEQ(r, "Eof", "SR-06");
}

void runSTMLexerTests() {
  printf("\n======== STML 词法分析 ========");
  testXml();
  testWord();
  testString();
  testText();
  testNevext();
  testStope();
  testLine();
  testError();
  testRobust();
}

}  // namespace Stope::STML::Test
