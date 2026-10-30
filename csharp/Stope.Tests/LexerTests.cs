using System;
using System.Collections.Generic;

namespace Stope.Tests;

/// <summary>
/// 词法：全部由 <c>golden_lex.txt</c>（C++ 探针 dump）驱动，逐条比 TOKS / LEXEMES / ERRN / ERRS。
/// <para>
/// 147 条用例覆盖 整数 / 浮点 / 标识符 / 关键字 / 字符串 / 二进制串 / 标点 / 空白注释 /
/// 行号 / 错误 / 健壮性 / 自定义指令。用例编号与 <c>cpp/test/test_lexer_*.cpp</c> 一一对应
/// （<c>I-xx</c> 整数、<c>F-xx</c> 浮点 …… 见 <c>docs/zh-cn/lexer-test-plan.md</c>）。
/// </para>
/// <para>
/// token 流的写法与 GD 的 <c>test_lexer.gd</c> 一致：
/// <c>Type(line)[parsed]=value</c>，其中 <c>[]</c> 只在 parsed 非空时出现、<c>=value</c>
/// 只对整数与浮点出现。<c>LEXEMES</c> 只比「四方实现都提供」的类型（数字 / 字符串 /
/// 二进制数组）——标识符与标点的 lexeme 属实现自定，契约里不断言。
/// </para>
/// </summary>
public static class LexerTests
{
    public static readonly CustomOpcodeConfig Cfg = MakeConfig();

    /// <summary>golden 里所有用例都带着这两条自定义指令（与 <c>cpp/tools/golden.cpp</c> 的 g_cfg 一致）。</summary>
    public static CustomOpcodeConfig MakeConfig()
    {
        var cfg = new CustomOpcodeConfig();
        cfg.AddCustomOpcode("myop", 100, 2);
        cfg.AddCustomOpcode("vop", 101, -1);
        return cfg;
    }

    public static void Run(Report rep)
    {
        // ⚠ 这个文件的字段**不做二次转义**：TOKS / LEXEMES / ERRS 直接就是 esc_lex 形态，
        // 只有 SRC 是转义过的（且转义表里多 \v \f）。解错一层，字符串用例会大批红。
        var cases = Data.ReadGolden("golden_lex.txt", unescapeValues: false);
        if (cases.Count == 0)
        {
            rep.AddFail("词法", "golden_lex.txt 一条都没读到");
            return;
        }
        foreach (var c in cases)
        {
            string id = c.GetValueOrDefault("ID", "");
            var r = One(Data.UnescapeLex(c.GetValueOrDefault("SRC", "")));
            rep.Check(id, "TOKS", c.GetValueOrDefault("TOKS", ""), r.Toks);
            rep.Check(id, "LEXEMES", c.GetValueOrDefault("LEXEMES", ""), r.Lexemes);
            rep.Check(id, "ERRN", c.GetValueOrDefault("ERRN", ""), r.ErrN.ToString());
            rep.Check(id, "ERRS", c.GetValueOrDefault("ERRS", ""), r.Errs);
        }
    }

    public static (string Toks, string Lexemes, int ErrN, string Errs) One(string src)
    {
        var lx = new Lexer(src);
        var toks = new System.Text.StringBuilder();
        var lexemes = new System.Text.StringBuilder();
        for (int i = 0; i < 10000; ++i)
        {
            var t = lx.NextToken(Cfg);
            if (i > 0) toks.Append(' ');
            toks.Append(t.Type).Append('(').Append(t.Line).Append(')');
            if (t.Parsed.Length > 0) toks.Append('[').Append(Data.EscLex(t.Parsed)).Append(']');
            if (t.Type == TokenType.Integer) toks.Append('=').Append(t.IntValue);
            else if (t.Type == TokenType.Float) toks.Append('=').Append(Format.FmtG(t.FloatValue));
            if (t.Type is TokenType.Integer or TokenType.Float or TokenType.String or TokenType.BinArr)
            {
                if (lexemes.Length > 0) lexemes.Append(',');
                lexemes.Append(i).Append(':').Append(Data.EscLex(t.Lexeme));
            }
            if (t.Type == TokenType.Eof) break;
        }
        return (toks.ToString(), lexemes.ToString(), lx.Errors.Count, Data.JoinEsc(lx.Errors));
    }
}
