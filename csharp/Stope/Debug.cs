using System;
using System.Collections.Generic;
using System.Text;

namespace Stope;

/// <summary>
/// <see cref="Program"/> 反汇编（调试用）—— 端口 <c>cpp/include/stope/debug.hpp</c> 的
/// <c>Disasm</c>。
/// <para>
/// 内置 33 条指令的名字与「是否带操作数」是固定的；自定义指令（编号 &gt;
/// <see cref="Opcode.Return"/>）的名字、参数个数只有 <see cref="CustomOpcodeConfig"/> 知道。
/// 所以产物里只要可能有自定义指令，就得用 <c>Disasm(program, config)</c> 打印：
/// </para>
/// <list type="bullet">
/// <item>不带 config 只能用 <c>Custom#编号</c> 占位，而且变长指令后面那个「参数个数」
/// 会被当成下一条指令（两者只差一个整数，读起来全错位）；</item>
/// <item>带 config 才会印出名字，并按 <see cref="CustomOpcode.IsVarArg"/> 决定要不要吃掉
/// 后面那个数。</item>
/// </list>
/// <para>
/// 输出与 C++ / GDScript / Node.js 逐字节一致（<c>golden_disasm.txt</c> 是四方的共同期望值）：
/// 编号列宽 8、名字列宽 max(10, 最长名字)、int/float 常量同列连排、字符串常量一行一个、
/// 二进制数组只印字节数、最后是 warning 段。
/// </para>
/// </summary>
public static class Debug
{
    /// <summary>
    /// 下标与内置名一一对应，顺序必须跟 <see cref="Opcode"/> 枚举一致。
    /// 加枚举项时这里必须同步。
    /// </summary>
    public static readonly string[] BuiltinNames =
    {
        "Assign", "PushNull", "PushFalse", "PushTrue", "PushInt",
        "PushFloat", "PushString", "PushBinArr", "PushValue", "PushId",
        "Call", "At", "Pop", "Minus", "Not",
        "Pow", "Mul", "Div", "IDiv", "Mod",
        "Add", "Sub", "EQ", "NE", "LT",
        "LE", "GT", "GE", "If", "GoTo",
        "GetArg", "ArgNum", "Return",
    };

    /// <summary>内置指令条数（= 数组长度，33）。</summary>
    public static readonly int BuiltinOpcodeCount = BuiltinNames.Length;

    /// <summary>
    /// 名字列的对齐宽度下限 = 内置名里最长的两个（<c>PushString</c> / <c>PushBinArr</c>，
    /// 10 字节）。自定义名更长时整列变宽。名字按 <b>UTF-8 字节数</b>丈量（非 ASCII 名会把
    /// 列撑宽一点），与 C++ 一致。
    /// </summary>
    private const int MinOpcodeNameWidth = 10;

    private static string PadRight(string s, int width) =>
        s.Length >= width ? s : s + new string(' ', width - s.Length);

    private static int NameWidthOf(string s) => Encoding.UTF8.GetByteCount(s);

    /// <summary>
    /// 内置指令是否带一个操作数（操作数占紧随其后的一个整数）。
    /// 自定义指令不走这里：它们的「带不带操作数」由 <see cref="CustomOpcodeConfig"/> 决定。
    /// </summary>
    public static bool OpcodeHasArg(int op)
    {
        if (op >= (int)Opcode.PushInt && op <= (int)Opcode.At) return true;
        if (op == (int)Opcode.If || op == (int)Opcode.GoTo || op == (int)Opcode.Return) return true;
        return false;
    }

    /// <summary>
    /// 自定义指令只有在变长参数时才带操作数 —— 那个操作数是本次调用的参数个数
    /// （定长指令的参数个数是注册时定死的，产物里不再重复写）。
    /// </summary>
    public static bool CustomOpcodeHasArg(int raw, CustomOpcodeConfig? config)
    {
        if (config is null) return false;
        foreach (var info in config.Opcodes.Values)
            if (info.Opcode == raw && info.IsVarArg)
                return true;
        return false;
    }

    /// <summary>产物里确定没有自定义指令时的简写。</summary>
    public static string DisasmNoCustom(Program prog) => Disasm(prog, null);

