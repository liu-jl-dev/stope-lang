using System;

namespace Stope;

/// <summary>
/// 常量折叠 —— 端口 <c>cpp/src/expr_optim.cpp</c>（C++ 为权威实现）。
/// <para>
/// 契约：
/// <list type="bullet">
/// <item>只做「单节点」变换，<b>不递归</b>。挂在 parser 构造 <see cref="UnaryOpExpr"/> /
/// <see cref="BinaryOpExpr"/> 的末尾，子节点返回时就已折好，整棵树自底向上折完。</item>
/// <item><see cref="Optimize"/> 成功折叠时返回<b>新</b>节点（原节点不再使用），
/// 未折叠时返回入参本身。</item>
/// <item>拿不准就一律不折叠：除零、含浮点的 idiv、跨类型 <c>==</c>、null 参与比较、
/// Bool 参与比较 —— 全部保留原节点，交给后端报错。折叠后的节点沿用运算符节点的行号。</item>
/// </list>
/// </para>
/// <para>
/// 本项目自定的三条算术规则（详见 <c>cpp/docs/expr-optim.md</c> §4.9）：
/// <list type="number">
/// <item><c>BinArr + BinArr</c> == 字节连接；</item>
/// <item><c>String / BinArr * 非负整数</c> == 串重复（整数 * 串 同理）；</item>
/// <item><c>+ - * / idiv % ^</c> 里 Bool 视作 0 / 1，但 <c>&lt; &lt;= &gt; &gt;=</c> 与
/// <c>== !=</c> 仍按类型区分。</item>
/// </list>
/// </para>
/// <para>
/// 判断顺序与 C++ 一一对应（层号同 <c>expr-optim.md</c> §4.2 / §4.7）：
/// L0 两侧必须都是字面量常量 → L1 and/or → L2 任一侧 null → L3 比较 → L4 算术。
/// 刻意<b>不</b>拆成 <c>FoldXxx</c> 分派函数，保持「一个格子 = 一个分支」，方便两边对照。
/// </para>
/// <para>
/// ⚠ 整数是 <see cref="long"/>，<b>溢出不检查、按 64 位补码回绕</b>（与 C++ 的 unsigned
/// 乘法、intNeg/intDiv/intMod 等价）。本项目关掉了 <c>CheckForOverflowUnderflow</c>，
/// 所以 <c>+ - *</c> 天然回绕；除法与取模要自己兜 <c>INT64_MIN / -1</c>。
/// </para>
/// </summary>
public static class ExprOptim
{
    public enum ConstKind
    {
        NotConst = 0,
        Null = 1,
        Bool = 2,
        Int = 3,
        Float = 4,
        String = 5,
        BinArr = 6,
    }

    private const long MaxRepeatElem = 1 << 20; // 串重复的元素数上限：1 M

    // ==================== 入口 ====================
    /// <summary>
    /// 返回一个（可能是新的）节点：成功折叠时是新常量节点，否则是入参本身。
    /// </summary>
    public static Expr? Optimize(Expr? e)
    {
        if (e is null) return null;
        return e.NodeType switch
        {
            AstNodeType.UnaryOpExpr => FoldUnary((UnaryOpExpr)e),
            AstNodeType.BinaryOpExpr => FoldBinary((BinaryOpExpr)e),
            _ => e,
        };
    }

    // ==================== 常量分类与取值 ====================
    /// <summary>
    /// 只有 6 种字面量是「常量」。Ident / Call / At / Args / Argc / Custom 都不是
    /// （值要运行期才知道，且 Call / Custom 可能有副作用）。
    /// </summary>
    public static ConstKind KindOf(Expr? e)
    {
        if (e is null) return ConstKind.NotConst;
        return e.NodeType switch
        {
            AstNodeType.NullExpr => ConstKind.Null,
            AstNodeType.BoolExpr => ConstKind.Bool,
            AstNodeType.IntExpr => ConstKind.Int,
            AstNodeType.FloatExpr => ConstKind.Float,
            AstNodeType.StringExpr => ConstKind.String,
            AstNodeType.BinArrExpr => ConstKind.BinArr,
            _ => ConstKind.NotConst,
        };
    }

