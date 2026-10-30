using System;
using System.Collections.Generic;

namespace Stope.Stml;

/// <summary>
/// STML 词法器。四态状态机（Xml / Text / Nevext / Stope），契约见
/// <c>docs/zh-cn/stml-test-plan.md</c> §2.1~§2.5，权威实现是 <c>cpp/src/stml_lexer.cpp</c>。
/// <para>三条最容易写错的规则：</para>
/// <list type="number">
/// <item>Text / Nevext / Stope 扫完一段后<b>必须把 state 交还 Xml</b>，否则后续
/// <see cref="NextToken"/> 会产出无限个空 token（C++ 侧由 NextToken 自己收尾）；</item>
/// <item>输入耗尽后<b>永远</b>返回 <see cref="TokenType.Eof"/>，与当前状态无关；</item>
/// <item>任何异常路径都要<b>消费字符</b>，否则调用方的 while 会死循环。</item>
/// </list>
/// </summary>
public sealed class Lexer
{
    /// <summary>四态。<c>Xml</c> 是元素结构；其余三种是「元素内容怎么切」。</summary>
    public enum State
    {
        Xml = 0,
        Text = 1,
        Nevext = 2,
        Stope = 3,
    }

    public State CurrentState = State.Xml;

    private string _src;
    private int _pos;
    private int _line = 1;

    public readonly List<string> Errors = new();

    public int Line => _line;

    public Lexer(string source = "") => _src = source;

    public Token NextToken()
    {
        var token = new Token();
        SkipWs();
        token.Line = _line;

        if (Eof)
        {
            token.Set(TokenType.Eof, "");
        }
        else if (CurrentState == State.Xml)
        {
            if (Test("</"))
            {
                token.Set(TokenType.CLAngle, "</");
                _pos += 2;
            }
            else if (Test("/>"))
            {
                token.Set(TokenType.CRAngle, "/>");
                _pos += 2;
            }
            else if (_src[_pos] == '<')
            {
                token.Set(TokenType.LAngle, "<");
                _pos += 1;
            }
            else if (_src[_pos] == '>')
            {
                token.Set(TokenType.RAngle, ">");
                _pos += 1;
            }
            else if (_src[_pos] == '=')
            {
                token.Set(TokenType.EQ, "=");
                _pos += 1;
            }
            else if (_src[_pos] is '\'' or '"')
            {
                ScanString(token);
            }
            else if (IsWordBegin(_src[_pos]))
            {
                token.Set(TokenType.Word, ScanWord());
            }
            else
            {
                this.Error("unexpected character. ");
                token.Set(TokenType.Invalid, "");
                _pos += 1; // 必须消费，否则死循环
            }
        }
        else if (CurrentState == State.Text)
        {
            token.Set(TokenType.Text, ScanText());
            CurrentState = State.Xml;
        }
        else if (CurrentState == State.Nevext)
        {
            token.Set(TokenType.NevextSrc, ScanNevext());
            CurrentState = State.Xml;
        }
        else if (CurrentState == State.Stope)
        {
            token.Set(TokenType.StopeSrc, ScanStope());
            CurrentState = State.Xml;
        }
        else
        {
            this.Error("unexpected lexer state " + (int)CurrentState + ". ");
            _pos += 1;
        }
        return token;
    }

    // ============================ Xml 状态 ============================
    /// <summary>
    /// Xml 属性串：<b>不转义</b>（<c>\"</c> 里的引号就是结束引号，TD-9）。
    /// 未闭合时报错（文案比代码段那条少一个句号，TD-8）并吃掉剩余全部输入。
    /// </summary>
    private void ScanString(Token token)
    {
        token.Type = TokenType.String;
        char quote = _src[_pos];
        _pos += 1; // 跳过开头的引号
        int start = _pos;
        for (;;)
        {
            if (Eof)
            {
                Error("unclosed string literal");
                token.Type = TokenType.Invalid;
                return;
            }
            char c = _src[_pos];
            if (c == quote)
            {
                token.Lexeme = _src[start.._pos];
                _pos += 1;
                return;
            }
            if (c == '\n') ++_line;
            _pos += 1;
        }
    }

    private string ScanWord()
    {
        int end = _pos + 1;
        while (end < _src.Length)
        {
            if (!IsWordChar(_src[end])) break;
            end += 1;
        }
        string s = _src[_pos..end];
        _pos = end;
        return s;
    }

    // ============================ 内容三态 ============================
    // 三个扫描函数同构：从当前位置一路吃到 `</` 或输入耗尽，尾部空白不计入 lexeme（B-8）。
    // Text 只认 `</`，`<b/>` 会被整段当文本吃掉（B-2）。
    private string ScanText()
    {
        int start = _pos;
        while (!Eof)
        {
            if (Test("</")) break;
            if (_src[_pos] == '\n') ++_line;
            _pos += 1;
        }
        return TrimTrailingWs(_src[start.._pos]);
    }

