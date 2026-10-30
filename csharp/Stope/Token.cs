namespace Stope;

/// <summary>
/// 词法记号类型 —— 与 <c>cpp/include/stope/token.hpp</c> 的 <c>TokenType</c> 同序同值。
/// 顺序是跨实现契约：golden 数据里 <c>TOKS=Integer(1)[1]=1</c> 这类字段比对的就是名字。
/// </summary>
public enum TokenType
{
    Invalid = 0,   // 无效
    Eof = 1,       // 输入结尾
    Ident = 2,     // 标识符
    Integer = 3,   // 整数
    Float = 4,     // 浮点数
    String = 5,    // "..."
    BinArr = 6,    // '...'
    Comma = 7,     // ,
    Semi = 8,      // ;
    LParen = 9,    // (

    RParen = 10,    // )
    LBrack = 11,    // [
    RBrack = 12,    // ]
    LBrace = 13,    // {
    RBrace = 14,    // }
    Assign = 15,    // =
    Add = 16,       // +
    Sub = 17,       // -
    Mul = 18,       // *
    Div = 19,       // /

    IDiv = 20,      // idiv
    Mod = 21,       // %
    Pow = 22,       // ^
    EQ = 23,        // ==
    NE = 24,        // !=
    LT = 25,        // <
    LE = 26,        // <=
    GT = 27,        // >
    GE = 28,        // >=
    Not = 29,       // ! not

    And = 30,       // && and
    Or = 31,        // || or
    If = 32,        // if
    Elif = 33,      // elif
    Else = 34,      // else
    Let = 35,       // let
    Return = 36,    // return
    While = 37,     // while
    Break = 38,     // break
    Continue = 39,  // continue

    Null = 40,      // null
    False = 41,     // false
    True = 42,      // true
    Args = 43,      // args
    Argc = 44,      // argc
    Export = 45,    // export
    Custom = 46,    // 自定义指令
}

/// <summary>
/// 一个词法记号。三个文本字段分工与 C++ 的 <c>Token</c> 一致：
/// <list type="bullet">
/// <item><c>Lexeme</c> 是原文（标识符会保留 <c>:</c> 两侧的空白与注释）</item>
/// <item><c>Parsed</c> 是「拿去建节点用」的形式：数字去掉下划线、字符串去掉转义、
/// 标识符拼成不含空白的 <c>a:b</c></item>
/// <item><c>Value</c> 只对 <c>Integer</c>（<see cref="long"/>）与 <c>Float</c>（<see cref="double"/>）有值</item>
/// </list>
/// </summary>
public sealed class Token
{
    public int Line;
    public TokenType Type;
    public string Lexeme = "";
    public string Parsed = "";
    public object? Value;

    public Token(int line, TokenType type)
    {
        Line = line;
        Type = type;
    }

    /// <summary>整数值（仅 <c>Integer</c>；其它类型调用是产物错误）。</summary>
    public long IntValue => (long)Value!;

    /// <summary>浮点值（仅 <c>Float</c>）。</summary>
    public double FloatValue => (double)Value!;
}
