using System;
using System.Collections.Generic;
using System.Text;

namespace Stope.Tests;

/// <summary>
/// 语法 + 编译器：<c>golden.txt</c>（195 条，<c>cpp/tools/golden.cpp</c> dump）+ 嵌套深度上限。
/// <para>
/// 每条用例断言九件事：AST 形状串、语句行号序列、语法 / 词法错误条数与文案、
/// 单行产物（<see cref="Data.DumpProgram"/>）、编译状态、编译错误。期望值不手写 ——
/// 改行为时重跑 <c>cmake --build cpp/build --target gen-golden</c>。
/// </para>
/// </summary>
public static class ParserTests
{
    public static readonly CustomOpcodeConfig Cfg = LexerTests.MakeConfig();

    public static void RunGolden(Report rep)
    {
        var cases = Data.ReadGolden("golden.txt");
        if (cases.Count == 0)
        {
            rep.AddFail("语法", "golden.txt 一条都没读到");
            return;
        }
        rep.CheckInt("golden.txt", "用例数", 195, cases.Count);
        foreach (var rec in cases)
        {
            string id = rec.GetValueOrDefault("ID", "");
            var got = RunCase(rec);
            rep.Check(id, "SHAPE", rec.GetValueOrDefault("SHAPE", ""), got.Shape);
            rep.Check(id, "LINES", rec.GetValueOrDefault("LINES", ""), got.Lines);
            rep.Check(id, "PERR", rec.GetValueOrDefault("PERR", ""), got.PerR.ToString());
            rep.Check(id, "PERRS", rec.GetValueOrDefault("PERRS", ""), got.PerRs);
            rep.Check(id, "LEXERR", rec.GetValueOrDefault("LEXERR", ""), got.LexErr.ToString());
            rep.Check(id, "LEXERRS", rec.GetValueOrDefault("LEXERRS", ""), got.LexErrs);
            rep.Check(id, "CMP", rec.GetValueOrDefault("CMP", ""), got.Cmp);
            rep.Check(id, "OUT", rec.GetValueOrDefault("OUT", ""), got.Out);
            rep.Check(id, "CERRS", rec.GetValueOrDefault("CERRS", ""), got.CErrs);
        }
    }

    public sealed class CaseResult
    {
        public string Src = "";
        public string Shape = "";
        public string Lines = "";
        public int PerR;
        public int LexErr;
        public string PerRs = "";
        public string LexErrs = "";
        public string Cmp = "";
        public string Out = "";
        public string CErrs = "";
    }

    /// <summary>
    /// 跑一条 golden 用例：词法 → 语法 → 编译，把结果摊平成与 golden 记录同名的字段。
    /// <para>
    /// ⚠ <c>SRC</c> 要解<b>两</b>层转义：golden 里的源码是 <c>E_(escUtf8(源码))</c>
    /// （源码本身不是转义文本，所以要多解一层才能还原）；而 SHAPE / OUT 这些字段存的
    /// 就是「转义后的形态」，只解一层。
    /// </para>
    /// </summary>
    public static CaseResult RunCase(Dictionary<string, string> rec)
    {
        string src = Data.Unescape(rec.GetValueOrDefault("SRC", ""));
        bool fold = rec.GetValueOrDefault("FOLD", "") == "1";

        var lx = new Lexer(src);
        var ps = new Parser(lx, Cfg) { ConstFolding = fold };
        var tree = new Prog();
        ps.ParseProgram(tree);

        var outProg = new Program();
        var c = new Compiler(Cfg);
        var rc = c.Compile(tree, outProg);

        return new CaseResult
        {
            Src = src,
            Shape = Shape.Prog(tree),
            Lines = StmtLines(tree),
            PerR = ps.Errors.Count,
            LexErr = lx.Errors.Count,
            PerRs = Data.JoinEsc(ps.Errors),
            LexErrs = Data.JoinEsc(lx.Errors),
            Cmp = rc == Result.Success ? "OK" : "ERR",
            Out = Data.DumpProgram(outProg, Cfg),
            CErrs = Data.JoinEsc(c.Errors),
        };
    }

