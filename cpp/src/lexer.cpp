#include <stope/lexer.hpp>

#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace Stope {

void Lexer::NextToken(Token& token, const CustomOpcodeConfig* custom ) {
  token = Token();
  skipWs();
  token.line = line;
  if (input.empty()) {
    token.type = TokenType::Eof;
  } else if (isDigit(input[0]) || input[0] == u'.') {
    scanNumber(token);
    parseNumber(token);
    getNumberValue(token);
  } else if (isIdentBegin(input[0])) {
    scanIdent(token);
    analyzeIdent(token, custom);
  } else if (input[0] == u'\'') {
    scanBinArr(token);
  } else if (input[0] == u'"') {
    scanString(token);
  } else if (input[0] == u',') {
    token.type = TokenType::Comma;
    input.remove_prefix(1);
  } else if (input[0] == u';') {
    token.type = TokenType::Semi;
    input.remove_prefix(1);
  } else if (input[0] == u'(') {
    token.type = TokenType::LParen;
    input.remove_prefix(1);
  } else if (input[0] == u')') {
    token.type = TokenType::RParen;
    input.remove_prefix(1);
  } else if (input[0] == u'[') {
    token.type = TokenType::LBrack;
    input.remove_prefix(1);
  } else if (input[0] == u']') {
    token.type = TokenType::RBrack;
    input.remove_prefix(1);
  } else if (input[0] == u'{') {
    token.type = TokenType::LBrace;
    input.remove_prefix(1);
  } else if (input[0] == u'}') {
    token.type = TokenType::RBrace;
    input.remove_prefix(1);
  } else if (input[0] == u'=') {
    if (test(u"==")) {
      token.type = TokenType::EQ;
      input.remove_prefix(2);
    } else {
      token.type = TokenType::Assign;
      input.remove_prefix(1);
    }
  } else if (input[0] == u'+') {
    token.type = TokenType::Add;
    input.remove_prefix(1);
  } else if (input[0] == u'-') {
    token.type = TokenType::Sub;
    input.remove_prefix(1);
  } else if (input[0] == u'*') {
    token.type = TokenType::Mul;
    input.remove_prefix(1);
  } else if (input[0] == u'/') {
    token.type = TokenType::Div;
    input.remove_prefix(1);
  } else if (input[0] == u'%') {
    token.type = TokenType::Mod;
    input.remove_prefix(1);
  } else if (input[0] == u'^') {
    token.type = TokenType::Pow;
    input.remove_prefix(1);
  } else if (input[0] == u'!') {
    if (test(u"!=")) {
      token.type = TokenType::NE;
      input.remove_prefix(2);
    } else {
      token.type = TokenType::Not;
      input.remove_prefix(1);
    }
  } else if (input[0] == u'<') {
    if (test(u"<=")) {
      token.type = TokenType::LE;
      input.remove_prefix(2);
    } else {
      token.type = TokenType::LT;
      input.remove_prefix(1);
    }
  } else if (input[0] == u'>') {
    if (test(u">=")) {
      token.type = TokenType::GE;
      input.remove_prefix(2);
    } else {
      token.type = TokenType::GT;
      input.remove_prefix(1);
    }
  } else if (test(u"&&")) {
    token.type = TokenType::And;
    input.remove_prefix(2);
  } else if (test(u"||")) {
    token.type = TokenType::Or;
    input.remove_prefix(2);
  }

  else {
    token.type = TokenType::Invalid;
    input.remove_prefix(1);
    error("unknown token. ");
  }
}

void Lexer::scanNumber(Token& token) {
  if (test(u"0b") || test(u"0B")) {  // ^0[bB][_01]+
    scanBinInteger(token);
  } else if (test(u"0o") || test(u"0O")) {  // ^0[oO][_0-7]+
    scanOctInteger(token);
  } else if (test(u"0x") || test(u"0X")) {  // ^0[xX][_0-9a-fA-F]+
    scanHexInteger(token);
  } else if (input[0] == u'.') {  // .[_0-9]+([eE][+-]?[0-9]+)?
    scanDecNumberStartWithDot(token);
  } else {  // [_0-9]+(.[_0-9]*)?([eE][+-]?[0-9]+)?
    scanDecNumber(token);
  }
}

