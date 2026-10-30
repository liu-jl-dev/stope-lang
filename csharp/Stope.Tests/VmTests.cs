using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace Stope.Tests;

/// <summary>
/// 参考执行器：值语义 + 两条驱动路径。**没有 golden 数据** —— 执行器不属标准范围
/// （见根 README「标准范围」），C++ 侧的期望值也不能 dump 出来当权威。
/// <para>
/// 所以这一组锁两件事：
/// </para>
/// <list type="number">
/// <item><b>Run 与 Step 一致</b>：两条独立实现（热循环不套函数调用），连走的条数都一样；</item>
/// <item><b>与另外三份实现同一种答案</b>：算术 / 序列 / 真值 / 除零 / 回绕 / 相等这些
/// 容易在宿主语言里「顺手用原生运算符」的地方，结果必须与 C++ 逐条相同。</item>
/// </list>
/// <para>
/// 改执行器语义时先跑一次四方差分（同一批源码分别喂四条实现，只比 <c>returns</c> 与
/// 错误消息正文 —— 错误串前缀各实现不同），再动这里。
/// </para>
/// </summary>
public static class VmTests
{
    private sealed class NoArgs : Arguments
    {
        public override object? At(State state, object? indexOrKey)
        {
            state.Error("argument out of range. ");
            return null;
        }

        public override int Num() => 0;
    }

    private sealed class ArrayArgs : Arguments
    {
        private readonly object?[] _data;
        public ArrayArgs(object?[] data) => _data = data;

        public override object? At(State state, object? indexOrKey)
        {
            if (indexOrKey is not long k || k < 0 || k >= _data.Length)
            {
                state.Error("argument out of range. ");
                return null;
            }
            return _data[k];
        }

        public override int Num() => _data.Length;
    }

    /// <summary>
    /// 紧凑的返回值写法：<c>null</c> / 整数 / 浮点（无小数点时补 <c>.0</c>，与另外三份一致）
    /// / 字符串原样 / 二进制数组写成 <c>[1,2]</c>。
    /// </summary>
    private static string Fmt(object? v)
    {
        if (v is null) return "null";
        if (v is long l) return l.ToString(CultureInfo.InvariantCulture);
        if (v is bool b) return b ? "1" : "0"; // 值层面不该出现 bool，出现就是没归一
        if (v is double d)
        {
            if (double.IsNaN(d)) return "nan";
            if (double.IsInfinity(d)) return d > 0 ? "inf" : "-inf";
            string s = Format.FmtG(d);
            if (s.IndexOf('.') < 0 && s.IndexOf('e') < 0) s += ".0";
            return s;
        }
        if (v is string str) return str;
        if (v is byte[] ba)
        {
            var parts = new List<string>(ba.Length);
            foreach (var x in ba) parts.Add(x.ToString(CultureInfo.InvariantCulture));
            return "[" + string.Join(",", parts) + "]";
        }
        return "<other>";
    }

    private static string FmtReturns(State s)
    {
        var parts = new List<string>(s.Returns.Count);
        foreach (var v in s.Returns) parts.Add(Fmt(v));
        return "[" + string.Join(",", parts) + "]";
    }

    /// <summary>
    /// 编译并把 <see cref="State"/> 装配好，**但不执行** —— 宿主函数要先往
    /// <c>Variables</c> 里塞值，塞完再 <c>Run()</c>，所以执行必须留给调用方。
    /// </summary>
    private static State? BuildState(string src, Arguments? args, out Program prog, out List<string> compileErrors)
    {
        var tree = new Prog();
        var ps = new Parser(new Lexer(src));
        ps.ParseProgram(tree);
        prog = new Program();
        var c = new Compiler();
        compileErrors = c.Errors;
        if (c.Compile(tree, prog) != Result.Success || ps.Errors.Count > 0) return null;

        var st = new State();
        st.Reset(new Api(), prog, args);
        return st;
    }

    /// <summary>编译并执行一段源码；<paramref name="args"/> 为 null 表示不给实参表。</summary>
    private static State? Build(string src, Arguments? args, out Program prog, out List<string> compileErrors)
    {
        var st = BuildState(src, args, out prog, out compileErrors);
        st?.Run();
        return st;
    }

