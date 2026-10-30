// Demo 03: 自定义指令 —— 给编译器加几条自己的指令，只编译 + 反汇编，不运行。
//
// 项目只规定 32 条内置指令（include/stope/opcode.hpp）与 Program 的编码契约；
// 再往上加指令是宿主自己的事，三步：
//
//   1. 用 CustomOpcodeConfig 登记「名字 -> (编号, 参数个数)」；
//   2. 同一份 config 同时交给 Parser 和 Compiler：Parser 靠它把名字识别成
//      Custom token（查不到就只是普通标识符），Compiler 靠它查编号与参数个数；
//   3. 产物里就只是一串 short —— 编号什么含义、谁来执行，全由宿主决定。
//
// 本 demo 不运行程序：自定义指令在 BasicVM 里没有实现，也不该有 —— BasicVM
// 只是内置示例执行器，不是标准的一部分（见 01-quick-start.cpp 开头与
// docs/zh-cn/vm-guide.md）。自定义指令的意义正在于此：宿主自己定义、自己执行。
//
// 两条硬约束（见 docs/compiler-test-plan.md §4.4）：
//   * 编号必须 > Opcode::Return。opcodes 是 short 混排序列，撞号以后与内置指令
//     无法区分；Disasm() 会把这种注册报成 warning（[5] 演示）。
//   * 定长指令的 argNum 必须与实际调用一致，否则编译期报错、不产出（[4] 演示）。

#ifdef _WIN32
#include <Windows.h>
#endif
#include <algorithm>
#include <iostream>
#include <string>
#include <utility>
#include <vector>

#include <stope/core.hpp>
#include <stope/debug.hpp>
#include <stope/utf.hpp>

using namespace std;
using namespace Stope;

// 编译一份源码并打印错误。config 为 nullptr 时按「没有自定义指令」处理。
// 注意 Parser 收的是非 const 指针、Compiler 收的是 const 指针，所以这里取
// 非 const 版，两边都能传。
bool compileAndReport(const u16string& src,
                      CustomOpcodeConfig* config,
                      Program& out) {
  Lexer lexer(src);              // 借用 src，src 要活到解析结束
  Parser parser(lexer, config);  // 第二参：可空的 config，用指针
  AST::Prog tree;
  parser.ParseProgram(tree);
  for (const auto& e : parser.errors) {
    cout << "  parser: " << e << "\n";
  }

  Compiler compiler(config);  // 配置只在构造时注入一次
  Result r = compiler.Compile(tree, out);
  for (const auto& e : compiler.errors) {
    cout << "  compiler: " << e << "\n";
  }
  return r == Result::Success && parser.errors.empty();
}

int main() {
#ifdef _WIN32
  SetConsoleOutputCP(CP_UTF8);
#endif

  // ---------- 1. 登记自定义指令 ----------
  //
  // argNum >= 0 定长；argNum < 0（默认值 -1）变长，编译产物里会多写一个
  // 「本次调用的参数个数」。名字里的 ':' 是 lexer 支持的命名空间写法，用来
  // 避开宿主函数名。
  CustomOpcodeConfig config;
  u16string addName = u"my:add";
  u16string logName = u"my:log";
  u16string haltName = u"my:halt";
  cout << "[1] 登记自定义指令：\n";
  // 返回 Result：同名重复注册会拿到 DuplicateWithBuiltinOpcode。这里三条都新，
  // 不为返回值打断流程。
  config.addCustomOpcode(addName, kFirstCustomOpcode + 0, 2);
  config.addCustomOpcode(logName, kFirstCustomOpcode + 1, -1);
  config.addCustomOpcode(haltName, kFirstCustomOpcode + 2, 0);
  // 打印时按编号排序：config.opcodes 是 std::map，迭代顺序是名字字典序。
  vector<pair<short, u16string>> registered;
  for (const auto& kv : config.opcodes) {
    registered.emplace_back(kv.second.opcode, kv.first);
  }
  sort(registered.begin(), registered.end());
  for (const auto& item : registered) {
    const CustomOpcode& info = config.opcodes.at(item.second);
    cout << "  " << UTF::Utf16ToUtf8(item.second) << " -> #" << info.opcode;
    if (info.isVarArg) {
      cout << "（变长）";
    } else {
      cout << "（定长 " << info.argNum << " 参）";
    }
    cout << "\n";
  }

  // ---------- 2. 编译并反汇编 ----------
  //
  // 注意 my:add 的参数照常先压栈，指令本身不再带操作数；只有 my:log 这种变长
  // 指令后面多一个 short。反汇编要认出这些，必须把同一份 config 交给
  // Disasm()。
  u16string src =
      uR"(
    let x = 3;

    my:add(x, 4);        // 定长 2 参
    my:log("x =", x);    // 变长 2 参
    my:log();            // 变长 0 参
    my:halt();           // 定长 0 参

    return x;
  )";
  Program program;
  cout << "\n[2] 编译结果：\n";
  if (!compileAndReport(src, &config, program)) {
    return 1;
  }
  cout << Disasm(program, &config);

  // ---------- 3. 对照：名字没登记就只是普通调用 ----------
  //
  // lexer 只有在 config 里查得到名字时才吐 Custom token，否则 "my:add" 就是个
  // 普通标识符 —— 编译成 Call，即「调用一个名叫 my:add 的宿主函数」。
  u16string plainSrc = u"my:add(1, 2);";
  Program plain;
  cout << "\n[3] 同样的调用，不传 config：\n";
  if (compileAndReport(plainSrc, nullptr, plain)) {
    cout << DisasmNoCustom(plain);
  }

  // ---------- 4. 参数个数不符 ----------
  //
  // 定长指令的参数量在编译期校验；报错后 Compile() 会把 out 复原为空，免得
  // 一个半成品 Program 被当成能跑的东西。
  u16string badSrc = u"my:add(1);";
  Program bad;
  cout << "\n[4] 定长 2 参却只给 1 个：\n";
  if (!compileAndReport(badSrc, &config, bad)) {
    cout << "  -> 编译失败，Program 已清空（opcodes 剩 " << bad.opcodes.size()
         << " 个 short）\n";
  }

  // ---------- 5. 陷阱：编号撞到内置指令 ----------
  //
  // 自定义编号必须 > Opcode::Return。这里故意用一个内置编号注册：编译器写出
  // 的仍是同一个 short，谁也分不清它到底是 Add 还是 my:steal ——
  // Disasm() 只能按内置指令解码，并把它报成 warning。
  CustomOpcodeConfig collide;
  u16string stealName = u"my:steal";
  collide.addCustomOpcode(stealName, static_cast<short>(Opcode::Add), 2);
  u16string stealSrc = u"my:steal(1, 2);";
  Program stolen;
  cout << "\n[5] 用内置 Add 的编号注册 my:steal：\n";
  if (compileAndReport(stealSrc, &collide, stolen)) {
    cout << Disasm(stolen, &collide);
  }

  return 0;
}
