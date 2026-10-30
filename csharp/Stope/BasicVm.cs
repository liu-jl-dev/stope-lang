using System;
using System.Collections.Generic;
using System.Text;

namespace Stope;

/// <summary>槽位引用。<c>PushId</c> 压它（左值），<c>Assign</c> 靠它取槽位；其余指令都当普通值处理。</summary>
public sealed class Identifier
{
    public int Index;

    public Identifier(int index) => Index = index;
}

/// <summary>
/// 宿主的实参表。取不到就<b>自己报错</b>：<c>state.Error(...)</c> 然后返回 null ——
/// 与 C++ 的 <c>at(State&amp;, const Value&amp;, Value&amp; out) -&gt; Result</c> 等价
/// （错误进同一个 <see cref="State.Errors"/>，执行器立刻停）。
/// </summary>
public abstract class Arguments
{
    public abstract object? At(State state, object? indexOrKey);

    public abstract int Num();
}

/// <summary>
/// 参考执行器的一个执行状态 —— 端口 <c>cpp/include/stope/basic_vm.hpp</c> 的 <c>State</c>。
/// <para>
/// <b>这不是标准。</b>Stope 只规定语言、STML 与编译器的产物 <see cref="Program"/>；执行器的
/// 接口、值的表示、栈布局、宿主函数约定全属实现自由。这个类只用来证明 <see cref="Program"/>
/// 确实能跑；自己写执行器请看 <c>docs/zh-cn/vm-guide.md</c>。
/// </para>
/// <para>
/// 值的 C# 表示（对应 C++ 的 <c>Value::Type</c>）：
/// <list type="table">
/// <item><term>Null</term><description><c>null</c></description></item>
/// <item><term>Integer</term><description><see cref="long"/>（溢出不检查、按 64 位回绕）</description></item>
/// <item><term>Float</term><description><see cref="double"/></description></item>
/// <item><term>String</term><description><see cref="string"/></description></item>
/// <item><term>BinArr</term><description><c>byte[]</c></description></item>
/// <item><term>HostFunction</term><description><c>Func&lt;object?[], object?&gt;</c></description></item>
/// <item><term>Identifier</term><description><see cref="Identifier"/>（<c>PushId</c> 压的槽位引用，只有 Assign 认它）</description></item>
/// </list>
/// </para>
/// <para>
/// ⚠ <b>没有 Bool 值类型</b>：<c>PushTrue</c> / <c>PushFalse</c> 压的是 Integer 1 / 0
/// （与 C++ 的 opPushTrue/opPushFalse 一致），所以 <c>true == 1</c> 在运行期为真。
/// 常量折叠里的 Bool 是 AST 层的类型，别把这两件事混起来。
/// </para>
/// <para>
/// ⚠ 栈上除了 <c>Assign</c> 的左值之外<b>一定是值</b>：编译器保证 <c>PushId</c> 只出现在赋值
/// 左端。所以这里<b>没有</b>「解引用」helper —— 收到 <see cref="Identifier"/> 就是产物错了，
/// 该让它当场暴露，而不是悄悄换成变量内容（C++ 侧同样没有这层兜底）。
/// </para>
/// </summary>
public sealed class State
{
    public Api Api = null!;
    public Program Program = null!;
    public Arguments? Args;

    public List<object?> Returns = new();
    public int I;

    /// <summary>变量槽位。</summary>
    public object?[] Variables = Array.Empty<object?>();

    /// <summary>求值栈。</summary>
    public List<object?> Stack = new();

    /// <summary>运行期错误，格式 <c>"&lt;指令下标&gt;: msg"</c>。</summary>
    public readonly List<string> Errors = new();

    /// <summary>
    /// 三样都要给；同时清 returns / stack / errors，并按 <see cref="Program.VariableNum"/>
    /// 开好槽位（C++ 要宿主自己 resize，这里替你做掉，免得漏一步就是空槽位）。
    /// </summary>
    public void Reset(Api api, Program program, Arguments? args = null)
    {
        Api = api;
        Program = program;
        Args = args;
        Returns.Clear();
        I = 0;
        Variables = new object?[program.VariableNum];
        Stack.Clear();
        Errors.Clear();
    }

    public void SetArguments(Arguments? args) => Args = args;

