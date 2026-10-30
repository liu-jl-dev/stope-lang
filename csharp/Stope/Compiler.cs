using System;
using System.Collections.Generic;

namespace Stope;

/// <summary>
/// 编译器：把 AST 编译成 <see cref="Program"/>（指令流 + 常量池 + 变量表）——
/// 端口 <c>cpp/src/compiler.cpp</c>（C++ 为权威实现）。
/// <para>
/// 【指令流的形状】见 <see cref="Program"/> 的注释。带操作数的指令：
/// <c>PushInt/PushFloat/PushString/PushBinArr/PushValue/PushId</c>（常量池或变量表索引）、
/// <c>Call/At</c>（参数个数）、<c>If/GoTo</c>（跳转目标 = Opcodes 下标）、
/// <c>Return</c>（返回值个数）、自定义指令（变长时多一个参数个数）。
/// </para>
/// <para>
/// 【PushValue 与 PushId 的分工】<c>PushId</c> 压的是槽位引用（左值），<b>只有两处</b>产生：
/// 「有赋值的 let」左侧、<c>Assign</c> 左端是裸标识符时。其余读变量一律 <c>PushValue</c>。
/// 所以执行器<b>不需要</b>在运算指令里做解引用兜底 —— 那样只会掩盖编译器的产物错误。
/// </para>
/// <para>
/// 【遍历骨架】继承 <see cref="AstVisitor"/>：语义动作全在 <c>OnVisitXxx</c> 里。基类默认
/// 实现只是「按源码顺序递归子节点」，这里凡是需要发指令的一律整段重写（不再下钻到 base），
/// 其余靠基类递归。<c>CurLine</c> 由基类维护，没有专属行号的错误就用它。
/// </para>
/// </summary>
public sealed class Compiler : AstVisitor
{
    /// <summary>正在写入的 Program，不拥有。</summary>
    private Program _prog = null!;

    /// <summary>自定义指令表，可空、只读（不拥有）。</summary>
    private CustomOpcodeConfig? _customOpcodes;

    public readonly List<string> Errors = new();

    private VariableAllocator _varAlloc = new();
    private StackSizeManager _stackSizeMgr = new();
    private readonly List<Scope> _scopeStack = new();

    public Compiler(CustomOpcodeConfig? custom = null) => _customOpcodes = custom;

    /// <summary>与 C++ 的 <c>Compiler::Reset</c> 一致：清错误、换自定义指令表。</summary>
    public void Reset(CustomOpcodeConfig? custom = null)
    {
        Errors.Clear();
        _customOpcodes = custom;
    }

    /// <summary>
    /// 编译 <paramref name="ast"/>，结果直接写进 <paramref name="out"/>。有错误时返回
    /// <see cref="Result.Error"/> 并把 <paramref name="out"/> 复原为空 —— 半成品 Program
    /// 跑不了，留着反而误导。
    /// </summary>
    public Result Compile(Prog ast, Program outProg)
    {
        ResetCompile(outProg);
        Visit(ast);
        if (Errors.Count > 0)
        {
            _prog.Clear();
            return Result.Error;
        }
        outProg.VariableNum = _varAlloc.Num();
        outProg.RequiredStackSize = _stackSizeMgr.MaxSize;
        return Result.Success;
    }

    private void ResetCompile(Program outProg)
    {
        Errors.Clear();
        _varAlloc = new VariableAllocator();
        _stackSizeMgr = new StackSizeManager();
        _scopeStack.Clear();
        CurLine = -1;
        _prog = outProg;
        outProg.Clear();
        _scopeStack.Add(new FileScope());
    }

    // ---------------- 指令输出 ----------------
    private int CodeSize() => _prog.Opcodes.Count;

    private void EmitOp(Opcode op) => _prog.Opcodes.Add((int)op);

    private void EmitOp(int op) => _prog.Opcodes.Add(op);

