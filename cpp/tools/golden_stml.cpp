// golden 数据生成器：把 docs/zh-cn/stml-test-plan.md §4 的 121 条用例在 C++ 侧的
// 真实输出 dump 成机器可读文本，供 GDScript 测试直接引用（期望值不手推）。
//
// 与另三个 golden*.cpp 的差别：**用例不内嵌在本文件里**，而是读
// gdscript/test/data/stml_cases.txt —— 那一份是两侧共用的用例清单，
// 加删用例只改它一个地方。
//
// 常规用法（在 cpp/ 下，四个文件一起重生成）：
//   cmake --build build --target gen-golden
//
// 手动单跑：
//   g++ -std=c++20 -I include -I test -o gen_stml.exe tools/golden_stml.cpp \
//       src/stml_lexer.cpp src/stml_parser.cpp
//   ./gen_stml.exe ../gdscript/test/data/stml_cases.txt \
//       | tr -d '\r' > ../gdscript/test/data/golden_stml.txt
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include <stope/stml_parser.hpp>
#include <stope/utf.hpp>

#include "test_stml_common.hpp"

using namespace Stope;
using namespace Stope::STML;
using namespace Stope::STML::Test;

namespace {

// 与 GDScript 侧 StopeTestUtil.unesc 同一套规则：\\ \n \r \t
std::string unesc(const std::string& s) {
  std::string o;
  for (size_t i = 0; i < s.size();) {
    if (s[i] == '\\' && i + 1 < s.size()) {
      const char c = s[i + 1];
      if (c == '\\' || c == 'n' || c == 'r' || c == 't') {
        o += (c == '\\') ? '\\' : (c == 'n' ? '\n' : (c == 'r' ? '\r' : '\t'));
        i += 2;
        continue;
      }
    }
    o += s[i];
    ++i;
  }
  return o;
}

std::vector<std::string> split(const std::string& s, char sep) {
  std::vector<std::string> o;
  std::string cur;
  for (char c : s) {
    if (c == sep) {
      o.push_back(cur);
      cur.clear();
    } else {
      cur += c;
    }
  }
  o.push_back(cur);
  return o;
}

// "K=V" -> 只在第一个 '=' 处切，值里可以再含 '='
bool splitKV(const std::string& part, std::string& k, std::string& v) {
  const size_t p = part.find('=');
  if (p == std::string::npos)
    return false;
  k = part.substr(0, p);
  v = part.substr(p + 1);
  return true;
}

std::string escErr(const std::string& e) {
  return Stope::Test::escUtf8(UTF::Utf8ToUtf16(e));
}

// 以 '|' 连接，与 GDScript 侧 StopeTestUtil.join_esc 一致
std::string joinErr(const std::vector<std::string>& errs) {
  std::string o;
  for (size_t i = 0; i < errs.size(); ++i) {
    if (i)
      o += "|";
    o += escErr(errs[i]);
  }
  return o;
}

LexerState parseState(const std::string& s) {
  if (s == "Text")
    return LexerState::Text;
  if (s == "Nevext")
    return LexerState::Nevext;
  if (s == "Stope")
    return LexerState::Stope;
  return LexerState::Xml;
}

// SF=text：任何标签的内容都按普通文本扫
LexerState textStateFunc(std::u16string_view,
                         std::map<std::u16string_view, std::u16string_view>) {
  return LexerState::Text;
}

// lexeme 只在「双方实现都提供」的类型上比对：标点与 Eof 的 lexeme 属实现自定，
// 计划 §2.2 不断言。
bool hasLexeme(STML::TokenType t) {
  return t == STML::TokenType::Word || t == STML::TokenType::String ||
         t == STML::TokenType::Text || t == STML::TokenType::NevextSrc ||
         t == STML::TokenType::StopeSrc;
}

void dumpLex(const std::string& id, const std::u16string& src, LexerState st) {
  const SLexResult r = slexAll(src, st);
  std::string toks;
  std::string lexes;
  for (size_t i = 0; i < r.size(); ++i) {
    const STML::Token& t = r.at(i);
    if (i)
      toks += " ";
    toks += stmlTokenName(t.type);
    toks += "(" + std::to_string(t.line) + ")";
    if (hasLexeme(t.type)) {
      if (!lexes.empty())
        lexes += ",";
      lexes += std::to_string(i) + ":" + Stope::Test::escUtf8(t.lexeme);
    }
  }
  std::cout << "ID=" << id << "\tKIND=lex\tTOKS=" << toks << "\tLEXS=" << lexes
            << "\tERRN=" << r.errors.size() << "\tERRS=" << joinErr(r.errors)
            << "\n";
}

void dumpParse(const std::string& id,
               const std::u16string& src,
               const std::string& sf) {
  LexerStateFunc f = defaultStateFunc;
  if (sf == "null")
    f = nullptr;
  else if (sf == "text")
    f = textStateFunc;
  const SParseResult r = sparseAll(src, f);
  std::cout << "ID=" << id << "\tKIND=parse\tSHAPE=" << r.shape()
            << "\tRESULT="
            << (r.result == Stope::Result::Success ? "Success" : "Error")
            << "\tERRN=" << r.errors.size() << "\tERRS=" << joinErr(r.errors)
            << "\tLEXERRN=" << r.lexErrors.size()
            << "\tLEXERRS=" << joinErr(r.lexErrors) << "\n";
}

}  // namespace

int main(int argc, char** argv) {
  // 默认值按「在 cpp/ 下运行」解析；CMake 的 gen-golden 会显式传绝对路径。
  const std::string path = (argc > 1) ? argv[1] : "../gdscript/test/data/stml_cases.txt";
  std::ifstream in(path);
  if (!in) {
    std::cerr << "打不开用例清单: " << path << "\n"
              << "用法: " << argv[0] << " <stml_cases.txt 路径>\n";
    return 1;
  }
  std::cout << "# 由 cpp/tools/golden_stml.cpp 从 gdscript/test/data/stml_cases.txt 生成，"
               "勿手工编辑。\n";
  std::string raw;
  while (std::getline(in, raw)) {
    if (!raw.empty() && raw.back() == '\r')
      raw.pop_back();
    if (raw.empty() || raw[0] == '#')
      continue;
    std::string id, kind, st, sf, src;
    int times = 1;
    for (const auto& part : split(raw, '\t')) {
      std::string k, v;
      if (!splitKV(part, k, v))
        continue;
      if (k == "ID")
        id = v;
      else if (k == "KIND")
        kind = v;
      else if (k == "ST")
        st = v;
      else if (k == "SF")
        sf = v;
      else if (k == "SRC")
        src = v;
      else if (k == "TIMES")
        times = std::atoi(v.c_str());
    }
    if (id.empty())
      continue;
    std::string one = unesc(src);
    std::string all;
    for (int i = 0; i < times; ++i)
      all += one;
    const std::u16string u = UTF::Utf8ToUtf16(all);
    if (kind == "parse")
      dumpParse(id, u, sf);
    else
      dumpLex(id, u, parseState(st));
  }
  return 0;
}
