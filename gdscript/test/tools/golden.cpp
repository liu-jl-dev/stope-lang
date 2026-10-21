// 临时探针：把「通用测试计划」里每一条用例在 C++ 侧的真实输出 dump 成机器可读文本，
// 供 GDScript 测试直接引用（期望值不手推）。
#include <cstdio>
#include <string>
#include <vector>

#include "compiler.hpp"
#include "program.hpp"
#include "test_common.hpp"

using namespace Stope;
using namespace Stope::Test;

static std::u16string U(const char* s) {
  std::u16string o;
  for (const char* p = s; *p; ++p) o += char16_t((unsigned char)*p);
  return o;
}

// 把字段里的 \\ \n \t 转义掉，保证一行一条记录
static std::string E_(const std::string& in) {
  std::string o;
  for (char c : in) {
    switch (c) {
      case '\\': o += "\\\\"; break;
      case '\n': o += "\\n"; break;
      case '\r': o += "\\r"; break;
      case '\t': o += "\\t"; break;
      default: o += c;
    }
  }
  return o;
}
static std::string E16(const std::u16string& in) { return E_(toUtf8(in)); }

static const char* opName(short v) {
  switch (v) {
    case 0: return "Assign";
    case 1: return "PushNull";
    case 2: return "PushFalse";
    case 3: return "PushTrue";
    case 4: return "PushInt";
    case 5: return "PushFloat";
    case 6: return "PushString";
    case 7: return "PushBinArr";
    case 8: return "PushId";
    case 9: return "Call";
    case 10: return "At";
    case 11: return "Pop";
    case 12: return "Minus";
    case 13: return "Not";
    case 14: return "Pow";
    case 15: return "Mul";
    case 16: return "Div";
    case 17: return "IDiv";
    case 18: return "Mod";
    case 19: return "Add";
    case 20: return "Sub";
    case 21: return "EQ";
    case 22: return "NE";
    case 23: return "LT";
    case 24: return "LE";
    case 25: return "GT";
    case 26: return "GE";
    case 27: return "If";
    case 28: return "GoTo";
    case 29: return "GetArg";
    case 30: return "ArgNum";
    case 31: return "Return";
  }
  return "?";
}

static CustomOpcodeConfig* g_cfg = nullptr;

static std::string dumpProgram(const Program& p) {
  std::string s;
  s += "code[";
  size_t i = 0;
  while (i < p.opcodes.size()) {
    if (i) s += " ";
    short op = p.opcodes[i];
    ++i;
    bool hasParam;
    if (op > 31) {
      s += "Inst(" + std::to_string(op) + ")";
      hasParam = false;
      for (auto& kv : g_cfg->opcodes) {
        if (kv.second.opcode == op) {
          hasParam = kv.second.isVarArg;
          break;
        }
      }
    } else if (op <= 3) hasParam = false;
    else if (op <= 10) hasParam = true;
    else if (op <= 26) hasParam = false;
    else if (op <= 28) hasParam = true;
    else if (op <= 30) hasParam = false;
    else hasParam = true;
    if (op <= 31) s += opName(op);
    if (hasParam && i < p.opcodes.size()) {
      s += "(" + std::to_string(p.opcodes[i]) + ")";
      ++i;
    }
  }
  s += "]";
  s += " vars=" + std::to_string(p.variableNum);
  s += " stack=" + std::to_string(p.requiredStackSize);
  s += " maxRet=" + std::to_string(p.maxReturnNum);
  s += " ints=[";
  for (size_t k = 0; k < p.intConsts.size(); ++k) {
    if (k) s += ",";
    s += std::to_string(p.intConsts[k]);
  }
  s += "]";
  s += " floats=[";
  for (size_t k = 0; k < p.floatConsts.size(); ++k) {
    if (k) s += ",";
    char b[64];
    snprintf(b, sizeof(b), "%g", p.floatConsts[k]);
    s += b;
  }
  s += "]";
  s += " strs=[";
  for (size_t k = 0; k < p.stringConsts.size(); ++k) {
    if (k) s += ",";
    s += escUtf8(p.stringConsts[k]);
  }
  s += "]";
  s += " binarrs=[";
  for (size_t k = 0; k < p.binArrConsts.size(); ++k) {
    if (k) s += " ";
    s += "[";
    for (size_t j = 0; j < p.binArrConsts[k].size(); ++j) {
      if (j) s += ",";
      char b[8];
      snprintf(b, sizeof(b), "%02x", (unsigned char)p.binArrConsts[k][j]);
      s += b;
    }
    s += "]";
  }
  s += "]";
  s += " exports=[";
  bool first = true;
  for (auto& kv : p.exports) {
    if (!first) s += ",";
    first = false;
    s += escUtf8(kv.first) + ":" + std::to_string(kv.second);
  }
  s += "]";
  return s;
}

