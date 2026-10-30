using System;
using System.Collections.Generic;
using System.Text;

namespace Stope;

/// <summary>
/// AST 节点类型 —— 与 <c>cpp/include/stope/ast.hpp</c> 的 <c>NodeType</c> 同序同值。
/// 名字会进形状串（golden 比对），不能改名。
/// </summary>
public enum AstNodeType
{
    Node = 0,
    Prog = 1,
    Stmt = 2,
    Expr = 3,
    ExprStmt = 4,
    LetStmt = 5,
    ReturnStmt = 6,
    ExportStmt = 7,
    BlockStmt = 8,
    IfStmt = 9,
    WhileStmt = 10,
    AssignStmt = 11,
    BreakStmt = 12,
    ContinueStmt = 13,
    NullExpr = 14,
    BoolExpr = 15,
    IntExpr = 16,
    FloatExpr = 17,
    BinArrExpr = 18,
    StringExpr = 19,
    IdentExpr = 20,
    ArgcExpr = 21,
    ArgsExpr = 22,
    UnaryOpExpr = 23,
    BinaryOpExpr = 24,
    CallExpr = 25,
    AtExpr = 26,
    CustomOpcodeExpr = 27,
}

/// <summary>10 档优先级，与 <c>cpp/include/stope/common.hpp</c> 的 <c>OpPrecedence</c> 同序同值。</summary>
public enum Precedence
{
    Lowest = 0,
    Or = 1,
    And = 2,
    Equals = 3,
    LessGreater = 4,
    AddSub = 5,
    MulDiv = 6,
    Pow = 7,
    Prefix = 8,
    Paren = 9,
}

/// <summary>AST 基类。字段名沿用 C++ 的 camelCase（<c>leftExpr</c> 等），便于逐行对照。</summary>
public abstract class Node
{
    public int Line;
    public AstNodeType NodeType;

    protected Node(AstNodeType type, int line = -1)
    {
        NodeType = type;
        Line = line;
    }

    public virtual string ToStr(int level = 0) => "";
}

/// <summary>语句基类。</summary>
public abstract class Stmt : Node
{
    protected Stmt(AstNodeType type, int line = -1) : base(type, line) { }

    public override string ToStr(int level = 0) => ";\n";
}

/// <summary>表达式基类。</summary>
public abstract class Expr : Node
{
    protected Expr(AstNodeType type, int line = -1) : base(type, line) { }

    public override string ToStr(int level = 0) => "()";
}

/// <summary>
/// 失败路径的占位表达式 —— 对应 C++ 里直接 <c>new Expr(line)</c> 出来的裸基类节点
/// （C# 的 <see cref="Expr"/> 是抽象类，实例化不了，所以单开一个具体类型）。
/// 形状串固定为 <c>Err(L行号)</c>，行号恒为 -1。
/// </summary>
public sealed class ErrorExpr : Expr
{
    public ErrorExpr(int line = -1) : base(AstNodeType.Expr, line) { }
}

// ================================ prog ================================
/// <summary><c>prog : stmt*</c></summary>
public sealed class Prog : Node
{
    public List<Stmt> Stmts = new();

    public Prog(int line = -1) : base(AstNodeType.Prog, line) { }

    public override string ToStr(int level = 0)
    {
        var sb = new StringBuilder();
        foreach (var s in Stmts) sb.Append(s.ToStr(level));
        return sb.ToString();
    }
}

// ================================ 语句 ================================
/// <summary><c>expr_stmt : expr ";"</c></summary>
public sealed class ExprStmt : Stmt
{
    public Expr? Expr;

    public ExprStmt(int line = -1) : base(AstNodeType.ExprStmt, line) { }

    public override string ToStr(int level = 0) =>
        Shape.Indent(level) + Text.Of(Expr) + ";\n";
}

/// <summary><c>let_stmt : "let" ident ( ("," ident)* | ("=" expr) )? ";"</c></summary>
public sealed class LetStmt : Stmt
{
    public bool HasAssign;
    public List<string> Idents = new();
    public Expr? Expr;

