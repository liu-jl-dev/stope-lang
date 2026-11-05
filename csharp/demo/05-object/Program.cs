using System;
using System.Collections.Generic;

using Stope;
using Stope.Stml;

namespace Stope.Demo;

/// <summary>
/// Demo 05: 宿主侧的面向对象 —— 对应 <c>cpp/demo/05-object/</c>。
/// <para>
/// 多文件拆分与 C++ 参考实现同构：<see cref="Object"/>（对象模型）、
/// <see cref="ClassInfo"/>（类/方法/函数）、<see cref="ObjectManager"/>（obj:* 域
/// 行为）、<see cref="Runtime"/>（装配与调用）、<see cref="DocVisitor"/>（STML →
/// 类与函数）、本文件只留文档、装配与入口。设计推导见
/// <c>cpp/docs/object-oriented.md</c>，C# 侧差异见 <c>docs/object-oriented.md</c>。
/// </para>
/// <para>运行：<c>dotnet run --project csharp/demo/05-object</c></para>
/// </summary>
internal static class Demo05
{
    private const string Doc = """
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
""";

    private static int Main()
    {
        var runtime = new Runtime();
        runtime.AddHostFunction("println", HostPrintln);

        // ---------- 1. STML 解析：代码段标签按 Stope 代码扫 ----------
        var lexer = new Stml.Lexer(Doc);
        var stmlParser = new Stml.Parser(lexer);
        var root = new Stml.Element();
        if (stmlParser.Parse(root, StateFunc) != Result.Success)
        {
            foreach (var e in stmlParser.Errors) Console.WriteLine(e);
            return 1;
        }

        // ---------- 2. 访问文档：构建类、编译函数 ----------
        var visitor = new DocVisitor();
        FunctionInfo? mainFunc;
        try
        {
            visitor.VisitDoc(root, runtime);
            mainFunc = runtime.FindFunction("main");
        }
        catch (Exception ex)
        {
            Console.WriteLine(ex.Message);
            return 1;
        }
        if (mainFunc is null)
        {
            Console.WriteLine("no main function");
            return 1;
        }

        // ---------- 3. 装配主 State：绑定归 Runtime.BindEntry ----------
        var state = new State();
        state.SetApi(runtime.Api);
        state.SetProgram(mainFunc.Program);
        runtime.BindEntry(state, mainFunc);

        // ---------- 4. 运行 + 手动清理诊断 ----------
        if (state.Run() != Result.Success)
            foreach (var e in state.Errors) Console.WriteLine("  vm: " + e);
        runtime.ObjMgr.ReportLive(); // 忘了 obj:delete 的对象在这里现形
        return state.Errors.Count == 0 ? 0 : 1;
    }

    /// <summary>带 <c>stope</c> 属性的元素，内容按 Stope 代码扫；其余按子元素列表解析。</summary>
    private static Stml.Lexer.State StateFunc(string tag, Dictionary<string, string> _attrs) =>
        tag is "method" or "new" or "delete" or "func"
            ? Stml.Lexer.State.Stope
            : Stml.Lexer.State.Xml;

    /// <summary>宿主函数：与 C++ demo 一致——只格式化 Integer / Float / String，其余忽略。</summary>
    private static object? HostPrintln(object?[] args)
    {
        var sb = new System.Text.StringBuilder();
        foreach (var a in args)
        {
            if (a is long l) sb.Append(l);
            else if (a is double d) sb.Append(FormatFloat(d));
            else if (a is string str) sb.Append(str);
        }
        Console.WriteLine(sb.ToString());
        return null;
    }

    /// <summary>浮点按 C++ iostream 默认精度（6 位有效数字）的样子打。</summary>
    private static string FormatFloat(double v) =>
        v == Math.Floor(v) && Math.Abs(v) < 1e15 ? ((long)v).ToString() : v.ToString("G6");
}
