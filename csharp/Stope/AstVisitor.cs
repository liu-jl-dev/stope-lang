namespace Stope;

/// <summary>
/// 遍历骨架 —— 逐项对齐 <c>cpp/include/stope/ast_visitor.hpp</c>。
/// <para>
/// 用法：继承 <see cref="AstVisitor"/>，按需重写 <c>OnVisitXxx</c>。默认实现一律
/// 「按源码顺序递归子节点」，子类重写后若要继续下钻，调 <c>base.OnVisitXxx(...)</c> 即可。
/// </para>
/// <para>
/// 分发用 <c>switch</c> 而不是方法名字符串表：C# 的节点本来就是具体类型，<c>switch</c>
/// 既能被编译器检查，也比反射式派发快。**漏一个分支不会报错，只会静默跳过整类节点**
/// （<see cref="AstNodeType.Node"/> / <see cref="AstNodeType.Stmt"/> /
/// <see cref="AstNodeType.Expr"/> 三个裸基类本来就没有分支，它们只在错误恢复路径上出现）。
/// </para>
/// </summary>
public class AstVisitor
{
    /// <summary>
    /// 当前正在访问的节点行号，由 <see cref="Visit"/> 顺带更新。基类自己不用，留给要报
    /// 诊断的子类（编译器那些没有专属行号的错误就取它）。
    /// </summary>
    public int CurLine = -1;

    public void Visit(Node? n)
    {
        if (n is null) return;
        CurLine = n.Line;
        switch (n.NodeType)
        {
            // ---------------- prog ----------------
            case AstNodeType.Prog: OnVisitProg((Prog)n); break;

            // ---------------- 语句 ----------------
            case AstNodeType.ExprStmt: OnVisitExprStmt((ExprStmt)n); break;
            case AstNodeType.LetStmt: OnVisitLetStmt((LetStmt)n); break;
            case AstNodeType.ReturnStmt: OnVisitReturnStmt((ReturnStmt)n); break;
            case AstNodeType.ExportStmt: OnVisitExportStmt((ExportStmt)n); break;
            case AstNodeType.BlockStmt: OnVisitBlockStmt((BlockStmt)n); break;
            case AstNodeType.IfStmt: OnVisitIfStmt((IfStmt)n); break;
            case AstNodeType.WhileStmt: OnVisitWhileStmt((WhileStmt)n); break;
            case AstNodeType.AssignStmt: OnVisitAssignStmt((AssignStmt)n); break;
            case AstNodeType.BreakStmt: OnVisitBreakStmt((BreakStmt)n); break;
            case AstNodeType.ContinueStmt: OnVisitContinueStmt((ContinueStmt)n); break;

            // ---------------- 表达式 ----------------
            case AstNodeType.NullExpr: OnVisitNullExpr((NullExpr)n); break;
            case AstNodeType.BoolExpr: OnVisitBoolExpr((BoolExpr)n); break;
            case AstNodeType.IntExpr: OnVisitIntExpr((IntExpr)n); break;
            case AstNodeType.FloatExpr: OnVisitFloatExpr((FloatExpr)n); break;
            case AstNodeType.BinArrExpr: OnVisitBinArrExpr((BinArrExpr)n); break;
            case AstNodeType.StringExpr: OnVisitStringExpr((StringExpr)n); break;
            case AstNodeType.IdentExpr: OnVisitIdentExpr((IdentExpr)n); break;
            case AstNodeType.ArgcExpr: OnVisitArgcExpr((ArgcExpr)n); break;
            case AstNodeType.ArgsExpr: OnVisitArgsExpr((ArgsExpr)n); break;
            case AstNodeType.UnaryOpExpr: OnVisitUnaryOpExpr((UnaryOpExpr)n); break;
            case AstNodeType.BinaryOpExpr: OnVisitBinaryOpExpr((BinaryOpExpr)n); break;
            case AstNodeType.CallExpr: OnVisitCallExpr((CallExpr)n); break;
            case AstNodeType.AtExpr: OnVisitAtExpr((AtExpr)n); break;
            case AstNodeType.CustomOpcodeExpr: OnVisitCustomOpcodeExpr((CustomOpcodeExpr)n); break;

            default: break; // Node / Stmt / Expr 裸基类：跳过
        }
    }