    /// <summary>
    /// 写一个操作数（索引 / 跳转目标）。超出 int16 要报错，否则回绕出来的跳转目标会把
    /// 执行器带飞。
    /// </summary>
    private void EmitIndex(int idx)
    {
        if (idx < short.MinValue || idx > short.MaxValue)
        {
            Error(CurLine, "compile output too large: index exceeds int16. ");
            idx = 0;
        }
        _prog.Opcodes.Add(idx);
    }

    /// <summary>占位：先写 -1，回填时才知道目标。返回该操作数的位置。</summary>
    private int EmitPlaceholder()
    {
        _prog.Opcodes.Add(-1);
        return CodeSize() - 1;
    }

    private void PatchIndex(int pos, int target)
    {
        if (target < short.MinValue || target > short.MaxValue)
        {
            Error(CurLine, "compile output too large: jump target exceeds int16. ");
            target = 0;
        }
        _prog.Opcodes[pos] = target;
    }

    /// <summary>
    /// 常量入池：相同的值只存一份，返回索引。直接写 Program 里那个池子，不给编译器
    /// 再留一份副本。
    /// </summary>
    private static int ConstIndex<T>(List<T> pool, T v)
    {
        for (int i = 0; i < pool.Count; ++i)
            if (SameConst(pool[i], v))
                return i;
        pool.Add(v);
        return pool.Count - 1;
    }

    /// <summary>
    /// 常量池里「值相等」的判据。<c>long</c> / <c>double</c> / <c>string</c> 直接比；
    /// <c>byte[]</c> 必须<b>逐字节</b>比 —— C++ 的 <c>std::find</c> 对
    /// <c>std::vector&lt;char&gt;</c> 是逐元素比较，引用比较会让 <c>'a'</c> 与 <c>'a'</c>
    /// 各占一个槽位，产物与 C++ 不一致。
    /// </summary>
    private static bool SameConst(object? a, object? b)
    {
        if (a is byte[] x && b is byte[] y)
        {
            if (x.Length != y.Length) return false;
            for (int i = 0; i < x.Length; ++i)
                if (x[i] != y[i])
                    return false;
            return true;
        }
        if (a is string sa && b is string sb) return string.Equals(sa, sb, StringComparison.Ordinal);
        return Equals(a, b);
    }

    private void Error(int line, string msg) => Errors.Add("line " + line + ": " + msg);

    // ---------------- 作用域 ----------------
    private BlockScope PushBlockScope()
    {
        var s = new BlockScope();
        _scopeStack.Add(s);
        return s;
    }

    private WhileScope PushWhileScope()
    {
        var s = new WhileScope();
        _scopeStack.Add(s);
        return s;
    }

    private void PopScope() => _scopeStack.RemoveAt(_scopeStack.Count - 1);

    /// <summary>由内向外找最近的名字作用域（<see cref="FileScope"/> 也算，它继承 BlockScope）。</summary>
    private BlockScope? TopBlockScope()
    {
        for (int i = _scopeStack.Count - 1; i >= 0; --i)
            if (_scopeStack[i] is BlockScope bs)
                return bs;
        return null;
    }

    private WhileScope? TopWhileScope()
    {
        for (int i = _scopeStack.Count - 1; i >= 0; --i)
            if (_scopeStack[i] is WhileScope ws)
                return ws;
        return null;
    }

    private BlockScope? FindIdentHost(string name)
    {
        for (int i = _scopeStack.Count - 1; i >= 0; --i)
            if (_scopeStack[i] is BlockScope bs && bs.IdMap.ContainsKey(name))
                return bs;
        return null;
    }

    private FileScope FileScope() => (FileScope)_scopeStack[0];

    // ---------------- 语句 ----------------
    public override void OnVisitProg(Prog p)
    {
        foreach (var s in p.Stmts) Visit(s);
    }

    public override void OnVisitExprStmt(ExprStmt s)
    {
        Visit(s.Expr);
        EmitOp(Opcode.Pop);
        _stackSizeMgr.Dec();
    }

