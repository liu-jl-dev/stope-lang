#pragma once
// STML 测试框架（2026-10-18 新增）
//
// 与 cpp/stope 的 header-only 现状一致：零第三方依赖。
// 计数与断言核心复用 Stope::Test（test_common.hpp）的 g_total/g_failed/g_known/g_flip
// 与 check()/knownCheck()，这样 ctest 一个二进制就能汇总。
//
// 宏一律带 S 前缀（EXPECT_STOK_* / EXPECT_SP_*），避免与 lexer/parser 的宏重名。
//
// ⚠ 两条硬约束（与 lexer/parser 测试同源）：
//   1) STML::Token::lexeme 是指向输入的 string_view，不拥有内存。
//      slexAll()/sparseAll() 用 shared_ptr 持有输入副本，保证断言期间有效。
//   2) slexAll() 内置 10000 次迭代上限，兜底 NextToken 不消费字符导致的死循环。
//      （stml_lexer 历史上就有这个坑：skipWs 缺 else break、scanWord 不推进。）

#include <cstdio>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include <stope/stml_lexer.hpp>
#include <stope/stml_parser.hpp>
#include "test_common.hpp"

namespace Stope::STML::Test {

// ---------------------------------------------------------------- 类型与名字

inline std::set<int> g_seenSTMLTypes;  // STML::TokenType 覆盖统计

inline const char* stmlTokenName(TokenType t) {
  switch (t) {
    case TokenType::Invalid:    return "Invalid";
    case TokenType::EndOfFile:  return "Eof";
    case TokenType::LAngle:     return "LAngle";
    case TokenType::RAngle:     return "RAngle";
    case TokenType::CLAngle:    return "CLAngle";
    case TokenType::CRAngle:    return "CRAngle";
    case TokenType::EQ:         return "EQ";
    case TokenType::Word:       return "Word";
    case TokenType::String:     return "String";
    case TokenType::Text:       return "Text";
    case TokenType::NevextSrc:  return "NevextSrc";
    case TokenType::StopeSrc:   return "StopeSrc";
  }
  return "?";
}

inline const char* stmlStateName(LexerState s) {
  switch (s) {
    case LexerState::Xml:     return "Xml";
    case LexerState::Text:    return "Text";
    case LexerState::Nevext:  return "Nevext";
    case LexerState::Stope:   return "Stope";
  }
  return "?";
}

// ---------------------------------------------------------------- 词法驱动

struct SLexResult {
  std::shared_ptr<const std::u16string> src;  // 持有输入，保证 lexeme 有效
  std::vector<Token> tokens;
  std::vector<std::string> errors;
  std::vector<LexerState> states;  // 产出该 token 之后 lexer 的 state（状态回退断言用）
  size_t size() const { return tokens.size(); }
  const Token& at(size_t i) const { return tokens[i]; }
};

// 从指定状态开始一路扫到 Eof。lexer 在 Text/Nevext/Stope 遇到 "</" 会把 state
// 交还 Xml（stml_lexer 2026-10-18 补的语义），所以一路扫到底不会无限空 token。
inline SLexResult slexAll(std::u16string src, LexerState state = LexerState::Xml) {
  auto holder = std::make_shared<std::u16string>(std::move(src));
  SLexResult r;
  r.src = holder;
  Lexer lx(*holder);
  lx.state = state;
  for (int i = 0; i < 10000; ++i) {  // 死循环保险丝
    Token t{};
    lx.NextToken(t);
    g_seenSTMLTypes.insert(static_cast<int>(t.type));
    r.tokens.push_back(t);
    r.states.push_back(lx.state);
    if (t.type == TokenType::EndOfFile) break;
  }
  r.errors = lx.errors;
  return r;
}

inline std::string slErrDetail(const SLexResult& r) {
  std::string d = "errors=" + std::to_string(r.errors.size());
  for (const auto& e : r.errors) d += "\n         [" + e + "]";
  return d;
}

inline std::string stokDesc(const SLexResult& r, size_t i) {
  if (i >= r.tokens.size()) return "<index out of range>";
  const Token& t = r.tokens[i];
  return "tok[" + std::to_string(i) + "] type=" + stmlTokenName(t.type) +
         " lex=[" + Stope::Test::escUtf8(t.lexeme) + "]" +
         " line=" + std::to_string(t.line) +
         " state=" + stmlStateName(r.states[i]);
}

// 类型序列整体比对，如 EXPECT_SSEQ(r, "LAngle Word RAngle Eof", "SX-01")
inline std::string stokSeq(const SLexResult& r) {
  std::string got;
  for (const auto& t : r.tokens) {
    got += stmlTokenName(t.type);
    got += " ";
  }
  if (!got.empty()) got.pop_back();
  return got;
}

// ---------------------------------------------------------------- 语法驱动

// 默认回调：<sto> → Stope，<nev> → Nevext，<p> → Text，其余 → Xml（子元素模式）
inline LexerState defaultStateFunc(
    std::u16string_view tag,
    std::map<std::u16string_view, std::u16string_view>) {
  if (tag == u"sto") return LexerState::Stope;
  if (tag == u"nev") return LexerState::Nevext;
  if (tag == u"p") return LexerState::Text;
  return LexerState::Xml;
}

// Element 形状串：字段顺序固定 —— tag、行号、自闭合、属性、文本、子元素。
//   Elem(a, L1)                        空元素对
//   Elem(a, L1, /)                     自闭合
//   Elem(a, L1, @id="x", @flag)        属性；无值属性只写名字
//   Elem(a, L1, T="hello")             文本
//   Elem(a, L1, C=[Elem(b, L1, /)])    子元素
// 属性来自 std::map，顺序是键的字典序，**不是源码顺序**（项目定夺：不保证属性顺序）。
inline std::string shapeElem(const Element& e) {
  std::string d = "Elem(" + Stope::Test::escUtf8(e.tagName) + ", L" +
                  std::to_string(e.line);
  if (e.selfClosing) d += ", /";
  for (const auto& [k, v] : e.attrs) {
    d += ", @" + Stope::Test::escUtf8(k);
    if (!v.empty()) d += "=\"" + Stope::Test::escUtf8(v) + "\"";
  }
  if (!e.text.empty()) d += ", T=\"" + Stope::Test::escUtf8(e.text) + "\"";
  if (!e.children.empty()) {
    d += ", C=[";
    for (size_t i = 0; i < e.children.size(); ++i) {
      if (i) d += " ";
      d += shapeElem(e.children[i]);
    }
    d += "]";
  }
  return d + ")";
}

struct SParseResult {
  std::shared_ptr<const std::u16string> src;  // 持有输入，保证 tagName/text 有效
  Element root;
  std::vector<std::string> errors;      // Parser::errors（语法错误）
  std::vector<std::string> lexErrors;   // Lexer::errors（词法错误，两侧不合并）
  Stope::Result result = Stope::Result::Success;
  std::string shape() const { return shapeElem(root); }
};

inline SParseResult sparseAll(std::u16string src,
                              LexerStateFunc sf = defaultStateFunc) {
  auto holder = std::make_shared<std::u16string>(std::move(src));
  SParseResult r;
  r.src = holder;
  Lexer lx(*holder);
  Parser p(lx);
  r.result = p.Parse(r.root, sf);
  r.errors = p.errors;
  r.lexErrors = lx.errors;
  return r;
}

inline std::string spErrDetail(const SParseResult& r) {
  std::string d = "errors=" + std::to_string(r.errors.size());
  for (const auto& e : r.errors) d += "\n         [P " + e + "]";
  if (!r.lexErrors.empty()) {
    d += "\n         lexErrors=" + std::to_string(r.lexErrors.size());
    for (const auto& e : r.lexErrors) d += "\n         [L " + e + "]";
  }
  return d;
}

inline std::string spRootDesc(const SParseResult& r) {
  return "root=" + shapeElem(r.root) + " result=" +
         (r.result == Stope::Result::Success ? "Success" : "Error");
}

// 树的深度（根节点算 1），SF-02 深嵌套用
inline int spDepth(const Element& e) {
  int d = 1;
  for (const auto& c : e.children) {
    int cd = spDepth(c);
    if (cd + 1 > d) d = cd + 1;
  }
  return d;
}

// ---------------------------------------------------------------- 覆盖统计

// STML::TokenType 共 12 项，全部要被至少 1 个用例产生
inline int stmlTypeCoverage() {
  int missing = 0;
  printf("\n-- STML TokenType 覆盖\n");
  for (int i = 0; i < 12; ++i) {
    if (g_seenSTMLTypes.find(i) == g_seenSTMLTypes.end()) {
      printf("   未覆盖: %s\n", stmlTokenName(static_cast<TokenType>(i)));
      ++missing;
    }
  }
  printf("   已覆盖 %zu/12\n", g_seenSTMLTypes.size());
  return missing;
}

}  // namespace Stope::STML::Test