    private static bool IsConst(ConstKind k) => k != ConstKind.NotConst;

    /// <summary>真正的 Int / Float（不含 Bool）。</summary>
    private static bool IsNumeric(ConstKind k) => k is ConstKind.Int or ConstKind.Float;

    private static bool BothInt(ConstKind lk, ConstKind rk) => lk == ConstKind.Int && rk == ConstKind.Int;

    /// <summary>String / BinArr 统称「序列」：连接、重复、相等的规则一致。</summary>
    private static bool IsSeq(ConstKind k) => k is ConstKind.String or ConstKind.BinArr;

    // 「算术上下文」里的 Bool：视作 0 / 1 的整数。只对 + - * / idiv % ^ 生效。
    private static bool IsNumLike(ConstKind k) => k == ConstKind.Bool || IsNumeric(k);

    // 两侧都参与整数运算（Bool 算整数），只有出现 Float 才走浮点分支
    private static bool BothNumInt(ConstKind lk, ConstKind rk) =>
        IsNumLike(lk) && IsNumLike(rk) && lk != ConstKind.Float && rk != ConstKind.Float;

    // ---------- 取值：NumAsInt / AsDouble 会把 Bool 折算成 0 / 1 ----------
    private static long AsInt(Expr e) => ((IntExpr)e).Value;

    private static long NumAsInt(Expr e) =>
        e.NodeType == AstNodeType.BoolExpr ? (((BoolExpr)e).Value ? 1L : 0L) : AsInt(e);

    private static double AsDouble(Expr e) => e.NodeType switch
    {
        AstNodeType.BoolExpr => ((BoolExpr)e).Value ? 1.0 : 0.0,
        AstNodeType.IntExpr => ((IntExpr)e).Value,
        _ => ((FloatExpr)e).Value,
    };

    // ==================== 序列（String / BinArr）的载荷读写 ====================
    private static int SeqSize(Expr e) => e.NodeType == AstNodeType.StringExpr
        ? ((StringExpr)e).Value.Length
        : ((BinArrExpr)e).Value.Length;

    private static bool SeqEqual(Expr a, Expr b)
    {
        if (a.NodeType == AstNodeType.StringExpr)
            return string.Equals(((StringExpr)a).Value, ((StringExpr)b).Value, StringComparison.Ordinal);
        var x = ((BinArrExpr)a).Value;
        var y = ((BinArrExpr)b).Value;
        if (x.Length != y.Length) return false;
        for (int i = 0; i < x.Length; ++i)
            if (x[i] != y[i])
                return false;
        return true;
    }

    private static Expr MakeSeq(int line, ConstKind k) =>
        k == ConstKind.String ? new StringExpr(line) : new BinArrExpr(line);

    private static void SeqAppend(Expr dst, Expr src)
    {
        if (dst.NodeType == AstNodeType.StringExpr)
        {
            ((StringExpr)dst).Value += ((StringExpr)src).Value;
        }
        else
        {
            var d = ((BinArrExpr)dst).Value;
            var s = ((BinArrExpr)src).Value;
            var outBytes = new byte[d.Length + s.Length];
            Array.Copy(d, 0, outBytes, 0, d.Length);
            Array.Copy(s, 0, outBytes, d.Length, s.Length);
            ((BinArrExpr)dst).Value = outBytes;
        }
    }

    /// <summary>真值规则：null → 假；bool → 自身；int/float → 非零；序列 → 非空。</summary>
    private static bool Truthy(Expr e) => e.NodeType switch
    {
        AstNodeType.NullExpr => false,
        AstNodeType.BoolExpr => ((BoolExpr)e).Value,
        AstNodeType.IntExpr => ((IntExpr)e).Value != 0,
        AstNodeType.FloatExpr => ((FloatExpr)e).Value != 0.0,
        _ => IsSeq(KindOf(e)) && SeqSize(e) != 0,
    };

