// golden 数据生成器：把「词法分析通用测试计划」里每一条用例在 C++ 侧的真实 token 流
// dump 成机器可读文本，供 GDScript 测试直接比对。
//
// 重生成（在 cpp/ 下）：cmake --build build --target gen-golden
#include <cstdio>
#include <string>
#include <vector>

#include "lexer.hpp"
#include "test_common.hpp"

using namespace Stope;
using namespace Stope::Test;

static std::u16string U(const char* s) {
  std::u16string o;
  for (const char* p = s; *p; ++p) o += char16_t((unsigned char)*p);
  return o;
}
static std::string E_(const std::string& in) {
  std::string o;
  for (char c : in) {
    switch (c) {
      case '\\': o += "\\\\"; break;
      case '\n': o += "\\n"; break;
      case '\r': o += "\\r"; break;
      case '\t': o += "\\t"; break;
      case '\v': o += "\\v"; break;
      case '\f': o += "\\f"; break;
      default: o += c;
    }
  }
  return o;
}

static CustomOpcodeConfig* g_cfg = nullptr;

static void one(const char* id, const char* src) {
  auto holder = std::make_shared<std::u16string>(U(src));
  Lexer lx(*holder);  // 构造即 Reset：输入、行号、errors 一次到位
  std::string toks;
  std::string lexemes;
  for (int i = 0; i < 10000; ++i) {
    Token t;
    lx.NextToken(t, g_cfg);
    if (i) toks += " ";
    toks += tokenName(t.type);
    toks += "(" + std::to_string(t.line) + ")";
    if (!t.parsed.empty()) toks += "[" + E_(toUtf8(t.parsed)) + "]";
    if (t.type == TokenType::Integer || t.type == TokenType::Float) {
      char b[64];
      if (t.type == TokenType::Integer)
        snprintf(b, sizeof(b), "=%lld", t.numberValue.integer);
      else
        snprintf(b, sizeof(b), "=%g", t.numberValue.floating);
      toks += b;
    }
    // lexeme 只在「双方实现都提供」的类型上比对：数字 / 字符串 / 二进制数组
    // （标识符的 lexeme 在 C++ 侧为空、GDScript 侧有原文，属实现自定，不参与比对）
    if (t.type == TokenType::Integer || t.type == TokenType::Float ||
        t.type == TokenType::String || t.type == TokenType::BinArr) {
      if (!lexemes.empty()) lexemes += ",";
      lexemes += std::to_string(i) + ":" + E_(toUtf8(t.lexeme));
    }
    if (t.type == TokenType::Eof) break;
  }
  std::string errs;
  for (auto& e : lx.errors) {
    if (!errs.empty()) errs += "|";
    errs += E_(e);
  }
  printf("ID=%s\tSRC=%s\tTOKS=%s\tLEXEMES=%s\tERRN=%zu\tERRS=%s\n", id,
         E_(src).c_str(), toks.c_str(), lexemes.c_str(), lx.errors.size(),
         errs.c_str());
}