    /// <summary>产物里有几条指令（跳过操作数格）——与「走了几步」对照用。</summary>
    private static int InstructionCount(Program p)
    {
        int n = 0;
        for (int i = 0; i < p.Opcodes.Count; ++i)
        {
            ++n;
            if (Debug.OpcodeHasArg(p.Opcodes[i])) ++i;
        }
        return n;
    }

    private static void Returns(Report rep, string id, string src, string want)
    {
        var st = Build(src, null, out _, out var cerrs);
        if (st is null)
        {
            rep.AddFail(id, "编译失败：" + src + " | " + string.Join("", cerrs));
            return;
        }
        rep.Check(id, "returns", want, FmtReturns(st));
        rep.Check(id, "errors", "", string.Join("|", st.Errors));
    }

    /// <summary>断言报错；只比 <c>: </c> 之后的正文（前缀「下标 + 指令名」由实现自定）。</summary>
    private static void Errs(Report rep, string id, string src, string wantMsg)
    {
        var st = Build(src, null, out _, out var cerrs);
        if (st is null)
        {
            rep.AddFail(id, "编译失败：" + src + " | " + string.Join("", cerrs));
            return;
        }
        rep.CheckInt(id, "错误条数", 1, st.Errors.Count);
        rep.Check(id, "错误消息", wantMsg, st.Errors.Count > 0 ? MsgOnly(st.Errors[0]) : "<无错误>");
    }

    /// <summary><c>"3 Div: msg"</c> → <c>msg</c>：前缀（下标 + 指令名）由实现决定，跨实现只比消息。</summary>
    private static string MsgOnly(string e)
    {
        int i = e.IndexOf(": ", StringComparison.Ordinal);
        return i < 0 ? e : e[(i + 2)..];
    }

