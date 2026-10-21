#ifdef _WIN32
#include <Windows.h>
#endif
#include <iostream>
#include <map>
#include <string>
#include <string_view>
#include <vector>

#include <stope/core.hpp>
#include <stope/utf.hpp>

using namespace std;
using namespace Stope;

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
  parser.Parse(root, lexerStateFunc);

  for (auto& err : parser.errors) {
    cout << err << endl;
  }

  for (auto& e : root.children) {
    cout << UTF::Utf16ToUtf8(e.tagName) << endl;
  }
  for (auto& e : root.children[2].children) {
    cout << UTF::Utf16ToUtf8(e.tagName) << endl;
  }
  cout << UTF::Utf16ToUtf8(root.children[1].text) << endl;

  return 0;
}
