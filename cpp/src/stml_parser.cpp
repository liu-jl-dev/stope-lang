#include <stope/stml_parser.hpp>

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
  nextToken();
  parseElement(root);
  return errors.empty() ? Result::Success : Result::Error;
}

void Parser::parseElement(Element& e) {
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
        parseElement(e.children.emplace_back());
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

void Parser::error(const char* msg) {
  std::stringstream ss;
  ss << "line " << token.line << ": " << msg;
  errors.push_back(ss.str());
}

}  // namespace Stope::STML
