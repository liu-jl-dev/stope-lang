// golden 数据生成器：把反汇编器（debug.hpp 的 `Disasm` / `DisasmNoCustom`）
// 在一批用例上的输出 dump 成机器可读文本，供 GDScript 侧的 `StopeDebug.disasm` 逐字节比对。
//
// 为什么要比对：反汇编是**调试工具**，不在三项标准里（见 cpp/docs/README.md §3），
// 但两侧既然都实现了，输出就该一样。列宽、表顺序、warning 文案、unknown 编号的兜底
// 写法这些细节手写期望值必错，所以照旧让权威实现产出。
//
// 记录格式（一行一条，\t 分字段，值里的 \\ \n \r \t 已转义）：
//   ID=DA-01  MODE=src  CFG=main     SRC=<源码>   DIS=<Disasm 输出>
//   ID=DA-11  MODE=raw  OPS=200,1                DIS=<同上>
// MODE=raw 的两条是手工构造的 Program（未知编号、缺操作数），源码造不出来。
//
// 重生成（在 cpp/ 下）：cmake --build build --target gen-golden
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "compiler.hpp"
#include "debug.hpp"
#include "lexer.hpp"
#include "parser.hpp"
#include "program.hpp"

using namespace Stope;

static std::u16string U(const char* s) {
  std::u16string o;
  for (const char* p = s; *p; ++p)
    o += char16_t((unsigned char)*p);
  return o;
}

// 与另几个探针同一套转义：保证一条记录一行
static std::string E_(const std::string& in) {
  std::string o;
  for (char c : in) {
    switch (c) {
      case '\\':
        o += "\\\\";
        break;
      case '\n':
        o += "\\n";
        break;
      case '\r':
        o += "\\r";
        break;
      case '\t':
        o += "\\t";
        break;
      default:
        o += c;
    }
  }
  return o;
}

// 编译一份源码并 dump 反汇编。cfg 同时交给 Parser / Compiler / Disasm ——
// 三处必须**同一份**：少给一处，自定义指令就会被当成普通函数调用（编译期）
// 或印成 Opcode(100)（反汇编），数据与真实用法不符。
// 编译失败直接退出：本探针只收「能编译」的用例，失败说明用例写错了，不该静默
// 跳过（那样 GD 侧会找不到对应 ID）。
static void one(const char* id,
                const char* cfgName,
                const char* src,
                CustomOpcodeConfig* cfg) {
  // ⚠ 源码必须自己托住：Lexer 里存的是 u16string_view（借用），写成
  // `Lexer lexer(U(src))` 会让临时 u16string 当场析构、视图悬空 —— 表现是同一份
  // 源码每次编出不同的垃圾指令（实测 `while a { break; }` 随机冒出十几个 Pop），
  // 而不是崩溃。另几个探针用 make_shared 托住，同理。
  std::u16string src16 = U(src);
  Lexer lexer(src16);
  Parser parser(lexer, cfg);
  AST::Prog tree;
  parser.ParseProgram(tree);
  Compiler compiler(cfg);
  Program program;
  if (compiler.Compile(tree, program) != Result::Success) {
    std::fprintf(stderr, "用例 %s 编译失败，先修用例\n", id);
    for (const auto& e : compiler.errors)
      std::fprintf(stderr, "  %s\n", e.c_str());
    std::exit(1);
  }
  printf("ID=%s\tMODE=src\tCFG=%s\tSRC=%s\tDIS=%s\n", id, cfgName,
         E_(std::string(src)).c_str(), E_(Disasm(program, cfg)).c_str());
}

static void raw(const char* id, const std::vector<short>& ops) {
  Program p;
  p.opcodes = ops;
  std::string list;
  for (size_t k = 0; k < ops.size(); ++k) {
    if (k > 0)
      list += ",";
    list += std::to_string(ops[k]);
  }
  printf("ID=%s\tMODE=raw\tOPS=%s\tDIS=%s\n", id, list.c_str(),
         E_(Disasm(p, nullptr)).c_str());
}

int main() {
  // 与其它三份 golden 用同一张指令表；撞号那份单独建（DA-10）
  static CustomOpcodeConfig main_cfg;
  std::u16string myop = U("myop"), vop = U("vop");
  main_cfg.addCustomOpcode(myop, 100, 2);
  main_cfg.addCustomOpcode(vop, 101, -1);

  static CustomOpcodeConfig collide_cfg;
  std::u16string steal = U("my:steal");
  collide_cfg.addCustomOpcode(steal, static_cast<short>(Opcode::Add), 2);

  printf("# 由 cpp/tools/golden_disasm.cpp 生成，勿手工编辑。\n");
  printf("# DIS = Disasm 的输出，\\\\ \\n \\r \\t 已转义\n");

  one("DA-01", "none", "", nullptr);               // 空程序：指令流为空
  one("DA-02", "none", "let a = 1;", nullptr);     // 变量未导出 -> 名字是空串
  one("DA-03", "none", "export a = 1;", nullptr);  // 导出变量 -> 变量表有名字
  one("DA-04", "none", "let a = 1; let s = \"hi\"; return a;", nullptr);
  one("DA-05", "main", "myop(1, 2);", &main_cfg);  // 定长自定义指令
  one("DA-06", "main", "vop(); vop(1, 2, 3);",
      &main_cfg);                                       // 变长：多一个参数个数
  one("DA-07", "none", "while a { break; }", nullptr);  // If / GoTo 带跳转目标
  one("DA-08", "none", "1.5; 2.25; 1e20;", nullptr);    // 浮点常量的打印格式
  one("DA-09", "none", "'ab';", nullptr);  // 二进制数组常量按字节数报
  one("DA-10", "collide", "my:steal(1, 2);",
      &collide_cfg);  // 撞内置编号 -> warning

  // 未知编号：不传 config 就没法解码，只能印 Custom<编号> 并警告
  raw("DA-11", {200, 1});
  // 缺操作数：指令流在 PushInt 处断了
  raw("DA-12", {static_cast<short>(Opcode::PushInt)});

  return 0;
}
