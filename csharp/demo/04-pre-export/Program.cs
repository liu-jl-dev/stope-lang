using System;
using System.Collections.Generic;
using System.Text;

using Stope;
using Stope.Stml;

namespace Stope.Demo;

/// <summary>
/// Demo 04: 预导出（<c>preExports</c>）—— 宿主先把形参塞进作用域，再编译函数体。
/// <para>对应 <c>cpp/demo/04-pre-export.cpp</c>。</para>
/// <para>
/// 场景：STML 文档里定义函数，参数表写在标签属性上（<c>params="a b"</c>），函数体是
/// Stope 源码。编译函数体时把 params 里的名字当 preExports 传进去，它们就先占好槽位、
/// 进 <c>Program.Exports</c>；宿主在 <c>Run()</c> 之前把实参写进这些槽位，函数体里的
/// a、b 直接就能读到。
/// </para>
/// <para>
/// 为什么不靠「未声明标识符自动导出」？那条路也行，但导出的是<b>函数体里用到的名字</b>，
/// 顺序取决于出现位置、没用到的形参根本不会存在。预导出让「参数表」只有一份、且顺序
/// 固定为标签里写的顺序，宿主可以照参数表直接写槽位。
/// </para>
/// <para>运行：<c>dotnet run --project csharp/demo/04-pre-export</c></para>
/// </summary>
internal static class Demo04
{
    private const string Doc = """
<stml>
<func name="add" params="a b" stope>
    return a + b;
</func>
</stml>
""";

    /// <summary>带 <c>stope</c> 属性的元素，内容按 Stope 代码扫；其余按子元素列表解析。</summary>
    private static Stml.Lexer.State StateFunc(string tag, Dictionary<string, string> attrs)
    {
        _ = tag;
        return attrs.ContainsKey("stope") ? Stml.Lexer.State.Stope : Stml.Lexer.State.Xml;
    }

    /// <summary>按名字找子元素。</summary>
    private static Stml.Element? ChildByTag(Stml.Element ele, string tag)
    {
        foreach (var c in ele.Children)
            if (c.Tag == tag)
                return c;
        return null;
    }

    /// <summary>
    /// 编译一份源码，preExports 原样交给 Compile。失败时打印错误并返回 false。
    /// startLine 是 src 首行的物理行号 —— 从 STML 切出来的代码段不是从 1 开始，设给
    /// Lexer 之后报错行号才和文档对得上（这里直接从 fn.TextLine 取）。
    /// </summary>
    private static bool CompileAndReport(
        string src, int startLine, IReadOnlyList<string> preExports, Program outProg)
    {
        var lexer = new Lexer(src);
        lexer.Line = startLine;
        var parser = new Parser(lexer);
        var tree = new Prog();
        parser.ParseProgram(tree);
        foreach (var e in lexer.Errors) Console.WriteLine("  lexer: " + e);
        foreach (var e in parser.Errors) Console.WriteLine("  parser: " + e);

        var compiler = new Compiler();
        var rc = compiler.Compile(tree, outProg, preExports);
        foreach (var e in compiler.Errors) Console.WriteLine("  compiler: " + e);
        return rc == Result.Success && lexer.Errors.Count == 0 && parser.Errors.Count == 0;
    }

    private static int Main()
    {
        Console.OutputEncoding = Encoding.UTF8;

        // ---------------- 1. 从 STML 里取出函数定义 ----------------
        // ⚠ Lexer / Parser / Element 两个命名空间下都有，STML 的要写全名 Stml.Xxx。
        var lexer = new Stml.Lexer(Doc);
        var parser = new Stml.Parser(lexer);
        var root = new Stml.Element();
        if (parser.Parse(root, StateFunc) != Result.Success)
        {
            foreach (var e in lexer.Errors) Console.Error.WriteLine("[lex] " + e);
            foreach (var e in parser.Errors) Console.Error.WriteLine("[parse] " + e);
            return 1;
        }

        var fn = ChildByTag(root, "func");
        if (fn is null)
        {
            Console.Error.WriteLine("找不到 <func>");
            return 1;
        }
        string name = fn.Attrs.GetValueOrDefault("name", "");
        // 多个空格不算一个空名字，所以去掉空项。
        var pre = fn.Attrs.GetValueOrDefault("params", "")
            .Split(' ', StringSplitOptions.RemoveEmptyEntries);
        Console.WriteLine($"[1] 从 <func> 取出：{name}({string.Join(", ", pre)})");

        // ---------------- 2. 用参数表当 preExports 编译 ----------------
        //
        // 形参先占槽位（a=0、b=1），函数体里的 a、b 于是解析到文件作用域 ——
        // 反汇编里是 PushValue(0) / PushValue(1)。
        var program = new Program();
        Console.WriteLine("\n[2] 编译函数体（preExports = 形参表）：");
        if (!CompileAndReport(fn.Text, fn.TextLine, pre, program)) return 1;
        Console.WriteLine(Debug.DisasmNoCustom(program));
        var parts = new List<string>();
        foreach (var kv in program.Exports) parts.Add($"{kv.Key}={kv.Value}");
        Console.WriteLine("  exports: " + string.Join(" ", parts));

        // ---------------- 3. 塞实参、运行 ----------------
        //
        // 编译期就知道槽位，所以 Run 之前就能把值写进去 —— 这才是预导出的用处：
        // 宿主的「调用」就是写变量 + 跑一遍，不需要额外的参数传递机制。
        var state = new State();
        state.SetApi(new Api());
        state.SetProgram(program); // 没有实参表，args 省略
        state.Variables[program.Exports["a"]] = 3L; // 整数在 C# 侧是 long
        state.Variables[program.Exports["b"]] = 4L;

        if (state.Run() != Result.Success)
        {
            foreach (var e in state.Errors) Console.Error.WriteLine("[vm] " + e);
            return 1;
        }
        Console.WriteLine($"\n[3] add(3, 4) = {state.Returns[0]}");

        // ---------------- 4. 陷阱：预导出的名字不能再声明 ----------------
        //
        // 名字已经进了文件作用域，源码里再 export 同名、或顶层 let 同名，都是 duplicate。
        // 预导出的变量只能赋值（a = 1;），不能重新声明。
        Console.WriteLine("\n[4] 函数体里又写 export a;：");
        CompileAndReport("export a; return a;", 1, pre, new Program());
        return 0;
    }
}