static std::string join(const std::vector<std::string>& v) {
  std::string o;
  for (auto& e : v) {
    if (!o.empty()) o += "|";
    o += E_(e);
  }
  return o;
}

// 语句行号序列（关系到 L 组）
static std::string stmtLines(const AST::Prog& p) {
  std::string o;
  for (auto& s : p.stmts) {
    if (!o.empty()) o += ",";
    o += std::to_string(s->line);
  }
  return o;
}

static void one(const char* id, const char* src, bool fold) {
  auto holder = std::make_shared<std::u16string>(U(src));
  Lexer lx(*holder);
  Parser ps(lx, g_cfg);
  ps.constFolding = fold;
  AST::Prog prog;
  ps.ParseProgram(prog);

  Program out;
  Compiler c(g_cfg);
  auto rc = c.Compile(prog, out);

  printf("ID=%s\tSRC=%s\tFOLD=%d\tSHAPE=%s\tLINES=%s\tPERR=%zu\tLEXERR=%zu\tPERRS=%s\tLEXERRS=%s\tCMP=%s\tOUT=%s\tCERRS=%s\n",
         id, E_(src).c_str(), fold ? 1 : 0,
         E_(shapeProg(prog)).c_str(), stmtLines(prog).c_str(),
         ps.errors.size(), lx.errors.size(), join(ps.errors).c_str(),
         join(lx.errors).c_str(),
         rc == Result::Success ? "OK" : "ERR",
         E_(dumpProgram(out)).c_str(), join(c.errors).c_str());
}

