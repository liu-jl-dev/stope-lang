// Compiler 测试：AST → Program 的指令流、常量池、变量表、栈容量。
//
// 与 parser 测试共用一套 g_total/g_failed 与 check()。
// 默认**关闭常量折叠**，这样能看到完整树形的编译结果（`1 + 2 * 3` 会 leave 成 Powi…）。
// 指令是否可以带操作数（从而占 2 个 short）由 paramWidth 决定，
// 规则来自 gdscript/stope/stope.gd 的 Stope.has_a_param，按 C++ 多出 PushBinArr 后移一位。
#include <cstdio>
#include <map>
#include <string>
#include <vector>

#include <stope/ast.hpp>
#include <stope/compiler.hpp>
#include <stope/lexer.hpp>
#include <stope/opcode.hpp>
#include <stope/parser.hpp>
#include <stope/program.hpp>
#include "test_common.hpp"

#ifdef _WIN32
#include <Windows.h>
#endif

namespace Stope {
namespace Test {

inline std::set<int> g_seenOpcodes;  // Opcode 覆盖统计

inline const char* opName(short raw) {
  switch (static_cast<Opcode>(raw)) {
    case Opcode::Assign:
      return "Assign";
    case Opcode::PushNull:
      return "PushNull";
    case Opcode::PushFalse:
      return "PushFalse";
    case Opcode::PushTrue:
      return "PushTrue";
    case Opcode::PushInt:
      return "PushInt";
    case Opcode::PushFloat:
      return "PushFloat";
    case Opcode::PushString:
      return "PushString";
    case Opcode::PushBinArr:
      return "PushBinArr";
    case Opcode::PushId:
      return "PushId";
    case Opcode::Call:
      return "Call";
    case Opcode::At:
      return "At";
    case Opcode::Pop:
      return "Pop";
    case Opcode::Minus:
      return "Minus";
    case Opcode::Not:
      return "Not";
    case Opcode::Pow:
      return "Pow";
    case Opcode::Mul:
      return "Mul";
    case Opcode::Div:
      return "Div";
    case Opcode::IDiv:
      return "IDiv";
    case Opcode::Mod:
      return "Mod";
    case Opcode::Add:
      return "Add";
    case Opcode::Sub:
      return "Sub";
    case Opcode::EQ:
      return "EQ";
    case Opcode::NE:
      return "NE";
    case Opcode::LT:
      return "LT";
    case Opcode::LE:
      return "LE";
    case Opcode::GT:
      return "GT";
    case Opcode::GE:
      return "GE";
    case Opcode::If:
      return "If";
    case Opcode::GoTo:
      return "GoTo";
    case Opcode::GetArg:
      return "GetArg";
    case Opcode::ArgNum:
      return "ArgNum";
    case Opcode::Return:
      return "Return";
  }
  static char buf[24];
  snprintf(buf, sizeof(buf), "Custom%d", raw);
  return buf;
}

// 指令是否带一个操作数（与参考实现 Stope.has_a_param 等价，C++ 多 PushBinArr 一位）。
// 注意最后必须把自定义指令排除掉：它们的编号都 > Return，会落进 `return true` 的兜底
// 分支里（曾把 Custom100 后面跟的 Pop 当成操作数吃掉）。自定义指令是否带操作数由
// customHasParam 单独判断。
inline bool opHasParam(short raw) {
  if (raw > static_cast<short>(Opcode::Return))
    return false;
  if (raw <= static_cast<short>(Opcode::PushTrue))
    return false;
  if (raw <= static_cast<short>(Opcode::At))
    return true;
  if (raw <= static_cast<short>(Opcode::GE))
    return false;
  if (raw <= static_cast<short>(Opcode::GoTo))
    return true;
  if (raw <= static_cast<short>(Opcode::ArgNum))
    return false;
  return true;  // Return
}

// 自定义指令是否变长参数（决定了它后面是否跟一个参数个数）
inline bool customIsVarArg(short raw, const CustomOpcodeConfig* cfg) {
  if (cfg == nullptr)
    return false;
  for (const auto& kv : cfg->opcodes)
    if (kv.second.opcode == raw)
      return kv.second.isVarArg;
  return false;
}

inline bool customHasParam(short raw, const CustomOpcodeConfig* cfg) {
  return raw > static_cast<short>(Opcode::Return) && customIsVarArg(raw, cfg);
}

// 把指令流序列化成 "PushInt(0) Pop" 这样的串
inline std::string dumpCode(const Program& p, const CustomOpcodeConfig* cfg) {
  std::string d;
  for (size_t i = 0; i < p.opcodes.size(); ++i) {
    short raw = p.opcodes[i];
    if (i)
      d += " ";
    if (raw >= 0 && raw <= static_cast<short>(Opcode::Return))
      g_seenOpcodes.insert(raw);
    d += opName(raw);
    if (opHasParam(raw) || customHasParam(raw, cfg)) {
      d += "(" + std::to_string(p.opcodes[i + 1]) + ")";
      ++i;
    }
  }
  return d;
}
inline std::string dumpExportNames(const Program& p) {
  std::string d;
  for (const auto& kv : p.exports) {
    if (!d.empty())
      d += " ";
    d += toUtf8(kv.first) + ":" + std::to_string(kv.second);
  }
  return d;
}

struct CompileResult {
  std::shared_ptr<const std::u16string> src;
  Program prog;
  std::vector<std::string> errors;   // compiler.errors
  std::vector<std::string> pErrors;  // parser.errors
  bool ok = false;
  size_t size() const { return prog.opcodes.size(); }
};

// compileCfg 非空时用它编译（parser 仍用 cfg）。两边的配置不一致才能走到
// 「自定义指令在编译器这边没定义」这条防御分支 —— 单看 parser 是碰不到的，
// 因为不在 cfg 里的名字压根不会被识别成 Custom token。
inline CompileResult compileSrc(std::u16string src,
                                CustomOpcodeConfig* cfg = nullptr,
                                bool fold = false,
                                CustomOpcodeConfig* compileCfg = nullptr) {
  auto holder = std::make_shared<std::u16string>(std::move(src));
  CompileResult r;
  r.src = holder;
  Lexer lx(*holder);
  Parser p(lx, cfg);
  p.constFolding = fold;
  AST::Prog prog;
  p.ParseProgram(prog);
  r.pErrors = p.errors;
  // 配置只在构造时注入：compileCfg 非空时以它为准，模拟「parser 与 compiler 配置不一致」
  Compiler c(compileCfg != nullptr ? compileCfg : cfg);
  r.ok = c.Compile(prog, r.prog) == Result::Success;
  r.errors = c.errors;
  return r;
}

// 期望：code 文本 + 错误条数（默认 0）
inline void expectCode(const CompileResult& r,
                       const char* want,
                       const char* id,
                       const CustomOpcodeConfig* cfg = nullptr) {
  std::string got = dumpCode(r.prog, cfg);
  check(got == want, id, std::string("code == ") + want, "got=[" + got + "]");
}
inline void expectErrCount(const CompileResult& r, int n, const char* id) {
  check(static_cast<int>(r.errors.size()) == n, id,
        "compiler error count == " + std::to_string(n), [&] {
          std::string d;
          for (const auto& e : r.errors)
            d += "\n         [" + e + "]";
          return d.empty() ? std::string("") : d;
        }());
}

void runCompilerTests() {
  section("C 编译器 (C-COMPILE)");

  // ---------- C-01…C-06 字面量与变量的落地 ----------
  {
    struct {
      const char* id;
      std::u16string src;
      const char* want;
    } cases[] = {
        {"C-01", u"1;", "PushInt(0) Pop"},
        {"C-02", u"1.5;", "PushFloat(0) Pop"},
        {"C-03", u"\"ab\";", "PushString(0) Pop"},
        {"C-04", u"'x 41';", "PushBinArr(0) Pop"},
        {"C-05", u"true;", "PushTrue Pop"},
        {"C-06", u"null;", "PushNull Pop"},
    };
    for (const auto& c : cases) {
      auto r = compileSrc(c.src);
      expectCode(r, c.want, c.id);
      expectErrCount(r, 0, c.id);
      // 表达式语句：Push 一次 +1，Pop 一次 -1 → 需要的栈容量恒为 1
      check(r.prog.requiredStackSize == 1, c.id, "stack size == 1",
            "got=" + std::to_string(r.prog.requiredStackSize));
    }
  }
  {  // C-07 相同常量合并进同一个池位
    auto r = compileSrc(u"1; 2; 1; 2.0; 2.0;");
    expectCode(r,
               "PushInt(0) Pop PushInt(1) Pop PushInt(0) Pop PushFloat(0) Pop "
               "PushFloat(0) Pop",
               "C-07");
    check(r.prog.intConsts.size() == 2 && r.prog.floatConsts.size() == 1,
          "C-07", "int consts dedup",
          "ints=" + std::to_string(r.prog.intConsts.size()) +
              " floats=" + std::to_string(r.prog.floatConsts.size()));
  }
  {  // C-08 未声明就使用的标识符 → file scope 的唯一变量，进 exports
    auto r = compileSrc(u"a; b; a;");
    expectCode(r, "PushId(0) Pop PushId(1) Pop PushId(0) Pop", "C-08");
    check(r.prog.variableNum == 2, "C-08", "variable num == 2",
          "got=" + std::to_string(r.prog.variableNum));
    check(dumpExportNames(r.prog) == "a:0 b:1", "C-08", "exports == a:0 b:1",
          "got=[" + dumpExportNames(r.prog) + "]");
  }
  {  // C-09 let 与赋值
    auto r = compileSrc(u"let a = 1;");
    expectCode(r, "PushId(0) PushInt(0) Assign", "C-09");
    check(dumpExportNames(r.prog).empty(), "C-09", "local var not exported",
          "got=[" + dumpExportNames(r.prog) + "]");
  }
  {  // C-10 let 无赋值可以有多个标识符
    auto r = compileSrc(u"let a, b; a = 1; b = a;");
    expectCode(r, "PushId(0) PushInt(0) Assign PushId(1) PushId(0) Assign",
               "C-10");
    check(r.prog.variableNum == 2, "C-10", "variable num == 2", "");
  }
  {  // C-11 块结束回收局部变量索引
    auto r = compileSrc(u"{ let a = 1; } let b = 2;");
    expectCode(r, "PushId(0) PushInt(0) Assign PushId(0) PushInt(1) Assign",
               "C-11");
    check(r.prog.variableNum == 1, "C-11", "index recycled, variable num == 1",
          "got=" + std::to_string(r.prog.variableNum));
  }
  {  // C-12 export 只登记变量、不产生指令
    auto r = compileSrc(u"export a, b;");
    expectCode(r, "", "C-12");
    check(dumpExportNames(r.prog) == "a:0 b:1", "C-12", "exports == a:0 b:1",
          "got=[" + dumpExportNames(r.prog) + "]");
  }

  // ---------- C-13…C-16 运算符 ----------
  {
    struct {
      const char* id;
      std::u16string src;
      const char* want;
    } cases[] = {
        {"C-13", u"a + b;", "PushId(0) PushId(1) Add Pop"},
        {"C-14", u"a - b;", "PushId(0) PushId(1) Sub Pop"},  // 二元减必须是 Sub
        // `^` 的优先级高于 `* / idiv %`（common.hpp 的 OpPrecedence），
        // 所以这里是 ((a*b)/c%d) idiv (e^f)，不是 ((((a*b)/c)%d) idiv e)^f。
        {"C-15", u"a * b / c % d idiv e ^ f;",
         "PushId(0) PushId(1) Mul PushId(2) Div PushId(3) Mod PushId(4) "
         "PushId(5) Pow IDiv Pop"},
        {"C-16", u"a == b; a != b; a < b; a <= b; a > b; a >= b;",
         "PushId(0) PushId(1) EQ Pop PushId(0) PushId(1) NE Pop "
         "PushId(0) PushId(1) LT Pop PushId(0) PushId(1) LE Pop "
         "PushId(0) PushId(1) GT Pop PushId(0) PushId(1) GE Pop"},
    };
    for (const auto& c : cases) {
      auto r = compileSrc(c.src);
      expectCode(r, c.want, c.id);
      expectErrCount(r, 0, c.id);
    }
  }
  {  // C-17 一元：- 取 Minus，! / not 取 Not
    auto r = compileSrc(u"-a; !b; not c;");
    expectCode(r, "PushId(0) Minus Pop PushId(1) Not Pop PushId(2) Not Pop",
               "C-17");
  }
  {  // C-18 短路或：两条路径都只留 1 个结果。
     // 索引要把操作数算进去：PushId(0) 占 2 个 short，If(x) 占 2 个。
     //   0:PushId 1:(0) 2:If 3:(7) 4:PushTrue 5:GoTo 6:(15)
    //   7:PushId 8:(1) 9:If 10:(14) 11:PushTrue 12:GoTo 13:(15) 14:PushFalse 15:Pop
    auto r = compileSrc(u"a or b;");
    expectCode(r,
               "PushId(0) If(7) PushTrue GoTo(15) PushId(1) If(14) PushTrue "
               "GoTo(15) PushFalse Pop",
               "C-18");
    // 分支必须「汇合」着记账，否则会算成各分支深度之和（曾算出 3）
    check(r.prog.requiredStackSize == 1, "C-18", "stack size == 1",
          "got=" + std::to_string(r.prog.requiredStackSize));
  }
  {  // C-19 短路且
    auto r = compileSrc(u"a and b;");
    expectCode(
        r, "PushId(0) If(11) PushId(1) If(11) PushTrue GoTo(12) PushFalse Pop",
        "C-19");
    check(r.prog.requiredStackSize == 1, "C-19", "stack size == 1",
          "got=" + std::to_string(r.prog.requiredStackSize));
  }

  // ---------- C-20…C-24 调用 / 索引 / args / argc / return ----------
  {
    struct {
      const char* id;
      std::u16string src;
      const char* want;
    } cases[] = {
        {"C-20", u"f();", "PushId(0) Call(0) Pop"},
        {"C-21", u"f(1, 2);", "PushId(0) PushInt(0) PushInt(1) Call(2) Pop"},
        {"C-22", u"a[];", "PushId(0) At(0) Pop"},
        {"C-23", u"a[1, 2];", "PushId(0) PushInt(0) PushInt(1) At(2) Pop"},
        {"C-24", u"a(b[0]);",
         "PushId(0) PushId(1) PushInt(0) At(1) Call(1) Pop"},
    };
    for (const auto& c : cases) {
      auto r = compileSrc(c.src);
      expectCode(r, c.want, c.id);
      expectErrCount(r, 0, c.id);
    }
  }
  {  // C-25 调用：callee + n 个参数换成 1 个返回值 → 峰值 = n+1
    auto r = compileSrc(u"f(1, 2);");
    check(r.prog.requiredStackSize == 3, "C-25", "stack size == 3",
          "got=" + std::to_string(r.prog.requiredStackSize));
  }
  {  // C-26 args / argc
    auto r = compileSrc(u"args[0]; argc;");
    expectCode(r, "PushInt(0) GetArg Pop ArgNum Pop", "C-26");
  }
  {  // C-27 return：返回值个数Recorded
    auto r = compileSrc(u"return 1, 2; return;");
    expectCode(r, "PushInt(0) PushInt(1) Return(2) Return(0)", "C-27");
    check(r.prog.maxReturnNum == 2, "C-27", "max return num == 2",
          "got=" + std::to_string(r.prog.maxReturnNum));
  }

  // ---------- C-28…C-33 if / while / break / continue ----------
  {  // C-28 if：跳转目标含操作数的 short 一起数
    auto r = compileSrc(u"if a { b; }");
    expectCode(r, "PushId(0) If(9) PushId(1) Pop GoTo(9)", "C-28");
  }
  {  // C-29 if / elif / else
    auto r = compileSrc(u"if a { b; } elif c { d; } else { e; }");
    expectCode(r,
               "PushId(0) If(9) PushId(1) Pop GoTo(21) "
               "PushId(2) If(18) PushId(3) Pop GoTo(21) "
               "PushId(4) Pop",
               "C-29");
  }
  {  // C-30 while + continue：回到条件开头（索引 0）
    auto r = compileSrc(u"while a { continue; }");
    expectCode(r, "PushId(0) If(8) GoTo(0) GoTo(0)", "C-30");
  }
  {  // C-31 while + break：跳到循环末尾（索引 8）
    auto r = compileSrc(u"while a { break; }");
    expectCode(r, "PushId(0) If(8) GoTo(8) GoTo(0)", "C-31");
  }
  {  // C-32 无条件 while：没有条件就不需要回填跳转目标
    // （参考实现这里会把 code[0] 写成 code 长度，见 compiler.hpp 的偏离说明 4）
    auto r = compileSrc(u"while { b; }");
    expectCode(r, "PushId(0) Pop GoTo(0)", "C-32");
  }
  {  // C-33 if 分支有独立作用域，出分支后变量索引被回收复用
     //   a 是未声明就使用的 → file scope 索引 0；块里的 x 与块外的 y 共用索引 1
    auto r = compileSrc(u"if a { let x = 1; } let y = 2;");
    expectCode(r,
               "PushId(0) If(11) PushId(1) PushInt(0) Assign GoTo(11) "
               "PushId(1) PushInt(1) Assign",
               "C-33");
    check(r.prog.variableNum == 2, "C-33", "variable num == 2",
          "got=" + std::to_string(r.prog.variableNum));
  }

  // ---------- C-34…C-37 自定义指令 ----------
  {
    CustomOpcodeConfig cfg;
    std::u16string myop = u"myop";
    std::u16string myva = u"myva";
    cfg.addCustomOpcode(myop, 100, 2);
    cfg.addCustomOpcode(myva, 101, -1);
    {  // C-34 固定参数：不带 arity
      auto r = compileSrc(u"myop(1, 2);", &cfg);
      expectCode(r, "PushInt(0) PushInt(1) Custom100 Pop", "C-34", &cfg);
      expectErrCount(r, 0, "C-34");
    }
    {  // C-35 变长参数：多一个参数个数
      auto r = compileSrc(u"myva(1, 2, 3);", &cfg);
      expectCode(r, "PushInt(0) PushInt(1) PushInt(2) Custom101(3) Pop", "C-35",
                 &cfg);
      expectErrCount(r, 0, "C-35");
    }
    {  // C-36 固定参数个数不匹配 → 报错
      auto r = compileSrc(u"myop(1);", &cfg);
      expectErrCount(r, 1, "C-36");
      check(r.errors.size() == 1 &&
                r.errors[0].find("expected 2 args, but got 1") !=
                    std::string::npos,
            "C-36", "error mentions arg numbers", "");
    }
    {  // C-37 解析器认得、编译器不认得的自定义指令 → 报错。
       // compile() 出错时不写 out（与参考实现一致：返回 null），所以产出为空。
      CustomOpcodeConfig emptyCfg;
      auto r = compileSrc(u"myop(1);", &cfg, false, &emptyCfg);
      expectCode(r, "", "C-37", &emptyCfg);
      expectErrCount(r, 1, "C-37");
      check(!r.ok, "C-37", "compile() returns Error", "");
    }
    {  // C-37b 名字不在 cfg 里时 parser 根本不会产出 Custom token，退化成普通调用
      auto r = compileSrc(u"nope(1);", &cfg);
      expectCode(r, "PushId(0) PushInt(0) Call(1) Pop", "C-37b", &cfg);
      expectErrCount(r, 0, "C-37b");
    }
  }

  // ---------- C-38…C-42 错误场景 ----------
  {
    struct {
      const char* id;
      std::u16string src;
      const char* sub;
    } cases[] = {
        {"C-38", u"break;", "cannot use \"break\" outside of a loop. "},
        {"C-39", u"continue;", "cannot use \"continue\" outside of a loop. "},
        {"C-40", u"if a { export b; }",
         "\"export\" can only be used at top scope. "},
        {"C-41", u"let a; let a;", "duplicate declaration of 'a'. "},
        {"C-42", u"export a; export a;", "duplicate export of \"a\". "},
    };
    for (const auto& c : cases) {
      auto r = compileSrc(c.src);
      check(
          r.errors.size() == 1 && r.errors[0].find(c.sub) != std::string::npos,
          c.id, std::string("errors contains ") + c.sub, [&] {
            std::string d;
            for (const auto& e : r.errors)
              d += "[" + e + "]";
            return d;
          }());
    }
  }

  // ---------- C-43…C-45 折叠与编译的配合 ----------
  {  // C-43 折叠开启：常量表达式不再产生运算符指令
    auto on = compileSrc(u"1 + 2 * 3;", nullptr, true);
    expectCode(on, "PushInt(0) Pop", "C-43");
    check(on.prog.intConsts.size() == 1 && on.prog.intConsts[0] == 7, "C-43",
          "folded const == 7", "");
  }
  {  // C-44 折叠关闭：同一输入编译出完整运算
    auto off = compileSrc(u"1 + 2 * 3;", nullptr, false);
    expectCode(off, "PushInt(0) PushInt(1) PushInt(2) Mul Add Pop", "C-44");
  }
  {  // C-45 混合：只有含变量的子树保留
    auto r = compileSrc(u"a + 2 * 3;", nullptr, true);
    expectCode(r, "PushId(0) PushInt(0) Add Pop", "C-45");
    check(r.prog.intConsts[0] == 6, "C-45", "2*3 folded == 6", "");
  }

  // ---------- C-46 综合：一段小程序 ----------
  {
    auto r = compileSrc(
        u"export main;"
        u"let a, b;"
        u"let sum = 0;"
        u"while a < argc {"
        u"  sum = sum + args[a];"
        u"  a = a + 1;"
        u"}"
        u"return sum;");
    expectErrCount(r, 0, "C-46");
    //  0..4  let sum = 0       5..10 while a < argc  11..19 sum = sum + args[a]
    //  20..27 a = a + 1        28..29 GoTo 条件开头   30..33 return sum
    // 变量：main=0(export) a=1 b=2 sum=3；常量池 [0, 1]
    expectCode(r,
               "PushId(3) PushInt(0) Assign "
               "PushId(1) ArgNum LT If(30) "
               "PushId(3) PushId(3) PushId(1) GetArg Add Assign "
               "PushId(1) PushId(1) PushInt(1) Add Assign "
               "GoTo(5) "
               "PushId(3) Return(1)",
               "C-46");
    check(dumpExportNames(r.prog) == "main:0", "C-46", "exports == main:0",
          "got=[" + dumpExportNames(r.prog) + "]");
    check(r.prog.variableNum == 4, "C-46", "variable num == 4",
          "got=" + std::to_string(r.prog.variableNum));
    check(r.prog.requiredStackSize >= 3, "C-46", "stack size >= 3",
          "got=" + std::to_string(r.prog.requiredStackSize));
  }

  // ---------- C-47…C-52 边界：嵌套、遮蔽、跳转归属 ----------
  {  // C-47 嵌套调用：峰值出现在「最内层调用 + 外层已压栈」的那一刻
    auto r = compileSrc(u"f(g(1), 2);");
    expectCode(r,
               "PushId(0) PushId(1) PushInt(0) Call(1) PushInt(1) Call(2) Pop",
               "C-47");
    check(r.prog.requiredStackSize == 3, "C-47", "stack size == 3",
          "got=" + std::to_string(r.prog.requiredStackSize));
  }
  {  // C-48 下标在左值位置：按参考实现的做法，先算 At 再 Assign（CD-5）
    auto r = compileSrc(u"a[0] = 1;");
    expectCode(r, "PushId(0) PushInt(0) At(1) PushInt(1) Assign", "C-48");
  }
  {  // C-49 内层块可以遮蔽外层同名变量（不同 BlockScope）
    auto r = compileSrc(u"{ let a = 1; { let a = 2; } }");
    expectCode(r, "PushId(0) PushInt(0) Assign PushId(1) PushInt(1) Assign",
               "C-49");
  }
  {  // C-50 同一作用域内重复声明才报错（有赋值的 let 分支）
    auto r = compileSrc(u"{ let a = 1; let a = 2; }");
    expectErrCount(r, 1, "C-50");
  }
  {  // C-51 嵌套循环：break / continue 归最近的那一层
    auto r = compileSrc(u"while a { while b { break; } continue; }");
    expectCode(
        r, "PushId(0) If(16) PushId(1) If(12) GoTo(12) GoTo(4) GoTo(0) GoTo(0)",
        "C-51");
  }
  {  // C-52 循环嵌套 if 时的跳转目标仍然正确
    auto r = compileSrc(u"while a { if b { break; } else { continue; } }");
    expectCode(
        r,
        "PushId(0) If(16) PushId(1) If(12) GoTo(16) GoTo(14) GoTo(0) GoTo(0)",
        "C-52");
  }
}

}  // namespace Test
}  // namespace Stope

// compiler 测试入口：与 parser/lexer 一样自成二进制。
// 退出码：0 = 全部通过；1 = 有断言失败。
int main() {
  using namespace Stope::Test;
#ifdef _WIN32
  SetConsoleOutputCP(CP_UTF8);
#endif
  setvbuf(stdout, nullptr, _IONBF, 0);

  printf("=== stope compiler tests ===\n");
  runCompilerTests();

  const int totalTypes = 32;  // opcode.hpp 里的 Opcode 总数
  printf("\n== Opcode 覆盖: %zu/%d", g_seenOpcodes.size(), totalTypes);
  if (g_seenOpcodes.size() < static_cast<size_t>(totalTypes)) {
    printf("  缺失:");
    for (int i = 0; i < totalTypes; ++i)
      if (!g_seenOpcodes.count(i))
        printf(" %s", opName(static_cast<short>(i)));
  }
  printf("\n");

  printf("\n== 汇总\n");
  printf("   断言总数 %d | 失败 %d\n", g_total, g_failed);
  if (g_failed > 0) {
    printf("RESULT: FAILED\n");
    return 1;
  }
  printf("RESULT: PASSED\n");
  return 0;
}