void Lexer::parseNumber(Token& token) {
  for (char16_t c : token.lexeme) {
    if (c != u'_')
      token.parsed += c;
  }
}

void Lexer::scanBinInteger(Token& token) {
  int length = 2;
  token.type = TokenType::Integer;
  for (; length < input.size();) {
    if (input[length] == u'_' || input[length] == u'0' ||
        input[length] == u'1') {
      ++length;
    } else {
      break;
    }
  }
  token.lexeme = input.substr(0, length);
  input.remove_prefix(length);
}

void Lexer::scanOctInteger(Token& token) {
  int length = 2;
  token.type = TokenType::Integer;
  for (; length < input.size();) {
    if (input[length] == u'_' ||
        (input[length] >= u'0' && input[length] <= u'7')) {
      ++length;
    } else {
      break;
    }
  }
  token.lexeme = input.substr(0, length);
  input.remove_prefix(length);
}

void Lexer::scanHexInteger(Token& token) {
  int length = 2;
  token.type = TokenType::Integer;
  for (; length < input.size();) {
    if (input[length] == u'_' || (isDigit(input[length])) ||
        (input[length] >= u'a' && input[length] <= u'f') ||
        (input[length] >= u'A' && input[length] <= u'F')) {
      ++length;
    } else {
      break;
    }
  }
  token.lexeme = input.substr(0, length);
  input.remove_prefix(length);
}

void Lexer::scanDecNumber(Token& token) {
  int length = 1;                   // 外层已经保证第一个字符是数字
  token.type = TokenType::Integer;
  for (; length < input.size();) {  // [_0-9]+
    if (input[length] == u'_' || isDigit(input[length])) {
      ++length;
    } else {
      break;
    }
  }
  if (length < input.size() && input[length] == u'.') {  // (.[_0-9]*)?
    token.type = TokenType::Float;
    ++length;                         // 跳过 .
    for (; length < input.size();) {  // [_0-9]*
      if (input[length] == u'_' || isDigit(input[length])) {
        ++length;
      } else {
        break;
      }
    }
  }
  if (length < input.size() &&  // ([eE][+-]?[0-9]+)?
      (input[length] == u'e' || input[length] == u'E')) {
    token.type = TokenType::Float;
    ++length;                     // 跳过 eE
    if (length < input.size() &&  // [+-]
        (input[length] == u'+' || input[length] == u'-')) {
      ++length;  // 跳过 +-
    }
    for (; length < input.size();) {  // [0-9]+
      if (isDigit(input[length])) {
        ++length;
      } else {
        break;
      }
    }
  }
  token.lexeme = input.substr(0, length);
  input.remove_prefix(length);
}

void Lexer::scanDecNumberStartWithDot(Token& token) {
  int length = 1;                               // 外层已保证第一个字符是 .
  token.type = TokenType::Float;
  for (; length < input.size();) {  // [_0-9]+
    if (input[length] == u'_' || isDigit(input[length])) {
      ++length;
    } else {
      break;
    }
  }
  if (length < input.size() &&  // ([eE][+-]?[0-9]+)?
      (input[length] == u'e' || input[length] == u'E')) {
    ++length;                     // 跳过 eE
    if (length < input.size() &&  // [+-]
        (input[length] == u'+' || input[length] == u'-')) {
      ++length;  // 跳过 +-
    }
    for (; length < input.size();) {  // [0-9]+
      if (isDigit(input[length])) {
        ++length;
      } else {
        break;
      }
    }
  }
  token.lexeme = input.substr(0, length);
  input.remove_prefix(length);
}

int Lexer::numberBase(const std::string& s, size_t& prefixLen) {
  prefixLen = 0;
  if (s.size() >= 2 && s[0] == '0') {
    switch (s[1]) {
      case 'b':
      case 'B':
        prefixLen = 2;
        return 2;
      case 'o':
      case 'O':
        prefixLen = 2;
        return 8;
      case 'x':
      case 'X':
        prefixLen = 2;
        return 16;
      default:
        break;
    }
  }
  return 10;
}