    /// <summary>宿主的报错入口（对应 C++ 的 <c>State::Error</c>）：<c>"&lt;指令下标&gt;: msg"</c>。</summary>
    public void Error(string msg) => Errors.Add(I + ": " + msg);

    public bool HasError() => Errors.Count > 0;

    /// <summary>
    /// 执行<b>一条</b>指令。<see cref="Result.Success"/> = 这条跑完了且没出错，可以接着 Step。
    /// 返回 <see cref="Result.Error"/> 有两种情况，靠 <see cref="Errors"/> 区分：
    /// <list type="bullet">
    /// <item>Errors 非空 —— 出错了，<see cref="I"/> 停在出错的那条指令上；</item>
    /// <item>Errors 为空 —— 指令流已经走完（I 越过末尾）。</item>
    /// </list>
    /// 所以 <c>while (s.Step() == Result.Success) {}</c> 与 <c>s.Run()</c> 等价，连走的条数都一样。
    /// </summary>
    public Result Step()
    {
        if (Errors.Count > 0) return Result.Error;
        if (I >= Program.Opcodes.Count) return Result.Success;
        Api.OpMap[Program.Opcodes[I]](this);
        if (Errors.Count > 0) return Result.Error;
        ++I;
        return Result.Success;
    }

    /// <summary>
    /// 一直执行到指令流结束；出错立即停。与 <see cref="Step"/> 是<b>两份独立实现</b>
    /// （热循环里不套函数调用），代价是改步进规则要同时改两处 —— 由测试锁着。
    /// </summary>
    public Result Run()
    {
        var ops = Program.Opcodes; // 执行中不会变长（Return 只是把 I 拨到末尾）
        int n = ops.Count;
        while (I < n)
        {
            Api.OpMap[ops[I]](this);
            if (Errors.Count > 0) return Result.Error;
            ++I;
        }
        return Result.Success;
    }

    /// <summary>栈顶下标一律「从栈顶数、1 起算」：<c>AtTop(1)</c> 就是 <c>Stack[^1]</c>。</summary>
    public object? AtTop(int k) => Stack[Stack.Count - k];

    public void Pop() => Stack.RemoveAt(Stack.Count - 1);

    public void PopN(int num)
    {
        for (int k = 0; k < num; ++k) Pop();
    }

    public void PushInt(long v) => Stack.Add(v);

    /// <summary>二元算术统一的收尾：弹出右操作数，结果写回左操作数的位置。</summary>
    public void StoreBinary(object? result)
    {
        Pop();
        Stack[Stack.Count - 1] = result;
    }
}

/// <summary>
/// 指令分派表 —— 对应 C++ 的 <c>API::opFuncs</c>。
/// <para>
/// <see cref="OpMap"/> 下标 = 指令编号，默认恰好 33 格（稠密）。要跑自定义指令必须自己扩表：
/// <c>OpMap.Add(...)</c> 到 N 且 0..N 每格都是有效委托；否则 <c>State.Step</c> 会抛
/// <see cref="ArgumentOutOfRangeException"/>。
/// </para>
/// </summary>
public sealed class Api
{
    public readonly List<Action<State>> OpMap = new()
    {
        Ops.Assign, Ops.PushNull, Ops.PushFalse, Ops.PushTrue, Ops.PushInt,
        Ops.PushFloat, Ops.PushString, Ops.PushBinArr, Ops.PushValue, Ops.PushId,
        Ops.Call, Ops.At, Ops.Pop, Ops.Minus, Ops.Not,
        Ops.Pow, Ops.Mul, Ops.Div, Ops.IDiv, Ops.Mod,
        Ops.Add, Ops.Sub, Ops.EQ, Ops.NE, Ops.LT,
        Ops.LE, Ops.GT, Ops.GE, Ops.If, Ops.GoTo,
        Ops.GetArg, Ops.ArgNum, Ops.Return,
    };
}

/// <summary>运行期值判定与整数运算的小工具。</summary>
public static class Runtime
{
    public static bool IsInt(object? v) => v is long;
    public static bool IsFloat(object? v) => v is double;
    public static bool IsNumber(object? v) => v is long or double;
    public static bool IsString(object? v) => v is string;
    public static bool IsBinArr(object? v) => v is byte[];
    public static bool IsFunc(object? v) => v is Func<object?[], object?>;
    public static bool IsSequence(object? v) => v is string or byte[];
    public static bool IsNull(object? v) => v is null;

