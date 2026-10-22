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
