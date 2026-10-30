using System;
using System.Collections.Generic;
using System.Globalization;
using System.Numerics;
using System.Text;
using System.Text.RegularExpressions;

namespace Stope;

/// <summary>
/// 词法器 —— 端口 <c>cpp/src/lexer.cpp</c>（C++ 为权威实现）。
/// 契约见 <c>docs/zh-cn/lexer-test-plan.md</c>，期望值见 <c>gdscript/test/data/golden_lex.txt</c>。
/// <para>
/// 三条容易踩错的地方：
/// <list type="number">
/// <item>标识符允许命名空间形式 <c>a:b</c>，<b>冒号两侧的空白与注释要保留进 lexeme</b>，
/// 但 <c>Parsed</c> 里不能有空白 —— 否则自定义指令名字对不上登记表。</item>
/// <item>数字的 <c>Lexeme</c> 是原文（含下划线与进制前缀），<c>Parsed</c> 去掉下划线，
/// <c>Value</c> 才是数值。三者都可能不一致，别合并。</item>
/// <item>字符串是 <c>"..."</c>（转义）、二进制数组是 <c>'...'</c>（<b>不转义</b>、可跨行）。
/// 两者搞反是这套语言最常见的笔误。</item>
/// </list>
/// </para>
/// </summary>
public sealed class Lexer
{
    private string _input = "";
    private int _pos;
    private int _line;

    /// <summary>词法错误，格式 <c>line N: msg</c>。与语法错误分开放，排查时两个都要看。</summary>
    public readonly List<string> Errors = new();

    public int Line => _line;

    public Lexer(string input) => Reset(input);

    /// <summary>重设输入并清空错误（对应 C++ 的 <c>Lexer::Reset</c>）。</summary>
    public void Reset(string input)
    {
        _input = input;
        _pos = 0;
        _line = 1;
        Errors.Clear();
    }

    /// <summary>
    /// 取下一个 token。传了 <paramref name="custom"/> 时，登记表里的名字会被识别成
    /// <see cref="TokenType.Custom"/>（关键字优先，登记一个叫 <c>if</c> 的指令无效）。
    /// </summary>
    public Token NextToken(CustomOpcodeConfig? custom = null)
    {
        SkipWs();
        var token = new Token(_line, TokenType.Eof);
        token.Lexeme = "";
        token.Parsed = "";

        if (Eof) return token; // 输入结尾

        char c = Cur;
        if (IsDigit(c) || c == '.')
        {
            ScanNumber(token);
            ParseNumber(token);
            GetNumberValue(token);
        }
        else if (IsIdentBegin(c))
        {
            ScanIdent(token);
            AnalyzeIdent(token, custom);
        }
        else if (c == '\'') ScanBinArr(token);
        else if (c == '"') ScanString(token);
        else ScanPunct(token, c);
        return token;
    }

    // ================================ 数字 ================================
    private void ScanNumber(Token token)
    {
        if (Test("0b") || Test("0B"))
        {
            token.Type = TokenType.Integer;
            token.Lexeme = MatchRadixInteger(2);
        }
        else if (Test("0o") || Test("0O"))
        {
            token.Type = TokenType.Integer;
            token.Lexeme = MatchRadixInteger(8);
        }
        else if (Test("0x") || Test("0X"))
        {
            token.Type = TokenType.Integer;
            token.Lexeme = MatchRadixInteger(16);
        }
        else if (Cur == '.')
        {
            // .[_0-9]*([eE][+-]?[0-9]+)?
            token.Type = TokenType.Float;
            var sb = new StringBuilder();
            sb.Append('.');
            Advance(1);
            while (!Eof && (IsDigit(Cur) || Cur == '_'))
            {
                sb.Append(Cur);
                Advance(1);
            }
            string exp = ScanExponent();
            if (exp.Length > 0) token.Type = TokenType.Float;
            sb.Append(exp);
            token.Lexeme = sb.ToString();
        }
        else
        {
            // [_0-9]+(.[_0-9]*)?([eE][+-]?[0-9]+)?
            token.Type = TokenType.Integer;
            var sb = new StringBuilder();
            while (!Eof && (IsDigit(Cur) || Cur == '_'))
            {
                sb.Append(Cur);
                Advance(1);
            }
            if (!Eof && Cur == '.')
            {
                token.Type = TokenType.Float;
                sb.Append('.');
                Advance(1);
                while (!Eof && (IsDigit(Cur) || Cur == '_'))
                {
                    sb.Append(Cur);
                    Advance(1);
                }
            }
            string exp = ScanExponent();
            if (exp.Length > 0) token.Type = TokenType.Float;
            sb.Append(exp);
            token.Lexeme = sb.ToString();
        }
    }

