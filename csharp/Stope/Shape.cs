using System.Collections.Generic;
using System.Text;

namespace Stope;

/// <summary>
/// 【测试用】AST 序列化 —— 严格照抄 <c>cpp/test/test_common.hpp</c> 的
/// <c>shapeExpr</c> / <c>shapeStmt</c> / <c>shapeProg</c>，格式见
/// <c>docs/zh-cn/parser-test-plan.md</c> §2：
/// <code>
/// Null / Argc / Bool(true) / Int(31) / Float(1.5) / BinArr[04,01] / Str("a\nb") /
/// Ident(a) / Args(null) / Unary(Sub, Int(1)) / Bin(Add, Int(1), Int(2)) /
/// Call(f; Int(1)) / At(a; Int(1)) / Custom(myop; Int(1)) / Err(L-1)
/// ExprStmt(..) / Let[a,b]=Int(1) / Return(Int(1), Int(2)) / Export[a] /
/// Block{..} / If(c){..}Elif(c){..}Else{..} / While(c){..} /
/// Assign(l, r) / Break / Continue
/// </code>
/// prog：语句按 <c>" ; "</c> 连接，无外层包装；空 prog 给空串。
/// <para>
/// golden 数据里存的期望值就是这些字符串，所以一个字符都不能变 —— 这是跨实现
/// 检查「AST 长得一样」的唯一手段。
/// </para>
/// </summary>
public static class Shape
{
    public static string Indent(int level) => new(' ', level * 2);

    public static string Prog(Prog? p)
    {
        if (p is null) return "null";
        var parts = new List<string>(p.Stmts.Count);
        foreach (var s in p.Stmts) parts.Add(Stmt(s));
        return string.Join(" ; ", parts);
    }

    public static string Stmt(Stmt? s)
    {
        if (s is null) return "null";
        switch (s.NodeType)
        {
            case AstNodeType.ExprStmt:
                return "ExprStmt(" + Expr(((ExprStmt)s).Expr) + ")";
            case AstNodeType.LetStmt:
            {
                var n = (LetStmt)s;
                var sb = new StringBuilder("Let[");
                for (int i = 0; i < n.Idents.Count; ++i)
                {
                    if (i > 0) sb.Append(',');
                    sb.Append(Format.Esc(n.Idents[i]));
                }
                sb.Append(']');
                if (n.HasAssign) sb.Append('=').Append(Expr(n.Expr));
                return sb.ToString();
            }
            case AstNodeType.ReturnStmt:
            {
                var n = (ReturnStmt)s;
                var parts = new List<string>(n.Exprs.Count);
                foreach (var e in n.Exprs) parts.Add(Expr(e));
                return "Return(" + string.Join(", ", parts) + ")";
            }
            case AstNodeType.ExportStmt:
            {
                var n = (ExportStmt)s;
                var sb = new StringBuilder("Export[");
                for (int i = 0; i < n.Idents.Count; ++i)
                {
                    if (i > 0) sb.Append(',');
                    sb.Append(Format.Esc(n.Idents[i]));
                }
                return sb.Append(']').ToString();
            }
            case AstNodeType.BlockStmt:
                return "Block{" + Prog(((BlockStmt)s).Prog) + "}";
            case AstNodeType.IfStmt:
            {
                var n = (IfStmt)s;
                var sb = new StringBuilder();
                sb.Append("If(").Append(Expr(n.Cond)).Append("){").Append(Prog(n.FirstProg)).Append('}');
                foreach (var ei in n.Elifs)
                    sb.Append("Elif(").Append(Expr(ei.Cond)).Append("){").Append(Prog(ei.Prog)).Append('}');
                if (n.ElseProg is not null) sb.Append("Else{").Append(Prog(n.ElseProg)).Append('}');
                return sb.ToString();
            }
            case AstNodeType.WhileStmt:
            {
                var n = (WhileStmt)s;
                return "While(" + Expr(n.Cond) + "){" + Prog(n.Prog) + "}";
            }
            case AstNodeType.AssignStmt:
            {
                var n = (AssignStmt)s;
                return "Assign(" + Expr(n.LeftExpr) + ", " + Expr(n.RightExpr) + ")";
            }
            case AstNodeType.BreakStmt:
                return "Break";
            case AstNodeType.ContinueStmt:
                return "Continue";
            default:
                return "?" + s.NodeType;
        }
    }

    public static string Expr(Expr? e)
    {
        if (e is null) return "null";
        switch (e.NodeType)
        {
            case AstNodeType.Expr: // 失败路径返回的裸节点：line 恒为 -1
                return "Err(L" + e.Line + ")";
            case AstNodeType.NullExpr:
                return "Null";
            case AstNodeType.ArgcExpr:
                return "Argc";
            case AstNodeType.BoolExpr:
                return ((BoolExpr)e).Value ? "Bool(true)" : "Bool(false)";
            case AstNodeType.IntExpr:
                return "Int(" + ((IntExpr)e).Value + ")";
            case AstNodeType.FloatExpr:
                return "Float(" + Format.FmtG(((FloatExpr)e).Value) + ")";
            case AstNodeType.BinArrExpr:
                return "BinArr[" + Format.FmtBytes(((BinArrExpr)e).Value) + "]";
            case AstNodeType.StringExpr:
                return "Str(\"" + Format.Esc(((StringExpr)e).Value) + "\")";
            case AstNodeType.IdentExpr:
                return "Ident(" + Format.Esc(((IdentExpr)e).Ident) + ")";
            case AstNodeType.ArgsExpr:
            {
                var n = (ArgsExpr)e;
                return n.KeyExpr is null ? "Args(null)" : "Args(" + Expr(n.KeyExpr) + ")";
            }
            case AstNodeType.UnaryOpExpr:
            {
                var n = (UnaryOpExpr)e;
                return "Unary(" + n.Op + ", " + Expr(n.Expr) + ")";
            }
            case AstNodeType.BinaryOpExpr:
            {
                var n = (BinaryOpExpr)e;
                return "Bin(" + n.Op + ", " + Expr(n.LeftExpr) + ", " + Expr(n.RightExpr) + ")";
            }
            case AstNodeType.CallExpr:
            {
                var n = (CallExpr)e;
                var sb = new StringBuilder("Call(").Append(Expr(n.Callee));
                foreach (var a in n.Args) sb.Append("; ").Append(Expr(a));
                return sb.Append(')').ToString();
            }
            case AstNodeType.AtExpr:
            {
                var n = (AtExpr)e;
                var sb = new StringBuilder("At(").Append(Expr(n.Container));
                foreach (var k in n.KeyExprs) sb.Append("; ").Append(Expr(k));
                return sb.Append(')').ToString();
            }
            case AstNodeType.CustomOpcodeExpr:
            {
                var n = (CustomOpcodeExpr)e;
                var sb = new StringBuilder("Custom(").Append(Format.Esc(n.OpcodeName));
                foreach (var a in n.Args) sb.Append("; ").Append(Expr(a));
                return sb.Append(')').ToString();
            }
            default:
                return "?" + e.NodeType;
        }
    }
}