    public LetStmt(int line = -1) : base(AstNodeType.LetStmt, line) { }

    public int IdentNum() => Idents.Count;

    public override string ToStr(int level = 0)
    {
        string s = Shape.Indent(level) + "let";
        if (HasAssign)
        {
            s += " " + (Idents.Count > 0 ? Idents[0] : "?") + " = " + Text.Of(Expr);
        }
        else
        {
            foreach (var id in Idents) s += " " + id + ",";
            if (Idents.Count > 0) s = s[..^1];
        }
        return s + ";\n";
    }
}

/// <summary><c>return_stmt : "return" ( expr ( "," expr )* )? ";"</c></summary>
public sealed class ReturnStmt : Stmt
{
    public List<Expr> Exprs = new();

    public ReturnStmt(int line = -1) : base(AstNodeType.ReturnStmt, line) { }

    public int ExprNum() => Exprs.Count;

    public override string ToStr(int level = 0)
    {
        string s = Shape.Indent(level) + "return";
        foreach (var e in Exprs) s += " " + Text.Of(e) + ",";
        if (Exprs.Count > 0) s = s[..^1];
        return s + ";\n";
    }
}

/// <summary><c>export_stmt : "export" ident ( "," ident )* ";"</c></summary>
public sealed class ExportStmt : Stmt
{
    public List<string> Idents = new();

    public ExportStmt(int line = -1) : base(AstNodeType.ExportStmt, line) { }

    public int IdentNum() => Idents.Count;

    public override string ToStr(int level = 0)
    {
        string s = Shape.Indent(level) + "export";
        foreach (var id in Idents) s += " " + id + ",";
        if (Idents.Count > 0) s = s[..^1];
        return s + ";\n";
    }
}

/// <summary><c>block_stmt : "{" prog "}"</c></summary>
public sealed class BlockStmt : Stmt
{
    public Prog Prog;

    public BlockStmt(int line = -1) : base(AstNodeType.BlockStmt, line) { Prog = new Prog(); }

    public override string ToStr(int level = 0) =>
        Shape.Indent(level) + "{\n" + Prog.ToStr(level + 1) + Shape.Indent(level) + "}\n";
}

/// <summary><c>if</c> 的一个 <c>elif</c> 分支（C++ 的 <c>IfStmtElif</c>）。</summary>
public sealed class IfStmtElif : Node
{
    public Expr? Cond;
    public Prog Prog;

    public IfStmtElif(int line = -1) : base(AstNodeType.Node, line) { Prog = new Prog(); }
}

/// <summary><c>if_stmt : "if" expr "{" prog "}" ( "elif" … )* ( "else" … )?</c></summary>
public sealed class IfStmt : Stmt
{
    public Expr? Cond;
    public Prog FirstProg;
    public List<IfStmtElif> Elifs = new();
    public Prog? ElseProg;

    public IfStmt(int line = -1) : base(AstNodeType.IfStmt, line) { FirstProg = new Prog(); }

    public bool HasElse() => ElseProg is not null;

    public override string ToStr(int level = 0)
    {
        string o = Shape.Indent(level) + "if " + Text.Of(Cond) + " " + FirstProg.ToStr(level);
        foreach (var ei in Elifs) o += Shape.Indent(level) + "elif " + Text.Of(ei.Cond) + " " + ei.Prog.ToStr(level);
        if (HasElse()) o += Shape.Indent(level) + "else " + ElseProg!.ToStr(level);
        return o;
    }
}

/// <summary><c>while_stmt : "while" expr? "{" prog "}"</c> —— <c>Cond</c> 为 null 表示无条件循环。</summary>
public sealed class WhileStmt : Stmt
{
    public Expr? Cond;
    public Prog Prog;

    public WhileStmt(int line = -1) : base(AstNodeType.WhileStmt, line) { Prog = new Prog(); }

    public override string ToStr(int level = 0) =>
        Shape.Indent(level) + "while " + Text.Of(Cond) + " " + Prog.ToStr(level);
}

