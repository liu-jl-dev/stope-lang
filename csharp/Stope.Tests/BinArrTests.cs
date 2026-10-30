using System;
using System.Collections.Generic;
using System.Text;

namespace Stope.Tests;

/// <summary>
/// 二进制数组解析 + 常量折叠矩阵：<c>golden_binarr.txt</c>（<c>cpp/tools/golden_binarr.cpp</c> dump）。
/// <para>文件里有两类记录：</para>
/// <list type="bullet">
/// <item><c>BA\t内容\tok|err\t[bytes]</c> —— 直接打 <see cref="BinArrParser"/>；</item>
/// <item><c>FB</c> / <c>FU\t运算符\t是否折叠\t结果</c> —— 直接打常量折叠矩阵（不经过词法/语法）。</item>
/// </list>
/// <para>
/// 用例表照抄 GD 的 <c>test_parser.gd</c> 与 nodejs 的 <c>binary.test.js</c>
/// （顺序即行序，缺一条就整体错位），结果串格式与 C++ 的 <c>fmtValue</c> 逐字一致。
/// </para>
/// </summary>
public static class BinArrTests
{
    private const long Int64Max = long.MaxValue;
    private const long Int64Min = long.MinValue;

    // BA 用例表：与 GD test_parser.gd 的 _dump_binarr 逐条一致
    private static readonly string[] BaCases =
    {
        "", " ", "a", "ab", "b 0100 0001", "b 01000001", "B 1", "o 101", "O 7",
        "d 65", "d 300", "D 255 0", "x 41", "x ff FF", "X 0f", "41", "4_1", "_41",
        "01 02", "  01   02  ", "x zz", "z", "b", "d", "b 2", "o 8", "0 1",
        "9999999999999999999999", "d 2147483647", "d 2147483648", "ff",
    };

    public static void Run(Report rep)
    {
        var golden = new List<string>();
        foreach (var line in Data.ReadText("golden_binarr.txt").Split('\n'))
            if (line.Length > 0)
                golden.Add(line);

        var got = DumpAll();
        rep.CheckInt("golden_binarr.txt", "行数", golden.Count, got.Count);
        int n = Math.Min(golden.Count, got.Count);
        for (int i = 0; i < n; ++i) rep.Check("#" + (i + 1), "行", golden[i], got[i]);
    }

