using System;
using System.Collections.Generic;
using System.Text;

using Stope;
using Stope.Stml;

namespace Stope.Demo;

/// <summary>
/// Demo 02: STML —— 解析一份内嵌的标记文档，把里面的代码段原样切出来。
/// <para>
/// 对应 <c>cpp/demo/02-stml.cpp</c> 与 <c>gdscript/demo/demo_02.gd</c>：<b>只解析</b>，
/// 不编译也不执行 —— 接过 <c>Text</c> 之后干什么完全是宿主的事。
/// </para>
/// <para>
/// 运行：<c>dotnet run --project csharp/demo/02-stml</c>
/// </para>
/// <para>
/// STML 是「两半」：树的形状由 <see cref="Parser"/> 管（标签名、属性、嵌套、结束标签是否
/// 配对），内容怎么切由宿主管 —— 就是传给 <c>Parse()</c> 的那个 <c>stateFunc</c> 回调，
/// 它决定「这个标签的内容是子元素 / 纯文本 / Nevext 代码 / Stope 代码」。
/// </para>
/// </summary>
internal static class Demo02
{
    private const string Doc = """
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
""";

    /// <summary>
    /// 宿主回调：与 C++ demo 的 <c>lexerStateFunc</c> 一一对应。
    /// <c>&lt;config&gt;</c> → Nevext 代码；带 <c>stope</c> 属性的元素 → Stope 代码；
    /// 其余 → Xml（按子元素列表解析）。
    /// </summary>
    private static Stml.Lexer.State StateFunc(string tag, Dictionary<string, string> attrs)
    {
        if (tag == "config") return Stml.Lexer.State.Nevext;
        if (attrs.ContainsKey("stope")) return Stml.Lexer.State.Stope;
        return Stml.Lexer.State.Xml;
    }

    /// <summary>按名字找，别像 C++ demo 那样写死下标 —— 下标会随空行 / 注释变。</summary>
    private static Stml.Element? ChildByTag(Stml.Element ele, string tag)
    {
        foreach (var c in ele.Children)
            if (c.Tag == tag)
                return c;
        return null;
    }

    private static int Main()
    {
        Console.OutputEncoding = Encoding.UTF8;

        // ⚠ `Lexer` / `Parser` / `Element` 两个命名空间下都有：STML 的要写全名 `Stml.Xxx`
        // （`using Stope.Stml;` 与 `using Stope;` 同时在场时，裸名优先解析成 Stope 的）。
        var lexer = new Stml.Lexer(Doc);
        var parser = new Stml.Parser(lexer);
        var root = new Stml.Element();
        if (parser.Parse(root, StateFunc) != Result.Success)
        {
            foreach (var e in lexer.Errors) Console.Error.WriteLine("[lex] " + e);
            foreach (var e in parser.Errors) Console.Error.WriteLine("[parse] " + e);
            return 1;
        }

        Console.WriteLine($"[1] 根元素 <{root.Tag}>，属性 package=\"{root.Attrs.GetValueOrDefault("package", "")}\"");
        Console.WriteLine("[2] 它的直接子元素：");
        foreach (var c in root.Children) Console.WriteLine("  " + c.Tag);

        var funcEle = ChildByTag(root, "func");
        var classEle = ChildByTag(root, "class");
        Console.WriteLine("[3] <class> 的子元素：");
        if (classEle is not null)
        {
            foreach (var c in classEle.Children)
                Console.WriteLine("  " + c.Tag + (c.SelfClosing ? "(自闭合)" : ""));
        }

        // 代码段原样切出来：换行是真的换行，缩进也保留（尾部空白已被词法裁掉）。
        // 拿到它交给 Lexer 就能编译执行（见 01-quick-start）—— STML 不管代码写得对不对。
        Console.WriteLine("[4] <func> 里的 Stope 代码段：");
        Console.WriteLine(funcEle?.Text ?? "");
        return 0;
    }
}