    public override void OnVisitLetStmt(LetStmt s)
    {
        var bs = TopBlockScope();
        if (bs is null) return;
        if (s.HasAssign)
        {
            // let a = expr; —— 只有一个标识符
            if (s.Idents.Count == 0) return;
            string name = s.Idents[0];
            if (bs.IdMap.ContainsKey(name))
            {
                Error(s.Line, "duplicate declaration of '" + name + "'. ");
                return;
            }
            // 不要 Visit 标识符本身（那会生成 PushValue 取值），这里是要绑定到新变量
            int idx = _varAlloc.NewVar();
            bs.IdMap[name] = idx;
            EmitOp(Opcode.PushId);
            EmitIndex(idx);
            _stackSizeMgr.Inc();
            Visit(s.Expr);
            EmitOp(Opcode.Assign);
            _stackSizeMgr.Dec(2);
        }
        else
        {
            foreach (var nm in s.Idents)
            {
                if (bs.IdMap.ContainsKey(nm))
                {
                    Error(s.Line, "duplicate declaration of '" + nm + "'. ");
                    continue;
                }
                bs.IdMap[nm] = _varAlloc.NewVar();
            }
        }
    }

    public override void OnVisitReturnStmt(ReturnStmt s)
    {
        foreach (var e in s.Exprs) Visit(e);
        EmitOp(Opcode.Return);
        EmitIndex(s.Exprs.Count);
        _prog.MaxReturnNum = Math.Max(_prog.MaxReturnNum, s.Exprs.Count);
        // Return 会让执行器直接跳到指令流末尾，栈上的返回值不回收
    }

    public override void OnVisitExportStmt(ExportStmt s)
    {
        if (_scopeStack.Count > 1) Error(s.Line, "\"export\" can only be used at top scope. ");
        var fs = FileScope();
        foreach (var id in s.Idents)
        {
            if (fs.IdMap.ContainsKey(id))
            {
                Error(s.Line, "duplicate export of \"" + id + "\". ");
                continue;
            }
            DeclareExported(id, _varAlloc.NewUniqueVar(id));
        }
    }

    public override void OnVisitBlockStmt(BlockStmt s)
    {
        var bs = PushBlockScope();
        Visit(s.Prog);
        PopScope();
        foreach (var idx in bs.IdMap.Values) _varAlloc.FreeVar(idx); // 回收局部变量索引
    }

    public override void OnVisitIfStmt(IfStmt s)
    {
        if (s.Cond is null) return;
        var gotoEndIndices = new List<int>();
        Visit(s.Cond);
        EmitOp(Opcode.If);
        _stackSizeMgr.Dec();
        int lastIfPos = EmitPlaceholder(); // 条件为假时跳到这里
        VisitBodyAsBlock(s.FirstProg);
        EmitOp(Opcode.GoTo); // 分支走完，跳出整个 if
        gotoEndIndices.Add(EmitPlaceholder());
        PatchIndex(lastIfPos, CodeSize());
        foreach (var ei in s.Elifs)
        {
            if (ei.Cond is null) continue;
            Visit(ei.Cond);
            EmitOp(Opcode.If);
            _stackSizeMgr.Dec();
            lastIfPos = EmitPlaceholder();
            VisitBodyAsBlock(ei.Prog);
            EmitOp(Opcode.GoTo);
            gotoEndIndices.Add(EmitPlaceholder());
            PatchIndex(lastIfPos, CodeSize());
        }
        if (s.ElseProg is not null) VisitBodyAsBlock(s.ElseProg);
        foreach (var pos in gotoEndIndices) PatchIndex(pos, CodeSize());
    }

    public override void OnVisitWhileStmt(WhileStmt s)
    {
        var ws = PushWhileScope();
        ws.StartIndex = CodeSize(); // continue 回到这里
        int caseGotoEndPos = -1;
        if (s.Cond is not null)
        {
            // while cond { } —— cond 可省
            Visit(s.Cond);
            EmitOp(Opcode.If);
            _stackSizeMgr.Dec();
            caseGotoEndPos = EmitPlaceholder();
        }
        VisitBodyAsBlock(s.Prog);
        EmitOp(Opcode.GoTo);
        EmitIndex(ws.StartIndex);
        foreach (var pos in ws.BreakIndices) PatchIndex(pos, CodeSize());
        // 条件可省。无条件时必须跳过回填，否则会把第 0 条指令改成跳转目标。
        if (caseGotoEndPos >= 0) PatchIndex(caseGotoEndPos, CodeSize());
        PopScope();
    }