/// <summary><c>assign_stmt : expr "=" expr ";"</c></summary>
public sealed class AssignStmt : Stmt
{
    public Expr? LeftExpr;
    public Expr? RightExpr;

    public AssignStmt(int line = -1) : base(AstNodeType.AssignStmt, line) { }

    public override string ToStr(int level = 0) =>
        Shape.Indent(level) + Text.Of(LeftExpr) + " = " + Text.Of(RightExpr) + ";\n";
}

public sealed class BreakStmt : Stmt
{
    public BreakStmt(int line = -1) : base(AstNodeType.BreakStmt, line) { }

    public override string ToStr(int level = 0) => Shape.Indent(level) + "break;\n";
}

public sealed class ContinueStmt : Stmt
{
    public ContinueStmt(int line = -1) : base(AstNodeType.ContinueStmt, line) { }

    public override string ToStr(int level = 0) => Shape.Indent(level) + "continue;\n";
}

// ================================ 表达式 ================================
public sealed class NullExpr : Expr
{
    public NullExpr(int line = -1) : base(AstNodeType.NullExpr, line) { }

    public override string ToStr(int level = 0) => "null";
}

public sealed class BoolExpr : Expr
{
    public bool Value;

    public BoolExpr(int line = -1, bool v = false) : base(AstNodeType.BoolExpr, line) { Value = v; }

    public override string ToStr(int level = 0) => Value ? "true" : "false";
}

/// <summary>整数常量。值是 <see cref="long"/>（64 位回绕），常量折叠与执行器都用同一表示。</summary>
public sealed class IntExpr : Expr
{
    public long Value;

    public IntExpr(int line = -1, long v = 0) : base(AstNodeType.IntExpr, line) { Value = v; }

    public override string ToStr(int level = 0) => Value.ToString(System.Globalization.CultureInfo.InvariantCulture);
}

public sealed class FloatExpr : Expr
{
    public double Value;

    public FloatExpr(int line = -1, double v = 0.0) : base(AstNodeType.FloatExpr, line) { Value = v; }

    public override string ToStr(int level = 0) => Format.FmtG(Value);
}

/// <summary>二进制数组常量。载荷是 <c>byte[]</c>（对应 C++ 的 <c>std::vector&lt;char&gt;</c>）。</summary>
public sealed class BinArrExpr : Expr
{
    public byte[] Value;

    public BinArrExpr(int line = -1, byte[]? v = null) : base(AstNodeType.BinArrExpr, line)
    {
        Value = v ?? Array.Empty<byte>();
    }

    public override string ToStr(int level = 0) => "'" + Format.FmtBytes(Value) + "'";
}

public sealed class StringExpr : Expr
{
    public string Value;

    public StringExpr(int line = -1, string v = "") : base(AstNodeType.StringExpr, line) { Value = v; }

    public override string ToStr(int level = 0) => "\"" + Value + "\"";
}

public sealed class IdentExpr : Expr
{
    public string Ident;

    public IdentExpr(int line = -1, string v = "") : base(AstNodeType.IdentExpr, line) { Ident = v; }

    public override string ToStr(int level = 0) => Ident;
}

public sealed class ArgcExpr : Expr
{
    public ArgcExpr(int line = -1) : base(AstNodeType.ArgcExpr, line) { }

    public override string ToStr(int level = 0) => "argc";
}

public sealed class ArgsExpr : Expr
{
    public Expr? KeyExpr;

    public ArgsExpr(int line = -1) : base(AstNodeType.ArgsExpr, line) { }

    public override string ToStr(int level = 0) => "args[" + Text.Of(KeyExpr) + "]";
}

public sealed class UnaryOpExpr : Expr
{
    public TokenType Op; // 只可能是 Sub 或 Not
    public Expr? Expr;

    public UnaryOpExpr(int line = -1) : base(AstNodeType.UnaryOpExpr, line) { }

