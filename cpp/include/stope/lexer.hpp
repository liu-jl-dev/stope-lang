#pragma once
#include <set>
#include <sstream>
#include <stdexcept>
#include <stope/common.hpp>
#include <stope/opcode.hpp>
#include <stope/scope_context.hpp>
#include <stope/token.hpp>
#include <string>
#include <string_view>
#include <vector>

namespace Stope {
struct Lexer {
  std::u16string_view input;
  std::vector<std::string> errors;
  int line = 1;
  void NextToken(Token& token, const CustomOpcodeConfig* custom = nullptr);
  Lexer(std::u16string_view input) { Reset(input); }
  void Reset(std::u16string_view input) {
    line = 1;
    this->input = input;
    errors.clear();
  }

 private:
  // 将 type 和 lexeme 输出到 token
  void scanNumber(Token& token);
  void parseNumber(Token& token);
  void scanBinInteger(Token& token);
  void scanOctInteger(Token& token);
  void scanHexInteger(Token& token);
  void scanDecNumber(Token& token);
  void scanDecNumberStartWithDot(Token& token);
  // 按字面量前缀决定基数，并回传前缀长度（调用方需跳过前缀后再转换）
  // 0b/0B -> 2，0o/0O -> 8，0x/0X -> 16，其余（含 "0"、"0009"）-> 10
  static int numberBase(const std::string& s, size_t& prefixLen);
  void getNumberValue(Token& token);
  void scanBinArr(Token& token);
  void scanString(Token& token);
  static const std::map<char16_t, char16_t> escapeMap;
  void escapeString(Token& token);
  // ^[a-zA-Z_][a-zA-Z0-9_]*(?::[a-zA-Z_][a-zA-Z0-9_]*)*
  void scanIdent(Token& token);
  void analyzeIdent(Token& token, const CustomOpcodeConfig* custom);
  static const std::map<std::u16string, TokenType> keywords;
  bool test(const std::u16string_view& prefix);
  static const std::set<char16_t> whiteChars;
  void skipWs();
  void skipMultilineComment();
  void error(const char* msg);
  static bool isDigit(char16_t ch);
  static bool isAlpha(char16_t ch);
  static bool isIdentBegin(char16_t ch);
  static bool isIdentChar(char16_t ch);
};
}  // namespace Stope
