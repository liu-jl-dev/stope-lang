#pragma once
//
// utf.hpp —— UTF-8 / UTF-16 字符串互转（header-only，C++20）
//
// ⚠ 本文件由 LLM 生成（2026-10-13），未经大规模生产环境验证，
//   合入前请自行审阅，尤其是错误恢复策略是否符合你的业务预期。
//
// 所有公开函数位于 namespace utf，调用时写作 utf::Utf16ToUtf8(...)。
// 内部辅助函数同样在该命名空间内，以 Utf 前缀区分
// （UtfNextUtf8 / UtfAppendUtf8 / kUtfReplacement 等），请勿在业务代码中直接调用。
//
// 实现取舍：
//   1. 手写编解码，不使用 C++17 起弃用、C++26 移除的 <codecvt> /
//      std::wstring_convert；
//   2. 不依赖平台 API（Windows 的 MultiByteToWideChar / WideCharToMultiByte），
//      可跨平台编译；
//   3. 合法性判定严格遵循 Unicode 15 Table 3-7（Well-Formed UTF-8 Byte
//      Sequences），因此 overlong、UTF-8 编码的代理项、超出 U+10FFFF 的序列
//      在字节层面就会被拦下，无需事后检查码位；
//   4. 错误恢复采用标准的「最大子部分（maximal subpart）」规则：一段非法序列
//      只产出 1 个 U+FFFD，之后从下一个合法边界继续，
//      与浏览器 / ICU 的行为一致（例如 "\xE6\x97" "A" → U+FFFD + 'A'）；
//   5. 提供两套接口：
//        · 宽容版（返回新字符串）：非法序列替换为 U+FFFD，绝不抛异常；
//        · 严格版（写入 out 并返回 bool）：遇到非法序列立即返回 false，
//          并通过 errPos 给出出错下标。
//
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

