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
  Parser(Lexer& lexer);
  Result Parse(Element& root, LexerStateFunc stateFunc);

 private:
  void parseElement(Element& e);
  void nextToken();
  void error(const char* msg);
};
}  // namespace Stope::STML