    public static void Run(Report rep)
    {
        // ==================== 布尔就是整数 1 / 0 ====================
        Returns(rep, "V-06", "return true;", "[1]");
        Returns(rep, "V-06b", "return false;", "[0]");
        Returns(rep, "V-06c", "let t = true; let f = false; return t + f + (1 == 1);", "[2]");
        Returns(rep, "V-06d", "let a = 1; let b = 2; return a < b;", "[1]");

        // ==================== 整数幂：回绕 / 负指数转浮点 ====================
        Returns(rep, "V-07", "let a = 2; let b = 64; return a ^ b;", "[0]");
        Returns(rep, "V-07b", "let a = 2; return a ^ -1;", "[0.5]");

        // ==================== 序列重复与拼接 ====================
        Returns(rep, "V-08", "let s = \"ab\"; return s * 2;", "[abab]");
        Returns(rep, "V-08b", "let s = \"ab\"; return 2 * s;", "[abab]");
        Returns(rep, "V-08c", "let b = 'd 1 2'; return b * 2;", "[[1,2,1,2]]");
        Errs(rep, "V-08d", "let s = \"ab\"; let n = -1; return s * n;",
            "\"Mul\" cannot repeat a sequence by a negative number. ");
        Returns(rep, "V-08e", "let a = \"x\"; let b = \"y\"; return a + b;", "[xy]");
        Returns(rep, "V-08f", "let a = 'd 1'; let b = 'd 2'; return a + b;", "[[1,2]]");

        // ==================== 真值 ====================
        Returns(rep, "V-09", "let s = \"\"; if s { return 1; } return 2;", "[2]");
        Returns(rep, "V-09b", "let s = \"x\"; if s { return 1; } return 2;", "[1]");

        // ==================== 除零 ====================
        Errs(rep, "V-10", "let a = 1; let b = 0; return a / b;", "\"Div\" division by zero. ");
        Errs(rep, "V-10b", "let a = 1; let b = 0; return a idiv b;", "\"IDiv\" division by zero. ");
        Errs(rep, "V-10c", "let a = 1; let b = 0; return a % b;", "\"Mod\" division by zero. ");
        Returns(rep, "V-10d", "let a = 1.0; let b = 0; return a / b;", "[inf]");

        // ==================== `!` 只接受 null / 整数 / 浮点 ====================
        Errs(rep, "V-11", "let s = \"abc\"; return !s;",
            "\"Not\" can only operate on integer or float. ");

        // ==================== INT64_MIN 的三个角落 ====================
        Returns(rep, "V-12", "let m = 0 - 9223372036854775807 - 1; return -m;", "[-9223372036854775808]");
        Returns(rep, "V-12b", "let m = 0 - 9223372036854775807 - 1; return m idiv -1;",
            "[-9223372036854775808]");
        Returns(rep, "V-12c", "let m = 0 - 9223372036854775807 - 1; return m % -1;", "[0]");

        // ==================== idiv：含浮点仍向零取整，但保持浮点 ====================
        Returns(rep, "V-13", "let a = 7; let b = 2; return a idiv b;", "[3]");
        Returns(rep, "V-13b", "let a = 7.5; let b = 2; return a idiv b;", "[3.0]");

        // ==================== 相等：类型不同一律不等 ====================
        Returns(rep, "V-15", "let a = \"1\"; let b = 1; return a == b;", "[0]");
        Returns(rep, "V-15b", "let a = null; let b = 0; return a == b;", "[0]");
        Returns(rep, "V-15c", "let a = 'd 1 2'; let b = 'd 1 2'; return a == b;", "[1]");
        Returns(rep, "V-15d", "let a = 'd 1'; let b = 'd 2'; return a == b;", "[0]");
        Returns(rep, "V-15e", "let a = \"ab\"; let n = 0; return a * n;", "[]");

        // ==================== 宿主函数 / 实参表 ====================
        HostFunctionTests(rep);
        ArgumentTests(rep);

        // ==================== 错误串带指令下标 ====================
        {
            var st = Build("return 1 / 0;", null, out _, out _);
            if (st is null || st.Errors.Count != 1)
            {
                rep.AddFail("V-16", "`return 1 / 0;` 应当恰好报一条错");
            }
            else
            {
                // 产物是 PushInt(0) PushInt(1) Div Return(1) —— Div 在下标 4
                // （下标本身就是指令的位置，操作数各占一格）。
                rep.CheckTrue("V-16", "错误串形如 \"4: ...\"：" + st.Errors[0],
                    st.Errors[0].StartsWith("4: \"Div\" division by zero. ", StringComparison.Ordinal));
            }
        }

        // ==================== Run 与 Step 等价 ====================
        RunStepEquivalence(rep);
    }

    private static void HostFunctionTests(Report rep)
    {
        // 宿主函数：一个值，直接放变量槽（对应 C++ 的 Value::Type::HostFunction）
        var st = BuildState("return f(1, 2);", null, out var prog, out var cerrs);
        if (st is null)
        {
            rep.AddFail("V-14", "编译失败：" + string.Join("", cerrs));
            return;
        }
        // 未声明就被调用 → 编译器隐式登记进 exports；槽位号由编译器分配，不能写死
        st.Variables[prog.Exports["f"]] = (Func<object?[], object?>)(argv =>
            (long)argv[0]! + (long)argv[1]!);
        var rc = st.Run();
        rep.Check("V-14", "run 返回", Result.Success.ToString(), rc.ToString());
        rep.Check("V-14", "returns", "[3]", FmtReturns(st));

        // 宿主函数返回 bool：归一成整数（Stope 没有布尔值类型）
        var st2 = BuildState("return g();", null, out var prog2, out _);
        if (st2 is null)
        {
            rep.AddFail("V-14b", "编译失败");
            return;
        }
        st2.Variables[prog2.Exports["g"]] = (Func<object?[], object?>)(_ => true);
        st2.Run();
        rep.Check("V-14b", "returns", "[1]", FmtReturns(st2));

        // Call 到非函数
        var st3 = Build("let x = 1; return x(2);", null, out _, out _);
        if (st3 is null)
        {
            rep.AddFail("V-17", "编译失败");
            return;
        }
        rep.CheckInt("V-17", "错误条数", 1, st3.Errors.Count);
        rep.Check("V-17", "错误消息", "\"Call\" can only call a function. ",
            st3.Errors.Count > 0 ? MsgOnly(st3.Errors[0]) : "<无错误>");
    }