    /// <summary>Nevext 代码段：引号串与注释整段跳过，其中的 <c>&lt;/</c> 不算结束标签（B-3）。</summary>
    private string ScanNevext()
    {
        int start = _pos;
        while (!Eof)
        {
            if (Test("</")) break;
            if (_src[_pos] is '\'' or '"') ScanNevextStr(_src[_pos]);
            else if (Test("//")) SkipSinglelineComment();
            else if (Test("/*")) SkipMultilineComment();
            else
            {
                if (_src[_pos] == '\n') ++_line;
                _pos += 1;
            }
        }
        return TrimTrailingWs(_src[start.._pos]);
    }

    /// <summary>Stope 代码段：同 Nevext，只有引号规则不同（单引号是 BinArr，不转义）。</summary>
    private string ScanStope()
    {
        int start = _pos;
        while (!Eof)
        {
            if (Test("</")) break;
            if (_src[_pos] is '\'' or '"') ScanStopeStr(_src[_pos]);
            else if (Test("//")) SkipSinglelineComment();
            else if (Test("/*")) SkipMultilineComment();
            else
            {
                if (_src[_pos] == '\n') ++_line;
                _pos += 1;
            }
        }
        return TrimTrailingWs(_src[start.._pos]);
    }

    /// <summary>Nevext 的引号串：两种引号<b>都</b>转义，且 <c>\</c> 后的任意字符都被吃掉。</summary>
    private void ScanNevextStr(char quote)
    {
        int beginLine = _line;
        _pos += 1; // 跳过开头的引号
        for (;;)
        {
            if (Eof)
            {
                Error2(beginLine, "unclosed string literal. ");
                return;
            }
            char c = _src[_pos];
            _pos += 1;
            if (c == '\\')
            {
                if (Eof)
                {
                    Error2(beginLine, "unclosed string literal. ");
                    return;
                }
                if (_src[_pos] == '\n') ++_line;
                _pos += 1;
            }
            else if (c == quote)
            {
                return;
            }
            else if (c == '\n')
            {
                ++_line;
            }
        }
    }

    /// <summary>
    /// Stope 的引号串：双引号是字符串、转义；单引号是 BinArr，<b>不转义</b>
    /// （与 Stope 的 Lexer.ScanBinArr 一致）。
    /// </summary>
    private void ScanStopeStr(char quote)
    {
        bool escapes = quote == '"';
        int beginLine = _line;
        _pos += 1; // 跳过开头的引号
        for (;;)
        {
            if (Eof)
            {
                Error2(beginLine, "unclosed string literal. ");
                return;
            }
            char c = _src[_pos];
            _pos += 1;
            if (escapes && c == '\\')
            {
                if (Eof)
                {
                    Error2(beginLine, "unclosed string literal. ");
                    return;
                }
                if (_src[_pos] == '\n') ++_line;
                _pos += 1;
            }
            else if (c == quote)
            {
                return;
            }
            else if (c == '\n')
            {
                ++_line;
            }
        }
    }

    private void SkipSinglelineComment()
    {
        _pos += 2;
        while (!Eof)
        {
            char c = _src[_pos];
            _pos += 1;
            if (c == '\n')
            {
                ++_line;
                break;
            }
        }
    }

    private void SkipMultilineComment()
    {
        _pos += 2;
        while (!Eof)
        {
            if (Test("*/"))
            {
                _pos += 2;
                break;
            }
            if (_src[_pos] == '\n') ++_line;
            _pos += 1;
        }
    }

    // ============================ 空白与注释 ============================
    private void SkipWs()
    {
        while (!Eof)
        {
            if (IsWhite(_src[_pos]))
            {
                if (_src[_pos] == '\n') ++_line;
                _pos += 1;
            }
            else if (CurrentState == State.Xml && Test("<!--"))
            {
                // `<!--` 只在 Xml 状态是注释；Nevext / Stope 里的 '<' 是小于号
                SkipXmlComment();
            }
            else
            {
                break;
            }
        }
    }

    private void SkipXmlComment()
    {
        _pos += 4;
        while (!Eof)
        {
            if (Test("-->"))
            {
                _pos += 3;
                break;
            }
            if (_src[_pos] == '\n') ++_line;
            _pos += 1;
        }
    }

    // ============================ 小工具 ============================
    private bool Eof => _pos >= _src.Length;

    private bool Test(string s)
    {
        if (_pos + s.Length > _src.Length) return false;
        return string.CompareOrdinal(_src, _pos, s, 0, s.Length) == 0;
    }

    private void Error(string msg) => Errors.Add("line " + _line + ": " + msg);

    private void Error2(int line, string msg) => Errors.Add("line " + line + ": " + msg);

    private static bool IsWhite(char c) => c is ' ' or '\t' or '\v' or '\f' or '\r' or '\n';

    private static bool IsAlpha(char ch) => (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');

    private static bool IsDigit(char ch) => ch >= '0' && ch <= '9';

    private static bool IsWordBegin(char ch) => IsAlpha(ch) || ch == '_' || ch == ':';

    private static bool IsWordChar(char ch) => IsWordBegin(ch) || IsDigit(ch) || ch == '-';

    /// <summary>去掉尾部空白（B-8：内容段尾部的空白不计入 lexeme）。</summary>
    private static string TrimTrailingWs(string s)
    {
        int n = s.Length;
        while (n > 0 && IsWhite(s[n - 1])) n -= 1;
        return s[..n];
    }
}