    /// <summary>
    /// <c>[eE][+-]?[0-9]*</c> —— 指数部分；返回空串表示没有。
    /// 注意数字部分可以为空（<c>"1e"</c> 的 <c>e</c> 也进 lexeme），交给
    /// <see cref="GetNumberValue"/> 报错。
    /// </summary>
    private string ScanExponent()
    {
        if (Eof) return "";
        char c = Cur;
        if (c != 'e' && c != 'E') return "";
        int start = _pos;
        Advance(1);
        if (!Eof && (Cur == '+' || Cur == '-')) Advance(1);
        while (!Eof && IsDigit(Cur)) Advance(1);
        return _input.Substring(start, _pos - start);
    }

    /// <summary>
    /// 取走 <c>0x</c> 之后符合该进制的字符；一个都没有时只取前缀（如 <c>"0b"</c>），
    /// 让 <see cref="GetNumberValue"/> 报 <c>invalid integer.</c>。
    /// </summary>
    private string MatchRadixInteger(int radix)
    {
        int start = _pos;
        Advance(2); // 0b / 0o / 0x
        int digitsStart = _pos;
        while (!Eof && (DigitOf(Cur, radix) >= 0 || Cur == '_')) Advance(1);
        if (_pos == digitsStart)
        {
            _pos = start + 2;
            return _input.Substring(start, 2);
        }
        return _input.Substring(start, _pos - start);
    }

    private void ParseNumber(Token token)
    {
        token.Parsed = token.Lexeme.Replace("_", "", StringComparison.Ordinal);
    }

    /// <summary>
    /// 按 <c>Parsed</c> 求数值；不合法（含超出 int64 范围）则报错并把 token 置为 Invalid。
    /// 判定顺序与 C++ 的 <c>stoll</c> / <c>stod</c> 行为对齐 —— 是「整串必须合法」而不是「能读多少读多少」。
    /// </summary>
    private void GetNumberValue(Token token)
    {
        if (token.Type == TokenType.Integer)
        {
            (int radix, int prefixLen) = NumberBase(token.Parsed);
            string digits = token.Parsed.Substring(prefixLen);
            if (!DigitsValid(digits, radix))
            {
                Error("invalid integer. ");
                token.Type = TokenType.Invalid;
                return;
            }
            BigInteger value;
            try
            {
                value = ParseBigInteger(digits, radix);
            }
            catch (FormatException)
            {
                Error("invalid integer. ");
                token.Type = TokenType.Invalid;
                return;
            }
            // 对齐 C++ stoll 的 out_of_range
            if (value < long.MinValue || value > long.MaxValue)
            {
                Error("invalid integer. ");
                token.Type = TokenType.Invalid;
                return;
            }
            token.Value = (long)value;
        }
        else if (token.Type == TokenType.Float)
        {
            if (!ReFloat.IsMatch(token.Parsed))
            { // 如 "1e"、"." —— C++ 用 stod 的 pos 判断
                Error("invalid float. ");
                token.Type = TokenType.Invalid;
                return;
            }
            double value;
            try
            {
                value = double.Parse(token.Parsed, NumberStyles.Float, CultureInfo.InvariantCulture);
            }
            catch (OverflowException)
            {
                Error("invalid float. ");
                token.Type = TokenType.Invalid;
                return;
            }
            // C++ 用 stod，上溢与下溢都抛 out_of_range → Invalid。.NET 不抛，只能自己判：
            // 非有限值（1e999），或者有非零数字却算出 0（1e-999 下溢）
            if (!double.IsFinite(value) || (value == 0.0 && HasNonZeroDigit(token.Parsed)))
            {
                Error("invalid float. ");
                token.Type = TokenType.Invalid;
                return;
            }
            token.Value = value;
        }
    }

