#ifdef _WIN32
#include <Windows.h>
#endif
#include <iostream>
#include <map>
#include <string>
#include <vector>

#include <stope/basic_vm.hpp>
#include <stope/compiler.hpp>
#include <stope/lexer.hpp>
#include <stope/parser.hpp>
#include <stope/stml_lexer.hpp>
#include <stope/stml_parser.hpp>
#include <stope/utf.hpp>

#include "05-object/Runtime.hpp"
#include "05-object/DocVisitor.hpp"

using namespace std;
using namespace Stope;

// ==================== STML 文档：类定义与主程序 ====================
static u16string doc =
    uR"(
<stml>

<class name="Person">
  <property name="name" />
  <property name="age" />
  <method name="Greet">
    println("i am ", self:name, ", ", self:age, " years old.");
  </method>
  <method name="Age">
    return self:age;
  </method>
  <method name="Introduce">
    // self:<方法名>() 调用同对象的另一个方法，无需 [对象]：self 绑定
    println("-- introducing --");
    self:Greet();
    println("age via self:Age() = ", self:Age());
  </method>
  <new name="New" params="name age">
    self:name = name;
    self:age = age;
  </new>
  <delete>
    // 析构函数，可以用来清理宿主的非托管资源等
    println("[Person] deleted!");
  </delete>
</class>

<func name="main">
  let p = Person:New("Tom", 18);
  obj:name[p] = "James";
  obj:Introduce[p]();
  obj:delete(p);
</func>

</stml>
)";

int main() {
#ifdef _WIN32
  SetConsoleOutputCP(CP_UTF8);
#endif

  auto hostPrintln = [](BasicVM::State& state,
                        std::span<const BasicVM::Value> args,
                        BasicVM::Value& output) -> void {
    for (auto& arg : args) {
      if (arg.type == BasicVM::Value::Type::Integer) {
        cout << arg.data.integer;
      } else if (arg.type == BasicVM::Value::Type::Float) {
        cout << arg.data.floating;
      } else if (arg.type == BasicVM::Value::Type::String) {
        u16string& u16s = state.alloc->GetString(arg.data.handle);
        cout << Stope::UTF::Utf16ToUtf8(u16s);
      }
    }
    cout << endl;
  };

  Runtime runtime;
  runtime.AddHostFunction(u"println", hostPrintln);

  // ---------- 1. STML 解析：代码段标签按 Stope 代码扫 ----------
  STML::Element root;
  STML::Lexer lexer(doc);
  STML::Parser parser(lexer);
  auto stateFunc =
      [](std::u16string_view tag,
         map<u16string_view, u16string_view> attrs) -> STML::LexerState {
    if (tag == u"method" || tag == u"new" || tag == u"delete" ||
        tag == u"func") {
      return STML::LexerState::Stope;
    }
    return STML::LexerState::Xml;
  };
  if (parser.Parse(root, stateFunc) != Result::Success) {
    for (auto& err : parser.errors) {
      cout << err << "\n";
    }
    return 1;
  }

  // ---------- 2. 访问文档：构建类、编译函数 ----------
  DocVisitor visitor;
  try {
    visitor.VisitDoc(root, runtime);
  } catch (const exception& e) {
    cout << e.what() << "\n";
    return 1;
  }
  Function* mainFunc = runtime.FindFunction(u"main");
  if (mainFunc == nullptr) {
    cout << "no main function\n";
    return 1;
  }

  // ---------- 3. 装配入口帧：绑定归 Runtime::PushEntryFrame ----------
  runtime.objMgr.maxObjects = 4096;  // 存活对象上限（忘了 obj:delete 顶到
                                     // 上限时构造器直接报错）；0 = 不限
  runtime.PushEntryFrame(*mainFunc);

  // ---------- 4. 运行：两种驱动，随时可切 + 清理诊断 ----------
  // 限步：RunSteps(20) 每帧最多 20 条指令，帧间就是宿主的逻辑帧；方法调用
  //   压帧、返回弹帧，预算跨调用共享——main 与方法体的每条指令都在循环里
  //   跑完，没有一步是「隐式连跑」的。单步调试就把 20 改成 1。
  // 直接：RunAll() 一口气跑到帧栈清空。两者随时可切：demo 先限步 1 帧，
  //   再直接执行跑完剩下的。
  int slices = 0;
  while (slices < 1 && runtime.RunSteps(20)) {
    ++slices;
  }
  runtime.RunAll();
  cout << "-- " << slices << " stepped slice(s), 20 steps each, then RunAll --\n";
  runtime.objMgr.ReportLive();  // 忘了 obj:delete 的对象在这里现形
  return runtime.hadErrors ? 1 : 0;
}