    /// <summary>
    /// 把 <see cref="Program"/> 反汇编成可读文本。
    /// <para>
    /// <paramref name="config"/> 可空：产物里没有自定义指令时传 null 即可。含自定义指令时
    /// <b>必须</b>传注册时用的那一份，否则名字、变长指令的参数个数都无从得知。
    /// </para>
    /// </summary>
    public static string Disasm(Program prog, CustomOpcodeConfig? config = null)
    {
        // ---------- 编号 -> (名字, 注册项) 的反查表 ----------
        var customByOpcode = new Dictionary<int, (string Name, CustomOpcode Info)>();
        var warnings = new List<string>();
        int nameWidth = MinOpcodeNameWidth;

        if (config is not null)
        {
            // C++ 的 CustomOpcodeConfig 是 std::map（按名字字典序）。这里显式排序，
            // 否则「谁先注册谁在前」会让自定义指令表的行序与 C++ 不一致。
            var names = new List<string>(config.Opcodes.Keys);
            names.Sort(StringComparer.Ordinal);
            foreach (var name in names)
            {
                var info = config.Opcodes[name];
                if (info.Opcode < OpcodeLimits.FirstCustomOpcode)
                {
                    string what = info.Opcode >= 0 && info.Opcode < BuiltinOpcodeCount
                        ? BuiltinNames[info.Opcode]
                        : "(not an opcode)";
                    warnings.Add($"custom opcode \"{name}\" uses #{info.Opcode}, which collides with {what}; builtin decoding wins.");
                    continue;
                }
                if (customByOpcode.TryGetValue(info.Opcode, out var prev))
                {
                    warnings.Add($"custom opcodes \"{prev.Name}\" and \"{name}\" share #{info.Opcode}; the former wins.");
                    continue;
                }
                customByOpcode[info.Opcode] = (name, info);
                nameWidth = Math.Max(nameWidth, NameWidthOf(name));
            }
        }

        // ---------- 指令流 ----------
        var sb = new StringBuilder();
        var unknown = new List<int>(); // 不认识的编号，最后统一提示（保持首次出现顺序）
        int n = prog.Opcodes.Count;
        for (int i = 0; i < n; ++i)
        {
            int raw = prog.Opcodes[i];
            string name;
            bool hasArg = false;
            if (raw >= 0 && raw < BuiltinOpcodeCount)
            {
                name = BuiltinNames[raw];
                hasArg = OpcodeHasArg(raw);
            }
            else if (customByOpcode.TryGetValue(raw, out var it))
            {
                name = it.Name;
                hasArg = it.Info.IsVarArg;
            }
            else
            {
                // 编号不认识就只能印数字。绝不能猜「有没有操作数」，否则会把下一条指令
                // 当成操作数吃掉、后面整段错位。
                name = raw > (int)Opcode.Return ? "Custom" + raw : "Op#" + raw;
                if (!unknown.Contains(raw)) unknown.Add(raw);
            }
            sb.Append(PadRight("[" + i + "]", 8)).Append(PadRight(name, nameWidth)).Append(' ');
            if (hasArg)
            {
                if (i + 1 < n)
                {
                    sb.Append(prog.Opcodes[++i]);
                }
                else
                {
                    sb.Append("<missing operand>");
                    warnings.Add($"opcode at [{i}] expects an operand but the stream ends there.");
                }
            }
            sb.Append('\n');
        }

        // ---------- 自定义指令表（名字、编号、参数形态一次交代清楚） ----------
        if (customByOpcode.Count > 0)
        {
            sb.Append("custom opcodes:\n");
            // 必须按**编号**排序打印：C++ 的 customByOpcode 是 map<short, ...>，迭代序是
            // 编号序。上面那张表是按名字排序建的（撞号时「谁赢」取决于此，与 C++ 一致），
            // 直接迭代会印成名字序，多指令时与 C++ 不一致。
            var opcodes = new List<int>(customByOpcode.Keys);
            opcodes.Sort();
            foreach (var raw in opcodes)
            {
                var (name, info) = customByOpcode[raw];
                sb.Append("  ").Append(PadRight(name, nameWidth)).Append(" -> ").Append(info.Opcode);
                if (info.IsVarArg) sb.Append(" (vararg)");
                else sb.Append(" (").Append(info.ArgNum).Append(" args)");
                sb.Append('\n');
            }
        }

        // ---------- 变量表与常量池 ----------
        sb.Append("variables:\n");
        var vars = new string[prog.VariableNum];
        Array.Fill(vars, "");
        foreach (var (name, idx) in prog.Exports)
            if (idx >= 0 && idx < vars.Length)
                vars[idx] = name;
        sb.Append("  ");
        for (int i = 0; i < vars.Length; ++i)
        {
            sb.Append('"').Append(vars[i]).Append('"');
            if (i < vars.Length - 1) sb.Append(' ');
        }
        sb.Append("\nint consts:\n");
        foreach (var v in prog.IntConsts) sb.Append("  ").Append(v);
        sb.Append("\nfloat consts:\n");
        foreach (var v in prog.FloatConsts) sb.Append("  ").Append(Format.FmtG(v));
        sb.Append("\nstring consts:\n");
        foreach (var v in prog.StringConsts) sb.Append("  \"").Append(v).Append("\"\n");
        sb.Append("binary array consts:\n");
        foreach (var v in prog.BinArrConsts) sb.Append("  ").Append(v.Length).Append(" bytes\n");
        sb.Append("max return num: ").Append(prog.MaxReturnNum).Append('\n');
        sb.Append("required stack size: ").Append(prog.RequiredStackSize).Append('\n');

        foreach (var raw in unknown)
        {
            if (raw > (int)Opcode.Return)
                warnings.Add($"opcode #{raw} is not a builtin; pass the CustomOpcodeConfig to Disasm() to decode it.");
            else
                warnings.Add($"opcode #{raw} is not a valid instruction (unpatched placeholder?).");
        }
        foreach (var w in warnings) sb.Append("warning: ").Append(w).Append('\n');
        return sb.ToString();
    }
}
