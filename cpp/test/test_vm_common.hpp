#pragma once
// VM 测试公共设施：编译一张 Program 并在 BasicVM 上跑一遍，取返回值比对。
//
// 用法：
//   auto r = runSrc(u"let a = 1; return a + 1;");
//   EXPECT_VM_INT(r, 2, "V-01");
//
// 注意：
//   1) 本组测的是 basic_vm.hpp（**参考实现，不是标准**），断言锁的是「编译器产物
//      能被这个执行器正确执行」，不是 VM 的设计本身。
//   2) 每个用例都自带 Allocator / ProgramConstants / Program，互相不共享状态。
//   3) 栈上不允许残留 Identifier —— 编译器已保证（PushValue 解引用、PushId 只紧邻
//      Assign），这里用 assertNoIdentifierLeft() 把这条约束钉住。

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include <stope/basic_vm.hpp>
#include <stope/compiler.hpp>
#include <stope/debug.hpp>  // OpcodeHasArg：算「指令条数」用，与反汇编同一判据
#include <stope/lexer.hpp>
#include <stope/parser.hpp>

namespace Stope {
namespace Test {

// 没有 args / argc 的宿主：用到 args 的用例会走 at() 报错，这样能立刻暴露
struct VmNoArgs : BasicVM::Arguments {
  Result at(BasicVM::State& s,
            const BasicVM::Value& key,
            BasicVM::Value& out) override {
    (void)key;
    (void)out;
    s.Error("args not provided in this test. ");
    return Result::Error;
  }
  std::int64_t num() override { return 0; }
};

// 可见形式：非 ASCII 码元打成 '?'（与 test_common.hpp 的 toUtf8 同样处理，
// 这里单独写一份是因为 test_vm 不 include test_common.hpp）
inline std::string vmAscii(std::u16string_view v) {
  std::string s;
  for (char16_t c : v)
    s += (c < 128) ? static_cast<char>(c) : '?';
  return s;
}

struct VmResult {
  BasicVM::Allocator alloc;  // 必须比 constants / state 活得久
  BasicVM::ProgramConstants* constants = nullptr;
  BasicVM::API api;
  Program program;
  bool compiled = false;
  bool ran = false;
  bool runError = false;
  std::vector<std::string> compileErrors;
  std::vector<std::string> runErrors;
  std::vector<BasicVM::Value> returns;  // 拷出来，避免 span 悬空
  BasicVM::Value::Type retType = BasicVM::Value::Type::Null;
  int64_t retInt = 0;
  double retFloat = 0;
  std::string retStr;    // String / BinArr 的可见形式
  size_t stackLeft = 0;  // 跑完后栈上剩下的元素数
  int finalI = 0;        // 停机时的指令指针（与 StepTrace 对照用）