    public static double AsDouble(object? v) => v is long l ? l : (double)v!;

    /// <summary>
    /// 宿主可能返回 <see cref="bool"/>（宿主语言里有这个类型，Stope 没有）：统一折成整数
    /// 1 / 0，否则后续算术会拿到一个「既不是整数也不是浮点」的值而报类型错。
    /// </summary>
    public static object? Normalize(object? v) => v is bool b ? (b ? 1L : 0L) : v;

    /// <summary>
    /// 真值：null → 假；整数 / 宿主函数 → 非零；浮点 → 非 0；序列 → 非空；其余 → 真。
    /// </summary>
    public static bool Truely(object? val)
    {
        if (val is null) return false;
        if (val is long l) return l != 0;
        if (val is Func<object?[], object?>) return true;
        if (val is double d) return d != 0.0;
        if (val is byte[] ba) return ba.Length != 0;
        if (val is string s) return s.Length != 0;
        return true;
    }

    /// <summary>
    /// 相等。类型不同一律不等（除了整数与浮点互通），<b>不能让宿主语言的 <c>==</c>
    /// 替我们决定</b> —— C# 的 <c>object.Equals("1", 1L)</c> 是 false，但装箱比较要靠这里统一。
    /// </summary>
    public static bool AreEqual(object? left, object? right)
    {
        if (left is null || right is null) return left is null && right is null;
        if (left is long li && right is long ri) return li == ri;
        if (left is long lf && right is double rd) return lf == rd;
        if (left is double ld && right is long rl) return ld == rl;
        if (left is double ldd && right is double rdd) return ldd == rdd;
        if (left is string ls && right is string rs) return string.Equals(ls, rs, StringComparison.Ordinal);
        if (left is byte[] lb && right is byte[] rb)
        {
            if (lb.Length != rb.Length) return false;
            for (int i = 0; i < lb.Length; ++i)
                if (lb[i] != rb[i])
                    return false;
            return true;
        }
        if (left is Func<object?[], object?> lf2 && right is Func<object?[], object?> rf2)
            return ReferenceEquals(lf2, rf2);
        return false;
    }

    /// <summary>整数除法：向零取整；<c>INT64_MIN / -1</c> 回绕而不抛 <see cref="OverflowException"/>。</summary>
    public static long IntDiv(long a, long b) => b == -1 ? unchecked(-a) : a / b;

    /// <summary>整数取模：余数符号跟被除数；<c>INT64_MIN % -1</c> 得 0。</summary>
    public static long IntMod(long a, long b) => b == -1 ? 0 : a % b;

    /// <summary>整数快速幂，exp ≥ 0；回绕，不检查溢出。</summary>
    public static long IntPow(long baseV, long exp)
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
}

/// <summary>33 条内置指令的实现。每个函数签名都是 <c>void (State)</c>，可由宿主替换 / 扩展。</summary>
public static class Ops
{
    // ---------------- 公共检查 ----------------
    /// <summary>算术公共前置检查：null 不能参与算术；两侧都必须是数字。</summary>
    private static bool CheckArith(State s, string op, object? left, object? right)
    {
        if (Runtime.IsNull(left) || Runtime.IsNull(right))
        {
            s.Error("\"" + op + "\" cannot operate on null. ");
            return false;
        }
        if (!Runtime.IsNumber(left) || !Runtime.IsNumber(right))
        {
            s.Error("\"" + op + "\" can only operate on integer or float. ");
            return false;
        }
        return true;
    }

    /// <summary>
    /// 整数除以 0 → 报错（不做除法）。判定看<b>运算走哪条路径</b>：只有两侧都是整数才是整数
    /// 除法；任一侧是 Float 就走 IEEE，不拦（<c>1.0 / 0</c> 与 <c>1 / 0.0</c> 都得 inf）。
    /// </summary>
    private static bool CheckIntZero(State s, string op, object? left, object? right)
    {
        if (left is long && right is long r && r == 0)
        {
            s.Error("\"" + op + "\" division by zero. ");
            return false;
        }
        return true;
    }

    private static bool LessThan(State s, object? left, object? right)
    {
        if (Runtime.IsNumber(left) && Runtime.IsNumber(right))
            return Runtime.AsDouble(left) < Runtime.AsDouble(right);
        s.Error("only on integer or float can be compared. ");
        return false;
    }