    private static bool HasNonZeroDigit(string s)
    {
        foreach (char c in s)
            if (c >= '1' && c <= '9')
                return true;
        return false;
    }

    private static (int Radix, int PrefixLen) NumberBase(string s)
    {
        if (s.Length >= 2 && s[0] == '0')
        {
            switch (s[1])
            {
                case 'b':
                case 'B': return (2, 2);
                case 'o':
                case 'O': return (8, 2);
                case 'x':
                case 'X': return (16, 2);
            }
        }
        return (10, 0);
    }

    private static bool DigitsValid(string digits, int radix)
    {
        if (digits.Length == 0) return false;
        foreach (char c in digits)
            if (DigitOf(c, radix) < 0)
                return false;
        return true;
    }

    private static BigInteger ParseBigInteger(string digits, int radix)
    {
        if (radix == 10) return BigInteger.Parse(digits, CultureInfo.InvariantCulture);
        BigInteger v = BigInteger.Zero;
        var bigRadix = new BigInteger(radix);
        foreach (char c in digits)
        {
            int d = DigitOf(c, radix);
            if (d < 0) throw new FormatException("bad digit");
            v = v * bigRadix + d;
        }
        return v;
    }

    // ================================ 字符串 / 二进制数组 ================================
    /// <summary>
    /// <c>'...'</c> 到下一个 <c>'</c> 为止，中间可以换行（换行计入 line）。
    /// <b>不做任何转义</b> —— 内容原样进 lexeme。
    /// </summary>
    private void ScanBinArr(Token token)
    {
        token.Type = TokenType.BinArr;
        Advance(1); // 跳过开头的 '
        int start = _pos;
        while (!Eof && Cur != '\'')
        {
            if (Cur == '\n') ++_line;
            Advance(1);
        }
        string body = _input.Substring(start, _pos - start);
        if (Eof)
        { // 没扫到闭合的 '
            Error("unclosed binary array. ");
            token.Type = TokenType.Invalid;
            token.Lexeme = body;
            return;
        }
        token.Lexeme = body;
        Advance(1); // 跳过结尾的 '
    }

    /// <summary><c>"..."</c> 里的 <c>\</c> 会转义后一个字符（含 <c>\"</c>），未闭合则报错。</summary>
    private void ScanString(Token token)
    {
        token.Type = TokenType.String;
        Advance(1); // 跳过开头的 "
        int start = _pos;
        while (!Eof)
        {
            char c = Cur;
            if (c == '\\' && _pos + 1 < _input.Length)
            {
                // 跳过转义对（含 \"）；换行也要记行号
                if (_input[_pos + 1] == '\n') ++_line;
                Advance(2);
                continue;
            }
            if (c == '"') break;
            if (c == '\n') ++_line;
            Advance(1);
        }
        string body = _input.Substring(start, _pos - start);
        if (Eof)
        { // 没扫到闭合的 "
            Error("unclosed string literal. ");
            token.Type = TokenType.Invalid;
            token.Lexeme = body;
            return;
        }
        token.Lexeme = body;
        Advance(1); // 跳过结尾的 "
        EscapeString(token);
    }

