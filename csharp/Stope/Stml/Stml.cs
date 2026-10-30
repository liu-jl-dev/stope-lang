using System.Collections.Generic;
using System.Text;

namespace Stope.Stml;

/// <summary>
/// STML 的 12 项 token 类型，与 C++ 的 <c>STML::TokenType</c> 一一对应：<b>值和名字都一样</b>。
/// 所以打印类型名直接用枚举名，不需要再映射一层。
/// </summary>
public enum TokenType
{
    Invalid = 0,
    Eof = 1,
    LAngle = 2,   // <
    RAngle = 3,   // >
    CLAngle = 4,  // </>
    CRAngle = 5,  // />
    EQ = 6,       // =
    Word = 7,     // ^[a-zA-Z_:][a-zA-Z0-9_:-]*$（不含 '.'）
    String = 8,   // "" '' —— Xml 属性串，不转义
    Text = 9,     // 元素内普通文本
    NevextSrc = 10, // Nevext 代码
    StopeSrc = 11,  // Stope 代码
}

/// <summary>
/// STML 元素 —— 对应 <c>cpp/include/stope/stml.hpp</c> 的 <c>Element</c>。
/// <para>
/// 模型只有 6 个字段，<b>不要加字段</b>：形状串与跨实现比对都按这 6 项来。
/// </para>
/// <para>
/// 注意 <see cref="Attrs"/> 的类型是 <see cref="Dictionary{TKey,TValue}"/>（插入序），
/// 而 C++ 是 <c>std::map</c>（字典序）。契约明确「属性顺序不保证」
/// （<c>stml-test-plan.md</c> §2.3），所以**形状串里按字典序输出**，否则两头会为了一个
/// 不保证的顺序互相打架。
/// </para>
/// </summary>
public sealed class Element
{
    public int Line = -1;

    /// <summary>标签名。</summary>
    public string Tag = "";

    /// <summary>属性，无值属性的值是空串。</summary>
    public readonly Dictionary<string, string> Attrs = new();

    public bool SelfClosing;

    public List<Element> Children = new();

    /// <summary>与 <see cref="Children"/> 互斥；只有一段，不拼接。</summary>
    public string Text = "";

    /// <summary>调试用：不一定与源文本逐字符相同（属性顺序、自闭合写法都不保留）。</summary>
    public string ToStr(int level = 0)
    {
        string sp = new(' ', level * 2);
        var o = new StringBuilder();
        o.Append(sp).Append('<').Append(Tag);
        foreach (var (name, value) in Attrs)
            o.Append(' ').Append(name).Append(value != "" ? "=\"" + value + "\"" : "");
        if (SelfClosing)
        {
            o.Append(" />\n");
        }
        else
        {
            o.Append(">\n").Append(Text);
            foreach (var c in Children) o.Append(c.ToStr(level + 1));
            o.Append(sp).Append("</").Append(Tag).Append(">\n");
        }
        return o.ToString();
    }
}

/// <summary>STML 词法 token。</summary>
public sealed class Token
{
    public int Line = -1;
    public TokenType Type = TokenType.Invalid;

    /// <summary>词素、词位，表示具体字符序列。</summary>
    public string Lexeme = "";

    public void Set(TokenType t, string l)
    {
        Type = t;
        Lexeme = l;
    }
}