    // ==================== 有符号整数运算（64 位回绕） ====================
    // + - * 按 64 位补码回绕（项目已关闭溢出检查）；除法 / 取模向零取整，
    // INT64_MIN / -1 也回绕（不抛 OverflowException），与 C++ 的 intDiv/intMod 等价。
    private static long IntAdd(long a, long b) => unchecked(a + b);
    private static long IntSub(long a, long b) => unchecked(a - b);
    private static long IntMul(long a, long b) => unchecked(a * b);

    private static long IntDiv(long a, long b) =>
        b == -1 ? unchecked(-a) : a / b; // INT64_MIN / -1 回绕

    private static long IntMod(long a, long b) => b == -1 ? 0 : a % b;

    private static long IntNeg(long a) => unchecked(-a);

    /// <summary>整数快速幂，exp ≥ 0；溢出不检测、按 64 位回绕（与 C++ 的 unsigned 乘法一致）。</summary>
    private static long IntPow(long baseV, long exp)
    {
        long result = 1;
        long b = baseV;
        long e = exp;
        while (e > 0)
        {
            if ((e & 1) != 0) result = unchecked(result * b);
            e >>= 1;
            if (e > 0) b = unchecked(b * b);
        }
        return result;
    }

    // ==================== 造节点 / 拷贝常量 / 取负 / 串重复 ====================
    private static BoolExpr MakeBool(int line, bool v) => new(line, v);
    private static IntExpr MakeInt(int line, long v) => new(line, v);
    private static FloatExpr MakeFloat(int line, double v) => new(line, v);

    /// <summary>
    /// 取负：Int/Float → 同类型取负；Bool → 转成 Int 取负。不可取负（null / 序列）返回 null。
    /// 整数按 64 位回绕（<c>-INT64_MIN == INT64_MIN</c>）。
    /// </summary>
    private static Expr? NegateConst(int line, Expr e) => e.NodeType switch
    {
        AstNodeType.BoolExpr => MakeInt(line, ((BoolExpr)e).Value ? -1 : 0),
        AstNodeType.IntExpr => MakeInt(line, IntNeg(AsInt(e))),
        AstNodeType.FloatExpr => MakeFloat(line, -((FloatExpr)e).Value),
        _ => null,
    };

    /// <summary>
    /// 串重复：<c>"ab" * 3</c> / <c>'x 41' * 3</c>。<paramref name="times"/> 必须是非负整数
    /// （Bool 已在调用侧折算）；负次或结果元素数超过上限 → null。
    /// </summary>
    private static Expr? RepeatSeq(int line, Expr baseSeq, long times)
    {
        if (times < 0) return null; // 负次重复无定义 -> 不折叠
        int unit = SeqSize(baseSeq);
        if (unit == 0) return MakeSeq(line, KindOf(baseSeq)); // 空串/空数组的任意次重复仍是空
        if (times > MaxRepeatElem / unit) return null; // 结果过大 -> 不折叠
        var r = MakeSeq(line, KindOf(baseSeq));
        for (long i = 0; i < times; ++i) SeqAppend(r, baseSeq);
        return r;
    }

    /// <summary><c>&lt; &lt;= &gt; &gt;=</c> 的四分支（整数与浮点共用一套）。</summary>
    private static bool CmpOf(TokenType op, double a, double b) => op switch
    {
        TokenType.LT => a < b,
        TokenType.LE => a <= b,
        TokenType.GT => a > b,
        _ => a >= b,
    };