    private static bool GreaterThan(State s, object? left, object? right) => LessThan(s, right, left);

    // ---------------- 指令 ----------------
    public static void Assign(State s)
    {
        if (s.Stack.Count < 2)
        {
            s.Error("stack underflow. ");
            return;
        }
        if (s.AtTop(2) is not Identifier id)
        {
            s.Error("no implement for value type. ");
            return;
        }
        s.Variables[id.Index] = s.Stack[^1];
        s.PopN(2);
    }

    public static void PushNull(State s) => s.Stack.Add(null);

    public static void PushFalse(State s) => s.Stack.Add(0L);

    public static void PushTrue(State s) => s.Stack.Add(1L);

    public static void PushInt(State s)
    {
        ++s.I;
        s.Stack.Add(s.Program.IntConsts[s.Program.Opcodes[s.I]]);
    }

    public static void PushFloat(State s)
    {
        ++s.I;
        s.Stack.Add(s.Program.FloatConsts[s.Program.Opcodes[s.I]]);
    }

    public static void PushString(State s)
    {
        ++s.I;
        s.Stack.Add(s.Program.StringConsts[s.Program.Opcodes[s.I]]);
    }

    public static void PushBinArr(State s)
    {
        ++s.I;
        s.Stack.Add(s.Program.BinArrConsts[s.Program.Opcodes[s.I]]);
    }

    public static void PushValue(State s)
    {
        ++s.I;
        int idx = s.Program.Opcodes[s.I];
        s.Stack.Add(s.Variables[idx]); // 压【值】；要槽位引用请用 PushId
    }

    public static void PushId(State s)
    {
        ++s.I;
        int idx = s.Program.Opcodes[s.I];
        s.Stack.Add(new Identifier(idx)); // 不能是值，否则无法 Assign
    }

    public static void Call(State s)
    {
        // 不检查栈下溢：参数个数在编译期就定了
        ++s.I;
        int argNum = s.Program.Opcodes[s.I];
        if (s.AtTop(argNum + 1) is not Func<object?[], object?> callee)
        {
            s.Error("\"Call\" can only call a function. ");
            return;
        }
        var argv = new object?[argNum];
        for (int k = argNum; k >= 1; --k) argv[argNum - k] = s.AtTop(k);
        var outVal = Runtime.Normalize(callee(argv)); // 参数整包进来，由宿主自己拆
        s.PopN(argNum);
        s.Stack[^1] = outVal;
    }

    public static void At(State s)
    {
        // 不检查栈下溢：key 个数在编译期就定了
        ++s.I;
        int keyNum = s.Program.Opcodes[s.I];
        if (keyNum != 1)
        {
            s.Error("no implement for key num != 1. ");
            return;
        }
        var container = s.AtTop(2);
        var key = s.AtTop(1);
        if (key is not long k)
        {
            s.Error("index must be integer. ");
            return;
        }
        int index = (int)k;
        object? result;
        if (container is byte[] bytes)
        {
            if (index < 0 || index >= bytes.Length)
            {
                s.Error("index out of range. ");
                return;
            }
            result = (long)bytes[index];
        }
        else if (container is string str)
        {
            if (index < 0 || index >= str.Length)
            {
                s.Error("index out of range. ");
                return;
            }
            // 取的是**码元**（UTF-16），不是单字符子串 —— 与 C++ 一致
            result = (long)str[index];
        }
        else
        {
            s.Error("no implement for container type. ");
            return;
        }
        s.PopN(keyNum + 1);
        s.Stack.Add(result);
    }

    public static void Pop(State s) => s.Pop();

    public static void Minus(State s)
    {
        var val = s.Stack[^1];
        if (val is long l) s.Stack[^1] = unchecked(-l); // 回绕，不检查溢出
        else if (val is double d) s.Stack[^1] = -d;
        else s.Error("\"Minus\" can only operate on integer or float. ");
    }

    public static void Not(State s)
    {
        var val = s.Stack[^1];
        if (val is null) s.Stack[^1] = 1L;
        else if (val is long l) s.Stack[^1] = l == 0 ? 1L : 0L;
        else if (val is double d) s.Stack[^1] = d == 0.0 ? 1L : 0L;
        else s.Error("\"Not\" can only operate on integer or float. ");
    }

