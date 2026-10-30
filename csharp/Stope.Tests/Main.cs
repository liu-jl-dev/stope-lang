using System;

namespace Stope.Tests;

/// <summary>
/// 测试入口。分组顺序与 GDScript 侧的 <c>run_tests.gd</c> 一致，输出格式也刻意做成一样
/// （每组一行「断言 N 条，失败 M 条」+ 最后一行的总数），这样可以三条命令横向对照：
/// <code>
/// dotnet run --project csharp/Stope.Tests
/// godot --headless --path gdscript --script res://test/run_tests.gd
/// npm test --prefix nodejs
/// </code>
/// </summary>
public static class Runner
{
    public static int Main()
    {
        Console.OutputEncoding = System.Text.Encoding.UTF8;
        Console.WriteLine("====================================================");
        Console.WriteLine("Stope C# 实现 —— 测试跑器");
        Console.WriteLine("数据目录：" + Data.Dir);
        Console.WriteLine("====================================================");

        var total = new Report();
        var groups = new (string Title, Action<Report> Fn)[]
        {
            ("词法（golden_lex.txt）", LexerTests.Run),
            ("二进制数组 + 常量折叠（golden_binarr.txt）", BinArrTests.Run),
            ("语法 + 编译器（golden.txt）", ParserTests.RunGolden),
            ("嵌套深度上限", ParserTests.RunDepth),
            ("反汇编（golden_disasm.txt）", DisasmTests.Run),
            ("STML（stml_cases.txt + golden_stml.txt）", StmlTests.Run),
            ("参考执行器", VmTests.Run),
        };

        for (int i = 0; i < groups.Length; ++i)
        {
            var (title, fn) = groups[i];
            Console.WriteLine();
            Console.WriteLine($"[{i + 1}/{groups.Length}] {title}");
            var rep = new Report();
            try
            {
                fn(rep);
            }
            catch (Exception ex)
            {
                rep.AddFail(title, "抛异常：" + ex);
            }
            rep.Dump();
            Console.WriteLine($"  （本组）  断言 {rep.Pass + rep.Fail} 条，失败 {rep.Fail} 条");
            total.Pass += rep.Pass;
            total.Fail += rep.Fail;
        }

        Console.WriteLine();
        Console.WriteLine("====================================================");
        if (total.Fail == 0)
        {
            Console.WriteLine("全部通过：共 " + total.Pass + " 条断言");
            Console.WriteLine("====================================================");
            return 0;
        }
        Console.WriteLine("失败 " + total.Fail + " 条 / 共 " + (total.Pass + total.Fail) + " 条断言");
        Console.WriteLine("====================================================");
        return 1;
    }
}
