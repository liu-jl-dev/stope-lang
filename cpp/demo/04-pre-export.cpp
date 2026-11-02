// Demo 04: 预导出（preExports）—— 宿主先把形参塞进作用域，再编译函数体。
//
// 场景：STML 文档里定义函数，参数表写在标签属性上（params="a b"），函数体是
// Stope 源码。编译函数体时把 params 里的名字当 preExports 传进去，它们就先占好
// 槽位、进 Program.exports；宿主在 Run 之前把实参写进这些槽位，函数体里的 a、b
// 直接就能读到。
//
// 为什么不靠「未声明标识符自动导出」？—— 那条路也行，但导出的是**函数体里用到
// 的名字**，顺序取决于出现位置、没用到的形参根本不会存在。预导出让「参数表」
// 只有一份、且顺序固定为标签里写的顺序，宿主可以照参数表直接写槽位。

#ifdef _WIN32
#include <Windows.h>
#endif
#include <cstdint>
#include <iostream>
#include <map>
#include <string>
#include <string_view>
#include <vector>

#include <stope/basic_vm.hpp>
#include <stope/core.hpp>
#include <stope/debug.hpp>
#include <stope/utf.hpp>

using namespace std;
using namespace Stope;

u16string DOC = uR"(
<stml>
<func name="add" params="a b" stope>
    return a + b;
</func>
</stml>
)";

// 按名字找子元素。
static const STML::Element* childByTag(const STML::Element& ele,
                                       u16string_view tag) {
  for (auto& c : ele.children) {
    if (c.tagName == tag) {
      return &c;
    }
  }
  return nullptr;
}

// "a b" -> {"a", "b"}。参数表是空白分隔的，多个空格不算一个空名字。
static vector<u16string> splitParams(std::u16string_view s) {
  vector<u16string> out;
  u16string cur;
  for (char16_t c : s) {
    if (c == u' ' || c == u'\t' || c == u'\n' || c == u'\r') {
      if (!cur.empty()) {
        out.push_back(cur);
        cur.clear();
      }
    } else {
      cur += c;
    }
  }
  if (!cur.empty()) {
    out.push_back(cur);
  }
  return out;
}

// 编译一段 Stope 源码，preExports 原样交给 Compiler。失败时打印错误并返回 false。
static bool compileAndReport(std::u16string_view src,
                             const vector<u16string>& preExports,
                             Program& out) {
  Lexer lexer(src);  // 借用 src，src 要活到编译结束
  Parser parser(lexer);
  AST::Prog tree;
  parser.ParseProgram(tree);
  for (const auto& e : parser.errors) {
    cout << "  parser: " << e << "\n";
  }

  Compiler compiler;
  Result r = compiler.Compile(tree, out, preExports);
  for (const auto& e : compiler.errors) {
    cout << "  compiler: " << e << "\n";
  }
  return r == Result::Success && parser.errors.empty();
}

int main() {
#ifdef _WIN32
  SetConsoleOutputCP(CP_UTF8);
#endif

  // ---------- 1. 从 STML 里取出函数定义 ----------
  //
  // 带 stope 属性的元素，内容按 Stope 代码扫；切出来的 text 就是原样源码。
  STML::Element root;
  STML::Lexer lexer(DOC);
  STML::Parser parser(lexer);
  auto stateFunc = [](std::u16string_view,
                      std::map<std::u16string_view, std::u16string_view> attrs)
      -> STML::LexerState {
    return attrs.find(u"stope") != attrs.end() ? STML::LexerState::Stope
                                               : STML::LexerState::Xml;
  };
  if (parser.Parse(root, stateFunc) != Result::Success) {
    for (auto& err : parser.errors) {
      cout << err << "\n";
    }
    return 1;
  }

  const STML::Element* fn = childByTag(root, u"func");
  if (fn == nullptr) {
    cout << "找不到 <func>\n";
    return 1;
  }
  // attrs / text 都是**视图**：指向 DOC（词法器持有它），所以 DOC 必须活到最后。
  std::u16string_view name = fn->attrs.at(u"name");
  vector<u16string> params = splitParams(fn->attrs.at(u"params"));

  cout << "[1] 从 <func> 取出：" << UTF::Utf16ToUtf8(name) << "(";
  for (size_t i = 0; i < params.size(); ++i) {
    cout << (i ? ", " : "") << UTF::Utf16ToUtf8(params[i]);
  }
  cout << ")\n";

  // ---------- 2. 用参数表当 preExports 编译 ----------
  //
  // 形参先占槽位（a=0、b=1），函数体里的 a、b 于是解析到文件作用域 ——
  // 反汇编里是 PushValue(0) / PushValue(1)。
  Program program;
  cout << "\n[2] 编译函数体（preExports = 形参表）：\n";
  if (!compileAndReport(fn->text, params, program)) {
    return 1;
  }
  cout << DisasmNoCustom(program);
  cout << "  exports:";
  for (const auto& kv : program.exports) {
    cout << " " << UTF::Utf16ToUtf8(kv.first) << "=" << kv.second;
  }
  cout << "\n";

  // ---------- 3. 塞实参、运行 ----------
  //
  // 编译期就知道槽位，所以 Run 之前就能把值写进去 —— 这才是预导出的用处：
  // 宿主的「调用」就是写变量 + 跑一遍，不需要额外的参数传递机制。
  BasicVM::Allocator alloc;
  BasicVM::ProgramConstants constants(alloc, program);
  BasicVM::API api;
  BasicVM::State state;
  state.SetAPI(api);
  state.SetAllocator(alloc);
  state.SetProgramConstants(constants);
  state.SetProgram(program);
  state.variables.resize(program.variableNum);

  auto setInt = [&](const u16string& ident, int64_t v) {
    auto& slot = state.variables[program.exports.at(ident)];
    slot.type = BasicVM::Value::Type::Integer;
    slot.data.integer = v;
  };
  setInt(u"a", 3);
  setInt(u"b", 4);

  state.Run();
  cout << "\n[3] add(3, 4) = " << state.returns[0].data.integer << "\n";

  // ---------- 4. 陷阱：预导出的名字不能再声明 ----------
  //
  // 名字已经进了文件作用域，源码里再 export 同名、或顶层 let 同名，都是 duplicate。
  // 预导出的变量只能赋值（a = 1;），不能重新声明。
  cout << "\n[4] 函数体里又写 export a;：\n";
  u16string bad = u"export a; return a;";
  Program badProgram;
  compileAndReport(bad, params, badProgram);

  return 0;
}
