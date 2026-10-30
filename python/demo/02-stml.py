"""Demo 02: STML —— 解析一份内嵌的标记文档，把里面的代码段原样切出来。

对应 cpp/demo/02-stml.cpp、gdscript/demo/demo_02.gd、nodejs/demo/02-stml.js：
**只解析**，不编译也不执行 —— 接过 text 之后干什么完全是宿主的事。

运行：python demo/02-stml.py

STML 是「两半」：树的形状由 stml_parser 管（标签名、属性、嵌套、结束标签是否配对），
内容怎么切由宿主管 —— 就是传给 ``parse()`` 的那个 state_func 回调，它决定
「这个标签的内容是子元素 / 纯文本 / Nevext 代码 / Stope 代码」。
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from stope.lexer import Lexer                       # noqa: E402  Stope 的词法器
from stope.stml import Element, LexerState          # noqa: E402
from stope.stml_lexer import Lexer as StmlLexer     # noqa: E402
from stope.stml_parser import Parser as StmlParser  # noqa: E402
from stope.token import TokenType                   # noqa: E402

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")

doc = """
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
"""


def state_func(tag, attrs):
    """宿主回调：与 C++ demo 的 lexerStateFunc 一一对应。

    ``<config>`` → Nevext 代码；带 ``stope`` 属性的元素 → Stope 代码；
    其余 → Xml（按子元素列表解析）。
    """
    if tag == "config":
        return LexerState.Nevext
    if "stope" in attrs:
        return LexerState.Stope
    return LexerState.Xml


def child_by_tag(ele, tag):
    """按名字找，别像 C++ demo 那样写死下标 —— 下标会随空行 / 注释变。"""
    for c in ele.children:
        if c.tag == tag:
            return c
    return None


def main() -> int:
    lexer = StmlLexer(doc)
    parser = StmlParser(lexer)
    root = Element()
    result = parser.parse(root, state_func)
    for e in lexer.errors:
        print("[lex] " + e, file=sys.stderr)
    for e in parser.errors:
        print("[parse] " + e, file=sys.stderr)

    print(f'[1] 根元素 <{root.tag}>，属性 package="{root.attrs.get("package")}"')
    print("[2] 它的直接子元素：")
    for c in root.children:
        print("  " + c.tag)

    func_ele = child_by_tag(root, "func")
    class_ele = child_by_tag(root, "class")
    print("[3] <class> 的子元素：")
    for c in class_ele.children:
        print("  " + c.tag + ("(自闭合)" if c.self_closing else ""))

    # 代码段原样切出来：换行是真的换行，缩进也保留（尾部空白已被词法裁掉）。
    print("[4] <func> 里的 Stope 代码段：")
    print(func_ele.text)

    # 想执行它就把 text 交给 Lexer（见 01-quick-start.py）。这里只演示「切得出来」。
    print("[5] 同一段代码，交给 Stope 词法器扫一遍 token 数：")
    stope_lexer = Lexer(func_ele.text)
    n = 0
    while True:
        t = stope_lexer.next_token()
        if t.type == TokenType.Eof:
            break
        n += 1
    print("  " + str(n) + " 个 token")

    # 标签里写 Parse() 是为了与另外四份实现的输出逐字节相同（本实现的方法叫 parse）。
    print("[6] Parse() 的返回值：" + ("Success" if result == 0 else "Error"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