    private static List<string> DumpAll()
    {
        var outLines = new List<string>();

        // ---- BA：二进制数组解析 ----
        foreach (var t in BaCases)
        {
            var bytes = new List<byte>();
            var ok = new BinArrParser().Parse(t, bytes);
            outLines.Add("BA\t" + t + "\t" + (ok == Result.Success ? "ok" : "err")
                         + "\t[" + Format.FmtBytes(bytes.ToArray()) + "]");
        }

        // ---- FB：二元折叠 ----
        outLines.Add(Fb("+", TokenType.Add, Int(1), Int(2)));
        outLines.Add(Fb("-", TokenType.Sub, Int(5), Int(3)));
        outLines.Add(Fb("*", TokenType.Mul, Int(2), Int(3)));
        outLines.Add(Fb("/", TokenType.Div, Int(7), Int(2)));
        outLines.Add(Fb("/", TokenType.Div, Int(6), Int(3)));
        outLines.Add(Fb("/", TokenType.Div, Int(1), Int(0)));
        outLines.Add(Fb("idiv", TokenType.IDiv, Int(7), Int(2)));
        outLines.Add(Fb("%", TokenType.Mod, Int(7), Int(2)));
        outLines.Add(Fb("^", TokenType.Pow, Int(2), Int(10)));
        outLines.Add(Fb("^", TokenType.Pow, Int(2), Int(-1)));
        outLines.Add(Fb("+", TokenType.Add, Float(1.5), Int(1)));
        outLines.Add(Fb("+", TokenType.Add, Int(Int64Max), Int(1)));
        outLines.Add(Fb("*", TokenType.Mul, Int(Int64Max), Int(2)));
        outLines.Add(Fb("+", TokenType.Add, Bool(true), Bool(true)));
        outLines.Add(Fb("+", TokenType.Add, Str("ab"), Str("cd")));
        outLines.Add(Fb("*", TokenType.Mul, Str("ab"), Int(3)));
        outLines.Add(Fb("*", TokenType.Mul, Int(3), Str("ab")));
        outLines.Add(Fb("*", TokenType.Mul, Str(""), Int(1000000)));
        outLines.Add(Fb("*", TokenType.Mul, Str("ab"), Int(-1)));
        outLines.Add(Fb("*", TokenType.Mul, Float(1.5), Str("ab")));
        outLines.Add(Fb("+", TokenType.Add, Bin(new byte[] { 1 }), Bin(new byte[] { 2 })));
        outLines.Add(Fb("*", TokenType.Mul, Bin(new byte[] { 1 }), Int(3)));
        outLines.Add(Fb("+", TokenType.Add, Null(), Int(5)));
        outLines.Add(Fb("+", TokenType.Add, Int(5), Null()));
        outLines.Add(Fb("+", TokenType.Add, Null(), Null()));
        outLines.Add(Fb("-", TokenType.Sub, Null(), Int(5)));
        outLines.Add(Fb("-", TokenType.Sub, Int(5), Null()));
        outLines.Add(Fb("-", TokenType.Sub, Null(), Null()));
        outLines.Add(Fb("*", TokenType.Mul, Null(), Int(5)));
        outLines.Add(Fb("^", TokenType.Pow, Null(), Int(5)));
        outLines.Add(Fb("==", TokenType.EQ, Null(), Null()));
        outLines.Add(Fb("==", TokenType.EQ, Null(), Int(1)));
        outLines.Add(Fb("!=", TokenType.NE, Null(), Int(1)));
        outLines.Add(Fb("<", TokenType.LT, Null(), Int(1)));
        outLines.Add(Fb("==", TokenType.EQ, Bool(true), Bool(true)));
        outLines.Add(Fb("==", TokenType.EQ, Bool(true), Int(1)));
        outLines.Add(Fb("==", TokenType.EQ, Int(1), Float(1.0)));
        outLines.Add(Fb("==", TokenType.EQ, Str("a"), Str("a")));
        outLines.Add(Fb("<", TokenType.LT, Int(1), Int(2)));
        outLines.Add(Fb("<", TokenType.LT, Bool(true), Int(2)));
        outLines.Add(Fb("<=", TokenType.LE, Float(1.5), Float(1.5)));
        outLines.Add(Fb(">", TokenType.GT, Int(2), Int(1)));
        outLines.Add(Fb(">=", TokenType.GE, Int(2), Int(2)));
        outLines.Add(Fb("and", TokenType.And, Int(1), Int(0)));
        outLines.Add(Fb("or", TokenType.Or, Int(0), Str("a")));

        // ---- FU：一元折叠 ----
        outLines.Add(Fu("-", TokenType.Sub, Bool(true)));
        outLines.Add(Fu("-", TokenType.Sub, Bool(false)));
        outLines.Add(Fu("-", TokenType.Sub, Int(5)));
        outLines.Add(Fu("-", TokenType.Sub, Float(1.5)));
        outLines.Add(Fu("-", TokenType.Sub, Int(Int64Min)));
        outLines.Add(Fu("!", TokenType.Not, Null()));
        outLines.Add(Fu("!", TokenType.Not, Int(0)));
        outLines.Add(Fu("!", TokenType.Not, Float(0.0)));
        outLines.Add(Fu("!", TokenType.Not, Int(5)));
        outLines.Add(Fu("!", TokenType.Not, Str("")));
        return outLines;
    }

    // ---------- 折叠结果的紧凑写法，与 C++ 的 fmtValue / GD 的 _val 一致 ----------
    private static string Val(Expr? e)
    {
        if (e is null) return "null";
        return e switch
        {
            NullExpr => "Null",
            BoolExpr b => b.Value ? "true" : "false",
            IntExpr i => i.Value.ToString(System.Globalization.CultureInfo.InvariantCulture),
            FloatExpr f => Format.FmtG(f.Value),
            BinArrExpr ba => "[" + Format.FmtBytes(ba.Value) + "]",
            StringExpr s => "\"" + s.Value + "\"",
            _ => "?",
        };
    }

    private static string Fb(string name, TokenType op, Expr l, Expr r)
    {
        var e = new BinaryOpExpr { Op = op, LeftExpr = l, RightExpr = r };
        var o = ExprOptim.Optimize(e);
        int folded = o is BinaryOpExpr ? 0 : 1;
        return "FB\t" + name + "\t" + folded + "\t" + Val(o);
    }

    private static string Fu(string name, TokenType op, Expr v)
    {
        var e = new UnaryOpExpr { Op = op, Expr = v };
        var o = ExprOptim.Optimize(e);
        int folded = o is UnaryOpExpr ? 0 : 1;
        return "FU\t" + name + "\t" + folded + "\t" + Val(o);
    }

    private static IntExpr Int(long v) => new(1, v);
    private static FloatExpr Float(double v) => new(1, v);
    private static BoolExpr Bool(bool v) => new(1, v);
    private static NullExpr Null() => new(1);
    private static StringExpr Str(string v) => new(1, v);
    private static BinArrExpr Bin(byte[] v) => new(1, v);
}