    private static string StmtLines(Prog p)
    {
        var sb = new StringBuilder();
        for (int i = 0; i < p.Stmts.Count; ++i)
        {
            if (i > 0) sb.Append(',');
            sb.Append(p.Stmts[i].Line);
        }
        return sb.ToString();
    }

    // ---------------- 嵌套深度上限 ----------------
    // 期望值不 dump：限额与错误文案是**四方约定**（C++ Parser::maxDepth 与本实现的
    // MaxDepth 同为 256，文案逐字相同），所以按约定写死。任一侧改了计数口径或文案，
    // 各实现的测试都会红。
    public static string DepthSource(string kind, int n) => kind switch
    {
        // 与 GD 侧 _depth_case 的构造逐字一致：块里要有语句，否则永远进不到 ParseExpr，
        // 深度计数根本没机会检查。
        "paren" => new string('(', n) + "a" + new string(')', n) + ";",
        "block" => new string('{', n) + "a;" + new string('}', n),
        "unary" => new string('-', n) + "a;",
        "at" => Repeat("a[", n) + "0" + new string(']', n) + ";",
        _ => throw new ArgumentException("unknown kind " + kind),
    };

    private static string Repeat(string s, int n)
    {
        var sb = new StringBuilder(s.Length * n);
        for (int i = 0; i < n; ++i) sb.Append(s);
        return sb.ToString();
    }

    private static (List<string> Errors, Prog Tree) ParseDepth(string kind, int n)
    {
        var ps = new Parser(new Lexer(DepthSource(kind, n)));
        var tree = new Prog();
        ps.ParseProgram(tree);
        return (ps.Errors, tree);
    }

    public static void RunDepth(Report rep)
    {
        (string Id, string Kind, int N, bool Deep)[] cases =
        {
            ("PD-DEPTH-1", "paren", 200, false), // 限额内：照常解析
            ("PD-DEPTH-2", "paren", 300, true),
            ("PD-DEPTH-3", "block", 300, true),
            ("PD-DEPTH-4", "unary", 300, true),  // 没有括号的递归
            ("PD-DEPTH-5", "at", 300, true),
            ("PD-DEPTH-6", "paren", 12000, true), // 曾真的栈溢出
            ("PD-DEPTH-7", "block", 200, false),
            ("PD-DEPTH-8", "unary", 200, false),
            ("PD-DEPTH-9", "at", 200, false),
        };

        foreach (var (id, kind, n, deep) in cases)
        {
            var (errors, tree) = ParseDepth(kind, n);
            if (!deep)
            {
                rep.CheckInt(id + " " + kind + " " + n, "错误条数", 0, errors.Count);
                rep.CheckTrue(id, "应解析出语句", tree.Stmts.Count > 0);
                continue;
            }
            // 超限只报一条（不刷连锁噪音），文案逐字固定
            rep.CheckInt(id + " " + kind + " " + n, "错误条数", 1, errors.Count);
            rep.Check(id, "错误文案", "line 1: nesting too deep (max 256). ",
                errors.Count > 0 ? errors[0] : "<无错误>");
        }

        rep.CheckInt("PD-DEFAULT", "默认 MaxDepth", 256, new Parser(new Lexer("")).MaxDepth);

        // maxDepth = 0 时不检查：600 层（远超 256）仍能解析。
        // 这里不用 nodejs 侧的 2000 层 —— C# 每层递归的栈帧更大，默认 1 MB 线程栈会在
        // 2000 层先在**引擎**层溢出，测不到「不检查」这件事本身。
        var ps0 = new Parser(new Lexer(DepthSource("paren", 600))) { MaxDepth = 0 };
        var tree0 = new Prog();
        ps0.ParseProgram(tree0);
        rep.CheckInt("PD-NOLIMIT", "错误条数", 0, ps0.Errors.Count);
        rep.CheckInt("PD-NOLIMIT", "语句数", 1, tree0.Stmts.Count);
    }
}