void Lexer::getNumberValue(Token& token) {
  std::string s8;
  s8.reserve(token.parsed.size());
  for (char16_t c : token.parsed) {  // 数字字面量只含 ASCII，直接窄化
    s8 += char(c);
  }
  if (token.type == TokenType::Integer) {
    try {
      size_t prefixLen = 0;
      int base = numberBase(s8, prefixLen);
      size_t pos = 0;
      long long value = std::stoll(s8.substr(prefixLen), &pos, base);
      if (prefixLen + pos != s8.size()) {  // 有字符没被消费，如 "0b2" 的 2
        throw std::invalid_argument("invalid integer. ");
      }
      token.numberValue.integer = value;
    } catch (...) {  // invalid_argument / out_of_range
      error("invalid integer. ");
      token.type = TokenType::Invalid;
    }
  } else if (token.type == TokenType::Float) {
    try {
      size_t pos = 0;
      double value = std::stod(s8, &pos);
      if (pos != s8.size()) {  // 有字符没被消费，如 "1e" 的 e
        throw std::invalid_argument("invalid float. ");
      }
      token.numberValue.floating = value;
    } catch (...) {
      error("invalid float. ");
      token.type = TokenType::Invalid;
    }
  }
}

void Lexer::scanBinArr(Token& token) {
  token.type = TokenType::BinArr;
  input.remove_prefix(1);  // 跳过 '
  int length = 0;
  for (; length < input.size();) {
    if (input[length] == u'\'')
      break;
    if (input[length] == u'\n')
      ++line;
    ++length;
  }
  if (length >= input.size()) {
    error("unclosed binary array. ");
    token.type = TokenType::Invalid;
    token.lexeme = input.substr(0, length);
    input.remove_prefix(input.size());
  } else {
    token.lexeme = input.substr(0, length);
    input.remove_prefix(length + 1);  // 跳过最后的 '
  }
}

void Lexer::scanString(Token& token) {
  token.type = TokenType::String;
  input.remove_prefix(1);
  int length = 0;
  for (;;) {
    if (length >= input.size()) {
      error("unclosed string literal. ");
      token.type = TokenType::Invalid;
      break;
    } else if (input[length] == u'\\') {
      length += 1;
      if (length >= input.size()) {
        error("unclosed string literal. ");
        token.type = TokenType::Invalid;
        break;
      }
      length += 1;
    } else if (input[length] == u'"') {  // 结束
      break;
    } else {
      length += 1;  // 普通字符，推进
    }
  }
  token.lexeme = input.substr(0, length);
  input.remove_prefix(length);
  if (input.size() > 0) {
    input.remove_prefix(1);
  }
  if (token.type == TokenType::String) {
    escapeString(token);
  }
}

void Lexer::escapeString(Token& token) {
  for (int i = 0; i < token.lexeme.size(); ++i) {
    if (token.lexeme[i] == u'\\') {
      ++i;
      if (i >= token.lexeme.size()) {
        error("invalid escape character. ");
        break;
      }
      if (escapeMap.find(token.lexeme[i]) != escapeMap.end()) {
        token.parsed.push_back(escapeMap.at(token.lexeme[i]));
      } else {
        error("invalid escape character. ");
        break;
      }
    } else {
      token.parsed.push_back(token.lexeme[i]);
    }
  }
}

void Lexer::scanIdent(Token& token) {
  token.type = TokenType::Ident;
  token.parsed.push_back(input[0]);  // [a-zA-Z_]
  input.remove_prefix(1);
  for (; !input.empty();) {  // [a-zA-Z0-9_]*
    if (!isIdentChar(input[0]))
      break;
    token.parsed.push_back(input[0]);
    input.remove_prefix(1);
  }
  for (; !input.empty();) {  // (?::[a-zA-Z_][a-zA-Z0-9_]*)*
    skipWs();
    if (input.empty() || input[0] != u':') {
      break;
    }
    token.parsed.push_back(input[0]);  // :
    input.remove_prefix(1);
    skipWs();
    if (input.empty() || !isIdentBegin(input[0])) {
      error("unclosed identifier. ");
      token.type = TokenType::Invalid;
      break;
    }
    for (; !input.empty();) {  // [a-zA-Z0-9_]*
      if (!isIdentChar(input[0]))
        break;
      token.parsed.push_back(input[0]);
      input.remove_prefix(1);
    }
  }
}