  VmResult() = default;
  VmResult(const VmResult&) = delete;
  VmResult& operator=(const VmResult&) = delete;
  // 不提供移动：Allocator 删了拷贝构造，隐式移动也随之失效。
  // 因此 runSrc 采用「调用方建对象、传引用进来」的形式，避免任何返回值传输。
};

// 编译 + 执行，结果写进调用方提供的 r（避免返回不可移动的对象）。
// ProgramConstants 需要 Allocator，故用 unique_ptr 保证析构顺序。
inline void runSrc(std::u16string src, VmResult& r) {
  Lexer lexer(src);
  Parser parser(lexer);
  AST::Prog tree;
  parser.ParseProgram(tree);
  Compiler compiler;
  compiler.Compile(tree, r.program);
  r.compileErrors = compiler.errors;
  if (!compiler.errors.empty())
    return;
  r.compiled = true;

  std::unique_ptr<BasicVM::ProgramConstants> constants(
      new BasicVM::ProgramConstants(r.alloc, r.program));
  r.constants = constants.get();

  BasicVM::State state;
  state.SetAPI(r.api);
  state.SetAllocator(r.alloc);
  state.SetProgramConstants(*constants);
  state.SetProgram(r.program);
  state.variables.resize(r.program.variableNum);

  // 脚本里用到但没声明的名字（fmt:println 等）走 exports，给个空实现防止崩。
  for (auto& kv : r.program.exports) {
    auto& v = state.variables[kv.second];
    if (v.type == BasicVM::Value::Type::Null) {
      v.type = BasicVM::Value::Type::HostFunction;
      v.data.hostFuncPtr = nullptr;
    }
  }

  VmNoArgs noargs;
  state.SetArguments(noargs);

  Result res = state.Run();
  r.ran = true;
  r.runError = (res == Result::Error);
  r.runErrors = state.errors;
  r.stackLeft = state.stack.size();
  r.finalI = state.i;

  for (auto& v : state.returns) {
    BasicVM::Value copy;
    BasicVM::Value::Copy(r.alloc, v, copy);
    r.returns.push_back(std::move(copy));
  }
  if (!r.returns.empty()) {
    auto& v = r.returns[0];
    r.retType = v.type;
    switch (v.type) {
      case BasicVM::Value::Type::Integer:
        r.retInt = v.data.integer;
        break;
      case BasicVM::Value::Type::Float:
        r.retFloat = v.data.floating;
        break;
      case BasicVM::Value::Type::String:
        r.retStr = vmAscii(r.alloc.GetString(v.data.handle));
        break;
      case BasicVM::Value::Type::BinArr: {
        auto& data = r.alloc.GetBinArr(v.data.handle);
        for (char c : data)
          r.retStr += static_cast<char>(static_cast<unsigned char>(c));
        break;
      }
      default:
        break;
    }
  }
  state.Clear();  // 显式释放：state 的析构也会做，但这让意图明确
}

// ---------------------------------------------------------------------------
// Step() 对照实验：同一份源码改用 Step 逐条驱动，记录轨迹。
// 装配部分与 runSrc 逐行相同（只是驱动方式不同），这样 V-31 起的断言比的就是
// 「两条驱动路径」本身，而不是两套装配。
// ---------------------------------------------------------------------------
struct StepTrace {
  BasicVM::Allocator alloc;  // 必须比 constants / state 活得久
  BasicVM::ProgramConstants* constants = nullptr;
  BasicVM::API api;
  Program program;
  bool compiled = false;
  std::vector<std::string> compileErrors;

  int instCount = 0;         // 指令条数（不含操作数）
  int steps = 0;             // 成功执行的指令条数
  int firstI = 0;            // 第一次 Step 之后的 i
  int finalI = 0;            // 停机时的 i
  bool hitError = false;     // 是否以 Result::Error 停下
  int errorRepeatDelta = 0;  // 错误态再 Step 一次，errors 的增量（期望 0）
  bool postEndNoop = false;  // 越界后连调两次 Step：都 Success 且 i 不变
  std::vector<std::string> errors;
  std::vector<BasicVM::Value> returns;
  BasicVM::Value::Type retType = BasicVM::Value::Type::Null;
  int64_t retInt = 0;
  std::string retStr;
  size_t stackLeft = 0;

