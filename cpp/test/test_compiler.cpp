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
    case Opcode::PushValue:
      return "PushValue";
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

// preExports 版：只是多传一个第三参，其余与 compileSrc 相同。
inline CompileResult compilePre(std::u16string src,
                                const std::vector<std::u16string>& pre) {
  auto holder = std::make_shared<std::u16string>(std::move(src));
  CompileResult r;
  r.src = holder;
  Lexer lx(*holder);
  Parser p(lx, nullptr);
  AST::Prog prog;
  p.ParseProgram(prog);
  r.pErrors = p.errors;
  Compiler c(nullptr);
  r.ok = c.Compile(prog, r.prog, pre) == Result::Success;
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
    // 三处都是「读值」→ PushValue（PushId 只留给 let / 赋值的等号左侧）
    expectCode(r, "PushValue(0) Pop PushValue(1) Pop PushValue(0) Pop", "C-08");
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
    // a = 1：等号左侧是裸标识符 → PushId；b = a：左侧 b 是 PushId，右侧 a 是读值
    expectCode(r, "PushId(0) PushInt(0) Assign PushId(1) PushValue(0) Assign",
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
        {"C-13", u"a + b;", "PushValue(0) PushValue(1) Add Pop"},
        {"C-14", u"a - b;",
         "PushValue(0) PushValue(1) Sub Pop"},  // 二元减必须是 Sub
        // `^` 的优先级高于 `* / idiv %`（common.hpp 的 OpPrecedence），
        // 所以这里是 ((a*b)/c%d) idiv (e^f)，不是 ((((a*b)/c)%d) idiv e)^f。
        {"C-15", u"a * b / c % d idiv e ^ f;",
         "PushValue(0) PushValue(1) Mul PushValue(2) Div PushValue(3) Mod "
         "PushValue(4) PushValue(5) Pow IDiv Pop"},
        {"C-16", u"a == b; a != b; a < b; a <= b; a > b; a >= b;",
         "PushValue(0) PushValue(1) EQ Pop PushValue(0) PushValue(1) NE Pop "
         "PushValue(0) PushValue(1) LT Pop PushValue(0) PushValue(1) LE Pop "
         "PushValue(0) PushValue(1) GT Pop PushValue(0) PushValue(1) GE Pop"},
    };
    for (const auto& c : cases) {
      auto r = compileSrc(c.src);
      expectCode(r, c.want, c.id);
      expectErrCount(r, 0, c.id);
    }
  }
  {  // C-17 一元：- 取 Minus，! / not 取 Not
    auto r = compileSrc(u"-a; !b; not c;");
    expectCode(
        r, "PushValue(0) Minus Pop PushValue(1) Not Pop PushValue(2) Not Pop",
        "C-17");
  }
  {  // C-18 短路或：两条路径都只留 1 个结果。
     // 索引要把操作数算进去：PushValue(0) 占 2 个 short，If(x) 占 2 个。
     //   0:PushValue 1:(0) 2:If 3:(7) 4:PushTrue 5:GoTo 6:(15)
    //   7:PushValue 8:(1) 9:If 10:(14) 11:PushTrue 12:GoTo 13:(15) 14:PushFalse 15:Pop
    auto r = compileSrc(u"a or b;");
    expectCode(r,
               "PushValue(0) If(7) PushTrue GoTo(15) PushValue(1) If(14) "
               "PushTrue GoTo(15) PushFalse Pop",
               "C-18");
    // 分支必须「汇合」着记账，否则会算成各分支深度之和（曾算出 3）
    check(r.prog.requiredStackSize == 1, "C-18", "stack size == 1",
          "got=" + std::to_string(r.prog.requiredStackSize));
  }
  {  // C-19 短路且
    auto r = compileSrc(u"a and b;");
    expectCode(r,
               "PushValue(0) If(11) PushValue(1) If(11) PushTrue GoTo(12) "
               "PushFalse Pop",
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
        // 被调用者 / 被索引的容器同样是「读值」→ PushValue
        {"C-20", u"f();", "PushValue(0) Call(0) Pop"},
        {"C-21", u"f(1, 2);", "PushValue(0) PushInt(0) PushInt(1) Call(2) Pop"},
        {"C-22", u"a[];", "PushValue(0) At(0) Pop"},
        {"C-23", u"a[1, 2];", "PushValue(0) PushInt(0) PushInt(1) At(2) Pop"},
        {"C-24", u"a(b[0]);",
         "PushValue(0) PushValue(1) PushInt(0) At(1) Call(1) Pop"},
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
  {  // C-27 return：返回值个数Recorded；后面的 return; 不可达，不发射
    auto r = compileSrc(u"return 1, 2; return;");
    expectCode(r, "PushInt(0) PushInt(1) Return(2)", "C-27");
    check(r.prog.maxReturnNum == 2, "C-27", "max return num == 2",
          "got=" + std::to_string(r.prog.maxReturnNum));
  }

  // ---------- C-28…C-33 if / while / break / continue ----------
  {  // C-28 if：跳转目标含操作数的 short 一起数
    auto r = compileSrc(u"if a { b; }");
    expectCode(r, "PushValue(0) If(9) PushValue(1) Pop GoTo(9)", "C-28");
  }
  {  // C-29 if / elif / else
    auto r = compileSrc(u"if a { b; } elif c { d; } else { e; }");
    expectCode(r,
               "PushValue(0) If(9) PushValue(1) Pop GoTo(21) "
               "PushValue(2) If(18) PushValue(3) Pop GoTo(21) "
               "PushValue(4) Pop",
               "C-29");
  }
  {  // C-30 while + continue：回到条件开头（索引 0）。体以 continue 结尾
     //   → 回跳 GoTo 是死代码，省略
    auto r = compileSrc(u"while a { continue; }");
    expectCode(r, "PushValue(0) If(6) GoTo(0)", "C-30");
  }
  {  // C-31 while + break：跳到循环末尾（索引 6）。体以 break 结尾
     //   → 回跳 GoTo 是死代码，省略
    auto r = compileSrc(u"while a { break; }");
    expectCode(r, "PushValue(0) If(6) GoTo(6)", "C-31");
  }
  {  // C-32 无条件 while：没有条件就不需要回填跳转目标
    // （参考实现这里会把 code[0] 写成 code 长度，见 compiler.hpp 的偏离说明 4）
    auto r = compileSrc(u"while { b; }");
    expectCode(r, "PushValue(0) Pop GoTo(0)", "C-32");
  }
  {  // C-33 if 分支有独立作用域，出分支后变量索引被回收复用
     //   a 是未声明就使用的 → file scope 索引 0（读值 → PushValue）；
     //   块里的 x 与块外的 y 共用索引 1，两处 let 的目标都是 PushId
    auto r = compileSrc(u"if a { let x = 1; } let y = 2;");
    expectCode(r,
               "PushValue(0) If(11) PushId(1) PushInt(0) Assign GoTo(11) "
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
      expectCode(r, "PushValue(0) PushInt(0) Call(1) Pop", "C-37b", &cfg);
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
    expectCode(r, "PushValue(0) PushInt(0) Add Pop", "C-45");
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
    // PushId 只出现在「等号左侧」：let sum 的目标、sum = … 的 sum、a = … 的 a。
    // 其余出现（条件里的 a、右侧的 sum 与 a、return 的 sum）都是读值 → PushValue。
    expectCode(r,
               "PushId(3) PushInt(0) Assign "
               "PushValue(1) ArgNum LT If(30) "
               "PushId(3) PushValue(3) PushValue(1) GetArg Add Assign "
               "PushId(1) PushValue(1) PushInt(1) Add Assign "
               "GoTo(5) "
               "PushValue(3) Return(1)",
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
               "PushValue(0) PushValue(1) PushInt(0) Call(1) PushInt(1) "
               "Call(2) Pop",
               "C-47");
    check(r.prog.requiredStackSize == 3, "C-47", "stack size == 3",
          "got=" + std::to_string(r.prog.requiredStackSize));
  }
  {  // C-48 下标在左值位置：按参考实现的做法，先算 At 再 Assign（CD-5）。
     // 等号左侧不是裸标识符（是 a[0]），所以 a 走普通的读值 → PushValue。
    auto r = compileSrc(u"a[0] = 1;");
    expectCode(r, "PushValue(0) PushInt(0) At(1) PushInt(1) Assign", "C-48");
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
  {  // C-51 嵌套循环：break / continue 归最近的那一层。内层体以 break
     //   结尾 → 内层回跳省略；continue 终止外层体 → 外层回跳省略
    auto r = compileSrc(u"while a { while b { break; } continue; }");
    expectCode(r, "PushValue(0) If(12) PushValue(1) If(10) GoTo(10) GoTo(0)",
               "C-51");
  }
  {  // C-52 循环嵌套 if（两分支都终止）→ 回跳省略；分支体终止 → 分支尾
     //   GoTo 也省略（旧产物里 break 的 GoTo 后面还有一条分支尾 GoTo）
    auto r = compileSrc(u"while a { if b { break; } else { continue; } }");
    expectCode(r, "PushValue(0) If(12) PushValue(1) If(10) GoTo(12) GoTo(0)",
               "C-52");
  }
  // ---------- C-53…C-56 预导出 ----------
  // 与 golden.txt 的 CM-73…CM-78 对应，只是这里手写：C++ 是权威实现，别只靠
  // 另外四份比对 golden 才发现自己错了。
  {  // C-53 形参先占槽位，且顺序就是名单顺序
    auto r = compilePre(u"a + b;", {u"a", u"b"});
    expectCode(r, "PushValue(0) PushValue(1) Add Pop", "C-53");
    check(r.prog.exports.size() == 2 && r.prog.exports.at(u"a") == 0 &&
              r.prog.exports.at(u"b") == 1,
          "C-53", "exports = {a:0, b:1}", "got=" +
              std::to_string(r.prog.exports.size()) + " 条");
  }
  {  // C-54 槽位后移：源码里的第一个变量编号是 1
    auto r = compilePre(u"let b = 1;", {u"a"});
    expectCode(r, "PushId(1) PushInt(0) Assign", "C-54");
    check(r.prog.variableNum == 2, "C-54", "variableNum == 2",
          "got=" + std::to_string(r.prog.variableNum));
  }
  {  // C-55 名单内重名 / 空名字：各报一条，行号记 0
    auto r = compilePre(u"a;", {u"a", u"a"});
    expectErrCount(r, 1, "C-55");
    r = compilePre(u"a;", {u"a", u"", u"b"});
    check(r.errors.size() == 1 &&
              r.errors[0] == "line 0: empty name in pre-exports. ",
          "C-55b", "empty name -> line 0", "got=[" +
              (r.errors.empty() ? std::string() : r.errors[0]) + "]");
  }
  {  // C-56 与源码冲突：导出同名、顶层 let 同名都算 duplicate
    auto r = compilePre(u"export a;", {u"a"});
    expectErrCount(r, 1, "C-56");
    r = compilePre(u"let a = 1;", {u"a"});
    expectErrCount(r, 1, "C-56b");
    // 块内 let 是遮蔽，不算冲突
    r = compilePre(u"{ let a = 1; }", {u"a"});
    expectErrCount(r, 0, "C-56c");
  }

  // ---------- C-57…C-63 defer：拼接布局与两条纪律 ----------
  {  // C-57 defer 语句位置零指令：载荷在程序尾拼接，指令流与手写赋值相同
    auto withDefer = compileSrc(u"defer x = 5;");
    auto without = compileSrc(u"x = 5;");
    expectCode(withDefer, "PushId(0) PushInt(0) Assign", "C-57");
    check(withDefer.prog.opcodes == without.prog.opcodes, "C-57",
          "defer compiles to the same layout as the bare assignment", "");
  }
  {  // C-58 前向引用（OQ-8 新语义）：后文本地名不再被捕获——msg 绑定隐式
     // 导出宿主变量；后文顶层 let msg 与它重名 → duplicate export，
     // 行号归 defer 语句（冲突在 defer 绑定符号时已注定）
    auto r = compileSrc(u"defer print(msg); let msg = 1;");
    expectErrCount(r, 1, "C-58");
    check(r.errors.size() == 1 &&
              r.errors[0] == "line 1: duplicate export of \"msg\". ",
          "C-58", "forward reference binds its own export; later top-level "
                  "let collides",
          r.errors.empty() ? "" : r.errors[0]);
  }
  {  // C-68 前向引用不冲突时完全合法（OQ-8）：got / msg 绑定隐式导出
     // 宿主变量（槽 1 / 2）；块内 let msg 是槽 0——两个 msg 互不相干
    auto r = compileSrc(u"defer got = msg; { let msg = 1; }");
    expectCode(r, "PushId(0) PushInt(0) Assign PushId(1) PushValue(2) Assign",
               "C-68");
    check(r.prog.exports.size() == 2, "C-68", "got and msg both exported",
          "exports=" + std::to_string(r.prog.exports.size()));
  }
  {  // C-59 break 越过 defer 边界（目标循环在载荷外）→ 报错
    auto r = compileSrc(u"while a { defer { break; } }");
    check(r.errors.size() == 1 &&
              r.errors[0].find("\"break\" cannot cross a defer statement.") !=
                  std::string::npos,
          "C-59", "break cannot cross defer boundary",
          r.errors.empty() ? "" : r.errors[0]);
  }
  {  // C-60 载荷内 return 一律报错（终点是整个程序，必然越界）
    auto r = compileSrc(u"defer { return 1; }");
    check(r.errors.size() == 1 &&
              r.errors[0].find(
                  "\"return\" cannot be used in a defer statement.") !=
                  std::string::npos,
          "C-60", "return cannot be used in defer",
          r.errors.empty() ? "" : r.errors[0]);
  }
  {  // C-61 LIFO：同 scope 多条 defer 逆序发射（后登记先执行）。
     //   常量池：Int(0)→0、Int(2)→1、Int(1)→2，故 b=2 是 PushInt(1)、a=1 是 PushInt(2)
    auto r = compileSrc(u"let a = 0; let b = 0; defer a = 1; defer b = 2;");
    expectCode(r,
               "PushId(0) PushInt(0) Assign PushId(1) PushInt(0) Assign "
               "PushId(1) PushInt(1) Assign PushId(0) PushInt(2) Assign",
               "C-61");
  }
  {  // C-62 冻结绑定：遮蔽情形下载荷绑定 defer 处可见的外层 msg（槽 0），
     //   不是块内后来声明的同名变量（槽 2）
    auto r = compileSrc(
        u"let msg = 0; let got = 0; { defer got = msg; let msg = 2; }");
    expectCode(r,
               "PushId(0) PushInt(0) Assign PushId(1) PushInt(0) Assign "
               "PushId(2) PushInt(1) Assign PushId(1) PushValue(0) Assign",
               "C-62");
  }
  {  // C-63 体以 break 结尾：break 出口拼一份结算，块尾副本与回跳都是
     //   死代码，省略（旧产物里 GoTo 16 之后还有一份块尾副本 + 回跳）
    auto r = compileSrc(
        u"let n = 0; while a { defer n = 1; break; }");
    expectCode(r,
               "PushId(0) PushInt(0) Assign PushValue(1) If(16) "
               "PushId(0) PushInt(1) Assign GoTo(16)",
               "C-63");
  }
  {  // C-64 多出口各拼一份（体不终止）：块尾正常退出一份（回跳 GoTo 5 前）、
     //   break 路径一份（GoTo 28 前）——运行期每轮块尾跑一次，break 时再跑
     //   一次（对应 V-40 的 2）
    auto r = compileSrc(
        u"let n = 0; while a { defer n = 1; if b { break; } }");
    expectCode(r,
               "PushId(0) PushInt(0) Assign PushValue(1) If(27) "
               "PushValue(2) If(20) PushId(0) PushInt(1) Assign GoTo(27) "
               "PushId(0) PushInt(1) Assign GoTo(5)",
               "C-64");
  }
  {  // C-65 终止语句之后的语句不发射：块内 return 已出栈，后面的 return 2
     //   不可达；常量 2 也不进池
    auto r = compileSrc(u"{ return 1; } return 2;");
    expectCode(r, "PushInt(0) Return(1)", "C-65");
    check(r.prog.intConsts.size() == 1, "C-65", "int consts == 1",
          "got=" + std::to_string(r.prog.intConsts.size()));
  }
  {  // C-66 无条件 while 且体无 break = 真死循环，其后的语句不发射
    auto r = compileSrc(u"while { } a = 1;");
    expectCode(r, "GoTo(0)", "C-66");
  }
  {  // C-67 字面量条件折叠（OQ-2）：while true 折叠为无条件循环，其后
     //   语句按真死循环消除——产物与 C-66 一致
    auto r = compileSrc(u"while true { } a = 1;");
    expectCode(r, "GoTo(0)", "C-67");
  }
  {  // C-69 if true：只发该分支，零条件、零跳转指令
    auto r = compileSrc(u"if true { a = 1; }");
    expectCode(r, "PushId(0) PushInt(0) Assign", "C-69");
  }
  {  // C-70 if false：整支消除，其后的语句照常；分支内的 defer 不登记
     //   （程序尾没有 defer 结算副本）。死分支从不编译——其中的名字 a
     //   不占槽位，b 就是 0 号
    auto r = compileSrc(u"if false { defer a = 1; } b = 2;");
    expectCode(r, "PushId(0) PushInt(0) Assign", "C-70");
  }
  {  // C-71 链上折叠：非常量打头，常量真的 elif 只发体——第二组 If/GoTo
     //   与 else 都消除；elif 的假路径跳到体开头
    auto r = compileSrc(
        u"if x { a = 1; } elif true { b = 2; } else { c = 3; }");
    expectCode(r,
               "PushValue(0) If(11) PushId(1) PushInt(0) Assign GoTo(16) "
               "PushId(2) PushInt(1) Assign",
               "C-71");
  }
  {  // C-72 全常量假 + else：只发 else 体
    auto r = compileSrc(
        u"if false { a = 1; } elif false { b = 2; } else { c = 3; }");
    expectCode(r, "PushId(0) PushInt(0) Assign", "C-72");
  }
  {  // C-73 while false：整环消除——体（含 defer）不编译，其后的语句照常
    auto r = compileSrc(u"while false { defer a = 1; } b = 2;");
    expectCode(r, "PushId(0) PushInt(0) Assign", "C-73");
  }
  {  // C-74 解析期折叠出的常量条件同样命中：fold=true 时 1 < 2 在 AST 里
     //   已是 Bool(true)。挂具默认关折叠（编译器测试要在未折叠 AST 上跑），
     //   这里显式打开
    auto r = compileSrc(u"if 1 < 2 { a = 1; } b = 2;", nullptr, /*fold=*/true);
    expectCode(r,
               "PushId(0) PushInt(0) Assign PushId(1) PushInt(1) Assign",
               "C-74");
  }
  {  // C-75 折叠为真但有 break：不算死循环，其后的语句照常；体终止故无回跳
    auto r = compileSrc(u"while true { break; } a = 1;");
    expectCode(r, "GoTo(2) PushId(0) PushInt(0) Assign", "C-75");
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

  const int totalTypes = 33;  // opcode.hpp 里的 Opcode 总数
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