    public override void OnVisitAssignStmt(AssignStmt s)
    {
        if (s.LeftExpr is null || s.RightExpr is null) return;
        if (s.LeftExpr.NodeType == AstNodeType.IdentExpr)
        {
            // 赋值左端的裸标识符要压【槽位】而不是值，否则 Assign 无处可存。
            // 这条与 OnVisitIdentExpr 的 PushValue 是一对：只有这里和
            // 「有赋值的 let」会产生 PushId。
            int idx = IdentSlot(((IdentExpr)s.LeftExpr).Ident);
            EmitOp(Opcode.PushId);
            EmitIndex(idx);
            _stackSizeMgr.Inc();
        }
        else
        {
            // 可能是使用者设计的数组元素引用、对象成员引用等。压入值。
            Visit(s.LeftExpr);
        }
        Visit(s.RightExpr);
        EmitOp(Opcode.Assign);
        _stackSizeMgr.Dec(2);
    }

    public override void OnVisitBreakStmt(BreakStmt s)
    {
        var ws = TopWhileScope();
        if (ws is null)
        {
            Error(s.Line, "cannot use \"break\" outside of a loop. ");
            return;
        }
        EmitOp(Opcode.GoTo);
        ws.BreakIndices.Add(EmitPlaceholder());
    }

    public override void OnVisitContinueStmt(ContinueStmt s)
    {
        var ws = TopWhileScope();
        if (ws is null)
        {
            Error(s.Line, "cannot use \"continue\" outside of a loop. ");
            return;
        }
        EmitOp(Opcode.GoTo);
        EmitIndex(ws.StartIndex);
    }

    // ---------------- 表达式 ----------------
    public override void OnVisitNullExpr(NullExpr n)
    {
        EmitOp(Opcode.PushNull);
        _stackSizeMgr.Inc();
    }

    public override void OnVisitBoolExpr(BoolExpr e)
    {
        EmitOp(e.Value ? Opcode.PushTrue : Opcode.PushFalse);
        _stackSizeMgr.Inc();
    }

    public override void OnVisitIntExpr(IntExpr e)
    {
        EmitOp(Opcode.PushInt);
        EmitIndex(ConstIndex(_prog.IntConsts, e.Value));
        _stackSizeMgr.Inc();
    }

    public override void OnVisitFloatExpr(FloatExpr e)
    {
        EmitOp(Opcode.PushFloat);
        EmitIndex(ConstIndex(_prog.FloatConsts, e.Value));
        _stackSizeMgr.Inc();
    }

    public override void OnVisitStringExpr(StringExpr e)
    {
        EmitOp(Opcode.PushString);
        EmitIndex(ConstIndex(_prog.StringConsts, e.Value));
        _stackSizeMgr.Inc();
    }

    public override void OnVisitBinArrExpr(BinArrExpr e)
    {
        EmitOp(Opcode.PushBinArr);
        EmitIndex(ConstIndex(_prog.BinArrConsts, e.Value));
        _stackSizeMgr.Inc();
    }

    public override void OnVisitIdentExpr(IdentExpr e)
    {
        int idx = IdentSlot(e.Ident);
        EmitOp(Opcode.PushValue); // 压的是变量的【值】；要槽位请用 PushId
        EmitIndex(idx);
        _stackSizeMgr.Inc();
    }

    public override void OnVisitArgcExpr(ArgcExpr n)
    {
        EmitOp(Opcode.ArgNum);
        _stackSizeMgr.Inc();
    }

    public override void OnVisitArgsExpr(ArgsExpr e)
    {
        Visit(e.KeyExpr);
        EmitOp(Opcode.GetArg); // 弹下标、压结果，栈大小不变
    }

