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

    /// <summary>
    /// 全局声明序号：declareLocal / declareExported（非隐式）时 +1，跨 scope 可比。
    /// defer 的「冻结名字绑定」基线 = 登记时的当前值。
    /// </summary>
    private int _declCounter;

    /// <summary>
    /// defer 载荷编译期状态：当前生效的声明序号基线（&lt; 0 = 不在拼接中）与
    /// 「declared after」错误的归责行号（defer 语句行）。
    /// </summary>
    private int _deferOrderFloor = -1;
    private int _deferErrLine = -1;

    /// <summary>
    /// 死代码消除：最后一条已访问语句是否必然退出当前序列（return / break /
    /// continue / 无条件死循环）。四个消费点见 OnVisitProg / OnVisitWhileStmt /
    /// OnVisitIfStmt / 块尾与程序尾的 defer 最终结算。
    /// </summary>
    private bool _stmtTerminates;

    /// <summary>最内层 while 的循环体里是否出现过 break（死循环判定用），按 while 配对保存/恢复。</summary>
    private bool _sawBreak;

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
    /// <param name="preExports">
    /// 遍历 AST 之前先导出的标识符（宿主注入的全局）。每个名字按给定顺序占一个
    /// 「永不回收」的槽位，所以源码里所有变量的编号整体后移；名字进了文件作用域，
    /// 源码里再 <c>export</c> 同名、或顶层 <c>let</c> 同名，都会报 duplicate ——
    /// 预导出的变量只能赋值。空名字与重名都是编译错误（行号记 0：这些名字不来自源码）。
    /// </param>
    public Result Compile(Prog ast, Program outProg, IReadOnlyList<string>? preExports = null)
    {
        ResetCompile(outProg);
        ExportPreExports(preExports);
        Visit(ast);
        // 顶层 defer：程序尾结算。程序以终止语句（return / 死循环等）结尾时
        // 这里不可达（return 出口已在 OnVisitReturnStmt 结算过），再拼就是
        // Return 之后的死代码——跳过；自然结束（fall-through）才需要这份结算。
        if (!_stmtTerminates) SpliceDefers(FileScope());
        FileScope().Defers.Clear(); // 最终结算：途中出口（return）已各拼过副本
        if (Errors.Count > 0)
        {
            _prog.Clear();
            return Result.Error;
        }
        outProg.VariableNum = _varAlloc.Num();
        outProg.RequiredStackSize = _stackSizeMgr.MaxSize;
        return Result.Success;
    }

    /// <summary>
    /// 预导出：必须在 <see cref="ResetCompile"/> 之后调用（reset 会重建分配器、清空 exports）。
    /// 走 NewUniqueVar，并且先于源码里任何变量分配 —— 这一步定了整个程序的槽位编号。
    /// </summary>
    private void ExportPreExports(IReadOnlyList<string>? names)
    {
        if (names == null) return;
        var fs = FileScope();
        foreach (var n in names)
        {
            // 行号记 0：这些名字不来自源码，硬套 CurLine（此刻是 -1）只会误导
            if (string.IsNullOrEmpty(n))
            {
                Error(0, "empty name in pre-exports. ");
                continue;
            }
            if (fs.IdMap.ContainsKey(n))
            {
                Error(0, "duplicate export of \"" + n + "\". ");
                continue;
            }
            DeclareExported(n, _varAlloc.NewUniqueVar(n));
        }
    }

    private void ResetCompile(Program outProg)
    {
        Errors.Clear();
        _varAlloc = new VariableAllocator();
        _stackSizeMgr = new StackSizeManager();
        _scopeStack.Clear();
        CurLine = -1;
        _declCounter = 0;
        _deferOrderFloor = -1;
        _deferErrLine = -1;
        _stmtTerminates = false;
        _sawBreak = false;
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

    private BlockScope? FindIdentHost(string name)
    {
        for (int i = _scopeStack.Count - 1; i >= 0; --i)
            if (_scopeStack[i] is BlockScope bs && bs.IdMap.ContainsKey(name))
                return bs;
        return null;
    }

    /// <summary>
    /// defer 拼接期的名字查找（冻结绑定）：<paramref name="floor"/> 是 defer
    /// 登记时的声明序号基线。最内层载荷根以内（栈中更靠内）是载荷自己的内部
    /// 作用域，名字解析不过滤；它以外跳过「声明序号 &gt;= 基线」的本地名 ——
    /// 基线 = 登记时的 declCounter（= 下一个待分配序号），所以「序号 &gt;= 基线」
    /// ⟺ 在 defer 之后声明。隐式导出记 -1，豁免检查。
    /// </summary>
    private BlockScope? FindIdentHostFrozen(string name, int floor)
    {
        int payloadIdx = -1;
        for (int i = _scopeStack.Count - 1; i >= 0; --i)
            if (_scopeStack[i] is BlockScope b && b.IsDeferPayload)
            {
                payloadIdx = i;
                break;
            }
        for (int i = _scopeStack.Count - 1; i >= 0; --i)
        {
            if (_scopeStack[i] is not BlockScope bs) continue;
            if (!bs.IdMap.ContainsKey(name)) continue;
            if (i < payloadIdx)
            {
                // 登记 scope 一侧：跳过 defer 之后才声明的（遮蔽）
                if (bs.IdOrder.TryGetValue(name, out int o) && o >= 0 && o >= floor)
                    continue;
            }
            return bs;
        }
        return null;
    }

    /// <summary>
    /// 拼接期间的名字解析（冻结绑定）：名字→槽位按 defer 语句位置的词法作用域。
    /// 冻结找不到但当前找得到 = 后文声明 → 报错（行号归 defer 语句），按当前绑定
    /// 继续（编译已失败）。都空 → 返回 null，走隐式导出路径。
    /// </summary>
    private BlockScope? ResolveAtSplice(string name)
    {
        var now = FindIdentHost(name);
        var frozen = FindIdentHostFrozen(name, _deferOrderFloor);
        if (frozen is not null) return frozen;
        if (now is not null)
            Error(_deferErrLine, "\"" + name + "\" is declared after the defer statement. ");
        return now;
    }

    /// <summary>
    /// 退出点结算：逆序拼接 <paramref name="bs"/> 登记的 defer 载荷（LIFO），
    /// 每个载荷包一层 IsDeferPayload 的隐式作用域，载荷 scope 自己的 defers
    /// 就地递归拼接（直接嵌套 defer defer X 落在这里）。
    /// <para>
    /// ⚠ 不清空 bs.Defers：一个块可以有多个运行期出口（break / continue /
    /// return 各一处 + 块尾），每个出口都要拼一份自己的副本；只有块尾 /
    /// 程序尾的「最终结算」由调用方在拼接后清空。
    /// </para>
    /// </summary>
    private void SpliceDefers(BlockScope bs)
    {
        if (bs.Defers.Count == 0 || Errors.Count > 0)
            return; // 错误去重：载荷在每个退出点重编译，报一次就够
        for (int k = bs.Defers.Count - 1; k >= 0; --k)
        {
            if (Errors.Count > 0)
                return; // 某个载荷编译出错即停，不再拼后续
            Deferred d = bs.Defers[k];
            int savedFloor = _deferOrderFloor;
            int savedLine = _deferErrLine;
            _deferOrderFloor = d.OrderBaseline;
            _deferErrLine = d.Line;
            // 载荷包一层隐式作用域并打标记：break/continue/return 的越界检查
            // 靠它识别「从收尾代码里跳回主流程」。
            var ps = PushBlockScope();
            ps.IsDeferPayload = true;
            Visit(d.Stmt);
            SpliceDefers(ps);
            PopScope();
            foreach (var idx in ps.IdMap.Values) _varAlloc.FreeVar(idx);
            _deferOrderFloor = savedFloor;
            _deferErrLine = savedLine;
        }
    }

    /// <summary>登记一个块内局部名，并占用一个全局声明序号（defer 冻结绑定的基线来源）。</summary>
    private void DeclareLocal(BlockScope bs, string name, int idx)
    {
        bs.IdMap[name] = idx;
        bs.IdOrder[name] = _declCounter++;
    }

    private FileScope FileScope() => (FileScope)_scopeStack[0];

    // ---------------- 语句 ----------------
    public override void OnVisitProg(Prog p)
    {
        // 语句序列：终止语句（return / break / continue / 死循环）之后的语句
        // 在语言语义下执行不到——不再发射，也不登记它们的 defer（死代码消除）。
        // 序列的终止性 = 最后一条已发射语句。
        bool terminated = false;
        foreach (var s in p.Stmts)
        {
            if (terminated) break;
            _stmtTerminates = false; // 每条语句先清零；终止语句的 visitor 置 true
            Visit(s);
            terminated = _stmtTerminates;
        }
        _stmtTerminates = terminated;
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
            DeclareLocal(bs, name, idx);
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
                DeclareLocal(bs, nm, _varAlloc.NewVar());
            }
        }
    }

    public override void OnVisitReturnStmt(ReturnStmt s)
    {
        // defer 边界：return 的终点是整个程序，在载荷内必然越界，一律报错。
        foreach (var sc in _scopeStack)
            if (sc is BlockScope b && b.IsDeferPayload)
            {
                Error(s.Line, "\"return\" cannot be used in a defer statement. ");
                return;
            }
        // 顺序：先结算，再求返回值，最后 Return（结算 → PushValue → Return）。
        // 结算先于退出动作，与块退出一致——defer 可以影响返回值。
        for (int i = _scopeStack.Count - 1; i >= 0; --i)
            if (_scopeStack[i] is BlockScope bs) SpliceDefers(bs);
        foreach (var e in s.Exprs) Visit(e);
        EmitOp(Opcode.Return);
        EmitIndex(s.Exprs.Count);
        _prog.MaxReturnNum = Math.Max(_prog.MaxReturnNum, s.Exprs.Count);
        _stmtTerminates = true;
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
        // 块尾结算：本 scope 的 defer 在这里执行（LIFO）。块体以终止语句结尾时
        // 这里不可达（return 出口已结算、break/continue 出口就地结算过）——
        // 跳过，避免拼出不可达的副本。
        if (!_stmtTerminates) SpliceDefers(bs);
        bs.Defers.Clear(); // 最终结算：途中出口（break/return）已各拼过副本
        PopScope();
        foreach (var idx in bs.IdMap.Values) _varAlloc.FreeVar(idx); // 回收局部变量索引
    }

    public override void OnVisitIfStmt(IfStmt s)
    {
        if (s.Cond is null) return;
        var gotoEndIndices = new List<int>();
        bool allBranchesTerminate = true;
        bool hasElse = false;
        Visit(s.Cond);
        EmitOp(Opcode.If);
        _stackSizeMgr.Dec();
        int lastIfPos = EmitPlaceholder(); // 条件为假时跳到这里
        VisitBodyAsBlock(s.FirstProg);
        bool branchTerm = _stmtTerminates;
        allBranchesTerminate = allBranchesTerminate && branchTerm;
        if (!branchTerm)
        {
            // 分支走完会落到这里，需要跳出整个 if；终止则死代码
            EmitOp(Opcode.GoTo);
            gotoEndIndices.Add(EmitPlaceholder());
        }
        PatchIndex(lastIfPos, CodeSize());
        foreach (var ei in s.Elifs)
        {
            if (ei.Cond is null) continue;
            Visit(ei.Cond);
            EmitOp(Opcode.If);
            _stackSizeMgr.Dec();
            lastIfPos = EmitPlaceholder();
            VisitBodyAsBlock(ei.Prog);
            branchTerm = _stmtTerminates;
            allBranchesTerminate = allBranchesTerminate && branchTerm;
            if (!branchTerm)
            {
                EmitOp(Opcode.GoTo);
                gotoEndIndices.Add(EmitPlaceholder());
            }
            PatchIndex(lastIfPos, CodeSize());
        }
        hasElse = s.ElseProg is not null;
        if (hasElse) VisitBodyAsBlock(s.ElseProg!);
        else allBranchesTerminate = false; // 无 else：条件全假时落到 if 之后
        foreach (var pos in gotoEndIndices) PatchIndex(pos, CodeSize());
        // if 语句的终止性：else 存在且所有分支终止（组合式，逐分支局部判断）
        _stmtTerminates = hasElse && allBranchesTerminate;
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
        // sawBreak 按 while 配对保存/恢复：嵌套循环里的 break 只算最内层的
        bool savedSawBreak = _sawBreak;
        _sawBreak = false;
        VisitBodyAsBlock(s.Prog);
        bool bodyTerm = _stmtTerminates;
        bool bodySawBreak = _sawBreak;
        _sawBreak = savedSawBreak;
        if (!bodyTerm)
        {
            // 体终止（return/break/continue 收尾）则回跳是死代码
            EmitOp(Opcode.GoTo);
            EmitIndex(ws.StartIndex);
        }
        foreach (var pos in ws.BreakIndices) PatchIndex(pos, CodeSize());
        // 条件可省。无条件时必须跳过回填，否则会把第 0 条指令改成跳转目标。
        if (caseGotoEndPos >= 0) PatchIndex(caseGotoEndPos, CodeSize());
        // while 的终止性：只有「无条件 + 体不含本层 break」的真死循环才永不
        // 退出。`while true { }` 带条件，按可退出处理（用户明确要求），不视同
        // `while { }`。
        _stmtTerminates = s.Cond is null && !bodySawBreak;
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
        // 找最内层 WhileScope。途中先撞到 defer 载荷边界 = 目标循环在载荷外：
        // 载荷在退出点才执行，break 从收尾代码里跳回主流程是灾难语义，禁。
        int wi = -1;
        for (int i = _scopeStack.Count - 1; i >= 0; --i)
        {
            Scope sc = _scopeStack[i];
            if (sc is WhileScope)
            {
                wi = i;
                break;
            }
            if (sc is BlockScope b && b.IsDeferPayload)
            {
                Error(s.Line, "\"break\" cannot cross a defer statement. ");
                return;
            }
        }
        if (wi < 0)
        {
            Error(s.Line, "cannot use \"break\" outside of a loop. ");
            return;
        }
        // 结算 break 越过的所有块：从最内层到循环体块（不含 WhileScope 本身、
        // 不含循环外的任何 scope）。运行时 break 直接跳循环尾，这些块的正常
        // 块尾拼接不会执行到，必须在跳转前就地结算。
        for (int i = _scopeStack.Count - 1; i > wi; --i)
            if (_scopeStack[i] is BlockScope bs) SpliceDefers(bs);
        EmitOp(Opcode.GoTo);
        ((WhileScope)_scopeStack[wi]).BreakIndices.Add(EmitPlaceholder());
        _sawBreak = true; // 告知最内层 while：本层有 break（死循环判定用）
        _stmtTerminates = true;
    }

    public override void OnVisitContinueStmt(ContinueStmt s)
    {
        // 同 break：continue 也退出循环体块，体块的 defer 必须先结算。
        int wi = -1;
        for (int i = _scopeStack.Count - 1; i >= 0; --i)
        {
            Scope sc = _scopeStack[i];
            if (sc is WhileScope)
            {
                wi = i;
                break;
            }
            if (sc is BlockScope b && b.IsDeferPayload)
            {
                Error(s.Line, "\"continue\" cannot cross a defer statement. ");
                return;
            }
        }
        if (wi < 0)
        {
            Error(s.Line, "cannot use \"continue\" outside of a loop. ");
            return;
        }
        for (int i = _scopeStack.Count - 1; i > wi; --i)
            if (_scopeStack[i] is BlockScope bs) SpliceDefers(bs);
        EmitOp(Opcode.GoTo);
        EmitIndex(((WhileScope)_scopeStack[wi]).StartIndex);
        _stmtTerminates = true;
    }

    public override void OnVisitDeferStmt(DeferStmt s)
    {
        var bs = TopBlockScope();
        if (bs is null) return; // 不可能：FileScope 常驻栈底
        // 纯编译期登记，defer 语句位置零指令。载荷在退出点才编译（每个退出点
        // 各编译一次——If/GoTo 操作数是绝对下标，编译一次再拷贝会破坏跳转目标）。
        bs.Defers.Add(new Deferred(s.Stmt, s.Line, _declCounter));
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
    /// defer 载荷编译期（<c>_deferOrderFloor &gt;= 0</c>）走冻结名字绑定规则。
    /// </summary>
    private int IdentSlot(string name)
    {
        var host = _deferOrderFloor >= 0 ? ResolveAtSplice(name) : FindIdentHost(name);
        if (host is not null) return host.IdMap[name];
        DeclareExported(name, _varAlloc.NewUniqueVar(name), implicitExport: true);
        return FileScope().IdMap[name];
    }

    /// <summary>
    /// 登记一个会进 <see cref="Program.Exports"/> 的变量。索引来自 NewUniqueVar（不回收）。
    /// implicitExport=true（从未声明就使用的宿主变量）：名字记序号 -1，
    /// 豁免 defer 的冻结绑定检查——它不是本地槽位。
    /// </summary>
    private void DeclareExported(string name, int idx, bool implicitExport = false)
    {
        var fs = FileScope();
        fs.IdMap[name] = idx;
        fs.IdOrder[name] = implicitExport ? -1 : _declCounter++;
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
        // 块尾结算（if 分支 / 循环体同普通块）。体以终止语句结尾时这里不可达，
        // 跳过——出口结算（return / break / continue）已就地拼过副本。
        if (!_stmtTerminates) SpliceDefers(bs);
        bs.Defers.Clear(); // 最终结算
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

    /// <summary>
    /// 名字 → 声明序号（<see cref="Compiler"/> 的全局 declCounter 值，跨 scope 可比）。
    /// defer 的「冻结名字绑定」靠它判定：载荷解析到的本地名字若序号晚于
    /// defer 语句处的基线，报 "declared after the defer statement."。
    /// 隐式导出（从未声明的宿主变量）记 -1，豁免检查。
    /// </summary>
    public readonly Dictionary<string, int> IdOrder = new();

    /// <summary>defer 语句在本 scope 的登记（逆序拼接见 Compiler.SpliceDefers）。</summary>
    public readonly List<Deferred> Defers = new();

    /// <summary>
    /// 该 scope 是否为 defer 载荷的隐式作用域：break / continue / return
    /// 不得跨越它（break/continue 的目标循环在载荷外 → 报错；return 在
    /// 载荷内一律报错）。
    /// </summary>
    public bool IsDeferPayload;

    public BlockScope() : base(Kind.Block) { }
}

/// <summary>defer 登记条目：载荷语句（所有权留在 AST）、defer 行号、登记时的声明序号基线。</summary>
public readonly struct Deferred
{
    public readonly Stmt? Stmt;
    public readonly int Line;
    public readonly int OrderBaseline;

    public Deferred(Stmt? stmt, int line, int orderBaseline)
    {
        Stmt = stmt;
        Line = line;
        OrderBaseline = orderBaseline;
    }
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