    /// <summary>处理转义序列；遇到非法转义就报错并停下（已解析的部分保留）。</summary>
    private void EscapeString(Token token)
    {
        var sb = new StringBuilder(token.Lexeme.Length);
        string s = token.Lexeme;
        int i = 0;
        for (; i < s.Length;)
        {
            if (s[i] == '\\')
            {
                ++i;
                if (i >= s.Length)
                { // 末尾一个孤立的 \
                    Error("invalid escape character. ");
                    break;
                }
                char? c = EscapeCharOf(s[i]);
                if (c is null)
                {
                    Error("invalid escape character. ");
                    break;
                }
                sb.Append(c.Value);
                ++i;
            }
            else
            {
                sb.Append(s[i]);
                ++i;
            }
        }
        token.Parsed = sb.ToString();
    }

    private static char? EscapeCharOf(char c) => c switch
    {
        '\\' => '\\',
        '\'' => '\'',
        '"' => '"',
        'b' => '\b',
        'r' => '\r',
        't' => '\t',
        'v' => '\v',
        'n' => '\n',
        'f' => '\f',
        _ => null,
    };

    // ================================ 标识符 ================================
    /// <summary>
    /// <c>[a-zA-Z_][a-zA-Z0-9_]*</c>，允许 <c>:</c> 续接（命名空间形式 <c>my:add</c>）。
    /// 冒号两侧的空白与注释<b>进 lexeme、不进 parsed</b>。
    /// </summary>
    private void ScanIdent(Token token)
    {
        token.Type = TokenType.Ident;
        var src = new StringBuilder();
        var parsed = new StringBuilder();

        int start = _pos;
        while (!Eof && IsIdentChar(Cur)) Advance(1);
        string head = _input.Substring(start, _pos - start);
        src.Append(head);
        parsed.Append(head);

        for (;;)
        {
            src.Append(SkipWsReturningSkipped()); // 冒号之前的空白与注释
            if (Eof || Cur != ':') break;
            src.Append(':');
            parsed.Append(':');
            Advance(1);
            src.Append(SkipWsReturningSkipped()); // 冒号之后的空白与注释
            if (Eof || !IsIdentBegin(Cur))
            { // 冒号后面不是标识符
                Error("unclosed identifier. ");
                token.Type = TokenType.Invalid;
                break;
            }
            int s2 = _pos;
            while (!Eof && IsIdentChar(Cur)) Advance(1);
            string seg = _input.Substring(s2, _pos - s2);
            src.Append(seg);
            parsed.Append(seg);
        }
        token.Lexeme = src.ToString();
        token.Parsed = parsed.ToString();
    }

    /// <summary>关键字 &gt; 自定义指令 &gt; 普通标识符。</summary>
    private static void AnalyzeIdent(Token token, CustomOpcodeConfig? custom)
    {
        if (token.Type == TokenType.Invalid) return;
        if (Keywords.TryGetValue(token.Parsed, out var kw)) token.Type = kw;
        else if (custom is not null && custom.Has(token.Parsed)) token.Type = TokenType.Custom;
        else token.Type = TokenType.Ident;
    }

    // ================================ 标点 ================================
    /// <summary>先按两字符查表（<c>== != &lt;= &gt;= &amp;&amp; ||</c>），再按单字符查表。</summary>
    private void ScanPunct(Token token, char c)
    {
        if (_pos + 1 < _input.Length)
        {
            string two = _input.Substring(_pos, 2);
            if (TwoCharOps.TryGetValue(two, out var t2))
            {
                token.Type = t2;
                token.Lexeme = two;
                Advance(2);
                return;
            }
        }
        token.Lexeme = c.ToString();
        Advance(1);
        if (OneCharOps.TryGetValue(c, out var t1))
        {
            token.Type = t1;
        }
        else
        {
            token.Type = TokenType.Invalid;
            Error("unknown token. ");
        }
    }

    // ================================ 空白与注释 ================================
    private void SkipWs()
    {
        for (; !Eof;)
        {
            char c = Cur;
            if (IsWhite(c))
            {
                if (c == '\n') ++_line;
                Advance(1);
            }
            else if (Test("//"))
            { // 单行注释
                int nl = _input.IndexOf('\n', _pos);
                if (nl < 0) _pos = _input.Length;
                else
                {
                    _pos = nl + 1;
                    ++_line;
                }
            }
            else if (Test("/*")) SkipMultilineComment();
            else break;
        }
    }

