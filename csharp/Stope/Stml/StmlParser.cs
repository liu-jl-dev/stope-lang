using System;
using System.Collections.Generic;

namespace Stope.Stml;

/// <summary>
/// STML 语法器 —— 端口 <c>cpp/src/stml_parser.cpp</c>。
/// 契约见 <c>docs/zh-cn/stml-test-plan.md</c> §2.6~§2.8。
/// <para>STML 比 XML 严格，三条容易写错：</para>
/// <list type="number">
/// <item>属性可以没有值 —— <c>&lt;a flag&gt;</c> 等价于 <c>flag = ""</c>，所以属性循环
/// <b>不能</b>在开头无条件 <c>NextToken()</c>，每个分支自己负责推进（否则无值属性会多吞一个
/// token）；</item>
/// <item>子元素与元素内文本<b>互斥</b>，文本只有一段、不拼接；</item>
/// <item>每个错误分支都<b>提前 return</b>，不在同一处级联（B-14）。</item>
/// </list>
/// </summary>
public sealed class Parser
{
    /// <summary>
    /// 宿主的内容回调：<c>(tag, attrs) -&gt; State</c>，决定某个标签的内容该按哪种状态扫。
    /// 传 null 等价于 C++ 的 <c>nullptr</c>，一律 Xml（子元素模式）。
    /// </summary>
    public delegate Lexer.State LexerStateFunc(string tag, Dictionary<string, string> attrs);

    private readonly Lexer _lexer;
    private LexerStateFunc? _stateFunc;
    private Token _token = new();

    public readonly List<string> Errors = new();

    public Parser(Lexer lex) => _lexer = lex;

    /// <summary>
    /// 顶层只解析<b>一个</b>元素（B-15），根之后的剩余输入被忽略。
    /// 返回值与编译器共用同一份 <see cref="Result"/>。
    /// </summary>
    public Result Parse(Element root, LexerStateFunc? stateFunc = null)
    {
        _stateFunc = stateFunc;
        NextToken();
        ParseElement(root);
        return Errors.Count == 0 ? Result.Success : Result.Error;
    }

    private void ParseElement(Element e)
    {
        // 进入元素一律先回到 Xml：自闭合分支与出错提前返回的路径都走不到 stateFunc，
        // 留着上一次的 Text/Nevext/Stope 会污染后续 token
        _lexer.CurrentState = Lexer.State.Xml;
        e.Line = _token.Line;
        if (_token.Type != TokenType.LAngle)
        {
            Error("expected \"<\". ");
            return;
        }
        NextToken();
        if (_token.Type != TokenType.Word)
        {
            Error("expected tag name. ");
            return;
        }
        e.Tag = _token.Lexeme;
        NextToken(); // 第一个属性名，或 > 或 />
        for (;;)
        {
            // (word ("=" string)?)*
            if (_token.Type == TokenType.RAngle) break;
            if (_token.Type == TokenType.CRAngle)
            {
                e.SelfClosing = true;
                return;
            }
            if (_token.Type == TokenType.Word)
            {
                string attr = _token.Lexeme;
                NextToken();
                if (_token.Type == TokenType.EQ)
                {
                    NextToken(); // 已跳过 =
                    if (_token.Type != TokenType.String)
                    {
                        Error("expected string. ");
                        return;
                    }
                    e.Attrs[attr] = _token.Lexeme;
                    NextToken();
                }
                else
                {
                    // 无值属性（B-9）：token 已经是下一个属性名 / > 或 />，不能再推进
                    e.Attrs[attr] = "";
                }
            }
            else
            {
                Error("expected \">\" or \"/>\" or attribute. ");
                return;
            }
        }
        // 此时 SelfClosing = false，且停在 ">"
        if (_stateFunc is not null)
        {
            // attrs 传**副本**：C++ 的 LexerStateFunc 按值收 std::map，宿主改不到解析器；
            // 这里不复制的话宿主删 / 加键会改到 e.Attrs 本身。
            _lexer.CurrentState = _stateFunc(e.Tag, new Dictionary<string, string>(e.Attrs));
        }
        else
        {
            _lexer.CurrentState = Lexer.State.Xml;
        }

        if (_lexer.CurrentState == Lexer.State.Xml)
        {
            for (;;)
            {
                NextToken();
                if (_token.Type == TokenType.CLAngle) break;
                if (_token.Type == TokenType.LAngle)
                {
                    var child = new Element();
                    e.Children.Add(child);
                    ParseElement(child);
                }
                else
                {
                    Error("expected \"<\" or \"</\". ");
                    return;
                }
            }
        }
        else
        {
            // Text / Nevext / Stope：整段内容由 Lexer 一次性给出
            NextToken();
            if (_token.Type is not (TokenType.Text or TokenType.NevextSrc or TokenType.StopeSrc))
            {
                Error("expected element content. ");
                return;
            }
            e.Text = _token.Lexeme; // 只有一段，不拼接（B-11）
            NextToken(); // 停在 CLAngle，与上面 Xml 分支的 break 处汇合
        }
        NextToken(); // 结束标签名
        if (_token.Type != TokenType.Word)
        {
            Error("expected tag name. ");
            return;
        }
        if (!string.Equals(_token.Lexeme, e.Tag, StringComparison.Ordinal))
        {
            Error("tag name mismatch. ");
            return;
        }
        NextToken();
        if (_token.Type != TokenType.RAngle)
        {
            Error("expected \">\". ");
            return;
        }
    }

    private void NextToken() => _token = _lexer.NextToken();

    private void Error(string msg) => Errors.Add("line " + _token.Line + ": " + msg);
}