  StepTrace() = default;
  StepTrace(const StepTrace&) = delete;
  StepTrace& operator=(const StepTrace&) = delete;
};

// 指令条数：按「这条指令吃不吃一个操作数」跳读，与调试器的切分规则一致。
inline int vmInstCount(const Program& p) {
  int n = 0;
  size_t k = 0;
  while (k < p.opcodes.size()) {
    short op = p.opcodes[k];
    ++n;
    ++k;
    // 自定义指令（> 32）本组用例不涉及；内置的判据与 debug.hpp 同源
    if (op >= 0 && op <= static_cast<short>(Opcode::Return) &&
        OpcodeHasArg(static_cast<Opcode>(op)))
      ++k;
  }
  return n;
}

inline void runSrcByStep(std::u16string src, StepTrace& t) {
  Lexer lexer(src);
  Parser parser(lexer);
  AST::Prog tree;
  parser.ParseProgram(tree);
  Compiler compiler;
  compiler.Compile(tree, t.program);
  t.compileErrors = compiler.errors;
  if (!compiler.errors.empty())
    return;
  t.compiled = true;

  std::unique_ptr<BasicVM::ProgramConstants> constants(
      new BasicVM::ProgramConstants(t.alloc, t.program));
  t.constants = constants.get();

  BasicVM::State state;
  state.SetAPI(t.api);
  state.SetAllocator(t.alloc);
  state.SetProgramConstants(*constants);
  state.SetProgram(t.program);
  state.variables.resize(t.program.variableNum);
  for (auto& kv : t.program.exports) {
    auto& v = state.variables[kv.second];
    if (v.type == BasicVM::Value::Type::Null) {
      v.type = BasicVM::Value::Type::HostFunction;
      v.data.hostFuncPtr = nullptr;
    }
  }

  VmNoArgs noargs;
  state.SetArguments(noargs);

  t.instCount = vmInstCount(t.program);

  const int size = static_cast<int>(t.program.opcodes.size());
  while (state.i < size && state.Step() == Result::Success) {
    ++t.steps;
    if (t.steps == 1)
      t.firstI = state.i;
  }
  t.hitError = state.HasError();
  t.finalI = state.i;
  t.errors = state.errors;
  t.stackLeft = state.stack.size();

  if (t.hitError) {
    // 错误态再调一次：Step 的预检应当直接返回 Error，不执行、不追加错误
    size_t before = state.errors.size();
    state.Step();
    t.errorRepeatDelta = static_cast<int>(state.errors.size() - before);
  } else {
    // 越界之后再调两次：Success 且什么也不做（这就是「终止条件必须用 i 判」）
    int iBefore = state.i;
    Result r1 = state.Step();
    Result r2 = state.Step();
    t.postEndNoop = (r1 == Result::Success && r2 == Result::Success &&
                     state.i == iBefore && !state.HasError());
  }

  for (auto& v : state.returns) {
    BasicVM::Value copy;
    BasicVM::Value::Copy(t.alloc, v, copy);
    t.returns.push_back(std::move(copy));
  }
  if (!t.returns.empty()) {
    auto& v = t.returns[0];
    t.retType = v.type;
    switch (v.type) {
      case BasicVM::Value::Type::Integer:
        t.retInt = v.data.integer;
        break;
      case BasicVM::Value::Type::String:
        t.retStr = vmAscii(t.alloc.GetString(v.data.handle));
        break;
      default:
        break;
    }
  }
  state.Clear();
}

inline std::string vmStepDetail(const StepTrace& t) {
  std::string d;
  d += "compiled=" + std::string(t.compiled ? "y" : "n");
  d += " inst=" + std::to_string(t.instCount);
  d += " steps=" + std::to_string(t.steps);
  d += " firstI=" + std::to_string(t.firstI);
  d += " finalI=" + std::to_string(t.finalI);
  d += " hitError=" + std::string(t.hitError ? "y" : "n");
  d += " errRepeat+" + std::to_string(t.errorRepeatDelta);
  d += " postEndNoop=" + std::string(t.postEndNoop ? "y" : "n");
  d += " retInt=" + std::to_string(t.retInt);
  d += " stackLeft=" + std::to_string(t.stackLeft);
  for (auto& e : t.compileErrors)
    d += "\n         compile: [" + e + "]";
  for (auto& e : t.errors)
    d += "\n         step: [" + e + "]";
  return d;
}

inline std::string vmDetail(const VmResult& r) {
  std::string d;
  d += "compiled=" + std::string(r.compiled ? "y" : "n");
  d += " ran=" + std::string(r.ran ? "y" : "n");
  d += " runError=" + std::string(r.runError ? "y" : "n");
  d += " retType=" + std::to_string(static_cast<int>(r.retType));
  d += " retInt=" + std::to_string(r.retInt);
  d += " stackLeft=" + std::to_string(r.stackLeft);
  if (!r.retStr.empty())
    d += " retStr=[" + r.retStr + "]";
  for (auto& e : r.compileErrors)
    d += "\n         compile: [" + e + "]";
  for (auto& e : r.runErrors)
    d += "\n         run: [" + e + "]";
  return d;
}

}  // namespace Test
}  // namespace Stope
