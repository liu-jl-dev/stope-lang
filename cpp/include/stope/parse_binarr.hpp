#pragma once
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>
#include <stope/common.hpp>

namespace Stope {
struct BinaryArrayParser {
  // 解析 '...' 里的内容（不含单引号），结果按字节追加到 output
  Result parseBinaryArray(std::u16string_view input_,
                          std::vector<char>& output);

 private:
  std::u16string_view input;

  // ---- 字符分类（静态谓词，可直接取函数指针） ----
  static bool isWs(char16_t c);
  static bool isBinDigit(char16_t c);
  static bool isOctDigit(char16_t c);
  static bool isDecDigit(char16_t c);
  static bool isHexDigit(char16_t c);

  // 按 base 逐段解析：每段一个数，转成一个字节追加到 output
  Result parseByBase(std::vector<char>& output, int base,
                     bool (*isDigit)(char16_t));

  // 从 input 头部取一段（空白/结束为界，下划线忽略），按 base 解释为一个数
  Result parseInteger(int& o, int base, bool (*isDigit)(char16_t));

  void skipWs();
};
}  // namespace Stope
