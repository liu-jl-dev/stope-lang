// STML 语法分析用例（STML-PARSE）
//
// 用例 ID 前缀：PA = 元素骨架、PB = 属性、PC = 元素内容（文本 / Nevext / Stope）、
//               PL = 行号、PE = 错误恢复、PF = 健壮性与回调、PH = 混合与既有约定。
// 期望值一律来自 C++ 侧实测（权威实现），不手推。
//
// 两条贯穿全文件的项目定夺：
//   1) 属性装在 std::map 里，**顺序不保证**（形状串里是键的字典序）。
//   2) 元素内文本只有一段，Lexer 一次性给出，Parser 不拼接。

#include "test_stml_common.hpp"

namespace Stope::STML::Test {

// ---------------------------------------------------------------- SA 元素骨架
static void testSkeleton() {
  Stope::Test::section("SA 元素骨架：自闭合 / 空元素对 / 子元素");

  auto r = sparseAll(u"<a/>");
  EXPECT_SP_SHAPE(r, "Elem(a, L1, /)", "PA-01");
  EXPECT_SP_RESULT(r, Stope::Result::Success, "PA-01");
  EXPECT_SP_SELFCLOSING(r, true, "PA-01");

  r = sparseAll(u"<a></a>");
  EXPECT_SP_SHAPE(r, "Elem(a, L1)", "PA-02");
  EXPECT_SP_SELFCLOSING(r, false, "PA-02");

  r = sparseAll(u"  <a/>  ");  // 首尾空白
  EXPECT_SP_SHAPE(r, "Elem(a, L1, /)", "PA-03");

  r = sparseAll(u"<a><b/></a>");
  EXPECT_SP_SHAPE(r, "Elem(a, L1, C=[Elem(b, L1, /)])", "PA-04");
  EXPECT_SP_CHILD_COUNT(r, 1, "PA-04");

  r = sparseAll(u"<a><b><c/></b></a>");  // 三层
  EXPECT_SP_SHAPE(r, "Elem(a, L1, C=[Elem(b, L1, C=[Elem(c, L1, /)])])",
                  "PA-05");
  EXPECT_SP_DEPTH(r, 3, "PA-05");

  r = sparseAll(u"<a><b/><c/><d/></a>");  // 多个兄弟
  EXPECT_SP_SHAPE(r, "Elem(a, L1, C=[Elem(b, L1, /) Elem(c, L1, /) "
                     "Elem(d, L1, /)])",
                  "PA-06");
  EXPECT_SP_CHILD_COUNT(r, 3, "PA-06");

  r = sparseAll(u"<a><b></b><c> </c></a>");  // 兄弟里混自闭合与元素对
  EXPECT_SP_CHILD_COUNT(r, 2, "PA-07");

  // 结束标签名必须逐字符相等
  r = sparseAll(u"<a-b></a-b>");
  EXPECT_SP_SHAPE(r, "Elem(a-b, L1)", "PA-08");

  // 根元素之后的剩余输入不解析（顶层只吃一个元素，不是"文档"）
  r = sparseAll(u"<a/><b/>");
  EXPECT_SP_SHAPE(r, "Elem(a, L1, /)", "PA-09");
  EXPECT_SP_RESULT(r, Stope::Result::Success, "PA-09");
}

// ---------------------------------------------------------------- SB 属性
static void testAttrs() {
  Stope::Test::section("SB 属性：有值 / 无值 / 顺序无关");

  auto r = sparseAll(u"<a id=\"x\"/>");
  EXPECT_SP_SHAPE(r, "Elem(a, L1, /, @id=\"x\")", "PB-01");
  EXPECT_SP_ATTR_COUNT(r, 1, "PB-01");

  r = sparseAll(u"<a id='x'/>");  // 单引号同价
  EXPECT_SP_SHAPE(r, "Elem(a, L1, /, @id=\"x\")", "PB-02");

  r = sparseAll(u"<a flag/>");  // 无值属性
  EXPECT_SP_SHAPE(r, "Elem(a, L1, /, @flag)", "PB-03");
  EXPECT_SP_ATTR_COUNT(r, 1, "PB-03");

  r = sparseAll(u"<a id=\"x\" flag/>");  // 有值 + 无值
  EXPECT_SP_SHAPE(r, "Elem(a, L1, /, @flag, @id=\"x\")", "PB-04");

  // 顺序无关：无值属性在前，形状串里仍是字典序
  r = sparseAll(u"<a flag id=\"x\"/>");
  EXPECT_SP_SHAPE(r, "Elem(a, L1, /, @flag, @id=\"x\")", "PB-05");

  r = sparseAll(u"<a z=\"1\" a=\"2\"/>");  // 字典序，不是源码顺序
  EXPECT_SP_SHAPE(r, "Elem(a, L1, /, @a=\"2\", @z=\"1\")", "PB-06");

  r = sparseAll(u"<a b=\"1\" c=\"2\" d/>");
  EXPECT_SP_SHAPE(r, "Elem(a, L1, /, @b=\"1\", @c=\"2\", @d)", "PB-07");
  EXPECT_SP_ATTR_COUNT(r, 3, "PB-07");

  // 空串值与无值在形状串里长得一样（map 值都是空 view）—— 用条数区分不了，
  // 所以这里只锁"能解析成功"
  r = sparseAll(u"<a id=\"\"/>");
  EXPECT_SP_RESULT(r, Stope::Result::Success, "PB-08");
  EXPECT_SP_ATTR_COUNT(r, 1, "PB-08");

  // 值里可以含 >  /  = （Lexer 的 scanString 不吃标签标点）
  r = sparseAll(u"<a t=\"x>y\"/>");
  EXPECT_SP_SHAPE(r, "Elem(a, L1, /, @t=\"x>y\")", "PB-09");

  // 属性名允许 : - （Word 的字符集；'.' 不在其中，见 SW-08 / TD-1）
  r = sparseAll(u"<a x:y=\"1\" z-w=\"2\"/>");
  EXPECT_SP_SHAPE(r, "Elem(a, L1, /, @x:y=\"1\", @z-w=\"2\")", "PB-10");

  // 带属性的元素对
  r = sparseAll(u"<a id=\"1\"><b/></a>");
  EXPECT_SP_SHAPE(r, "Elem(a, L1, @id=\"1\", C=[Elem(b, L1, /)])", "PB-11");
}

// ---------------------------------------------------------------- SC 元素内容
static void testContent() {
  Stope::Test::section("SC 元素内容：Text / Nevext / Stope");

  auto r = sparseAll(u"<p>hello</p>");
  EXPECT_SP_SHAPE(r, "Elem(p, L1, T=\"hello\")", "PC-01");
  EXPECT_SP_TEXT(r, u"hello", "PC-01");

  r = sparseAll(u"<p>  hello  </p>");  // 尾部空白由 Lexer 裁掉
  EXPECT_SP_TEXT(r, u"hello", "PC-02");

  r = sparseAll(u"<p></p>");  // 空文本：产出空 Text，不是错误
  EXPECT_SP_RESULT(r, Stope::Result::Success, "PC-03");
  EXPECT_SP_TEXT(r, u"", "PC-03");

  r = sparseAll(u"<sto>let a = 1;</sto>");
  EXPECT_SP_SHAPE(r, "Elem(sto, L1, T=\"let a = 1;\")", "PC-04");

  r = sparseAll(u"<nev>x 1, 2;</nev>");
  EXPECT_SP_SHAPE(r, "Elem(nev, L1, T=\"x 1, 2;\")", "PC-05");

  // 代码段里的 </ 藏在引号里，不能当成结束标签
  r = sparseAll(u"<sto>let s = \"a</b\";</sto>");
  EXPECT_SP_TEXT(r, u"let s = \"a</b\";", "PC-06");

  r = sparseAll(u"<nev>x \"a</b\";</nev>");
  EXPECT_SP_TEXT(r, u"x \"a</b\";", "PC-07");

  // 代码段跨行：text 保留换行
  r = sparseAll(u"<sto>let a = 1;\nlet b = 2;</sto>");
  EXPECT_SP_TEXT(r, u"let a = 1;\nlet b = 2;", "PC-08");

  // Text 状态只认 </ ：<b/> 会被当文本吃掉（既有设计）
  r = sparseAll(u"<p>a<b/>c</p>");
  EXPECT_SP_TEXT(r, u"a<b/>c", "PC-09");

  // Text 里的 <!-- 不是注释
  r = sparseAll(u"<p>a <!-- b</p>");
  EXPECT_SP_TEXT(r, u"a <!-- b", "PC-10");

  // 子元素与文本互斥：Xml 模式的元素里出现裸文本是错误
  r = sparseAll(u"<a>text</a>");
  EXPECT_SPERR_COUNT(r, 1, "PC-11");
  EXPECT_SPERR_HAS(r, "expected \"<\" or \"</\".", "PC-11");

  // Nevext 的转义串整段保留（Parser 不做任何解码）
  r = sparseAll(u"<nev>x \"a\\\"b\";</nev>");
  EXPECT_SP_TEXT(r, u"x \"a\\\"b\";", "PC-12");
}

// ---------------------------------------------------------------- SD 行号
static void testLine() {
  Stope::Test::section("SD 行号：元素行号取 '<' 所在行");

  auto r = sparseAll(u"<a>\n<b/>\n</a>");
  EXPECT_SP_LINE(r, 1, "PL-01");  // 根取 '<' 所在行
  EXPECT_SP_TAG(r, u"a", "PL-01");

  r = sparseAll(u"\n\n<a/>");
  EXPECT_SP_LINE(r, 3, "PL-02");

  r = sparseAll(u"<a>\n<b>\n<c/>\n</b>\n</a>");
  EXPECT_SP_DEPTH(r, 3, "PL-03");

  // 跨行的 Stope 段：元素行号仍是开头那行
  r = sparseAll(u"<sto>\nlet a = 1;\n</sto>");
  EXPECT_SP_LINE(r, 1, "PL-04");
  EXPECT_SP_TEXT(r, u"let a = 1;", "PL-04");
}

// ---------------------------------------------------------------- SE 错误
static void testError() {
  Stope::Test::section("SE 错误恢复：每个用例只报 1 条，不级联");

  auto r = sparseAll(u"<>");
  EXPECT_SPERR_COUNT(r, 1, "PE-01");
  EXPECT_SPERR_HAS(r, "expected tag name.", "PE-01");
  EXPECT_SP_RESULT(r, Stope::Result::Error, "PE-01");

  r = sparseAll(u"a");  // 没有 <
  EXPECT_SPERR_COUNT(r, 1, "PE-02");
  EXPECT_SPERR_HAS(r, "expected \"<\".", "PE-02");

  r = sparseAll(u"");
  EXPECT_SPERR_COUNT(r, 1, "PE-03");
  EXPECT_SPERR_HAS(r, "expected \"<\".", "PE-03");

  r = sparseAll(u"<a></b>");  // 结束标签名不匹配
  EXPECT_SPERR_COUNT(r, 1, "PE-04");
  EXPECT_SPERR_HAS(r, "tag name mismatch.", "PE-04");

  r = sparseAll(u"<a id=></a>");  // = 后面不是字符串
  EXPECT_SPERR_COUNT(r, 1, "PE-05");
  EXPECT_SPERR_HAS(r, "expected string.", "PE-05");

  r = sparseAll(u"<a 1></a>");  // 属性位置上不是 Word
  EXPECT_SPERR_COUNT(r, 1, "PE-06");
  EXPECT_SPERR_HAS(r, "expected \">\" or \"/>\" or attribute.", "PE-06");
  EXPECT_SPLEX_COUNT(r, 1, "PE-06");  // 词法侧另有 1 条 unexpected character

  r = sparseAll(u"<a>");  // 只有开始标签
  EXPECT_SPERR_COUNT(r, 1, "PE-07");
  EXPECT_SPERR_HAS(r, "expected \"<\" or \"</\".", "PE-07");

  r = sparseAll(u"<a");  // 开始标签没写完
  EXPECT_SPERR_COUNT(r, 1, "PE-08");
  EXPECT_SPERR_HAS(r, "expected \">\" or \"/>\" or attribute.", "PE-08");

  r = sparseAll(u"<a></a");  // 结束标签缺 >
  EXPECT_SPERR_COUNT(r, 1, "PE-09");
  EXPECT_SPERR_HAS(r, "expected \">\".", "PE-09");

  r = sparseAll(u"<a></a b>");  // 结束标签后多了东西
  EXPECT_SPERR_COUNT(r, 1, "PE-10");
  EXPECT_SPERR_HAS(r, "expected \">\".", "PE-10");

  // 未闭合的属性字符串：词法吃掉剩余输入 → 语法只报 1 条（提前 return，不级联）
  r = sparseAll(u"<a id=\"x></a>");
  EXPECT_SPERR_COUNT(r, 1, "PE-11");
  EXPECT_SPERR_HAS(r, "expected string.", "PE-11");
  EXPECT_SPLEX_COUNT(r, 1, "PE-11");

  // 子元素写坏了：parseElement 返回 void，父元素不知道子失败，会继续往下解析
  // → 第 1 条来自子元素，第 2 条是父元素对不上结束标签（TD-7，未修）
  r = sparseAll(u"<a><b id=></b></a>");
  EXPECT_SPERR_COUNT(r, 2, "PE-12");
  EXPECT_SPERR_HAS(r, "expected string.", "PE-12");
  EXPECT_SPERR_HAS(r, "tag name mismatch.", "PE-12");
}

// ---------------------------------------------------------------- SF 回调与健壮性
static void testCallback() {
  Stope::Test::section("SF stateFunc 回调与健壮性下限");

  // stateFunc = nullptr → 一律 Xml，含子元素模式
  auto r = sparseAll(u"<a><b/></a>", nullptr);
  EXPECT_SP_SHAPE(r, "Elem(a, L1, C=[Elem(b, L1, /)])", "PF-01");
  EXPECT_SP_RESULT(r, Stope::Result::Success, "PF-01");

  // nullptr 下 <p> 的文本也会被当成"意外 token"
  r = sparseAll(u"<p>hello</p>", nullptr);
  EXPECT_SPERR_COUNT(r, 1, "PF-02");
  EXPECT_SPERR_HAS(r, "expected \"<\" or \"</\".", "PF-02");

  // 自定义回调：一切元素都走 Text
  r = sparseAll(u"<any>hello</any>",
                [](std::u16string_view,
                   std::map<std::u16string_view, std::u16string_view>) {
                  return LexerState::Text;
                });
  EXPECT_SP_SHAPE(r, "Elem(any, L1, T=\"hello\")", "PF-03");

  // 深嵌套：50 层不出错（STML 没有递归深度保护，只求默认栈下够用）
  std::u16string deep;
  for (int i = 0; i < 50; ++i) deep += u"<n>";
  for (int i = 0; i < 50; ++i) deep += u"</n>";
  r = sparseAll(deep);
  EXPECT_SP_RESULT(r, Stope::Result::Success, "PF-04");
  EXPECT_SP_DEPTH(r, 50, "PF-04");

  // 大文本段
  std::u16string big;
  for (int i = 0; i < 2000; ++i) big += u"x";
  r = sparseAll(u"<p>" + big + u"</p>");
  EXPECT_SP_RESULT(r, Stope::Result::Success, "PF-05");
  EXPECT_SP_TEXT(r, big, "PF-05");

  // 注释出现在子元素之间（Xml 状态才认）
  r = sparseAll(u"<a><!-- c --><b/></a>");
  EXPECT_SP_SHAPE(r, "Elem(a, L1, C=[Elem(b, L1, /)])", "PF-06");

  // 注释出现在元素内容位置
  r = sparseAll(u"<p><!-- c --></p>");
  EXPECT_SP_TEXT(r, u"<!-- c -->", "PF-07");
}

// ---------------------------------------------------------------- SH 混合
static void testMixed() {
  Stope::Test::section("SH 混合：真实一点的片段");

  auto r = sparseAll(
      u"<div class=\"box\" hidden>\n"
      u"  <p>hello</p>\n"
      u"  <sto>let a = 1;</sto>\n"
      u"  <nev>windowSize 1280, 720;</nev>\n"
      u"</div>");
  EXPECT_SP_SHAPE(r,
                  "Elem(div, L1, @class=\"box\", @hidden, C=["
                  "Elem(p, L2, T=\"hello\") "
                  "Elem(sto, L3, T=\"let a = 1;\") "
                  "Elem(nev, L4, T=\"windowSize 1280, 720;\")])",
                  "PH-01");
  EXPECT_SP_RESULT(r, Stope::Result::Success, "PH-01");

  // Stope 段里有 <、>、//、/* */、字符串、BinArr
  r = sparseAll(u"<sto>if a < b { s = \"x</y\"; t = '01 02'; /* c */ }</sto>");
  EXPECT_SP_TEXT(r, u"if a < b { s = \"x</y\"; t = '01 02'; /* c */ }", "PH-02");

  // Nevext 段里有跨行注释与引号串
  r = sparseAll(u"<nev>title \"a\nb\"; /* x\ny */ size 1;</nev>");
  EXPECT_SP_TEXT(r, u"title \"a\nb\"; /* x\ny */ size 1;", "PH-03");

  // 自闭合带属性 + 兄弟文本元素
  r = sparseAll(u"<a><img src=\"i.png\" alt=\"\"/><p>cap</p></a>");
  EXPECT_SP_SHAPE(r,
                  "Elem(a, L1, C=[Elem(img, L1, /, @alt, @src=\"i.png\") "
                  "Elem(p, L1, T=\"cap\")])",
                  "PH-04");
}

void runSTMLParserTests() {
  printf("\n======== STML 语法分析 ========");
  testSkeleton();
  testAttrs();
  testContent();
  testLine();
  testError();
  testCallback();
  testMixed();
}

}  // namespace Stope::STML::Test