    /// <summary>
    /// 与 <see cref="SkipWs"/> 相同，但返回被跳过的原文 —— 标识符的 <c>:</c> 两侧要把它记进 lexeme。
    /// </summary>
    private string SkipWsReturningSkipped()
    {
        int start = _pos;
        SkipWs();
        return _input.Substring(start, _pos - start);
    }

    private void SkipMultilineComment()
    {
        Advance(2); // 跳过 /*
        for (; !Eof;)
        {
            if (Test("*/"))
            {
                Advance(2);
                break;
            }
            if (Cur == '\n') ++_line;
            Advance(1);
        }
    }

    // ================================ 底层 ================================
    private bool Eof => _pos >= _input.Length;
    private char Cur => _input[_pos];
    private void Advance(int n) => _pos += n;

    private bool Test(string s)
    {
        if (_pos + s.Length > _input.Length) return false;
        return string.CompareOrdinal(_input, _pos, s, 0, s.Length) == 0;
    }

    private void Error(string msg) => Errors.Add("line " + _line + ": " + msg);

    private static bool IsWhite(char c) =>
        c is ' ' or '\t' or '\r' or '\n' or '\v' or '\f';

    private static bool IsDigit(char c) => c >= '0' && c <= '9';

    private static bool IsAlpha(char c) => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');

    private static bool IsIdentBegin(char c) => IsAlpha(c) || c == '_';

    private static bool IsIdentChar(char c) => IsIdentBegin(c) || IsDigit(c);

    /// <summary>该进制下的数值；不是该进制的字符返回 -1。</summary>
    private static int DigitOf(char c, int radix)
    {
        int d = -1;
        if (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        return d >= 0 && d < radix ? d : -1;
    }

    // 浮点数（parsed，已去掉下划线）：整数部分允许省略，指数部分必须完整
    private static readonly Regex ReFloat = new(
        @"\A(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z",
        RegexOptions.Compiled);

    private static readonly Dictionary<string, TokenType> Keywords = new()
    {
        ["idiv"] = TokenType.IDiv,
        ["not"] = TokenType.Not,
        ["and"] = TokenType.And,
        ["or"] = TokenType.Or,
        ["if"] = TokenType.If,
        ["elif"] = TokenType.Elif,
        ["else"] = TokenType.Else,
        ["let"] = TokenType.Let,
        ["return"] = TokenType.Return,
        ["while"] = TokenType.While,
        ["break"] = TokenType.Break,
        ["continue"] = TokenType.Continue,
        ["null"] = TokenType.Null,
        ["false"] = TokenType.False,
        ["true"] = TokenType.True,
        ["args"] = TokenType.Args,
        ["argc"] = TokenType.Argc,
        ["export"] = TokenType.Export,
    };

    private static readonly Dictionary<string, TokenType> TwoCharOps = new()
    {
        ["=="] = TokenType.EQ,
        ["!="] = TokenType.NE,
        ["<="] = TokenType.LE,
        [">="] = TokenType.GE,
        ["&&"] = TokenType.And,
        ["||"] = TokenType.Or,
    };

    private static readonly Dictionary<char, TokenType> OneCharOps = new()
    {
        [','] = TokenType.Comma,
        [';'] = TokenType.Semi,
        ['('] = TokenType.LParen,
        [')'] = TokenType.RParen,
        ['['] = TokenType.LBrack,
        [']'] = TokenType.RBrack,
        ['{'] = TokenType.LBrace,
        ['}'] = TokenType.RBrace,
        ['+'] = TokenType.Add,
        ['-'] = TokenType.Sub,
        ['*'] = TokenType.Mul,
        ['/'] = TokenType.Div,
        ['%'] = TokenType.Mod,
        ['^'] = TokenType.Pow,
        ['='] = TokenType.Assign,
        ['!'] = TokenType.Not,
        ['<'] = TokenType.LT,
        ['>'] = TokenType.GT,
    };
}