    private static void ArgumentTests(Report rep)
    {
        // argc + args[i]
        var st = Build("return argc + args[0];", new ArrayArgs(new object?[] { 2L }), out _, out _);
        if (st is null)
        {
            rep.AddFail("V-18", "编译失败");
            return;
        }
        rep.Check("V-18", "returns", "[3]", FmtReturns(st)); // argc(1) + args[0](2)

        // 没给实参表
        var st2 = Build("return argc;", null, out _, out _);
        if (st2 is null)
        {
            rep.AddFail("V-19", "编译失败");
            return;
        }
        rep.CheckInt("V-19", "错误条数", 1, st2.Errors.Count);
        rep.Check("V-19", "错误消息", "no args. ",
            st2.Errors.Count > 0 ? MsgOnly(st2.Errors[0]) : "<无错误>");

        // 实参表越界由宿主自己报错
        var st3 = Build("return args[5];", new ArrayArgs(new object?[] { 1L }), out _, out _);
        if (st3 is null)
        {
            rep.AddFail("V-20", "编译失败");
            return;
        }
        rep.CheckInt("V-20", "错误条数", 1, st3.Errors.Count);
        rep.Check("V-20", "错误消息", "argument out of range. ",
            st3.Errors.Count > 0 ? MsgOnly(st3.Errors[0]) : "<无错误>");
    }

    /// <summary>
    /// <see cref="State.Run"/> 与 <see cref="State.Step"/> 是两份独立实现（热循环不套函数
    /// 调用）。这里把同一批程序跑两遍：返回值必须一致，**指令条数也必须一致**。
    /// </summary>
    private static void RunStepEquivalence(Report rep)
    {
        // linear = 没有跳转（顺序执行），只有这种才能断言「步数 == 指令流长度」；
        // 带 while / if / 短路运算符的程序会跳，执行条数天然多于产物长度。
        (string Src, bool Linear)[] srcs =
        {
            ("return 1 + 2 * 3;", true),
            ("let a = 1; while a < 5 { a = a + 1; } return a;", false),
            ("let s = 0; let i = 0; while i < 10 { if i % 2 == 0 { s = s + i; } i = i + 1; } return s;", false),
            ("let a = 1; let b = 2; return a < b and b < 3;", false),
            ("if 1 { return 10; } else { return 20; }", false),
            ("let x = 0; while { x = x + 1; if x > 3 { break; } } return x;", false),
        };

        foreach (var (src, linear) in srcs)
        {
            // Run
            var st1 = Build(src, null, out var prog1, out var e1);
            if (st1 is null)
            {
                rep.AddFail("V-21", "编译失败：" + src + " | " + string.Join("", e1));
                continue;
            }

            // Step：一条一条走，同时数条数
            var tree = new Prog();
            new Parser(new Lexer(src)).ParseProgram(tree);
            var prog2 = new Program();
            new Compiler().Compile(tree, prog2);
            var st2 = new State();
            st2.Reset(new Api(), prog2, null);
            int steps = 0;
            for (;;)
            {
                if (st2.I >= prog2.Opcodes.Count) break; // 已经走完
                if (st2.Step() != Result.Success) break;
                ++steps;
                if (steps > 100000) break;
            }

            rep.Check("V-21 " + src, "returns", FmtReturns(st1), FmtReturns(st2));
            rep.Check("V-21 " + src, "errors", string.Join("|", st1.Errors), string.Join("|", st2.Errors));
            rep.CheckTrue("V-21 " + src, "Step 应把指令流走完", st2.I >= prog2.Opcodes.Count);
            // 顺序执行的程序：走的条数 == 指令条数（操作数不单独算一步）
            if (linear) rep.CheckInt("V-21 " + src, "步数应等于指令条数", InstructionCount(prog1), steps);
        }
    }
}