int main() {
  static CustomOpcodeConfig cfg;
  std::u16string myop = U("myop"), vop = U("vop");
  cfg.addCustomOpcode(myop, 100, 2);
  cfg.addCustomOpcode(vop, 101, -1);
  g_cfg = &cfg;

  printf("# C++ golden dump (2026-10-18) for docs/zh-cn/*.md case tables\n");

  // ================= 语法分析计划 §4.1 S 语句层 =================
  const char* s_cases[] = {"",
                           ";",
                           ";;;",
                           "let a;",
                           "let a, b, c;",
                           "let a = 1;",
                           "let a = 1",
                           "let;",
                           "let 1;",
                           "let a, b = 1;",
                           "let a b;",
                           "let a,",
                           "export a;",
                           "export a, b;",
                           "export;",
                           "return;",
                           "return 1;",
                           "return 1, 2;",
                           "return 1 2;",
                           "return",
                           "{ }",
                           "{ let a; }",
                           "{ let a;",
                           "}",
                           "} let a;",
                           "break;",
                           "continue;",
                           "break",
                           "break x;",
                           "continue x;",
                           "a;",
                           "a = 1;",
                           "a = 1",
                           "a b;",
                           "a[0] = 1;"};
  for (size_t i = 0; i < sizeof(s_cases) / sizeof(s_cases[0]); ++i) {
    char id[32];
    snprintf(id, sizeof(id), "S-%02zu", i + 1);
    one(id, s_cases[i], false);
  }

  // ================= §4.2 X 表达式与字面量 =================
  struct C { const char* id; const char* src; bool fold; };
  std::vector<C> xs = {
      {"X-01", "null;", false},
      {"X-02", "true;", false},
      {"X-03", "false;", false},
      {"X-04", "1;", false},
      {"X-05", "0x1F;", false},
      {"X-06", "1.5;", false},
      {"X-07", "\"a\\nb\";", false},
      {"X-08", "'b 0100 0001';", false},
      {"X-09", "'';", false},
      {"X-10", "argc;", false},
      {"X-11", "args[0];", false},
      {"X-12", "args 0;", false},
      {"X-13", "a:b;", false},
      {"X-14", "-1;", false},
      {"X-15", "!a;", false},
      {"X-16", "--a;", false},
      {"X-17", "'ab';", false},
      {"X-18", "'d 01 02';", false},
  };

  // ================= §4.3 P 优先级 =================
  std::vector<C> ps_ = {
      {"P-01", "1 + 2 * 3;", false},  {"P-02", "1 * 2 + 3;", false},
      {"P-03", "1 - 2 - 3;", false},  {"P-04", "2 ^ 3 ^ 2;", false},
      {"P-05", "-2 ^ 2;", false},     {"P-06", "1 < 2 == true;", false},
      {"P-07", "a || b && c;", false},{"P-08", "a && b || c;", false},
      {"P-09", "1 + 2 < 3;", false},  {"P-10", "a idiv b % c;", false},
      {"P-11", "(1 + 2) * 3;", false},{"P-12", "-a * b;", false},
      {"P-13", "!a == b;", false},    {"P-14", "1 - -2;", false},
      {"P-15", "a / b / c;", false},
  };

  // ================= §4.4 F 调用/索引/括号 =================
  std::vector<C> fs = {
      {"F-01", "f();", false},        {"F-02", "f(1);", false},
      {"F-03", "f(1, 2);", false},    {"F-04", "f(1, 2, 3);", false},
      {"F-05", "f()();", false},      {"F-06", "f(a)(b);", false},
      {"F-07", "f(1, 2 x;", false},   {"F-08", "a[0];", false},
      {"F-09", "a[0, 1];", false},    {"F-10", "a[0][1];", false},
      {"F-11", "a[b[c]];", false},    {"F-12", "a[;", false},
      {"F-13", "(1);", false},        {"F-14", "(1 + 2) * 3;", false},
      {"F-15", "(1;", false},         {"F-16", "((((1))));", false},
      {"F-17", "f(a[0]);", false},    {"F-18", "f() + 1;", false},
  };

  // ================= §4.5 K 自定义指令 =================
  std::vector<C> ks = {
      {"K-01", "myop(1, 2);", false}, {"K-02", "vop();", false},
      {"K-03", "vop(1, 2, 3);", false},{"K-04", "myop(1);", false},
      {"K-05", "myop 1;", false},     {"K-06", "myop(1, 2;", false},
      {"K-07", "myop() + 1;", false}, {"K-08", "f(myop(1, 2));", false},
      {"K-09", "undefined_op(1);", false},{"K-10", "myop[0];", false},
  };

  // ================= §4.6 L 行号 =================
  std::vector<C> ls = {
      {"L-01", "let a;\nlet b;", false},
      {"L-02", "1 +\n2;", false},
      {"L-03", "{\nlet a;\n}", false},
      {"L-04", "if x {\na;\n}", false},
      {"L-05", "a\nb;", false},
  };

  // ================= §4.7 R 错误恢复 =================
  std::vector<C> rs = {
      {"R-01", "a; } b;", false},
      {"R-02", "{ a; } b;", false},
      {"R-03", "if a { b; } c;", false},
      {"R-04", "if a b;", false},
      {"R-05", "while a b;", false},
      {"R-06", "f(1, 2 x; y;", false},
      {"R-07", "let a, b = 1; c;", false},
  };

  // ================= §4.9 O 常量折叠 =================
  std::vector<C> os = {
      {"O-01", "1 + 2;", true},        {"O-02", "2 * 3 + 4;", true},
      {"O-03", "1 + 2 * 3;", true},    {"O-04", "\"ab\" + \"cd\";", true},
      {"O-05", "1 / 0;", true},        {"O-06", "9223372036854775807 + 1;", true},
      {"O-07", "f(1) + 2;", true},     {"O-08", "a + 2;", true},
      {"O-09", "null + 5;", true},     {"O-10", "-true;", true},
      {"O-11", "2 ^ 3 ^ 2;", true},    {"O-12", "f(1 + 2);", true},
      {"O-13", "1 + \"a\";", true},    {"O-14", "\"ab\" * 3;", true},
      {"O-15", "'01 ' + '02 ';", true},
  };

  for (auto& c : xs) one(c.id, c.src, c.fold);
  for (auto& c : ps_) one(c.id, c.src, c.fold);
  for (auto& c : fs) one(c.id, c.src, c.fold);
  for (auto& c : ks) one(c.id, c.src, c.fold);
  for (auto& c : ls) one(c.id, c.src, c.fold);
  for (auto& c : rs) one(c.id, c.src, c.fold);
  for (auto& c : os) one(c.id, c.src, c.fold);

  // ================= 编译器计划 §4 =================
  std::vector<C> cms = {
      {"CM-01", "let a;", false},
      {"CM-02", "let a, b, c;", false},
      {"CM-03", "let a = 1;", false},
      {"CM-04", "a;", false},
      {"CM-05", "a = 1;", false},
      {"CM-06", "a[0] = 1;", false},
      {"CM-07", "a; a;", false},
      {"CM-08", "let a; a = 1;", false},
      {"CM-09", "{ let a; } { let b; }", false},
      {"CM-10", "export a, b;", false},
      {"CM-11", "1; 1;", false},
      {"CM-12", "1; 1.5; \"s\"; 'ab';", false},
      {"CM-13", "'b 0100 0001';", false},
      {"CM-14", "'';", false},
      {"CM-15", "null;", false},
      {"CM-16", "true;", false},
      {"CM-16F", "false;", false},
      {"CM-17", "1;", false},
      {"CM-18", "0x1F;", false},
      {"CM-19", "1.5;", false},
      {"CM-20", "\"a\\nb\";", false},
      {"CM-21", "argc;", false},
      {"CM-22", "args[0];", false},
      {"CM-23", "-1;", false},
      {"CM-24", "!a;", false},
      {"CM-25", "1 + 2 * 3;", false},
      {"CM-26", "1 - 2 - 3;", false},
      {"CM-27", "2 ^ 3 ^ 2;", false},
      {"CM-28", "1 < 2 == true;", false},
      {"CM-29", "-a * b;", false},
      {"CM-30", "1 - -2;", false},
      {"CM-31", "a idiv b % c;", false},
      {"CM-32", "a || b && c;", false},
      {"CM-33", "a && b || c;", false},
      {"CM-34", "a || b;", false},
      {"CM-35", "a && b;", false},
      {"CM-36", "f();", false},
      {"CM-37", "f(1, 2);", false},
      {"CM-38", "f()();", false},
      {"CM-39", "a[0];", false},
      {"CM-40", "a[0, 1];", false},
      {"CM-41", "return;", false},
      {"CM-42", "return 1;", false},
      {"CM-43", "return 1, 2, 3;", false},
      {"CM-44", "{ return 1; } return 2;", false},
      {"CM-45", "if a { }", false},
      {"CM-46", "if a { } else { }", false},
      {"CM-47", "if a { } elif b { }", false},
      {"CM-48", "if a { } elif b { } else { }", false},
      {"CM-49", "while { }", false},
      {"CM-50", "while a { }", false},
      {"CM-51", "while a { break; }", false},
      {"CM-52", "while a { continue; }", false},
      {"CM-53", "while a { if b { break; } else { continue; } }", false},
      {"CM-54", "{ }", false},
      {"CM-55", "myop(1, 2);", false},
      {"CM-56", "vop();", false},
      {"CM-57", "vop(1, 2, 3);", false},
      {"CM-58", "myop(1, 2) + vop(1);", false},
      {"CM-59", "f(myop(1, 2));", false},
      {"CM-60", "myop(1);", false},
      {"CM-61", "myop() + 1;", false},
      {"CM-62", "undefined_op(1);", false},
      {"CM-63", "break;", false},
      {"CM-64", "continue;", false},
      {"CM-65", "let a; let a;", false},
      {"CM-66", "export a; export a;", false},
      {"CM-67", "{ export a; }", false},
      {"CM-69", "1 + 2;", true},
      {"CM-70", "\"ab\" + \"cd\";", true},
      {"CM-71", "f(1 + 2);", true},
      {"CM-72", "1 / 0;", true},
  };
  for (auto& c : cms) one(c.id, c.src, c.fold);

  return 0;
}