    public override void OnVisitUnaryOpExpr(UnaryOpExpr e)
    {
        Visit(e.Expr);
        if (e.Op == TokenType.Not) EmitOp(Opcode.Not);
        else if (e.Op == TokenType.Sub) EmitOp(Opcode.Minus);
        // 一元指令：弹 1 压 1，栈大小不变
    }

    public override void OnVisitBinaryOpExpr(BinaryOpExpr e)
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
        EmitOp(BinaryOpcode(e.Op));
        _stackSizeMgr.Dec(); // 弹 2 压 1
    }

    /// <summary>短路或：任一侧为真就 PushTrue，两条路径都在栈上留下恰好 1 个结果。</summary>
    public override void OnVisitOrExpr(BinaryOpExpr e)
    {
        Visit(e.LeftExpr);
        EmitOp(Opcode.If);
        _stackSizeMgr.Dec();
        int firstIfPos = EmitPlaceholder();
        int depthAtIfTarget = _stackSizeMgr.Size; // If 已弹掉条件 = 汇合点深度
        EmitOp(Opcode.PushTrue);
        _stackSizeMgr.Inc();
        EmitOp(Opcode.GoTo);
        int gotoEnd1 = EmitPlaceholder();
        PatchIndex(firstIfPos, CodeSize());
        _stackSizeMgr.Converge(depthAtIfTarget); // 后面接的是「左侧为假」这条路径

        Visit(e.RightExpr);
        EmitOp(Opcode.If);
        _stackSizeMgr.Dec();
        int secondIfPos = EmitPlaceholder();
        depthAtIfTarget = _stackSizeMgr.Size;
        EmitOp(Opcode.PushTrue);
        _stackSizeMgr.Inc();
        EmitOp(Opcode.GoTo);
        int gotoEnd2 = EmitPlaceholder();
        PatchIndex(secondIfPos, CodeSize());
        _stackSizeMgr.Converge(depthAtIfTarget);

        EmitOp(Opcode.PushFalse); // 两侧都不成立
        _stackSizeMgr.Inc();
        PatchIndex(gotoEnd1, CodeSize());
        PatchIndex(gotoEnd2, CodeSize());
    }

    public override void OnVisitAndExpr(BinaryOpExpr e)
    {
        Visit(e.LeftExpr);
        EmitOp(Opcode.If);
        _stackSizeMgr.Dec();
        int firstIfPos = EmitPlaceholder();
        Visit(e.RightExpr);
        EmitOp(Opcode.If);
        _stackSizeMgr.Dec();
        int secondIfPos = EmitPlaceholder();
        int depthAtIfTarget = _stackSizeMgr.Size; // 两侧都为真才落到这里
        EmitOp(Opcode.PushTrue);
        _stackSizeMgr.Inc();
        EmitOp(Opcode.GoTo);
        int gotoEnd = EmitPlaceholder();
        PatchIndex(firstIfPos, CodeSize());
        PatchIndex(secondIfPos, CodeSize());
        _stackSizeMgr.Converge(depthAtIfTarget);
        EmitOp(Opcode.PushFalse);
        _stackSizeMgr.Inc();
        PatchIndex(gotoEnd, CodeSize());
    }

    public override void OnVisitCallExpr(CallExpr e)
    {
        Visit(e.Callee);
        foreach (var a in e.Args) Visit(a);
        EmitOp(Opcode.Call);
        EmitIndex(e.Args.Count);
        _stackSizeMgr.Dec(e.Args.Count); // callee + args 换成 1 个返回值
    }

    public override void OnVisitAtExpr(AtExpr e)
    {
        Visit(e.Container);
        foreach (var k in e.KeyExprs) Visit(k);
        EmitOp(Opcode.At);
        EmitIndex(e.KeyExprs.Count);
        _stackSizeMgr.Dec(e.KeyExprs.Count);
    }

    public override void OnVisitCustomOpcodeExpr(CustomOpcodeExpr e)
    {
        if (_customOpcodes is null || !_customOpcodes.Opcodes.TryGetValue(e.OpcodeName, out var info))
        {
            Error(e.Line, "undefined custom opcode \"" + e.OpcodeName + "\". ");
            return;
        }
        bool isVarArg = info.IsVarArg; // 与 C++ 的 isVarArg 同一判据（argNum < 0）
        if (!isVarArg && info.ArgNum != e.Args.Count)
        {
            Error(e.Line, "custom opcode \"" + e.OpcodeName + "\" expected " + info.ArgNum
                          + " args, but got " + e.Args.Count + ". ");
        }
        foreach (var a in e.Args) Visit(a);
        EmitOp(info.Opcode);
        if (isVarArg) EmitIndex(e.Args.Count);
        // 自定义指令没有 callee 入栈，结果仍占 1 格 => dec(参数个数 - 1)
        _stackSizeMgr.Dec(e.Args.Count - 1);
    }

    // ---------------- 小工具 ----------------
    /// <summary>
    /// 标识符 → 变量槽位索引。没声明过就当作外部变量，登记到文件作用域（名字非空正是
    /// <see cref="Program.Exports"/> 的判据）。<c>PushValue</c> / <c>PushId</c> 共用这一处查找。
    /// </summary>
    private int IdentSlot(string name)
    {
        var host = FindIdentHost(name);
        if (host is not null) return host.IdMap[name];
        DeclareExported(name, _varAlloc.NewUniqueVar(name));
        return FileScope().IdMap[name];
    }

    /// <summary>登记一个会进 <see cref="Program.Exports"/> 的变量。索引来自 NewUniqueVar（不回收）。</summary>
    private void DeclareExported(string name, int idx)
    {
        FileScope().IdMap[name] = idx;
        _prog.Exports[name] = idx;
    }

    /// <summary>
    /// 块 / if 分支 / 循环体在 AST 里都是裸 <see cref="Prog"/>（没有 BlockStmt 包着），
    /// 这里补一层 <see cref="BlockScope"/>，让内部 let 的变量在离开时被回收。
    /// </summary>
    private void VisitBodyAsBlock(Prog p)
    {
        var bs = PushBlockScope();
        Visit(p);
        PopScope();
        foreach (var idx in bs.IdMap.Values) _varAlloc.FreeVar(idx);
    }

    /// <summary>二元运算符 → 指令。注意二元 <c>-</c> 是 Sub 而不是 Minus。</summary>
    private static Opcode BinaryOpcode(TokenType op) => op switch
    {
        TokenType.EQ => Opcode.EQ,
        TokenType.NE => Opcode.NE,
        TokenType.LT => Opcode.LT,
        TokenType.LE => Opcode.LE,
        TokenType.GT => Opcode.GT,
        TokenType.GE => Opcode.GE,
        TokenType.Add => Opcode.Add,
        TokenType.Sub => Opcode.Sub,
        TokenType.Mul => Opcode.Mul,
        TokenType.Div => Opcode.Div,
        TokenType.IDiv => Opcode.IDiv,
        TokenType.Mod => Opcode.Mod,
        TokenType.Pow => Opcode.Pow,
        _ => Opcode.Pop, // 到不了：parser 只会用上面这些 op 构造 BinaryOpExpr
    };
}