    // ==================== 一元 ====================
    private static Expr FoldUnary(UnaryOpExpr e)
    {
        if (e.Expr is null) return e;
        int line = e.Line;
        var inn = e.Expr;
        var ck = KindOf(inn);
        if (!IsConst(ck)) return e; // 非常量 -> 不折叠

        // `!` 走 Truthy；`-` 走 NegateConst（Bool 折算成 Int，null / 序列不可取负 -> 不折叠）
        Expr? ret = null;
        if (e.Op == TokenType.Not)
        {
            if (ck == ConstKind.Null || IsNumLike(ck)) ret = MakeBool(line, !Truthy(inn));
        }
        else if (e.Op == TokenType.Sub)
        {
            ret = NegateConst(line, inn);
        }
        return ret ?? e;
    }

    // ==================== 二元 ====================
    private static Expr FoldBinary(BinaryOpExpr e)
    {
        if (e.LeftExpr is null || e.RightExpr is null) return e;
        return TryFoldBinary(e) ?? e;
    }

    private static Expr? TryFoldBinary(BinaryOpExpr e)
    {
        int line = e.Line;
        var op = e.Op;
        var L = e.LeftExpr!;
        var R = e.RightExpr!;
        var lk = KindOf(L);
        var rk = KindOf(R);

        // L0 两侧必须都是字面量常量：否则既算不出值，也可能吞掉 Call/Custom 的副作用
        if (!IsConst(lk) || !IsConst(rk)) return null;

        // ---------- L1 and / or：结果与类型无关，恒返回 Bool ----------
        if (op == TokenType.And) return MakeBool(line, Truthy(L) && Truthy(R));
        if (op == TokenType.Or) return MakeBool(line, Truthy(L) || Truthy(R));

        // ---------- L2 null 参与 ----------
        // null 不是数字，也不参与算术：`+ - * / idiv % ^` 一律不折叠，交给后端报错。
        // 只有 `==` `!=` 有确定结论：null 只与 null 相等。< <= > >= 本该是类型错误 -> 不折叠。
        if (lk == ConstKind.Null || rk == ConstKind.Null)
        {
            bool bothNull = lk == ConstKind.Null && rk == ConstKind.Null;
            if (op == TokenType.EQ) return MakeBool(line, bothNull);
            if (op == TokenType.NE) return MakeBool(line, !bothNull);
            return null;
        }

        // ---------- L3 相等与大小比较 ----------
        // 到这里两侧都非 null；跨类型一律不折叠（强制转换规则未定，见 expr-optim.md §4.5）
        if (op is TokenType.EQ or TokenType.NE)
        {
            bool decided = false;
            bool eq = false;
            if (lk == ConstKind.Bool && rk == ConstKind.Bool)
            {
                decided = true;
                eq = ((BoolExpr)L).Value == ((BoolExpr)R).Value;
            }
            else if (IsNumeric(lk) && IsNumeric(rk))
            {
                // Bool ⊕ 数字 -> 不折
                decided = true;
                eq = BothInt(lk, rk) ? AsInt(L) == AsInt(R) : AsDouble(L) == AsDouble(R);
            }
            else if (IsSeq(lk) && lk == rk)
            {
                decided = true;
                eq = SeqEqual(L, R);
            }
            if (decided) return MakeBool(line, op == TokenType.EQ ? eq : !eq);
            return null;
        }

        if (op is TokenType.LT or TokenType.LE or TokenType.GT or TokenType.GE)
        {
            // Bool 与序列不参与数值比较 -> 两侧都必须是 Int / Float
            if (IsNumeric(lk) && IsNumeric(rk))
            {
                return MakeBool(line, BothInt(lk, rk)
                    ? CmpOf(op, AsInt(L), AsInt(R))
                    : CmpOf(op, AsDouble(L), AsDouble(R)));
            }
            return null;
        }

        // ---------- L4 算术 + - * / idiv % ^ ----------
        // 到这里两侧都非 null，左值只剩两类：数值（Bool 折算成 0/1）与序列
        if (IsNumLike(lk))
        {
            // ===== L4a 左值是 Bool / Int / Float =====
            if (op is TokenType.Add or TokenType.Sub or TokenType.Mul)
            {
                if (IsNumLike(rk))
                {
                    if (BothNumInt(lk, rk))
                    {
                        // 两侧都没有 Float -> 整数路径，溢出不检查、按 64 位回绕
                        long a = NumAsInt(L);
                        long b = NumAsInt(R);
                        if (op == TokenType.Add) return MakeInt(line, IntAdd(a, b));
                        if (op == TokenType.Sub) return MakeInt(line, IntSub(a, b));
                        return MakeInt(line, IntMul(a, b));
                    }
                    // 任一侧是 Float -> 浮点路径
                    double x = AsDouble(L);
                    double y = AsDouble(R);
                    double v = op == TokenType.Add ? x + y : op == TokenType.Sub ? x - y : x * y;
                    return MakeFloat(line, v);
                }
                if (op == TokenType.Mul && IsSeq(rk) && lk != ConstKind.Float)
                {
                    return RepeatSeq(line, R, NumAsInt(L)); // 数字 * 串 == 串重复
                }
            }
            else if (op == TokenType.Div)
            {
                if (IsNumLike(rk))
                {
                    if (BothNumInt(lk, rk))
                    {
                        long a = NumAsInt(L);
                        long b = NumAsInt(R);
                        // 除零 -> 不折叠；除不尽 -> 浮点数
                        if (b != 0)
                        {
                            return IntMod(a, b) == 0
                                ? MakeInt(line, IntDiv(a, b))
                                : MakeFloat(line, (double)a / b);
                        }
                    }
                    else
                    {
                        double bb = AsDouble(R);
                        if (bb != 0.0) return MakeFloat(line, AsDouble(L) / bb);
                    }
                }
            }
            else if (op == TokenType.IDiv)
            {
                if (BothNumInt(lk, rk))
                {
                    // 含浮点 -> float→int 收窄，不折叠
                    long a = NumAsInt(L);
                    long b = NumAsInt(R);
                    if (b != 0) return MakeInt(line, IntDiv(a, b)); // 向零取整
                }
            }
            else if (op == TokenType.Mod)
            {
                if (IsNumLike(rk))
                {
                    if (BothNumInt(lk, rk))
                    {
                        long a = NumAsInt(L);
                        long b = NumAsInt(R);
                        if (b != 0) return MakeInt(line, IntMod(a, b));
                    }
                    else
                    {
                        double bb = AsDouble(R);
                        if (bb != 0.0) return MakeFloat(line, AsDouble(L) % bb);
                    }
                }
            }
            else if (op == TokenType.Pow)
            {
                if (IsNumLike(rk))
                {
                    if (BothNumInt(lk, rk))
                    {
                        long b = NumAsInt(R);
                        // 非负整数指数走快速幂（溢出回绕）；负指数落到浮点分支
                        if (b >= 0) return MakeInt(line, IntPow(NumAsInt(L), b));
                    }
                    double rr = Math.Pow(AsDouble(L), AsDouble(R)); // 负指数 / 含浮点
                    if (double.IsFinite(rr)) return MakeFloat(line, rr); // NaN / Inf -> 不折叠
                }
            }
        }
        // ===== L4b 左值是序列（String / BinArr）=====
        else if (IsSeq(lk))
        {
            if (op == TokenType.Add)
            {
                if (rk == lk)
                {
                    // 同类才连接：字符串拼接 / 字节连接（跨类型不折）
                    var ret = MakeSeq(line, lk);
                    SeqAppend(ret, L);
                    SeqAppend(ret, R);
                    return ret;
                }
            }
            else if (op == TokenType.Mul)
            {
                if (rk is ConstKind.Int or ConstKind.Bool)
                {
                    return RepeatSeq(line, L, NumAsInt(R)); // 串 * 整数 == 串重复
                }
            }
            // 其余运算符（Sub 等）对序列无定义 -> 不折叠
        }
        return null;
    }
}
