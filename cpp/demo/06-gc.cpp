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

#include "06-gc/Runtime.hpp"
#include "06-gc/DocVisitor.hpp"

using namespace std;
using namespace Stope;

// ==================== STML 文档：类定义与主程序 ====================
static u16string doc =
    uR"(
<stml>

<class name="Person">
  <property name="name" />
  <property name="age" />
  <property name="friend" />
  <property name="partner" />
  <method name="Greet">
    println("i am ", self:name, ", ", self:age, " years old.");
  </method>
  <method name="Age">
    return self:age;
  </method>
  <method name="Introduce">
    println("-- introducing --");
    self:Greet();
    println("age via self:Age() = ", self:Age());
  </method>
  <method name="BlockGuard">
    // 块内 let 的 guard 对象：块退出不产生任何指令——槽位归还编译器的
    // 复用池，但值还在 variables 里，gc 根扫描每次都扫得到。
    {
      let f = Person:New("block-guard", 1);
    }
    println("-- block exited: nothing freed, nothing printed --");
  </method>
  <method name="Pair">
    // 循环引用：a、b 互指，且只存在于本方法的变量里。方法一返回，两个
    // 变量槽位随栈帧销毁，引用计数停在 1 互相锁定——计数收不走，只能
    // 等标记清除裁决。
    let a = Person:New("cycle.a", 1);
    let b = Person:New("cycle.b", 2);
    obj:partner[a] = b;
    obj:partner[b] = a;
  </method>
  <new name="New" params="name age">
    self:name = name;
    self:age = age;
  </new>
  <delete>
    // 析构函数：gc 回收对象前自动跑，可以打遗言、清理宿主的非托管资源。
    println("[Person] deleted: ", self:name);
  </delete>
</class>

<func name="main">
  let p = Person:New("James", 18);
  obj:Introduce[p]();

  // 1) 引用计数级联：孩子只挂在字段上，覆盖成 null 旧值计数归零，
  //    立即析构（安全点刚同步过根，VM 侧再无 Handle，即时释放是可靠的）。
  obj:friend[p] = Person:New("Jimmy", 1);
  println("-- expect [Person] deleted: Jimmy right above --");
  obj:friend[p] = null;

  // 2) 循环引用：引用计数收不走，脚本侧也没有 gc 函数可调——裁决时机在
  //    宿主手里：驱动循环的帧边界 Collect（见 main），游戏里就是
  //    「每 N 帧收集一次」。
  obj:Pair[p]();
  println("-- expect nothing above: the pair is locked in a cycle --");
  println("-- expect two [Person] deleted above at a frame-boundary collect --");

  // 3) 垃圾 churn：丢弃结果的对象走引用计数路径，在下个安全点被逐个收走；
  //    一路积累的一次性描述符（self 绑定等）由帧边界的标记清除成批收走。
  let i = 0;
  while i < 100 {
    Person:New("garbage", i);
    i = i + 1;
  }
  println("-- expect batches of deleted above: safe-point refcount + frame-boundary sweep --");
</func>

</stml>
)";

// HostFunction 是裸函数指针、没有 user-data 参数；需要触达 runtime 的宿主
// 函数只能经文件级静态指针桥接。demo 6 现在没有这样的函数了——gc 的裁决
// 时机在宿主的帧循环里，脚本侧无感（println 只读参数）。

int main() {
#ifdef _WIN32
  SetConsoleOutputCP(CP_UTF8);
#endif

  Runtime runtime;
  runtime.AddHostFunction(
      u"println",
      [](BasicVM::State& state, std::span<const BasicVM::Value> args,
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
      });
  // 注意没有 gc:Collect：宿主本来就能直接调 Collect()，注册成 VM 宿主函数
  // 只是让脚本能「主动要求 gc」——去掉之后桥接通道（静态指针）也跟着删，
  // gc 时机完全归帧循环（下方的 slices % 25 == 0）。

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
  runtime.objMgr.alloc.maxNodes = 4096;  // gc 节点上限（对象 + 描述符都算），
                                         // 顶到上限先 Collect 仍不够则开口报
                                         // too many gc nodes.；0 = 不限
  runtime.PushEntryFrame(*mainFunc);

  // ---------- 4. 运行：两种驱动，随时可切 + 帧边界 collect ----------
  // 限步：RunSteps(20) 每帧最多 20 条指令，帧间就是宿主的逻辑帧；每 25 帧
  //   做一次标记清除——gc 时机完全由这个循环决定，脚本侧无感。单步调试
  //   就把 20 改成 1。
  // 直接：RunAll() 一口气跑到帧栈清空——没有帧边界，gc 的裁决点只剩
  //   maxNodes 顶满与收尾那次 Collect。demo 先限步 25 帧（第一轮帧边界
  //   Collect 在这里触发，循环引用被破环），再直接执行跑完剩下的。
  int slices = 0;
  while (slices < 25 && runtime.RunSteps(20)) {
    ++slices;
    if (slices % 25 == 0) {
      runtime.objMgr.alloc.Collect();
      cout << "[gc] frame slice " << slices << ": collect freed "
           << runtime.objMgr.alloc.lastFreed << "\n";
    }
  }
  runtime.RunAll();
  cout << "-- " << slices << " stepped slice(s), 20 steps each, then RunAll --\n";
  runtime.objMgr.alloc.Collect();  // 入口帧弹出后 p 不可达：最后一次收集
  runtime.objMgr.ReportLive();     // 帧栈已空，根集合随最后一步同步清零
  return runtime.hadErrors ? 1 : 0;
}