    // ==================== 子类要重写的钩子 ====================
    public virtual void OnVisitProg(Prog p)
    {
        foreach (var s in p.Stmts) Visit(s);
    }

    // ---------------- 语句 ----------------
    public virtual void OnVisitExprStmt(ExprStmt s) => Visit(s.Expr);

    /// <summary>只走初值：<c>Idents</c> 是名字（字符串列表），不是表达式。</summary>
    public virtual void OnVisitLetStmt(LetStmt s)
    {
        if (s.HasAssign) Visit(s.Expr);
    }

    public virtual void OnVisitReturnStmt(ReturnStmt s)
    {
        foreach (var e in s.Exprs) Visit(e);
    }

    public virtual void OnVisitExportStmt(ExportStmt s) { }

    public virtual void OnVisitBlockStmt(BlockStmt s) => Visit(s.Prog);

    /// <summary>顺序：条件 → 首分支 → 每个 elif（条件 → 块）→ else 块。</summary>
    public virtual void OnVisitIfStmt(IfStmt s)
    {
        Visit(s.Cond);
        Visit(s.FirstProg);
        foreach (var ei in s.Elifs)
        {
            Visit(ei.Cond);
            Visit(ei.Prog);
        }
        if (s.ElseProg is not null) Visit(s.ElseProg);
    }

    public virtual void OnVisitWhileStmt(WhileStmt s)
    {
        Visit(s.Cond); // 条件可省（while { }），Visit(null) 自己会返回
        Visit(s.Prog);
    }

    public virtual void OnVisitAssignStmt(AssignStmt s)
    {
        Visit(s.LeftExpr);
        Visit(s.RightExpr);
    }

    public virtual void OnVisitBreakStmt(BreakStmt s) { }

    public virtual void OnVisitContinueStmt(ContinueStmt s) { }

    // ---------------- 表达式 ----------------
    public virtual void OnVisitNullExpr(NullExpr n) { }

    public virtual void OnVisitBoolExpr(BoolExpr e) { }

    public virtual void OnVisitIntExpr(IntExpr e) { }

    public virtual void OnVisitFloatExpr(FloatExpr e) { }

    public virtual void OnVisitBinArrExpr(BinArrExpr e) { }

    public virtual void OnVisitStringExpr(StringExpr e) { }

    public virtual void OnVisitIdentExpr(IdentExpr e) { }

    public virtual void OnVisitArgcExpr(ArgcExpr n) { }

    public virtual void OnVisitArgsExpr(ArgsExpr e) => Visit(e.KeyExpr); // args[] 的下标缺失时为 null

    public virtual void OnVisitUnaryOpExpr(UnaryOpExpr e) => Visit(e.Expr);

    public virtual void OnVisitBinaryOpExpr(BinaryOpExpr e)
    {
        if (e.Op == TokenType.Or)
        {
            OnVisitOrExpr(e);
            return;
        }
        if (e.Op == TokenType.And)
        {
            OnVisitAndExpr(e);
            return;
        }
        Visit(e.LeftExpr);
        Visit(e.RightExpr);
    }

    /// <summary>短路语义的钩子：默认实现与普通路径等价，需要特判的后端（编译器）自行重写。</summary>
    public virtual void OnVisitOrExpr(BinaryOpExpr e)
    {
        Visit(e.LeftExpr);
        Visit(e.RightExpr);
    }

    public virtual void OnVisitAndExpr(BinaryOpExpr e)
    {
        Visit(e.LeftExpr);
        Visit(e.RightExpr);
    }

    public virtual void OnVisitCallExpr(CallExpr e)
    {
        Visit(e.Callee);
        foreach (var a in e.Args) Visit(a);
    }

    public virtual void OnVisitAtExpr(AtExpr e)
    {
        Visit(e.Container);
        foreach (var k in e.KeyExprs) Visit(k);
    }

    public virtual void OnVisitCustomOpcodeExpr(CustomOpcodeExpr e)
    {
        foreach (var a in e.Args) Visit(a);
    }
}
