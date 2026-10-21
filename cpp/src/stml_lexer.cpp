#include <stope/stml_lexer.hpp>

#include <sstream>
#include <string>
#include <string_view>
#include <vector>

namespace Stope::STML {

Lexer::Lexer(const std::u16string_view& input) { this->input = input; }

void Lexer::NextToken(Token& token) {
  skipWs();
  token.line = line;
  if (input.empty()) {
    token.type = TokenType::EndOfFile;
  } else if (state == LexerState::Xml) {
    if (test(u"</")) {
      token.type = TokenType::CLAngle;
      input.remove_prefix(2);
    } else if (test(u"/>")) {
      token.type = TokenType::CRAngle;
      input.remove_prefix(2);
    } else if (input[0] == '<') {
      token.type = TokenType::LAngle;
      input.remove_prefix(1);
    } else if (input[0] == '>') {
      token.type = TokenType::RAngle;
      input.remove_prefix(1);
    } else if (input[0] == '=') {
      token.type = TokenType::EQ;
      input.remove_prefix(1);
    } else if (input[0] == '"' || input[0] == '\'') {
      scanString(token);
    } else if (isWordBegin(input[0])) {
      scanWord(token);
    } else {
      error("unexpected character. ");
      token.type = TokenType::Invalid;
      input.remove_prefix(1);
    }
  } else if (state == LexerState::Text) {
    scanText(token);
    state = LexerState::Xml;
  } else if (state == LexerState::Nevext) {
    scanNevextSrc(token);
    state = LexerState::Xml;
  } else if (state == LexerState::Stope) {
    scanStopeSrc(token);
    state = LexerState::Xml;
  }
}

bool Lexer::isWordBegin(char16_t c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' ||
         c == ':';
}

bool Lexer::isWordChar(char16_t c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
         (c >= '0' && c <= '9') || c == '_' || c == ':' || c == '-';
}

void Lexer::scanWord(Token& token) {
  token.type = TokenType::Word;
  size_t len = 1;  // 外层已保证首字符是 isWordBegin
  for (; len < input.size() && isWordChar(input[len]);) {
    ++len;
  }
  token.lexeme = input.substr(0, len);
  input.remove_prefix(len);
}

void Lexer::scanString(Token& token) {
  token.type = TokenType::String;
  char16_t quote = input[0];  // " 或 '
  input.remove_prefix(1);     // 跳过 " 或 '
  size_t len = 0;
  for (;;) {
    if (len >= input.size()) {
      error("unclosed string literal");
      input.remove_prefix(input.size());
      token.type = TokenType::Invalid;
      break;
    }
    if (input[len] == quote) {
      token.lexeme = input.substr(0, len);
      input.remove_prefix(len + 1);
      break;
    }
    if (input[len] == u'\n') {
      ++line;
    }
    ++len;
  }
}

void Lexer::scanText(Token& token) {
  token.type = TokenType::Text;
  std::u16string_view begin = input;
  int len = 0;
  for (; !input.empty();) {
    if (test(u"</")) {
      break;
    }
    if (input[0] == u'\n') {
      ++line;
    }
    input.remove_prefix(1);
    ++len;
  }
  token.lexeme = trimTrailingWs(begin.substr(0, len));
}

void Lexer::scanNevextSrc(Token& token) {
  token.type = TokenType::NevextSrc;
  std::u16string_view begin = input;
  int len = 0;
  for (; !input.empty();) {
    if (test(u"</")) {
      break;
    } else if (input[0] == u'\'' || input[0] == u'"') {
      len += scanNevextString(input[0]);
    } else if (test(u"//")) {
      len += scanNevextSinglelineComment();
    } else if (test(u"/*")) {
      len += scanNevextMultilineComment();
    } else {
      if (input[0] == u'\n') {
        ++line;
      }
      input.remove_prefix(1);
      ++len;
    }
  }
  token.lexeme = trimTrailingWs(begin.substr(0, len));
}

int Lexer::scanNevextSinglelineComment() {
  input.remove_prefix(2);
  int len = 2;
  for (; !input.empty();) {
    char16_t c = input[0];
    input.remove_prefix(1);
    ++len;
    if (c == u'\n') {
      ++line;
      break;
    }
  }
  return len;
}

int Lexer::scanNevextMultilineComment() {
  input.remove_prefix(2);
  int len = 2;
  for (; !input.empty();) {
    if (test(u"*/")) {
      input.remove_prefix(2);
      len += 2;
      break;
    }
    char16_t c = input[0];
    input.remove_prefix(1);
    ++len;
    if (c == u'\n') {
      ++line;
    }
  }
  return len;
}

int Lexer::scanNevextString(char16_t quote) {
  const int beginLine = line;
  input.remove_prefix(1);  // 跳过开头的引号
  int len = 1;
  for (;;) {
    if (input.empty()) {
      error2(beginLine, "unclosed string literal. ");
      return len;
    }
    char16_t c = input[0];
    input.remove_prefix(1);
    ++len;
    if (c == u'\\') {  // 转义字符：连同紧跟的一个字符一起吃掉
      if (input.empty()) {
        error2(beginLine, "unclosed string literal. ");
        return len;
      }
      if (input[0] == u'\n') {
        ++line;
      }
      input.remove_prefix(1);
      ++len;
    } else if (c == quote) {  // 结束引号
      return len;
    } else if (c == u'\n') {  // 引号串可以跨行，行号必须跟着走
      ++line;
    }
  }
}

void Lexer::scanStopeSrc(Token& token) {
  token.type = TokenType::StopeSrc;
  std::u16string_view begin = input;
  int len = 0;
  for (; !input.empty();) {
    if (test(u"</")) {
      break;
    } else if (input[0] == u'"' || input[0] == u'\'') {
      len += scanStopeString(input[0]);
    } else if (test(u"//")) {
      len += scanStopeSinglelineComment();
    } else if (test(u"/*")) {
      len += scanStopeMultilineComment();
    } else {
      if (input[0] == u'\n') {
        ++line;
      }
      input.remove_prefix(1);
      ++len;
    }
  }
  token.lexeme = trimTrailingWs(begin.substr(0, len));
}

int Lexer::scanStopeString(char16_t quote) {
  const bool escapes = (quote == u'"');
  const int beginLine = line;
  input.remove_prefix(1);  // 跳过开头的引号
  int len = 1;
  for (;;) {
    if (input.empty()) {
      error2(beginLine, "unclosed string literal. ");
      return len;
    }
    char16_t c = input[0];
    input.remove_prefix(1);
    ++len;
    if (escapes && c == u'\\') {  // 转义字符：连同紧跟的一个字符一起吃掉
      if (input.empty()) {
        error2(beginLine, "unclosed string literal. ");
        return len;
      }
      if (input[0] == u'\n') {
        ++line;
      }
      input.remove_prefix(1);
      ++len;
    } else if (c == quote) {  // 结束引号
      return len;
    } else if (c == u'\n') {
      ++line;
    }
  }
}

int Lexer::scanStopeSinglelineComment() {
  input.remove_prefix(2);
  int len = 2;
  for (; !input.empty();) {
    char16_t c = input[0];
    input.remove_prefix(1);
    ++len;
    if (c == u'\n') {
      ++line;
      break;
    }
  }
  return len;
}

int Lexer::scanStopeMultilineComment() {
  input.remove_prefix(2);
  int len = 2;
  for (; !input.empty();) {
    if (test(u"*/")) {
      input.remove_prefix(2);
      len += 2;
      break;
    }
    char16_t c = input[0];
    input.remove_prefix(1);
    ++len;
    if (c == u'\n') {
      ++line;
    }
  }
  return len;
}

void Lexer::skipWs() {
  while (input.size() > 0) {
    if (input[0] == ' ' || input[0] == '\t' || input[0] == '\n' ||
        input[0] == '\f' || input[0] == '\v' || input[0] == '\r') {
      if (input[0] == '\n')
        ++line;
      input.remove_prefix(1);
    } else if (state == LexerState::Xml && test(u"<!--")) {
      // '<!--' 只在 Xml 状态是注释；Nevext / Stope 代码里的 '<' 是小于号
      skipXmlComment();
    } else {
      break;
    }
  }
}

void Lexer::skipXmlComment() {
  input.remove_prefix(4);
  while (input.size() > 0) {
    if (test(u"-->")) {
      input.remove_prefix(3);
      break;
    }
    if (input[0] == '\n')
      ++line;
    input.remove_prefix(1);
  }
}

bool Lexer::test(const std::u16string_view& prefix) {
  if (input.size() < prefix.size())
    return false;
  return input.substr(0, prefix.size()) == prefix;
}

bool Lexer::test2(const std::u16string_view& prefix, int offset) {
  if (input.size() < prefix.size() + offset)
    return false;
  return input.substr(offset, prefix.size()) == prefix;
}

void Lexer::error(const char* msg) { error2(line, msg); }

void Lexer::error2(int line_, const char* msg) {
  std::stringstream ss;
  ss << "line " << line_ << ": " << msg;
  errors.emplace_back(ss.str());
}

std::u16string_view Lexer::trimTrailingWs(const std::u16string_view& s) {
  size_t len = s.size();
  for (; len > 0;) {
    char16_t c = s[len - 1];
    if (c == u' ' || c == u'\t' || c == u'\n' || c == u'\f' || c == u'\v' ||
        c == u'\r') {
      --len;
    } else {
      break;
    }
  }
  return s.substr(0, len);
}

}  // namespace Stope::STML