// ====================================================================
// 作用域
/// <summary>作用域基类。只有 <see cref="BlockScope"/> 参与名字查找。</summary>
public abstract class Scope
{
    public enum Kind
    {
        File,
        Block,
        While,
    }

    public Kind ScopeKind;

    protected Scope(Kind k) => ScopeKind = k;
}

/// <summary>名字作用域：标识符 → 变量总表中的索引。</summary>
public class BlockScope : Scope
{
    public readonly Dictionary<string, int> IdMap = new();

    public BlockScope() : base(Kind.Block) { }
}

/// <summary>文件作用域。<c>export</c> 与「未声明就使用的标识符」都落到这里。</summary>
public sealed class FileScope : BlockScope
{
    public FileScope()
    {
        ScopeKind = Kind.File;
    }
}

/// <summary>循环作用域：不参与名字查找（<see cref="Compiler.FindIdentHost"/> 只认 BlockScope）。</summary>
public sealed class WhileScope : Scope
{
    /// <summary><c>continue</c> 跳回这里（循环开头）。</summary>
    public int StartIndex;

    /// <summary>待回填的 <c>break</c> 跳转目标（Opcodes 里的操作数位置）。</summary>
    public readonly List<int> BreakIndices = new();

    public WhileScope() : base(Kind.While) { }
}