int main() {
  static CustomOpcodeConfig cfg;
  std::u16string myop = U("myop"), vop = U("vop"), kwif = U("if");
  cfg.addCustomOpcode(myop, 100, 2);
  cfg.addCustomOpcode(vop, 101, -1);
  cfg.addCustomOpcode(kwif, 102, 1);  // 关键字优先：[K-03]
  g_cfg = &cfg;

  printf("# C++ golden dump for docs/zh-cn/lexer-test-plan.md\n");

  struct C { const char* id; const char* src; };
  std::vector<C> cs = {
      // ---- LEX-W 空白与注释 ----
      {"LEX-W-01", ""},
      {"LEX-W-02", " \t\v\f\r"},
      {"LEX-W-03", "\n\n"},
      {"LEX-W-04", "// c\n1"},
      {"LEX-W-05", "// c"},
      {"LEX-W-06", "/* a\nb */1"},
      {"LEX-W-07", "/* a /* b */ c"},
      {"LEX-W-08", "1/* unclosed"},
      {"LEX-W-09", "a // x\n :b"},
      // ---- LEX-L 行号 ----
      {"LEX-L-01", "1\n2\n\n3\r\n4"},
      {"LEX-L-02", "'a\nb' 1"},
      {"LEX-L-03", "1\n  \t 2"},
      {"LEX-L-04", "a\n:\nb"},
      // ---- LEX-N-I 整数 ----
      {"LEX-N-I-01", "0"},
      {"LEX-N-I-02", "00"},
      {"LEX-N-I-03", "0009"},
      {"LEX-N-I-04", "1_000"},
      {"LEX-N-I-05", "1_"},
      {"LEX-N-I-06", "0_1"},
      {"LEX-N-I-07", "0x1F"},
      {"LEX-N-I-08", "0X1f"},
      {"LEX-N-I-09", "0xFF"},
      {"LEX-N-I-10", "0b101"},
      {"LEX-N-I-10B", "0B101"},
      {"LEX-N-I-11", "0o17"},
      {"LEX-N-I-11B", "0O17"},
      {"LEX-N-I-12", "0b1_01"},
      {"LEX-N-I-13", "0x_1"},
      {"LEX-N-I-14", "0o_7"},
      {"LEX-N-I-15", "9223372036854775807"},
      {"LEX-N-I-16", "0x7FFFFFFFFFFFFFFF"},
      {"LEX-N-I-17", "9223372036854775808"},
      {"LEX-N-I-18", "0xFFFFFFFFFFFFFFFFF"},
      {"LEX-N-I-19B", "0b"},
      {"LEX-N-I-19X", "0x"},
      {"LEX-N-I-19O", "0o"},
      {"LEX-N-I-20B", "0b_"},
      {"LEX-N-I-20X", "0x_"},
      {"LEX-N-I-20O", "0o_"},
      {"LEX-N-I-21", "0b2"},
      {"LEX-N-I-22", "123abc"},
      // ---- LEX-N-F 浮点 ----
      {"LEX-N-F-01", "1e5"},
      {"LEX-N-F-02", "1E-3"},
      {"LEX-N-F-03", ".5"},
      {"LEX-N-F-04", "1_.5"},
      {"LEX-N-F-05", "1e+3"},
      {"LEX-N-F-06", "1."},
      {"LEX-N-F-07", "1..2"},
      {"LEX-N-F-08", "1.5.5"},
      {"LEX-N-F-09", "."},
      {"LEX-N-F-10A", ".e5"},
      {"LEX-N-F-10B", "._"},
      {"LEX-N-F-11A", "1e"},
      {"LEX-N-F-11B", "1e+"},
      {"LEX-N-F-11C", ".5e"},
      {"LEX-N-F-12A", "1e999"},
      {"LEX-N-F-12B", "1e-999"},
      // ---- LEX-I 标识符 ----
      {"LEX-I-01A", "_"},
      {"LEX-I-01B", "__9"},
      {"LEX-I-01C", "_9a"},
      {"LEX-I-02", "9a"},
      {"LEX-I-03", "a:b"},
      {"LEX-I-04", "a:b:c"},
      {"LEX-I-05", "a\n:b"},
      {"LEX-I-06", "a // c\n:b"},
      {"LEX-I-07", "a :/*x*/ b"},
      {"LEX-I-08", "a::b"},
      {"LEX-I-09", "a:1"},
      {"LEX-I-10", "a:"},
      // ---- LEX-K 关键字与自定义指令 ----
      {"LEX-K-01idiv", "idiv"},
      {"LEX-K-01not", "not"},
      {"LEX-K-01and", "and"},
      {"LEX-K-01or", "or"},
      {"LEX-K-01if", "if"},
      {"LEX-K-01elif", "elif"},
      {"LEX-K-01else", "else"},
      {"LEX-K-01let", "let"},
      {"LEX-K-01return", "return"},
      {"LEX-K-01while", "while"},
      {"LEX-K-01break", "break"},
      {"LEX-K-01continue", "continue"},
      {"LEX-K-01null", "null"},
      {"LEX-K-01false", "false"},
      {"LEX-K-01true", "true"},
      {"LEX-K-01args", "args"},
      {"LEX-K-01argc", "argc"},
      {"LEX-K-01export", "export"},
      {"LEX-K-02A", "IF"},
      {"LEX-K-02B", "If"},
      {"LEX-K-02C", "iff"},
      {"LEX-K-02D", "if2"},
      {"LEX-K-03", "if"},
      {"LEX-K-04", "myop"},
      {"LEX-K-05", "vop"},
      {"LEX-K-06", "myop(1, vop)"},
      // ---- LEX-S 双引号字符串 ----
      {"LEX-S-01", "\"\""},
      {"LEX-S-02", "\"abc\""},
      {"LEX-S-03", "\"a\\\"b\""},
      {"LEX-S-04", "\"a\\nb\""},
      {"LEX-S-05", "\"a\\\\b\""},
      {"LEX-S-06b", "\"a\\bb\""},
      {"LEX-S-06f", "\"a\\fb\""},
      {"LEX-S-06r", "\"a\\rb\""},
      {"LEX-S-06t", "\"a\\tb\""},
      {"LEX-S-06v", "\"a\\vb\""},
      {"LEX-S-06q", "\"a\\'b\""},
      {"LEX-S-07", "\"a\\qb\""},
      {"LEX-S-08", "\"abc"},
      {"LEX-S-09", "\"abc\\"},
      // ---- LEX-B 单引号二进制数组 ----
      {"LEX-B-01", "''"},
      {"LEX-B-02", "'a'"},
      {"LEX-B-03", "'a' 'b'"},
      {"LEX-B-04", "'a\\nb'"},
      {"LEX-B-05", "'a"},
      {"LEX-B-06", "'a\nb'"},
      // ---- LEX-P 标点 ----
      {"LEX-P-01a", ","},
      {"LEX-P-01b", ";"},
      {"LEX-P-01c", "("},
      {"LEX-P-01d", ")"},
      {"LEX-P-01e", "["},
      {"LEX-P-01f", "]"},
      {"LEX-P-01g", "{"},
      {"LEX-P-01h", "}"},
      {"LEX-P-02a", "="},
      {"LEX-P-02b", "+"},
      {"LEX-P-02c", "-"},
      {"LEX-P-02d", "*"},
      {"LEX-P-02e", "/"},
      {"LEX-P-02f", "%"},
      {"LEX-P-02g", "^"},
      {"LEX-P-03", "=="},
      {"LEX-P-04a", "<="},
      {"LEX-P-04b", ">="},
      {"LEX-P-05", "!="},
      {"LEX-P-06a", "&&"},
      {"LEX-P-06b", "||"},
      {"LEX-P-07a", "&"},
      {"LEX-P-07b", "|"},
      {"LEX-P-08a", "@"},
      {"LEX-P-08b", "#"},
      {"LEX-P-08c", "$"},
      {"LEX-P-08d", "~"},
      {"LEX-P-08e", "?"},
      {"LEX-P-08f", "\\"},
      {"LEX-P-09", "@@#"},
      // ---- 混合长例子 ----
      {"LEX-MIX-01", "let a = 1 + 2.5; // c\n return a;"},
      {"LEX-MIX-02", "if a { b[0] = 'x 41'; }"},
  };
  for (auto& c : cs) one(c.id, c.src);
  return 0;
}
