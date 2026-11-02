#pragma once
#include <map>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>
#include <stope/common.hpp>
#include <stope/stml_lexer.hpp>
/*
STML 语法比 XML 更严格：
- 没有字符实体
- 属性可以没有值：<a flag> 等价于 flag = ""
  （因此属性解析必须"向前看一个 token 但不消费"，循环不能在开头无条件 nextToken）
- 子元素与元素内文本互斥。元素内文本只有一段，由 Lexer 一次性给出，不做多段拼接
*/
namespace Stope::STML {
struct Element {
  int line = -1;
  std::u16string_view tagName;
  std::map<std::u16string_view, std::u16string_view> attrs;
  bool selfClosing = false;
  std::vector<Element> children;  // 不需要 unique_ptr，因为没有重载
  std::u16string_view text;
};
using LexerStateFunc =
    LexerState (*)(std::u16string_view tag,
                   std::map<std::u16string_view, std::u16string_view> attrs);
struct Parser {
  Lexer* lexer;
  LexerStateFunc stateFunc = nullptr;
  std::vector<std::string> errors;
  Token token;
  // 元素嵌套深度上限（根元素算第 1 层），0 = 不限。
  // 与 Stope::Parser::maxDepth 同语义、同文案。STML 每层至少要 <a></a> 7 字节，
  // 正常文档到不了 256，这个限制兜底的是自动生成的畸形输入。
  int maxDepth = 256;
  Parser(Lexer& lexer);
  Result Parse(Element& root, LexerStateFunc stateFunc);

 private:
  bool aborted = false;  // 超限中止：此后不再消费 token，剩余输入全部忽略
  void parseElement(Element& e, int depth);
  void nextToken();
  void error(const char* msg);
  void abortTooDeep();
};
}  // namespace Stope::STML
