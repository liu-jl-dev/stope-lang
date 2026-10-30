#pragma once
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

namespace Stope::STML {
enum class TokenType {
  Invalid,
  EndOfFile,
  LAngle,     // <
  RAngle,     // >
  CLAngle,    // </
  CRAngle,    // />
  EQ,         // =
  Word,       // ^[a-zA-Z_:][a-zA-Z0-9_:-]*$  （注意不含 '.'，见 cpp/docs/stml-test-plan.md TD-1）
  String,     // ""  ''
  Text,       // 一般元素中的文本
  NevextSrc,  // Nevext 代码
  StopeSrc,   // Stope 代码
};

struct Token {
  TokenType type;
  int line;
  std::u16string_view lexeme;
};

enum class LexerState {
  Xml,
  Text,
  Nevext,
  Stope,
};

struct Lexer {
  std::u16string_view input;
  int line = 1;
  std::vector<std::string> errors;
  LexerState state = LexerState::Xml;
  Lexer(const std::u16string_view& input);
  void NextToken(Token& token);

 private:
  bool isWordBegin(char16_t c);
  bool isWordChar(char16_t c);
  void scanWord(Token& token);
  void scanString(Token& token);
  // 元素内容：一直取到 '</' （结束标签）为止，尾部空白不计入 lexeme。
  void scanText(Token& token);
  // 扫描一段 Nevext 代码，直到 '</'（结束标签）为止。
  // 引号字符串与注释整段跳过，其中的 '</' 不会被误判成结束标签。
  // 换行计入行号；尾部空白不计入 lexeme；遇到 '</' 时把状态交还给 Xml。
  void scanNevextSrc(Token& token);
  // 单行注释：'//' 到行尾。换行符一并消费，并推进行号。
  int scanNevextSinglelineComment();
  // 多行注释：'/*' 到 '*/'。未闭合不是错误，一直吃到输入末尾。
  int scanNevextMultilineComment();
  // 扫描一个引号字符串（sq_str / dq_str），含两侧引号。会推进 input，
  // 返回消费的字符总数。Nevext 的转义字符：\'  \"  \\  \n  \r  \t  \v  \b  \f；
  // 反斜杠后的任意字符都被吃掉，被转义的换行同样推进 line。
  // 到输入末尾仍未闭合时报错，并消费掉剩余全部输入（保证调用方不会死循环）。
  int scanNevextString(char16_t quote);
  // 扫描一段 Stope 代码，直到 '</'（结束标签）为止。与 scanNevextSrc 同构，
  // 只有引号字面量的转义规则不同（见 scanStopeString）。
  void scanStopeSrc(Token& token);
  // 扫描 Stope 的引号字面量，含两侧引号。会推进 input，返回消费的字符总数。
  // - 双引号是字符串字面量，支持转义（\"  \\  \'  \n  \r  \t  \v  \b  \f）；
  // - 单引号是 BinArr 字面量，与 Stope::Lexer::scanBinArr 一致：不做任何转义，
  //   遇到下一个 ' 就结束。
  // 字面量内部的换行同样推进 line（STML 只要求 "后续 token
  // 的行号是物理行号"）。 未闭合时报错并消费掉剩余全部输入。
  int scanStopeString(char16_t quote);
  // 单行注释：'//' 到行尾。换行符一并消费，并推进行号。
  int scanStopeSinglelineComment();
  // 多行注释：'/*' 到 '*/'。未闭合不是错误，一直吃到输入末尾。
  int scanStopeMultilineComment();
  void skipWs();
  void skipXmlComment();
  bool test(const std::u16string_view& prefix);
  bool test2(const std::u16string_view& prefix, int offset);
  void error(const char* msg);
  // 指定行号报错：跨行的字面量/注释报的是起始行，不是当前行
  void error2(int line_, const char* msg);
  // 去掉尾部空白字符
  static std::u16string_view trimTrailingWs(const std::u16string_view& s);
};
}  // namespace Stope::STML