    public static void Pow(State s)
    {
        var left = s.AtTop(2);
        var right = s.AtTop(1);
        if (!CheckArith(s, "Pow", left, right)) return;
        object result;
        // 两个整数且指数 ≥ 0 -> 整数结果；负指数（`2 ^ -1`）-> Float(0.5)。与常量折叠一致。
        if (left is long li && right is long ri && ri >= 0)
        {
            result = Runtime.IntPow(li, ri);
        }
        else
        {
            result = Math.Pow(Runtime.AsDouble(left), Runtime.AsDouble(right));
        }
        s.StoreBinary(result);
    }

    public static void Mul(State s)
    {
        var left = s.AtTop(2);
        var right = s.AtTop(1);
        if (Runtime.IsNull(left) || Runtime.IsNull(right))
        {
            s.Error("\"Mul\" cannot operate on null. ");
            return;
        }
        object? result;
        if (Runtime.IsNumber(left) && Runtime.IsNumber(right))
        {
            if (left is long li && right is long ri) result = unchecked(li * ri); // 回绕
            else result = Runtime.AsDouble(left) * Runtime.AsDouble(right);
        }
        else if ((Runtime.IsSequence(left) && right is long) || (left is long && Runtime.IsSequence(right)))
        {
            // 序列重复：`2 * "ab"` 与 `"ab" * 2` 都要成立 —— 取序列那一侧
            var seq = Runtime.IsSequence(left) ? left : right;
            long times = (long)(Runtime.IsSequence(left) ? right : left)!;
            if (times < 0)
            {
                s.Error("\"Mul\" cannot repeat a sequence by a negative number. ");
                return;
            }
            if (seq is byte[] bytes)
            {
                var outBytes = new byte[bytes.Length * times];
                for (long k = 0; k < times; ++k)
                    Array.Copy(bytes, 0, outBytes, k * bytes.Length, bytes.Length);
                result = outBytes;
            }
            else
            {
                var str = (string)seq!;
                var sb = new StringBuilder(str.Length * (int)times);
                for (long k = 0; k < times; ++k) sb.Append(str);
                result = sb.ToString();
            }
        }
        else
        {
            s.Error("\"Mul\" can only operate on numbers, or repeat a string / bin array by an integer. ");
            return;
        }
        s.StoreBinary(result);
    }

    public static void Div(State s)
    {
        var left = s.AtTop(2);
        var right = s.AtTop(1);
        if (!CheckArith(s, "Div", left, right) || !CheckIntZero(s, "Div", left, right)) return;
        object result;
        if (left is long li && right is long ri)
        {
            // 除不尽 -> 浮点数（`7 / 2` 是 Float(3.5)）；整除要用 idiv。与常量折叠一致。
            result = Runtime.IntMod(li, ri) == 0 ? Runtime.IntDiv(li, ri) : (double)li / ri;
        }
        else
        {
            result = Runtime.AsDouble(left) / Runtime.AsDouble(right);
        }
        s.StoreBinary(result);
    }

    public static void IDiv(State s)
    {
        var left = s.AtTop(2);
        var right = s.AtTop(1);
        if (!CheckArith(s, "IDiv", left, right) || !CheckIntZero(s, "IDiv", left, right)) return;
        object result;
        if (left is long li && right is long ri)
        {
            result = Runtime.IntDiv(li, ri); // 向零取整
        }
        else
        {
            // 含浮点：仍按数值整除（向零取整），结果保持浮点，不做 float→int 收窄
            result = Math.Truncate(Runtime.AsDouble(left) / Runtime.AsDouble(right));
        }
        s.StoreBinary(result);
    }

    public static void Mod(State s)
    {
        var left = s.AtTop(2);
        var right = s.AtTop(1);
        if (!CheckArith(s, "Mod", left, right) || !CheckIntZero(s, "Mod", left, right)) return;
        object result;
        if (left is long li && right is long ri) result = Runtime.IntMod(li, ri); // 余数符号跟被除数
        else result = Runtime.AsDouble(left) % Runtime.AsDouble(right);
        s.StoreBinary(result);
    }