/// <summary>
/// 最小堆：变量索引回收用，保证总是复用最小的空位（与 C++ 的
/// <c>std::priority_queue</c> 配 <c>greater</c> 一样，产出的槽位编号可预测、可比对）。
/// </summary>
public sealed class MinHeap
{
    private readonly List<int> _data = new() { 0 }; // 1 起算，方便算父子下标
    private int _count;

    public bool IsEmpty() => _count == 0;

    public void Push(int v)
    {
        _data.Add(v);
        _count += 1;
        PercUp(_count);
    }

    public int Pop()
    {
        int o = _data[1];
        _data[1] = _data[_count];
        _data.RemoveAt(_count);
        _count -= 1;
        PercDown(1);
        return o;
    }

    public bool Has(int v)
    {
        for (int i = 1; i <= _count; ++i)
            if (_data[i] == v)
                return true;
        return false;
    }

    private int MinChildId(int i)
    {
        int l = i * 2;
        int r = l + 1;
        if (r > _count) return l;
        return _data[l] < _data[r] ? l : r;
    }

    private void Swap(int a, int b) => (_data[a], _data[b]) = (_data[b], _data[a]);

    private void PercUp(int i)
    {
        int now = i;
        int next = i / 2;
        while (next > 0)
        {
            if (_data[now] < _data[next]) Swap(now, next);
            now = next;
            next /= 2;
        }
    }

    private void PercDown(int i)
    {
        while (i * 2 < _count)
        {
            int c = MinChildId(i);
            if (_data[i] > _data[c]) Swap(i, c);
            i = c;
        }
    }
}

/// <summary>
/// 变量分配器：所有变量统一编号；块结束时索引进入回收堆复用。
/// <para>
/// <see cref="NewUniqueVar"/> 不参与回收 —— 它给 <c>export</c> 与「未声明就使用的标识符」用，
/// 变量名非空正是 <see cref="Program.Exports"/> 的判据。
/// </para>
/// </summary>
public sealed class VariableAllocator
{
    private readonly List<string> _vars = new();
    private readonly MinHeap _recycled = new();

    public int Num() => _vars.Count;

    public int NewVar(string name = "")
    {
        if (!_recycled.IsEmpty())
        {
            int idx = _recycled.Pop();
            _vars[idx] = name;
            return idx;
        }
        int i = _vars.Count;
        _vars.Add(name);
        return i;
    }

    public int NewUniqueVar(string name)
    {
        int i = _vars.Count;
        _vars.Add(name); // 不回收：导出变量必须一直占着一个位置
        return i;
    }

    public void FreeVar(int idx)
    {
        if (_recycled.Has(idx)) return; // 同一索引不重复回收
        _recycled.Push(idx);
    }
}

/// <summary>
/// 只记「相对变化」，最大值最后落到 <see cref="Program.RequiredStackSize"/>。
/// <para>
/// 记账是<b>线性</b>的（按 emit 顺序走一遍），遇到分支就得手动「掰回去」——
/// 见 <see cref="Converge"/>。
/// </para>
/// </summary>
public sealed class StackSizeManager
{
    public int Size;
    public int MaxSize;

    public void Inc(int n = 1)
    {
        Size += n;
        if (Size > MaxSize) MaxSize = Size;
    }

    public void Dec(int n = 1) => Size -= n;

    /// <summary>
    /// 分支汇合。线性记账只能沿一条路径走，所以某条路径被 GoTo 送走以后，要把 Size
    /// 扳回到「从别处跳到这里」时应有的深度，否则 if / 短路运算符会把容量算成各分支
    /// 深度之和（实测 <c>a or b;</c> 会算成 3）。
    /// </summary>
    public void Converge(int depth) => Size = depth;
}
