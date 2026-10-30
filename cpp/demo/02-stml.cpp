#ifdef _WIN32
#include <Windows.h>
#endif
#include <iostream>
#include <map>
#include <string>
#include <string_view>

#include <stope/core.hpp>
#include <stope/utf.hpp>

using namespace std;
using namespace Stope;

// 按名字找子元素，别写死下标 —— 下标会随空行 / 注释变。
static const STML::Element* childByTag(const STML::Element& ele,
                                       u16string_view tag) {
  for (auto& c : ele.children) {
    if (c.tagName == tag) {
      return &c;
    }
  }
  return nullptr;
}

int main() {
#ifdef _WIN32
  SetConsoleOutputCP(CP_UTF8);
#endif

  u16string doc =
      uR"(
<stml package="MyPkg">

<config>
  windowTitle "demo";
  windowSize 1280, 720
</config>
<func name="myFunc" stope>
  let a = 1;
  return a + argc;
</func>
<class name="Person">
  <property name="name" />
  <property name="age" />
  <method name="greet" />
</class>

</stml>
)";

  STML::Element root;
  STML::Lexer lexer(doc);
  STML::Parser parser(lexer);
  // 宿主回调：读完开始标签、还没进内容时调用一次，返回值决定这段内容怎么扫。
  //   <config>            -> Nevext 代码
  //   带 stope 属性的元素  -> Stope 代码
  //   其余                -> Xml（按子元素列表解析）
  auto lexerStateFunc =
      [](std::u16string_view tag,
         std::map<std::u16string_view, std::u16string_view> attrs)
      -> STML::LexerState {
    if (tag == u"config") {
      return STML::LexerState::Nevext;
    }
    if (attrs.find(u"stope") != attrs.end()) {
      return STML::LexerState::Stope;
    }
    return STML::LexerState::Xml;
  };
  if (parser.Parse(root, lexerStateFunc) != Result::Success) {
    for (auto& err : parser.errors) {
      cout << err << endl;
    }
    return 1;
  }

  cout << "[1] 根元素 <" << UTF::Utf16ToUtf8(root.tagName)
       << ">，属性 package=\"" << UTF::Utf16ToUtf8(root.attrs.at(u"package"))
       << "\"" << endl;

  cout << "[2] 它的直接子元素：" << endl;
  for (auto& c : root.children) {
    cout << "  " << UTF::Utf16ToUtf8(c.tagName) << endl;
  }

  cout << "[3] <class> 的子元素：" << endl;
  if (const auto* cls = childByTag(root, u"class")) {
    for (auto& c : cls->children) {
      cout << "  " << UTF::Utf16ToUtf8(c.tagName)
           << (c.selfClosing ? "(自闭合)" : "") << endl;
    }
  }

  // 代码段原样切出来：换行是真的换行，缩进也保留（尾部空白已被词法裁掉）。
  // 拿到它交给 Lexer 就能编译执行（见 01-quick-start.cpp）—— STML 不管代码写得对不对。
  cout << "[4] <func> 里的 Stope 代码段：" << endl;
  if (const auto* fn = childByTag(root, u"func")) {
    cout << UTF::Utf16ToUtf8(fn->text) << endl;
  }

  return 0;
}
