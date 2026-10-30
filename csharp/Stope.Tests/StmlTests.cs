using System;
using System.Collections.Generic;
using System.Text;

namespace Stope.Tests;

/// <summary>
/// STML 两组测试：词法（STOK 族）与语法（SP 族），<b>全部由 golden 数据驱动</b>。
/// <para>
/// 用例清单 <c>stml_cases.txt</c>（121 条）是四方共用的唯一真源：C++ 探针读它 dump 出
/// <c>golden_stml.txt</c>，本文件读同一份清单 + golden 逐字段比对。加删用例只改清单。
/// </para>
/// <para>
/// 属性顺序：C++ 的 <c>Element.attrs</c> 是 <c>std::map</c>（字典序），本实现是
/// <see cref="Dictionary{TKey,TValue}"/>（插入序）。契约明确「属性顺序不保证」
/// （<c>stml-test-plan.md</c> §2.3），所以<b>形状串里按字典序输出</b>，否则两头会为了一个
/// 不保证的顺序互相打架。
/// </para>
/// </summary>
public static class StmlTests
{
    private sealed class Case
    {
        public string Id = "";
        public string Kind = "";
        public string State = "Xml";
        public string StateFunc = "";
        public string Src = "";
    }

    private static List<Case> ReadCases()
    {
        var outList = new List<Case>();
        foreach (var line in Data.ReadText("stml_cases.txt").Split('\n'))
        {
            if (line.Length == 0 || line.StartsWith("#", StringComparison.Ordinal)) continue;
            var one = new Dictionary<string, string>();
            foreach (var part in line.Split('\t'))
            {
                int eq = part.IndexOf('=');
                if (eq < 0) continue;
                one[part[..eq]] = part[(eq + 1)..];
            }
            if (!one.ContainsKey("ID")) continue;
            string src = Data.UnescapeLex(one.GetValueOrDefault("SRC", ""));
            int times = int.TryParse(one.GetValueOrDefault("TIMES", "1"), out int t) ? t : 1;
            outList.Add(new Case
            {
                Id = one["ID"],
                Kind = one.GetValueOrDefault("KIND", ""),
                State = one.GetValueOrDefault("ST", "Xml"),
                StateFunc = one.GetValueOrDefault("SF", ""),
                Src = string.Concat(System.Linq.Enumerable.Repeat(src, times)),
            });
        }
        return outList;
    }

    /// <summary>token 类型名的比对只覆盖「双方实现都提供 lexeme」的类型（计划 §2.2）。</summary>
    private static bool HasLexeme(Stml.TokenType t) =>
        t is Stml.TokenType.Word or Stml.TokenType.String or Stml.TokenType.Text
            or Stml.TokenType.NevextSrc or Stml.TokenType.StopeSrc;

    public static void Run(Report rep)
    {
        var cases = ReadCases();
        var golden = new Dictionary<string, Dictionary<string, string>>();
        // golden_stml.txt 的 SHAPE / ERRS 只做过 escUtf8，没有再套 E_ —— 不能再解一层
        foreach (var r in Data.ReadGolden("golden_stml.txt", unescapeValues: false))
            golden[r.GetValueOrDefault("ID", "")] = r;

        if (cases.Count == 0)
        {
            rep.AddFail("STML", "stml_cases.txt 一条都没读到");
            return;
        }

        foreach (var c in cases)
        {
            if (!golden.TryGetValue(c.Id, out var g))
            {
                rep.AddFail(c.Id, "golden_stml.txt 里缺少这条");
                continue;
            }
            if (c.Kind == "parse") RunParse(rep, c, g);
            else RunLex(rep, c, g);
        }
    }

    private static Stml.Lexer.State ParseState(string name) => name switch
    {
        "Text" => Stml.Lexer.State.Text,
        "Nevext" => Stml.Lexer.State.Nevext,
        "Stope" => Stml.Lexer.State.Stope,
        _ => Stml.Lexer.State.Xml,
    };

