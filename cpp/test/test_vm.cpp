#include "test_vm_common.hpp"

#include <cstdio>
#include <cstdint>
#include <string>
#include <vector>

#ifdef _WIN32
#include <Windows.h>
#endif

namespace Stope {
namespace Test {

inline int g_total = 0;
inline int g_failed = 0;

inline void section(const char* name) {
  printf("\n-- %s\n", name);
}

inline void check(bool ok,
                  const char* id,
                  const std::string& expr,
                  const std::string& detail) {
  ++g_total;
  if (ok)
    return;
  ++g_failed;
  printf("  FAIL [%s] %s\n         %s\n", id, expr.c_str(), detail.c_str());
}

// 每个用例的统一前置检查：编译通过、运行无错、确实跑过
inline bool healthy(const VmResult& r, const char* id) {
  check(r.compiled, id, "compiled without error", vmDetail(r));
  check(r.ran, id, "Run() executed", vmDetail(r));
  check(!r.runError, id, "no runtime error", vmDetail(r));
  return r.compiled && r.ran && !r.runError;
}

// ==================== V-01…V-10 Return 不依赖解引用 ====================
// 2026-10-22 删掉 ReplaceTopValues / GetValueTop 之后，Return 的每个表达式
// 都由编译器保证是「值」。这一组钉住这条约束。
void runReturnCases() {
  section("V-01…V-06 Return");

  {  // V-01 返回字面量
    VmResult r;
    runSrc(u"return 7;", r);
    if (healthy(r, "V-01")) {
      check(r.retType == BasicVM::Value::Type::Integer, "V-01",
            "return type is Integer", vmDetail(r));
      check(r.retInt == 7, "V-01", "return == 7", vmDetail(r));
      check(r.stackLeft == 1, "V-01", "stack keeps 1 return value",
            vmDetail(r));
    }
  }
  {  // V-02 返回变量（核心：以前靠 ReplaceTopValues 解引用）
    VmResult r;
    runSrc(u"let a = 42; return a;", r);
    if (healthy(r, "V-02")) {
      check(r.retType == BasicVM::Value::Type::Integer, "V-02",
            "return type is Integer, not Identifier", vmDetail(r));
      check(r.retInt == 42, "V-02", "return == 42", vmDetail(r));
    }
  }
  {  // V-03 返回多个变量，顺序不能乱
    VmResult r;
    runSrc(u"let a = 7; let b = 8; return a, b;", r);
    if (healthy(r, "V-03")) {
      check(r.returns.size() == 2, "V-03", "2 return values", vmDetail(r));
      if (r.returns.size() == 2) {
        check(r.returns[0].type == BasicVM::Value::Type::Integer &&
                  r.returns[0].data.integer == 7,
              "V-03", "returns[0] == 7", vmDetail(r));
        check(r.returns[1].type == BasicVM::Value::Type::Integer &&
                  r.returns[1].data.integer == 8,
              "V-03", "returns[1] == 8", vmDetail(r));
      }
    }
  }
  {  // V-04 返回值是表达式
    VmResult r;
    runSrc(u"let a = 3; return a * 4;", r);
    if (healthy(r, "V-04"))
      check(r.retInt == 12, "V-04", "return == 12", vmDetail(r));
  }
  {  // V-05 返回字符串变量（句柄必须活着）
    VmResult r;
    runSrc(u"let s = \"hello\"; return s;", r);
    if (healthy(r, "V-05")) {
      check(r.retType == BasicVM::Value::Type::String, "V-05",
            "return type is String", vmDetail(r));
      check(r.retStr == "hello", "V-05", "return == \"hello\"", vmDetail(r));
    }
  }
  {  // V-06 返回 BinArr 变量
    VmResult r;
    runSrc(u"let b = 'x 41 42'; return b;", r);
    if (healthy(r, "V-06")) {
      check(r.retType == BasicVM::Value::Type::BinArr, "V-06",
            "return type is BinArr", vmDetail(r));
      check(r.retStr == "AB", "V-06", "binarr == 0x41 0x42", vmDetail(r));
    }
  }
}

// ==================== V-07…V-13 At 不依赖解引用 ====================
// opAt 原来用 GetValueTop 取容器和键；删掉之后要求两者都已是值。
void runAtCases() {
  section("V-07…V-13 At");

  {  // V-07 String 字面量索引
    VmResult r;
    runSrc(u"return \"abc\"[1];", r);
    if (healthy(r, "V-07"))
      check(r.retInt == 'b', "V-07", "string[1] == 'b'(98)", vmDetail(r));
  }
  {  // V-08 String 变量索引（核心：容器是 PushValue）
    VmResult r;
    runSrc(u"let s = \"abc\"; return s[2];", r);
    if (healthy(r, "V-08"))
      check(r.retInt == 'c', "V-08", "s[2] == 'c'(99)", vmDetail(r));
  }
  {  // V-09 BinArr 字面量索引
    VmResult r;
    runSrc(u"return 'x 41 42 43'[1];", r);
    if (healthy(r, "V-09"))
      check(r.retInt == 0x42, "V-09", "binarr[1] == 0x42", vmDetail(r));
  }
  {  // V-10 BinArr 变量索引
    VmResult r;
    runSrc(u"let b = 'x 41 42 43'; return b[2];", r);
    if (healthy(r, "V-10"))
      check(r.retInt == 0x43, "V-10", "b[2] == 0x43", vmDetail(r));
  }
  {  // V-11 索引结果参与算术（At 的输出必须是值）
    VmResult r;
    runSrc(u"let s = \"abc\"; return s[0] + 1;", r);
    if (healthy(r, "V-11"))
      check(r.retInt == 'a' + 1, "V-11", "s[0]+1 == 98", vmDetail(r));
  }
  {  // V-12 索引结果赋给变量
    VmResult r;
    runSrc(u"let s = \"abc\"; let c = s[1]; return c;", r);
    if (healthy(r, "V-12"))
      check(r.retInt == 'b', "V-12", "c == 'b'", vmDetail(r));
  }
  {  // V-13 索引嵌套：容器本身是索引结果
    VmResult r;
    runSrc(u"let s = \"abcdef\"; return s[s[0] - 97 + 2];", r);
    if (healthy(r, "V-13"))
      check(r.retInt == 'c', "V-13", "s[s[0]-97+2] == 'c'", vmDetail(r));
  }
}

// ==================== V-14…V-22 二元运算 / Assign / Call ====================
void runBinaryAndAssign() {
  section("V-14…V-22 Binary / Assign / Call");

  {  // V-14 Add 两侧都是变量
    VmResult r;
    runSrc(u"let a = 3; let b = 4; return a + b;", r);
    if (healthy(r, "V-14"))
      check(r.retInt == 7, "V-14", "a+b == 7", vmDetail(r));
  }
  {  // V-15 三元相加（结合性 + 栈序）
    VmResult r;
    runSrc(u"let a = 1; let b = 2; let c = 3; return a + b + c;", r);
    if (healthy(r, "V-15"))
      check(r.retInt == 6, "V-15", "a+b+c == 6", vmDetail(r));
  }
  {  // V-16 字符串拼接
    VmResult r;
    runSrc(u"let a = \"ab\"; let b = \"cd\"; return a + b;", r);
    if (healthy(r, "V-16"))
      check(r.retStr == "abcd", "V-16", "\"ab\"+\"cd\" == \"abcd\"",
            vmDetail(r));
  }
  {  // V-17 BinArr 拼接
    VmResult r;
    runSrc(u"let a = 'x 41'; let b = 'x 42'; return a + b;", r);
    if (healthy(r, "V-17"))
      check(r.retStr == "AB", "V-17", "binarr concat == 0x41 0x42",
            vmDetail(r));
  }
  {  // V-18 Assign 右值是变量（不能变成别名）
    VmResult r;
    runSrc(u"let a = 11; let b = a; a = 99; return b;", r);
    if (healthy(r, "V-18"))
      check(r.retInt == 11, "V-18", "b still 11 after a=99", vmDetail(r));
  }
  {  // V-19 链式赋值依赖值语义
    VmResult r;
    runSrc(u"let a = 1; let b = 2; b = a; return a + b;", r);
    if (healthy(r, "V-19"))
      check(r.retInt == 2, "V-19", "a+b == 2", vmDetail(r));
  }
  {  // V-20 赋值右侧是表达式
    VmResult r;
    runSrc(u"let a = 5; let b = a + a; return b;", r);
    if (healthy(r, "V-20"))
      check(r.retInt == 10, "V-20", "b == 10", vmDetail(r));
  }
  {  // V-21 一元运算
    VmResult r;
    runSrc(u"let a = 5; return -a;", r);
    if (healthy(r, "V-21"))
      check(r.retInt == -5, "V-21", "-a == -5", vmDetail(r));
  }
  {  // V-22 比较
    VmResult r;
    runSrc(u"let a = 5; return a > 3;", r);
    if (healthy(r, "V-22"))
      check(r.retInt == 1, "V-22", "a>3 == 1", vmDetail(r));
  }
}

// ==================== V-23…V-26 控制流 + 栈平衡 ====================
void runControlFlow() {
  section("V-23…V-26 Control flow / stack balance");

  {  // V-23 if / else 走真分支
    VmResult r;
    runSrc(u"let a = 5; if a > 3 { a = 1; } else { a = 2; } return a;", r);
    if (healthy(r, "V-23"))
      check(r.retInt == 1, "V-23", "then branch: a == 1", vmDetail(r));
  }
  {  // V-24 if / else 走假分支
    VmResult r;
    runSrc(u"let a = 1; if a > 3 { a = 1; } else { a = 2; } return a;", r);
    if (healthy(r, "V-24"))
      check(r.retInt == 2, "V-24", "else branch: a == 2", vmDetail(r));
  }
  {  // V-25 while 累加
    VmResult r;
    runSrc(
        u"let i = 0; let sum = 0;"
        u"while i < 5 { sum = sum + i; i = i + 1; }"
        u"return sum;",
        r);
    if (healthy(r, "V-25"))
      check(r.retInt == 10, "V-25", "sum of 0..4 == 10", vmDetail(r));
  }
  {  // V-26 短路求值不能把栈搞歪。
     // 注意 `or` 是**逻辑或**，结果固定是 0/1，不是「返回第一个真值操作数」。
    VmResult r;
    runSrc(u"let a = 0; return a or 5;", r);
    if (healthy(r, "V-26"))
      check(r.retType == BasicVM::Value::Type::Integer && r.retInt == 1, "V-26",
            "0 or 5 == 1 (logical, not 5)", vmDetail(r));
  }
  {  // V-26b 逻辑且
    VmResult r;
    runSrc(u"let a = 3; return a and 0;", r);
    if (healthy(r, "V-26b"))
      check(r.retType == BasicVM::Value::Type::Integer && r.retInt == 0,
            "V-26b", "3 and 0 == 0", vmDetail(r));
  }
}

// ==================== V-27…V-30 栈上不留 Identifier ====================
// 这是本次删掉两个辅助函数的前提条件：编译器保证栈里只有值。
void runNoIdentifierLeft() {
  section("V-27…V-30 Stack has no Identifier left");

  struct {
    const char* id;
    std::u16string src;
  } cases[] = {
      {"V-27", u"let a = 1; return a + 1;"},
      {"V-28", u"let s = \"abc\"; return s[0];"},
      {"V-29", u"let a, b; a = 1; b = a; return b;"},
      {"V-30", u"let i = 0; while i < 3 { i = i + 1; } return i;"},
  };
  for (auto& c : cases) {
    VmResult r;
    runSrc(c.src, r);
    if (!healthy(r, c.id))
      continue;
    // Run() 结束时（Return 之后）栈上只剩返回值，它们必须都是真值
    bool anyIdentifier = false;
    for (auto& v : r.returns)
      if (v.type == BasicVM::Value::Type::Identifier)
        anyIdentifier = true;
    check(!anyIdentifier, c.id, "no Identifier among return values",
          vmDetail(r));
  }
}

// ==================== V-31…V-34 Step() 与 Run() 等价 ====================
// Step() 从 2026-10-28 起才有实现（之前只有声明，谁调都是链接错误）。这组把两条
// 驱动路径钉在一起：同一份源码，Run 一次跑完 vs Step 逐条走到停机，返回值、停机
// 位置、错误都必须一致。Step 的三个约定见 basic_vm.hpp 里的注释。
void runStepCases() {
  section("V-31…V-34 Step() vs Run()");

  struct {
    const char* id;
    std::u16string src;
    bool expectError;
    bool checkSteps;  // 顺序执行才有「步数 == 指令条数」，带循环的不成立
  } cases[] = {
      // 顺序执行：步数应当正好等于指令条数（不含操作数）
      {"V-31", u"let a = 1; let b = 2; return a + b;", false, true},
      // 带回边：If / GoTo 会改 i，同一条指令会被反复执行，只比终态
      {"V-32", u"let i = 0; while i < 3 { i = i + 1; } return i;", false,
       false},
      // 运行期出错（null 不参与算术）：两条路径停在同一条指令上；出错是提前停，
      // 步数同样不可预知
      {"V-33", u"let x; return 1 + x;", true, false},
      // 只有一条指令就 return：Step 一次就结束，越界后不得再动
      {"V-34", u"return 7;", false, true},
  };

  for (auto& c : cases) {
    VmResult r;
    runSrc(c.src, r);
    StepTrace t;
    runSrcByStep(c.src, t);

    if (!r.compiled || !t.compiled) {
      check(false, c.id, "compiled without error",
            vmDetail(r) + "\n         step:" + vmStepDetail(t));
      continue;
    }
    check(r.runError == t.hitError, c.id, "Run and Step agree on outcome",
          vmDetail(r) + "\n         step:" + vmStepDetail(t));
    check(r.finalI == t.finalI, c.id, "same instruction pointer at stop",
          vmDetail(r) + "\n         step:" + vmStepDetail(t));
    check(r.runErrors == t.errors, c.id, "same errors",
          vmDetail(r) + "\n         step:" + vmStepDetail(t));
    check(
        r.retType == t.retType && r.retInt == t.retInt && r.retStr == t.retStr,
        c.id, "same return value",
        vmDetail(r) + "\n         step:" + vmStepDetail(t));

    if (!c.expectError) {
      check(t.postEndNoop, c.id,
            "Step() after the end is a no-op returning Success",
            vmStepDetail(t));
      if (c.checkSteps)
        check(t.steps == t.instCount, c.id,
              "one Step per instruction (no operands counted)",
              vmStepDetail(t));
      check(t.firstI > 0, c.id, "first Step() moves i forward",
            vmStepDetail(t));
    } else {
      check(t.errorRepeatDelta == 0, c.id,
            "Step() in error state adds no error", vmStepDetail(t));
    }
  }
}

void runVmTests() {
  runReturnCases();
  runAtCases();
  runBinaryAndAssign();
  runControlFlow();
  runNoIdentifierLeft();
  runStepCases();
}

}  // namespace Test
}  // namespace Stope

int main() {
  using namespace Stope::Test;
#ifdef _WIN32
  SetConsoleOutputCP(CP_UTF8);
#endif
  setvbuf(stdout, nullptr, _IONBF, 0);

  printf("=== stope vm tests ===\n");
  runVmTests();

  printf("\n== 汇总\n");
  printf("   断言总数 %d | 失败 %d\n", g_total, g_failed);
  if (g_failed > 0) {
    printf("RESULT: FAILED\n");
    return 1;
  }
  printf("RESULT: PASSED\n");
  return 0;
}
