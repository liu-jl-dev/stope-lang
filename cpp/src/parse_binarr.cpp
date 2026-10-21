#include <stope/parse_binarr.hpp>

#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace Stope {

Result BinaryArrayParser::parseBinaryArray(std::u16string_view input_, std::vector<char>& output) {
  input = input_;
  skipWs();
  if (input.empty())
    return Success;  // 空内容：合法的空数组
  char16_t c = input[0];
  if (c == u'b' || c == u'B') {
    input.remove_prefix(1);
    return parseByBase(output, 2, isBinDigit);
  } else if (c == u'o' || c == u'O') {
    input.remove_prefix(1);
    return parseByBase(output, 8, isOctDigit);
  } else if (c == u'd' || c == u'D') {
    input.remove_prefix(1);
    return parseByBase(output, 10, isDecDigit);
  } else if (c == u'x' || c == u'X') {
    input.remove_prefix(1);
    return parseByBase(output, 16, isHexDigit);
  }
  // 无前缀：按十六进制解析（首字符尚未消费，即数据本身）
  return parseByBase(output, 16, isHexDigit);
}

bool BinaryArrayParser::isWs(char16_t c) {
  return c == u' ' || c == u'\t' || c == u'\n' || c == u'\r' || c == u'\v' ||
         c == u'\f';
}

bool BinaryArrayParser::isBinDigit(char16_t c) { return c == u'0' || c == u'1'; }

bool BinaryArrayParser::isOctDigit(char16_t c) { return c >= u'0' && c <= u'7'; }

bool BinaryArrayParser::isDecDigit(char16_t c) { return c >= u'0' && c <= u'9'; }

bool BinaryArrayParser::isHexDigit(char16_t c) {
  return isDecDigit(c) || (c >= u'a' && c <= u'f') ||
         (c >= u'A' && c <= u'F');
}

Result BinaryArrayParser::parseByBase(std::vector<char>& output, int base, bool (*isDigit)(char16_t)) {
  skipWs();
  for (; !input.empty(); skipWs()) {
    int value;
    if (parseInteger(value, base, isDigit) != Result::Success) {
      return Result::Error;
    }
    output.push_back(static_cast<char>(value));
  }
  return Result::Success;
}

Result BinaryArrayParser::parseInteger(int& o, int base, bool (*isDigit)(char16_t)) {
  std::string u8s;
  for (; !input.empty();) {
    if (isWs(input[0])) {
      break;
    }
    if (isDigit(input[0])) {
      u8s.push_back(static_cast<char>(input[0]));
      input.remove_prefix(1);
    } else if (input[0] == u'_') {
      input.remove_prefix(1);
    } else {  // 出现了该进制不允许的字符
      input.remove_prefix(1);
      return Result::Error;
    }
  }
  if (u8s.empty()) {  // 空段或只有下划线，不能交给 stoi
    return Result::Error;
  }
  try {
    o = std::stoi(u8s, nullptr, base);
  } catch (...) {  // invalid_argument / out_of_range
    return Result::Error;
  }
  return Result::Success;
}

void BinaryArrayParser::skipWs() {
  while (!input.empty() && isWs(input[0])) {
    input.remove_prefix(1);
  }
}

}  // namespace Stope