void Lexer::analyzeIdent(Token& token, const CustomOpcodeConfig* custom) {
  if (token.type == TokenType::Invalid) {
    return;
  }
  if (keywords.find(token.parsed) != keywords.end()) {  // 关键字
    token.type = keywords.at(token.parsed);
  } else if (custom &&  // 自定义操作码
             custom->opcodes.find(token.parsed) != custom->opcodes.end()) {
    token.type = TokenType::Custom;
  } else {  // 标识符
    token.type = TokenType::Ident;
  }
}

bool Lexer::test(const std::u16string_view& prefix) {
  if (input.size() < prefix.size())
    return false;
  return input.substr(0, prefix.size()) == prefix;
}

void Lexer::skipWs() {
  for (; !input.empty();) {
    if (whiteChars.find(input[0]) != whiteChars.end()) {  // 是空白字符，跳过
      if (input[0] == u'\n')
        ++line;
      input.remove_prefix(1);
    } else if (test(u"//")) {  // 单行注释
      size_t pos = input.find(u'\n');
      if (pos == std::u16string_view::npos) {
        input.remove_prefix(input.size());
      } else {
        input.remove_prefix(pos + 1);
        ++line;
      }
    } else if (test(u"/*")) {  // 多行注释
      skipMultilineComment();
    } else {
      break;
    }
  }
}

void Lexer::skipMultilineComment() {
  input.remove_prefix(2);
  for (; !input.empty();) {
    if (test(u"*/")) {
      input.remove_prefix(2);
      break;
    }
    if (input[0] == u'\n') {
      ++line;
    }
    input.remove_prefix(1);
  }
}

void Lexer::error(const char* msg) {
  std::stringstream ss;
  ss << "line " << line << ": " << msg;
  errors.emplace_back(ss.str());
}

bool Lexer::isDigit(char16_t ch) { return ch >= u'0' && ch <= u'9'; }

bool Lexer::isAlpha(char16_t ch) {
  return (ch >= u'a' && ch <= u'z') || (ch >= u'A' && ch <= u'Z');
}

bool Lexer::isIdentBegin(char16_t ch) { return isAlpha(ch) || ch == u'_'; }

bool Lexer::isIdentChar(char16_t ch) {
  return isIdentBegin(ch) || isDigit(ch);
}

const std::map<char16_t, char16_t> Lexer::escapeMap{
    {u'\\', u'\\'}, {u'\'', u'\''}, {u'"', u'"'},
    {u'b', u'\b'},  {u'r', u'\r'},  {u't', u'\t'},
    {u'v', u'\v'},  {u'n', u'\n'},  {u'f', u'\f'},
};

const std::map<std::u16string, TokenType> Lexer::keywords{
    {u"idiv", TokenType::IDiv},     {u"not", TokenType::Not},
    {u"and", TokenType::And},       {u"or", TokenType::Or},
    {u"if", TokenType::If},         {u"elif", TokenType::Elif},
    {u"else", TokenType::Else},     {u"let", TokenType::Let},
    {u"return", TokenType::Return}, {u"while", TokenType::While},
    {u"break", TokenType::Break},   {u"continue", TokenType::Continue},
    {u"null", TokenType::Null},     {u"false", TokenType::False},
    {u"true", TokenType::True},     {u"args", TokenType::Args},
    {u"argc", TokenType::Argc},     {u"export", TokenType::Export},
};

const std::set<char16_t> Lexer::whiteChars{
    u' ', u'\t', u'\v', u'\f', u'\n', u'\r',
};

}  // namespace Stope