// ---------------------------------------------------------------- 内部辅助
// 以下函数供本文件内部使用，不属于公开 API。
namespace utf {

inline constexpr char32_t kUtfReplacement = 0xFFFD;     // U+FFFD 替换字符
inline constexpr char32_t kUtfMaxCodePoint = 0x10FFFF;  // Unicode 码位上界

// 把一个码位以 UTF-8 追加到 out。
// cp 越界或落在代理区时自动降级为 U+FFFD，保证输出永远是合法 UTF-8。
inline void UtfAppendUtf8(std::string& out, char32_t cp) {
  if (cp > kUtfMaxCodePoint || (cp >= 0xD800 && cp <= 0xDFFF))
    cp = kUtfReplacement;
  if (cp < 0x80) {
    out.push_back(static_cast<char>(cp));
  } else if (cp < 0x800) {
    out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else if (cp < 0x10000) {
    out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else {
    out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  }
}

// 把一个码位以 UTF-16 追加到 out（非 BMP 码位自动拆成代理对）。
inline void UtfAppendUtf16(std::u16string& out, char32_t cp) {
  if (cp > kUtfMaxCodePoint || (cp >= 0xD800 && cp <= 0xDFFF))
    cp = kUtfReplacement;
  if (cp < 0x10000) {
    out.push_back(static_cast<char16_t>(cp));
  } else {
    const char32_t v = cp - 0x10000;
    out.push_back(static_cast<char16_t>(0xD800 + (v >> 10)));
    out.push_back(static_cast<char16_t>(0xDC00 + (v & 0x3FF)));
  }
}

// 由 UTF-8 首字节判断序列总长度；返回 0 表示首字节非法。
// 0xC0/0xC1（overlong）与 0xF5~0xFF（超出 U+10FFFF）都在此拒绝。
inline std::size_t Utf8SequenceLength(unsigned char lead) {
  if (lead < 0x80)
    return 1;
  if (lead >= 0xC2 && lead <= 0xDF)
    return 2;
  if (lead >= 0xE0 && lead <= 0xEF)
    return 3;
  if (lead >= 0xF0 && lead <= 0xF4)
    return 4;
  return 0;
}

// 第二个字节的合法区间（Unicode Table 3-7）。
// 正是这几条边界把 overlong、UTF-8 编码的代理项、超限码位挡在门外。
inline void Utf8SecondByteRange(unsigned char lead,
                                unsigned char& lo,
                                unsigned char& hi) {
  lo = 0x80;
  hi = 0xBF;
  if (lead == 0xE0)
    lo = 0xA0;  // 否则会出现 overlong
  else if (lead == 0xED)
    hi = 0x9F;  // 否则会编码出代理项 U+D800~U+DFFF
  else if (lead == 0xF0)
    lo = 0x90;  // 否则会出现 overlong
  else if (lead == 0xF4)
    hi = 0x8F;  // 否则会超过 U+10FFFF
}

// 从 UTF-8 中读取下一个码位，i 前进 1~4。
// 返回 false 表示序列非法：cp 被置为 U+FFFD，i 跳过整个「最大子部分」
// （至少 1 字节），保证不会死循环，也不会误伤后续合法字符。
inline bool UtfNextUtf8(std::string_view src, std::size_t& i, char32_t& cp) {
  const unsigned char lead = static_cast<unsigned char>(src[i]);
  const std::size_t len = Utf8SequenceLength(lead);
  if (len == 0) {  // 非法首字节：孤立续字节 / 0xC0 / 0xC1 / 0xF5~0xFF
    cp = kUtfReplacement;
    i += 1;
    return false;
  }
  unsigned char lo = 0x80, hi = 0xBF;
  Utf8SecondByteRange(lead, lo, hi);
  std::size_t k = 1;
  for (; k < len; ++k) {
    if (i + k >= src.size())
      break;  // 序列被输入末尾截断
    const unsigned char b = static_cast<unsigned char>(src[i + k]);
    if (k == 1 ? (b < lo || b > hi) : (b & 0xC0) != 0x80)
      break;
  }
  if (k < len) {  // 非法序列：整段最大子部分换成 1 个 U+FFFD
    cp = kUtfReplacement;
    i += k;
    return false;
  }
  switch (len) {
    case 1:
      cp = static_cast<char32_t>(lead);
      break;
    case 2:
      cp = (static_cast<char32_t>(lead & 0x1F) << 6) |
           static_cast<char32_t>(src[i + 1] & 0x3F);
      break;
    case 3:
      cp = (static_cast<char32_t>(lead & 0x0F) << 12) |
           (static_cast<char32_t>(src[i + 1] & 0x3F) << 6) |
           static_cast<char32_t>(src[i + 2] & 0x3F);
      break;
    default:
      cp = (static_cast<char32_t>(lead & 0x07) << 18) |
           (static_cast<char32_t>(src[i + 1] & 0x3F) << 12) |
           (static_cast<char32_t>(src[i + 2] & 0x3F) << 6) |
           static_cast<char32_t>(src[i + 3] & 0x3F);
      break;
  }
  i += len;
  return true;
}

// 从 UTF-16 中读取下一个码位，i 前进 1 或 2。
// 返回 false 表示遇到孤立代理项：cp 被置为 U+FFFD，i 前进 1。
inline bool UtfNextUtf16(std::u16string_view src,
                         std::size_t& i,
                         char32_t& cp) {
  const char16_t hi = src[i];
  if (hi >= 0xD800 && hi <= 0xDBFF) {  // 高代理项
    if (i + 1 < src.size()) {
      const char16_t lo = src[i + 1];
      if (lo >= 0xDC00 && lo <= 0xDFFF) {  // 合法的代理对
        cp = 0x10000u + (static_cast<char32_t>(hi - 0xD800) << 10) +
             static_cast<char32_t>(lo - 0xDC00);
        i += 2;
        return true;
      }
    }
    cp = kUtfReplacement;
    i += 1;  // 孤立高代理项
    return false;
  }
  if (hi >= 0xDC00 && hi <= 0xDFFF) {  // 孤立低代理项
    cp = kUtfReplacement;
    i += 1;
    return false;
  }
  cp = static_cast<char32_t>(hi);
  i += 1;
  return true;
}

// ================================================================ 宽容版本
// 任何非法序列都会按「最大子部分」替换为 U+FFFD，不会失败、不会抛异常。

// UTF-16 → UTF-8
inline std::string Utf16ToUtf8(std::u16string_view src) {
  std::string out;
  out.reserve(src.size() * 3 / 2);  // 多数情况下够用，避免反复扩容
  char32_t cp = 0;
  for (std::size_t i = 0; i < src.size();) {
    UtfNextUtf16(src, i, cp);
    UtfAppendUtf8(out, cp);
  }
  return out;
}

// UTF-8 → UTF-16
inline std::u16string Utf8ToUtf16(std::string_view src) {
  std::u16string out;
  out.reserve(src.size());  // UTF-16 单元数不会超过 UTF-8 字节数
  char32_t cp = 0;
  for (std::size_t i = 0; i < src.size();) {
    UtfNextUtf8(src, i, cp);
    UtfAppendUtf16(out, cp);
  }
  return out;
}

// ================================================================ 严格版本
// out 会先被清空；返回 false 表示输入不合法，errPos（可选）给出出错下标。
// 注意：出错时 out 中保留的是出错位置之前已成功转换的前缀，不是空串。

// UTF-16 → UTF-8
inline bool Utf16ToUtf8(std::u16string_view src,
                        std::string& out,
                        std::size_t* errPos = nullptr) {
  out.clear();
  out.reserve(src.size() * 3 / 2);
  char32_t cp = 0;
  for (std::size_t i = 0; i < src.size();) {
    const std::size_t begin = i;
    if (!UtfNextUtf16(src, i, cp)) {
      if (errPos)
        *errPos = begin;
      return false;
    }
    UtfAppendUtf8(out, cp);
  }
  return true;
}

// UTF-8 → UTF-16
inline bool Utf8ToUtf16(std::string_view src,
                        std::u16string& out,
                        std::size_t* errPos = nullptr) {
  out.clear();
  out.reserve(src.size());
  char32_t cp = 0;
  for (std::size_t i = 0; i < src.size();) {
    const std::size_t begin = i;
    if (!UtfNextUtf8(src, i, cp)) {
      if (errPos)
        *errPos = begin;
      return false;
    }
    UtfAppendUtf16(out, cp);
  }
  return true;
}

// ================================================================ C++20
// 便利重载 std::u8string / std::u8string_view（char8_t）与 std::string
// 内存布局一致， 这里只做零开销的 reinterpret 转换。

inline std::u16string Utf8ToUtf16(std::u8string_view src) {
  return Utf8ToUtf16(
      std::string_view(reinterpret_cast<const char*>(src.data()), src.size()));
}

// 注：无法按返回类型重载，故取名为 Utf16ToU8。
inline std::u8string Utf16ToU8(std::u16string_view src) {
  const std::string s = Utf16ToUtf8(src);
  return std::u8string(reinterpret_cast<const char8_t*>(s.data()), s.size());
}

// ================================================================ wchar_t
// 便利重载 Windows 上 wchar_t 为 16 位，可直接当作 UTF-16； Linux / macOS 上为
// 32 位，按码位逐个转换。

inline std::string WideToUtf8(std::wstring_view src) {
  if constexpr (sizeof(wchar_t) == sizeof(char16_t)) {
    return Utf16ToUtf8(std::u16string_view(
        reinterpret_cast<const char16_t*>(src.data()), src.size()));
  } else {
    std::string out;
    out.reserve(src.size());
    for (wchar_t wc : src)
      UtfAppendUtf8(out, static_cast<char32_t>(wc));
    return out;
  }
}

inline std::wstring Utf8ToWide(std::string_view src) {
  if constexpr (sizeof(wchar_t) == sizeof(char16_t)) {
    const std::u16string u16 = Utf8ToUtf16(src);
    return std::wstring(reinterpret_cast<const wchar_t*>(u16.data()),
                        u16.size());
  } else {
    std::wstring out;
    out.reserve(src.size());
    char32_t cp = 0;
    for (std::size_t i = 0; i < src.size();) {
      UtfNextUtf8(src, i, cp);
      out.push_back(static_cast<wchar_t>(cp));
    }
    return out;
  }
}
}  // namespace utf

// ---------------------------------------------------------------- 用法示例
//
//   #include "utf.hpp"
//
//   std::u16string u16  = u"海上生明月 \U0001F315";       // 🌕 U+1F315
//   std::string    u8   = utf::Utf16ToUtf8(u16);          // → UTF-8 字节串
//   std::u16string back = utf::Utf8ToUtf16(u8);           // → 与 u16 相同
//
//   std::u16string out;
//   std::size_t pos = 0;
//   if (!utf::Utf8ToUtf16(u8, out, &pos)) {               // 严格模式
//     printf("非法 UTF-8，位置 %zu\n", pos);
//   }
//
// 配合本项目的 demo01.cpp（内部统一 std::u16string，输出 std::string）：
//
//   #include "utf.hpp"
//   for (auto& str : prog[i].strings) {
//     cout << utf::Utf16ToUtf8(str) << " ";
//   }
//