// ---- STML 词法断言宏 ----
#define EXPECT_STOK_TYPE(r, i, T, id)                                        \
  Stope::Test::check(static_cast<size_t>(i) < (r).size() &&                  \
                         (r).at(i).type == (T),                              \
                     (id), "type == " #T, Stope::STML::Test::stokDesc(r, i))
#define EXPECT_STOK_LEX(r, i, U16, id)                                       \
  Stope::Test::check(static_cast<size_t>(i) < (r).size() &&                  \
                         (r).at(i).lexeme == (U16),                          \
                     (id), "lexeme == " #U16,                                \
                     Stope::STML::Test::stokDesc(r, i))
#define EXPECT_STOK_LINE(r, i, N, id)                                        \
  Stope::Test::check(static_cast<size_t>(i) < (r).size() &&                  \
                         (r).at(i).line == (N),                              \
                     (id), "line == " #N, Stope::STML::Test::stokDesc(r, i))
#define EXPECT_STOK_STATE(r, i, S, id)                                       \
  Stope::Test::check(static_cast<size_t>(i) < (r).size() &&                  \
                         (r).states[i] == (S),                               \
                     (id), "state == " #S, Stope::STML::Test::stokDesc(r, i))
#define EXPECT_SCOUNT(r, N, id)                                              \
  Stope::Test::check((r).size() == static_cast<size_t>(N), (id),             \
                     "token count == " #N,                                   \
                     "actual=" + std::to_string((r).size()) +                \
                         "\n         [" + Stope::STML::Test::stokSeq(r) + "]")
#define EXPECT_SSEQ(r, SEQ, id)                                              \
  Stope::Test::check(Stope::STML::Test::stokSeq(r) == (SEQ), (id),           \
                     "sequence == " #SEQ,                                    \
                     "got=[" + Stope::STML::Test::stokSeq(r) + "]")
#define EXPECT_SERR_COUNT(r, N, id)                                          \
  Stope::Test::check((r).errors.size() == static_cast<size_t>(N), (id),      \
                     "error count == " #N,                                   \
                     Stope::STML::Test::slErrDetail(r))
#define EXPECT_SERR_HAS(r, SUB, id)                                          \
  Stope::Test::check(                                                        \
      [&] {                                                                  \
        for (const auto& e : (r).errors)                                     \
          if (e.find(SUB) != std::string::npos) return true;                 \
        return false;                                                        \
      }(),                                                                   \
      (id), "errors contains " #SUB, Stope::STML::Test::slErrDetail(r))

// ---- STML 语法断言宏 ----
#define EXPECT_SP_SHAPE(r, SH, id)                                           \
  Stope::Test::check((r).shape() == (SH), (id), "shape == " #SH,             \
                     "got=[" + (r).shape() + "]")
#define EXPECT_SP_RESULT(r, RES, id)                                         \
  Stope::Test::check((r).result == (RES), (id), "result == " #RES,           \
                     Stope::STML::Test::spErrDetail(r))
#define EXPECT_SP_LINE(r, N, id)                                             \
  Stope::Test::check((r).root.line == (N), (id), "root.line == " #N,         \
                     "actual=" + std::to_string((r).root.line) +             \
                         "\n         " + Stope::STML::Test::spRootDesc(r))
#define EXPECT_SP_TAG(r, U16, id)                                            \
  Stope::Test::check((r).root.tagName == (U16), (id), "root.tagName == " #U16,\
                     Stope::STML::Test::spRootDesc(r))
#define EXPECT_SP_TEXT(r, U16, id)                                           \
  Stope::Test::check((r).root.text == (U16), (id), "root.text == " #U16,     \
                     Stope::STML::Test::spRootDesc(r))
#define EXPECT_SP_SELFCLOSING(r, B, id)                                      \
  Stope::Test::check((r).root.selfClosing == (B), (id),                      \
                     "root.selfClosing == " #B,                              \
                     Stope::STML::Test::spRootDesc(r))
#define EXPECT_SP_CHILD_COUNT(r, N, id)                                      \
  Stope::Test::check((r).root.children.size() == static_cast<size_t>(N),     \
                     (id), "root.children.size() == " #N,                    \
                     "actual=" + std::to_string((r).root.children.size()) +  \
                         "\n         " + Stope::STML::Test::spRootDesc(r))
#define EXPECT_SP_ATTR_COUNT(r, N, id)                                       \
  Stope::Test::check((r).root.attrs.size() == static_cast<size_t>(N), (id),  \
                     "root.attrs.size() == " #N,                             \
                     "actual=" + std::to_string((r).root.attrs.size()) +     \
                         "\n         " + Stope::STML::Test::spRootDesc(r))
#define EXPECT_SP_DEPTH(r, N, id)                                            \
  Stope::Test::check(Stope::STML::Test::spDepth((r).root) == (N), (id),      \
                     "depth == " #N,                                         \
                     "actual=" + std::to_string(                             \
                                    Stope::STML::Test::spDepth((r).root)))
#define EXPECT_SPLEX_COUNT(r, N, id)                                         \
  Stope::Test::check((r).lexErrors.size() == static_cast<size_t>(N), (id),   \
                     "lexError count == " #N,                                \
                     Stope::STML::Test::spErrDetail(r))
#define EXPECT_SPERR_COUNT(r, N, id)                                         \
  Stope::Test::check((r).errors.size() == static_cast<size_t>(N), (id),      \
                     "error count == " #N,                                   \
                     Stope::STML::Test::spErrDetail(r))
#define EXPECT_SPERR_HAS(r, SUB, id)                                         \
  Stope::Test::check(                                                        \
      [&] {                                                                  \
        for (const auto& e : (r).errors)                                     \
          if (e.find(SUB) != std::string::npos) return true;                 \
        return false;                                                        \
      }(),                                                                   \
      (id), "errors contains " #SUB, Stope::STML::Test::spErrDetail(r))

#define SKNOWN(defect, cond, id) Stope::Test::knownCheck(defect, (cond), #cond, id)