    private static void RunLex(Report rep, Case c, Dictionary<string, string> g)
    {
        var lx = new Stml.Lexer(c.Src) { CurrentState = ParseState(c.State) };
        var toks = new StringBuilder();
        var lexs = new StringBuilder();
        for (int i = 0; i < 10000; ++i)
        {
            var t = lx.NextToken();
            if (i > 0) toks.Append(' ');
            toks.Append(t.Type).Append('(').Append(t.Line).Append(')');
            if (HasLexeme(t.Type))
            {
                if (lexs.Length > 0) lexs.Append(',');
                lexs.Append(i).Append(':').Append(Data.Esc(t.Lexeme));
            }
            if (t.Type == Stml.TokenType.Eof) break;
        }
        rep.Check(c.Id, "TOKS", g.GetValueOrDefault("TOKS", ""), toks.ToString());
        rep.Check(c.Id, "LEXS", g.GetValueOrDefault("LEXS", ""), lexs.ToString());
        rep.Check(c.Id, "ERRN", g.GetValueOrDefault("ERRN", ""), lx.Errors.Count.ToString());
        rep.Check(c.Id, "ERRS", g.GetValueOrDefault("ERRS", ""), Data.JoinQuoted(lx.Errors));
    }

    private static void RunParse(Report rep, Case c, Dictionary<string, string> g)
    {
        var lx = new Stml.Lexer(c.Src);
        var p = new Stml.Parser(lx);
        var root = new Stml.Element();
        Stml.Parser.LexerStateFunc? sf = c.StateFunc switch
        {
            "null" => null,
            "text" => (_, _) => Stml.Lexer.State.Text,
            _ => DefaultStateFunc,
        };
        var rc = p.Parse(root, sf);
        rep.Check(c.Id, "SHAPE", g.GetValueOrDefault("SHAPE", ""), ShapeElem(root));
        rep.Check(c.Id, "RESULT", g.GetValueOrDefault("RESULT", ""),
            rc == Result.Success ? "Success" : "Error");
        rep.Check(c.Id, "ERRN", g.GetValueOrDefault("ERRN", ""), p.Errors.Count.ToString());
        rep.Check(c.Id, "ERRS", g.GetValueOrDefault("ERRS", ""), Data.JoinQuoted(p.Errors));
        rep.Check(c.Id, "LEXERRN", g.GetValueOrDefault("LEXERRN", ""), lx.Errors.Count.ToString());
        rep.Check(c.Id, "LEXERRS", g.GetValueOrDefault("LEXERRS", ""), Data.JoinQuoted(lx.Errors));
    }

    /// <summary>默认回调：<c>&lt;sto&gt;</c> → Stope、<c>&lt;nev&gt;</c> → Nevext、<c>&lt;p&gt;</c> → Text，其余 Xml。</summary>
    private static Stml.Lexer.State DefaultStateFunc(string tag, Dictionary<string, string> attrs)
    {
        _ = attrs;
        if (tag == "sto") return Stml.Lexer.State.Stope;
        if (tag == "nev") return Stml.Lexer.State.Nevext;
        if (tag == "p") return Stml.Lexer.State.Text;
        return Stml.Lexer.State.Xml;
    }

    /// <summary>形状串：字段顺序固定 —— tag、行号、自闭合、属性（字典序）、文本、子元素。</summary>
    private static string ShapeElem(Stml.Element e)
    {
        var sb = new StringBuilder();
        sb.Append("Elem(").Append(Data.Esc(e.Tag)).Append(", L").Append(e.Line);
        if (e.SelfClosing) sb.Append(", /");
        var names = new List<string>(e.Attrs.Keys);
        names.Sort(StringComparer.Ordinal);
        foreach (var k in names)
        {
            sb.Append(", @").Append(Data.Esc(k));
            string v = e.Attrs[k];
            if (v.Length != 0) sb.Append("=\"").Append(Data.Esc(v)).Append('"');
        }
        if (e.Text.Length != 0) sb.Append(", T=\"").Append(Data.Esc(e.Text)).Append('"');
        if (e.Children.Count > 0)
        {
            sb.Append(", C=[");
            for (int i = 0; i < e.Children.Count; ++i)
            {
                if (i > 0) sb.Append(' ');
                sb.Append(ShapeElem(e.Children[i]));
            }
            sb.Append(']');
        }
        return sb.Append(')').ToString();
    }
}
