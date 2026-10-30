// Quick-start demo: compile a Stope program and run it.
//
// Stope's standard covers three things only: the Stope language, STML, and the
// compiler's output (`Program`). It does NOT define a virtual machine, so the
// steps below have different stability guarantees:
//
//   step 1 (compile) : Lexer / Parser / Compiler / Program
//                      -> compiler API, relatively stable: `Program` has a
//                         documented encoding contract, so this part can be
//                         relied on (and copied) in host programs.
//   step 2-4 (run)   : BasicVM::* from <stope/basic_vm.hpp>
//                      -> the BUILT-IN BASIC VM: maintained (bugs get fixed,
//                         it is kept in sync with `Program`, and its semantics
//                         are aligned across the five implementations) and its
//                         interface is not changed casually -- but it is NOT
//                         part of the standard. Value representation, stack
//                         layout, host function binding and error reporting
//                         are this implementation's own choices, so another
//                         executor may not look like this at all.
//                         See docs/zh-cn/vm-guide.md.
//
// In other words: keep step 1; step 2-4 is one way to run the `Program`
// produced above, and it is safe to rely on within its documented limits.

#ifdef _WIN32
#include <Windows.h>
#endif
#include <iostream>
#include <span>
#include <string>

#include <stope/basic_vm.hpp>
#include <stope/core.hpp>
#include <stope/debug.hpp>
#include <stope/utf.hpp>

using namespace std;
using namespace Stope;

struct MyArgs : BasicVM::Arguments {  // used in step 4 (example API)
  std::vector<double> data;
  Result at(BasicVM::State& s,
            const BasicVM::Value& indexOrKey,
            BasicVM::Value& out) override {
    if (indexOrKey.type != BasicVM::Value::Type::Integer) {
      s.Error("index must be an integer");
      return Result::Error;
    }
    out.type = BasicVM::Value::Type::Float;
    out.data.floating = data[indexOrKey.data.integer];
    return Result::Success;
  }
  std::int64_t num() override { return data.size(); }
};

int main() {
#ifdef _WIN32
  SetConsoleOutputCP(CP_UTF8);
#endif

  // step 1: compile the source
  //
  // Stability: compiler API -- relatively stable. `Program` has a documented
  // encoding contract (opcode numbering, operands, jump targets are indices
  // into `program.opcodes`), so a host may rely on this part.
  u16string src =
      uR"(
    // example: sum all arguments

    let result = 0.0;
    let i = 0;
    while i < argc {
      result = result + args[i];
      i = i + 1;
    }

    fmt:println("结果为: ", result);
    return result;
  )";
  Lexer lexer(src);
  Parser parser(lexer);
  AST::Prog tree;
  parser.ParseProgram(tree);
  Compiler compiler;  // 构造参：CustomOpcodeConfig*，默认 nullptr
  Program program;
  compiler.Compile(tree, program);  // 输入、输出都传引用
  cout << DisasmNoCustom(program) << endl;

  // step 2: initialize the VM
  //
  // Stability: BUILT-IN EXAMPLE -- everything from step 2 to step 4 uses
  // BasicVM (include/stope/basic_vm.hpp), which is NOT part of the Stope
  // standard. Another executor may represent values, lay out the stack, bind
  // host functions and report errors in a completely different way; only the
  // language semantics have to match.
  BasicVM::Allocator alloc;
  BasicVM::ProgramConstants constants(alloc, program);
  BasicVM::API api;
  auto hostPrintln = [](BasicVM::State& state,
                        std::span<const BasicVM::Value> args,
                        BasicVM::Value& output) -> void {
    cout << "[Host] ";
    for (auto& arg : args) {
      if (arg.type == BasicVM::Value::Type::Float) {
        cout << arg.data.floating;
      } else if (arg.type == BasicVM::Value::Type::String) {
        u16string& u16s = state.alloc->GetString(arg.data.handle);
        cout << UTF::Utf16ToUtf8(u16s);
      }
    }
    cout << endl;
  };

  // step 3: create a state (BasicVM example API)
  BasicVM::State state;
  state.SetAPI(api);
  state.SetAllocator(alloc);
  state.SetProgramConstants(constants);
  state.SetProgram(program);
  state.variables.resize(program.variableNum);
  auto& v_fmtPrintln = state.variables[program.exports[u"fmt:println"]];
  v_fmtPrintln.type = BasicVM::Value::Type::HostFunction;
  v_fmtPrintln.data.hostFuncPtr = hostPrintln;

  // step 4: run the program (BasicVM example API)
  MyArgs args;
  args.data = {1.0, 2.0, 3.0, 4.0, 5.0};
  state.SetArguments(args);
  state.Run();
  cout << "result: " << state.returns[0].data.floating << endl;

  return 0;
}
