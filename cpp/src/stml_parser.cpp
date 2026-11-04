#include <stope/stml_parser.hpp>

#include <cstdio>
#include <map>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

namespace Stope::STML {

Parser::Parser(Lexer& lexer) {
  this->lexer = &lexer;
}

Result Parser::Parse(Element& root, LexerStateFunc stateFunc) {
  this->stateFunc = stateFunc;
  aborted = false;
  nextToken();
  parseElement(root, 1);  // 根元素算第 1 层
  return errors.empty() ? Result::Success : Result::Error;
}

void Parser::parseElement(Element& e, int depth) {
  // 深度检查：唯一递归点在子元素分支，检查放入口即可。
  // aborted 之后逐层提前 return，不再消费任何 token —— 与 Stope::Parser
  // 「中止但不逐层传染」同款，25 万层畸形输入只报一条错。
  if (aborted)
    return;
  if (maxDepth > 0 && depth > maxDepth) {
    abortTooDeep();
    return;
  }
  // 进入元素一律先回到 Xml 状态：自闭合分支与出错提前返回的路径都走不到
  // 下面的 stateFunc，留着上一次的 Text/Nevext/Stope 会污染后续 token
  lexer->state = LexerState::Xml;
  e.line = token.line;
  if (token.type != TokenType::LAngle) {
    error("expected \"<\". ");
    return;
  }
  nextToken();
  if (token.type != TokenType::Word) {
    error("expected tag name. ");
    return;
  }
  e.tagName = token.lexeme;
  nextToken();  // 第一个属性名，或 > 或 />
  // 每个分支自己负责推进到下一个待判断的 token。
  // 不能写成"循环开头 nextToken"，否则无值属性的向前看会多吞一个 token。
  for (;;) {  // (word ("=" string)?)*
    if (token.type == TokenType::RAngle) {
      break;
    } else if (token.type == TokenType::CRAngle) {
      e.selfClosing = true;
      return;
    } else if (token.type == TokenType::Word) {
      std::u16string_view attr = token.lexeme;
      nextToken();
      if (token.type == TokenType::EQ) {
        nextToken();
        if (token.type != TokenType::String) {
          error("expected string. ");
          return;
        }
        e.attrs.emplace(attr, token.lexeme);
        nextToken();
      } else {
        // 无值属性：<a flag> 等价于 attrs["flag"] = ""
        // 此时 token 已经是下一个属性名 / > 或 />，不能再推进
        e.attrs.emplace(attr, std::u16string_view());
      }
    } else {
      error("expected \">\" or \"/>\" or attribute. ");
      return;
    }
  }
  // 此时 e.selfClosing = false，且停在 ">"
  if (stateFunc) {
    lexer->state = stateFunc(e.tagName, e.attrs);
  } else {
    lexer->state = LexerState::Xml;
  }
  if (lexer->state == LexerState::Xml) {  // 递归解析子元素
    for (;;) {
      nextToken();
      if (token.type == TokenType::CLAngle) {  // </
        break;
      } else if (token.type == TokenType::LAngle) {  // < 子元素
        parseElement(e.children.emplace_back(), depth + 1);
        if (aborted)
          return;  // 超限的那层已报过错，逐层直接返回，不级联
      } else {
        error("expected \"<\" or \"</\". ");
        return;
      }
    }
  } else {        // Text / Nevext / Stope：整段内容由 Lexer 一次性给出
    nextToken();  // Lexer 保证了，只会结束在 </ ，不会结束在 <
    if (token.type != TokenType::Text && token.type != TokenType::NevextSrc &&
        token.type != TokenType::StopeSrc) {
      error("expected element content. ");
      return;
    }
    e.text = token.lexeme;  // 只有一段，不拼接（见文件头注释）
    e.textLine = token.line;  // 词法器已跳过前导空白，这是内容的首行（PL-05）
    nextToken();            // 停在 CLAngle，与上面 Xml 分支的 break 处汇合
  }
  nextToken();  // 结束标签名
  if (token.type != TokenType::Word) {
    error("expected tag name. ");
    return;
  }
  if (token.lexeme != e.tagName) {
    error("tag name mismatch. ");
    return;
  }
  nextToken();
  if (token.type != TokenType::RAngle) {
    error("expected \">\". ");
    return;
  }
}

void Parser::nextToken() {
  lexer->NextToken(token);
}

void Parser::abortTooDeep() {
  char buf[64];
  std::snprintf(buf, sizeof buf, "nesting too deep (max %d). ", maxDepth);
  error(buf);  // 必须在置 aborted 之前，否则会被下面那句直接吞掉
  aborted = true;
}

void Parser::error(const char* msg) {
  // 超限中止之后的错误都是连锁反应，不再记账 —— 与 Stope::Parser 同款。
  // 有了这道闸，abortTooDeep 只要保证自己那条先记上就行。
  if (aborted)
    return;
  std::stringstream ss;
  ss << "line " << token.line << ": " << msg;
  errors.push_back(ss.str());
}

}  // namespace Stope::STML