    public override string ToStr(int level = 0)
    {
        string op = Op == TokenType.Sub ? "-" : Op == TokenType.Not ? "!" : Op + "(";
        return op + Text.Of(Expr);
    }
}

public sealed class BinaryOpExpr : Expr
{
    public Expr? LeftExpr;
    public TokenType Op;
    public Expr? RightExpr;

    public BinaryOpExpr(int line = -1) : base(AstNodeType.BinaryOpExpr, line) { }

    public override string ToStr(int level = 0)
    {
        string o = TokenText.LiteralOf(Op) ?? "?";
        o = o == "idiv" ? " idiv " : " " + o + " ";
        return "(" + Text.Of(LeftExpr) + o + Text.Of(RightExpr) + ")";
    }
}

public sealed class CallExpr : Expr
{
    public Expr? Callee;
    public List<Expr> Args = new();

    public CallExpr(int line = -1) : base(AstNodeType.CallExpr, line) { }

    public override string ToStr(int level = 0)
    {
        string s = Text.Of(Callee) + "(";
        foreach (var a in Args) s += Text.Of(a) + ",";
        if (Args.Count > 0) s = s[..^1];
        return s + ")";
    }
}

public sealed class AtExpr : Expr
{
    public Expr? Container;
    public List<Expr> KeyExprs = new();

    public AtExpr(int line = -1) : base(AstNodeType.AtExpr, line) { }

    public override string ToStr(int level = 0)
    {
        string s = Text.Of(Container) + "[";
        foreach (var k in KeyExprs) s += Text.Of(k) + ",";
        if (KeyExprs.Count > 0) s = s[..^1];
        return s + "]";
    }
}

/// <summary><c>custom_opcode_expr : custom "(" ( expr ( "," expr )* )? ")"</c></summary>
public sealed class CustomOpcodeExpr : Expr
{
    public string OpcodeName = "";
    public List<Expr> Args = new();

    public CustomOpcodeExpr(int line = -1) : base(AstNodeType.CustomOpcodeExpr, line) { }

    public override string ToStr(int level = 0)
    {
        string s = OpcodeName + "(";
        foreach (var a in Args) s += Text.Of(a) + ",";
        if (Args.Count > 0) s = s[..^1];
        return s + ")";
    }
}

/// <summary>运算符 → 显示文本。只给 <c>ToStr</c> 用；节点里的 <c>Op</c> 存的是 <see cref="TokenType"/>。</summary>
public static class TokenText
{
    public static string? LiteralOf(TokenType op) => op switch
    {
        TokenType.Or => "||",
        TokenType.And => "&&",
        TokenType.EQ => "==",
        TokenType.NE => "!=",
        TokenType.LT => "<",
        TokenType.LE => "<=",
        TokenType.GT => ">",
        TokenType.GE => ">=",
        TokenType.Add => "+",
        TokenType.Sub => "-",
        TokenType.Mul => "*",
        TokenType.Div => "/",
        TokenType.IDiv => "idiv",
        TokenType.Mod => "%",
        TokenType.Pow => "^",
        _ => null,
    };

    /// <summary>二元 / 取元素 / 调用 的优先级表（等价于 <c>binopPrecMap</c>）。</summary>
    public static Precedence PrecOf(TokenType t) => t switch
    {
        TokenType.Or => Precedence.Or,
        TokenType.And => Precedence.And,
        TokenType.EQ or TokenType.NE => Precedence.Equals,
        TokenType.LT or TokenType.LE or TokenType.GT or TokenType.GE => Precedence.LessGreater,
        TokenType.Add or TokenType.Sub => Precedence.AddSub,
        TokenType.Mul or TokenType.Div or TokenType.IDiv or TokenType.Mod => Precedence.MulDiv,
        TokenType.Pow => Precedence.Pow,
        TokenType.LParen or TokenType.LBrack => Precedence.Paren,
        _ => Precedence.Lowest,
    };
}

/// <summary><c>ToStr</c> 的公共小工具。</summary>
internal static class Text
{
    public static string Of(Expr? e) => e is null ? "<null>" : e.ToStr();
}
