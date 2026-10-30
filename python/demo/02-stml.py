"""Demo 02：STML —— 解析一份标记文档，把里面的代码段原样切出来。

STML 是「两半」：树的形状（标签、属性、嵌套、结束标签是否配对）由 ``StmlParser`` 管；
「某个元素的内容怎么切」由宿主的回调决定 —— 是子元素、纯文本，还是一段代码。

只解析，不编译也不执行：拿到 text 之后干什么完全是宿主的事。

运行：python demo/02-stml.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from stope import Result, StmlElement, StmlLexer, StmlParser, StmlState  # noqa: E402

sys.stdout.reconfigure(encoding="utf-8")

DOC = """
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


def content_kind(tag, attrs):
    """宿主回调：读完开始标签、还没进内容时调用一次，返回值决定这段内容怎么扫。"""
    if tag == "config":
        return StmlState.Nevext  # 一段 Nevext 代码，整段原样保留
    if "stope" in attrs:
        return StmlState.Stope  # 一段 Stope 代码
    return StmlState.Xml  # 默认：内容是子元素列表


def child(ele, tag):
    """按名字找子元素 —— 别写死下标，空行和注释都会让它变。"""
    return next((c for c in ele.children if c.tag == tag), None)


def main():
    lexer = StmlLexer(DOC)
    parser = StmlParser(lexer)
    root = StmlElement()
    if parser.parse(root, content_kind) != Result.Success:
        raise SystemExit("\n".join(lexer.errors + parser.errors))

    print(f'[1] 根元素 <{root.tag}>，属性 package="{root.attrs["package"]}"')
    print("[2] 它的直接子元素：")
    for c in root.children:
        print("  " + c.tag)

    print("[3] <class> 的子元素：")
    for c in child(root, "class").children:
        print("  " + c.tag + ("(自闭合)" if c.self_closing else ""))

    # 代码段是原样的一整段 str：换行是真的换行、缩进保留（只有尾部空白被词法裁掉）。
    # 拿到它交给 stope.Lexer 就能编译执行（见 01-quick-start.py）—— STML 不管代码写得对不对。
    print("[4] <func> 里的 Stope 代码段：")
    print(child(root, "func").text)


if __name__ == "__main__":
    main()