    public static void Add(State s)
    {
        var left = s.AtTop(2);
        var right = s.AtTop(1);
        // null 不是「加法单位元」，也不与任何值做算术 —— 一律报错
        if (Runtime.IsNull(left) || Runtime.IsNull(right))
        {
            s.Error("\"Add\" cannot operate on null. ");
            return;
        }
        object? result;
        if (left is long li)
        {
            if (right is long ri) result = unchecked(li + ri); // 回绕，不检查溢出
            else if (right is double rd) result = li + rd;
            else
            {
                s.Error("integer can only add integer or float. ");
                return;
            }
        }
        else if (left is double ld)
        {
            if (Runtime.IsNumber(right)) result = ld + Runtime.AsDouble(right);
            else
            {
                s.Error("float can only add integer or float. ");
                return;
            }
        }
        else if (left is string ls && right is string rs)
        {
            result = ls + rs;
        }
        else if (left is byte[] lb && right is byte[] rb)
        {
            var outBytes = new byte[lb.Length + rb.Length];
            Array.Copy(lb, 0, outBytes, 0, lb.Length);
            Array.Copy(rb, 0, outBytes, lb.Length, rb.Length);
            result = outBytes;
        }
        else
        {
            s.Error("\"Add\" can only operate on numbers, strings or bin arrays. ");
            return;
        }
        s.StoreBinary(result);
    }

    public static void Sub(State s)
    {
        var left = s.AtTop(2);
        var right = s.AtTop(1);
        if (!CheckArith(s, "Sub", left, right)) return;
        object result;
        if (left is long li)
        {
            if (right is long ri) result = unchecked(li - ri); // 回绕，不检查溢出
            else if (right is double rd) result = li - rd;
            else
            {
                s.Error("integer can only subtract integer or float. ");
                return;
            }
        }
        else if (left is double ld)
        {
            if (Runtime.IsNumber(right)) result = ld - Runtime.AsDouble(right);
            else
            {
                s.Error("float can only subtract integer or float. ");
                return;
            }
        }
        else
        {
            s.Error("\"Sub\" can only operate on integer or float. ");
            return;
        }
        s.StoreBinary(result);
    }

    public static void EQ(State s) =>
        s.StoreBinary(Runtime.AreEqual(s.AtTop(2), s.AtTop(1)) ? 1L : 0L);

    public static void NE(State s) =>
        s.StoreBinary(Runtime.AreEqual(s.AtTop(2), s.AtTop(1)) ? 0L : 1L);

    public static void LT(State s) =>
        s.StoreBinary(LessThan(s, s.AtTop(2), s.AtTop(1)) ? 1L : 0L);

    public static void LE(State s) =>
        s.StoreBinary(GreaterThan(s, s.AtTop(2), s.AtTop(1)) ? 0L : 1L);

    public static void GT(State s) =>
        s.StoreBinary(GreaterThan(s, s.AtTop(2), s.AtTop(1)) ? 1L : 0L);

    public static void GE(State s) =>
        s.StoreBinary(LessThan(s, s.AtTop(2), s.AtTop(1)) ? 0L : 1L);

    public static void If(State s)
    {
        bool yes = Runtime.Truely(s.Stack[^1]);
        s.Pop(); // 条件用完即弹，不再留在栈上
        ++s.I; // 跳过操作数；条件成立时 Step/Run 的 ++I 正好落到下一句
        int goToIdx = s.Program.Opcodes[s.I];
        if (!yes) s.I = goToIdx - 1;
    }

    public static void GoTo(State s)
    {
        int goToIdx = s.Program.Opcodes[s.I + 1]; // 操作数在 I+1
        s.I = goToIdx - 1;
    }

    public static void GetArg(State s)
    {
        if (s.Args is null)
        {
            s.Error("no args. ");
            return;
        }
        // 先弹 key 再取参：实参表可能拿 key 做准备
        var key = s.Stack[^1];
        s.Stack.RemoveAt(s.Stack.Count - 1);
        s.Stack.Add(Runtime.Normalize(s.Args.At(s, key)));
    }

    public static void ArgNum(State s)
    {
        if (s.Args is null)
        {
            s.Error("no args. ");
            return;
        }
        s.Stack.Add((long)s.Args.Num());
    }

    public static void Return(State s)
    {
        ++s.I;
        int num = s.Program.Opcodes[s.I];
        s.Returns.Clear();
        for (int k = num; k >= 1; --k) s.Returns.Add(s.AtTop(k));
        s.I = s.Program.Opcodes.Count;
    }
}
