using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace Stope.Tests;

/// <summary>
/// golden 数据的读取与「单行产物格式」的生成。
/// <para>
/// 数据由 <c>cpp/tools/</c> 下的探针生成，入库在 <c>gdscript/test/data/</c>（仓库里只有这一份；
/// GDScript 侧从 <c>res://test/data/</c> 读、nodejs 侧从相对路径读，本实现也从同一个目录读 ——
/// 不复制第二份，否则 C++ 改行为时会出现「哪一份才是真值」的问题）。
/// 重生成（在 <c>cpp/</c> 下）：<c>cmake --build build --target gen-golden</c>。
/// </para>
/// <para>
/// 记录格式：一条用例一行，字段之间用 TAB，每个字段是 KEY=VALUE，值里的 <c>\\ \n \r \t</c>
/// 已转义。解析后按 KEY 取用即可。
/// </para>
/// </summary>
public static class Data
{
    /// <summary><c>gdscript/test/data</c> 的绝对路径（从可执行文件所在目录向上找）。</summary>
    public static readonly string Dir = LocateDataDir();

    private static string LocateDataDir()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            string candidate = Path.Combine(dir.FullName, "gdscript", "test", "data");
            if (Directory.Exists(candidate)) return candidate;
            dir = dir.Parent;
        }
        throw new DirectoryNotFoundException(
            "找不到 gdscript/test/data —— 请在仓库里运行（测试数据不入 NuGet 包）。");
    }

    public static string ReadText(string name) =>
        File.ReadAllText(Path.Combine(Dir, name)).Replace("\r", "", StringComparison.Ordinal);

    /// <summary>反转义：与探针的 <c>E_()</c> 对称。</summary>
    public static string Unescape(string s)
    {
        var sb = new StringBuilder(s.Length);
        for (int i = 0; i < s.Length; ++i)
        {
            if (s[i] != '\\')
            {
                sb.Append(s[i]);
                continue;
            }
            char c = ++i < s.Length ? s[i] : '\0';
            switch (c)
            {
                case '\\': sb.Append('\\'); break;
                case 'n': sb.Append('\n'); break;
                case 'r': sb.Append('\r'); break;
                case 't': sb.Append('\t'); break;
                default:
                    sb.Append('\\').Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    /// <summary>
    /// 与 <see cref="Unescape"/> 相同，但**多认 <c>\v</c> 与 <c>\f</c>** ——
    /// <c>golden_lex.txt</c> 的 <c>SRC</c> 用这一套（空白类用例要写出真正的垂直制表 / 换页符）。
    /// 另外这个文件的 <c>TOKS</c> / <c>LEXEMES</c> / <c>ERRS</c> **不做二次转义**，
    /// 读的时候要 <c>unescapeValues: false</c>，比对的是 esc-lex 形态。
    /// </summary>
    public static string UnescapeLex(string s)
    {
        var sb = new StringBuilder(s.Length);
        for (int i = 0; i < s.Length; ++i)
        {
            if (s[i] == '\\' && i + 1 < s.Length)
            {
                char c = s[i + 1];
                switch (c)
                {
                    case '\\': sb.Append('\\'); i += 1; continue;
                    case 'n': sb.Append('\n'); i += 1; continue;
                    case 'r': sb.Append('\r'); i += 1; continue;
                    case 't': sb.Append('\t'); i += 1; continue;
                    case 'v': sb.Append('\v'); i += 1; continue;
                    case 'f': sb.Append('\f'); i += 1; continue;
                }
            }
            sb.Append(s[i]);
        }
        return sb.ToString();
    }

    /// <summary>
    /// 读一份 golden 文件 → 若干 <c>KEY=VALUE</c> 字典，行首 <c>#</c> 是注释。
    /// <para>
    /// <paramref name="unescapeValues"/>：<c>golden.txt</c> 与 <c>golden_disasm.txt</c> 的字段
    /// 经过探针的 <c>E_()</c> <b>二次</b>转义（先 escUtf8 再 E_），读进来要解一层；
    /// <c>golden_stml.txt</c> 的 SHAPE/ERRS 只做了 escUtf8、没有再套 E_，多解一层会把
    /// <c>\n</c> 变成真换行。
    /// </para>
    /// </summary>
    public static List<Dictionary<string, string>> ReadGolden(string name, bool unescapeValues = true)
    {
        var outList = new List<Dictionary<string, string>>();
        foreach (var line in ReadText(name).Split('\n'))
        {
            if (line.Length == 0 || line.StartsWith("#", StringComparison.Ordinal)) continue;
            var rec = new Dictionary<string, string>();
            foreach (var field in line.Split('\t'))
            {
                int eq = field.IndexOf('=');
                if (eq < 0) continue;
                string v = field[(eq + 1)..];
                rec[field[..eq]] = unescapeValues ? Unescape(v) : v;
            }
            if (rec.Count == 0) continue;
            outList.Add(rec);
        }
        return outList;
    }

    /// <summary>
    /// 与 C++ 的 <c>escUtf8</c> 完全一致：<c>\ " \n \r \t</c> 转义，非 ASCII 一律变 <c>?</c>。
    /// 形状串与 STML 的 tag / text 比对用。
    /// </summary>
    public static string Esc(string s) => Format.Esc(s);

    /// <summary>
    /// 词法比对专用转义（比 <see cref="Esc"/> 多 <c>\v \f</c>、不转义引号）——
    /// 与 GD 的 <c>esc_lex</c> / C++ 探针的 lexeme 转义一致。
    /// </summary>
    public static string EscLex(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (char ch in s)
        {
            switch (ch)
            {
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                case '\v': sb.Append("\\v"); break;
                case '\f': sb.Append("\\f"); break;
                default: sb.Append(ch); break;
            }
        }
        return sb.ToString();
    }

    /// <summary>
    /// <c>E_()</c> 那一套：把 <c>\</c> 与 <c>"</c> 双写。<c>golden_stml.txt</c> 的 ERRS 没有
    /// 二次解转义，所以错误文案里的引号要以 <c>\"</c> 形态比对（形状串不用，那里引号是语法的一部分）。
    /// </summary>
    public static string EscQuote(string s) => s.Replace("\\", "\\\\").Replace("\"", "\\\"");

    public static string JoinQuoted(List<string> errs)
    {
        var parts = new List<string>(errs.Count);
        foreach (var e in errs) parts.Add(EscQuote(e));
        return string.Join("|", parts);
    }

    public static string JoinEsc(List<string> errs)
    {
        var parts = new List<string>(errs.Count);
        foreach (var e in errs) parts.Add(EscLex(e));
        return string.Join("|", parts);
    }

    /// <summary>
    /// 「单行产物格式」（<c>docs/zh-cn/compiler-test-plan.md</c> §2.3），对应 C++ 的私有
    /// <c>dumpLine</c> 与 GD 的 <c>dump_program</c> —— 三方都不进库，只在测试里用。
    /// </summary>
    public static string DumpProgram(Program p, CustomOpcodeConfig? custom = null)
    {
        var sb = new StringBuilder("code[");
        int i = 0;
        while (i < p.Opcodes.Count)
        {
            if (i > 0) sb.Append(' ');
            int op = p.Opcodes[i];
            ++i;
            bool hasParam;
            if (op > (int)Opcode.Return)
            {
                sb.Append("Opcode(").Append(op).Append(')');
                hasParam = false;
                if (custom is not null)
                {
                    foreach (var info in custom.Opcodes.Values)
                    {
                        if (info.Opcode == op)
                        {
                            hasParam = info.IsVarArg;
                            break;
                        }
                    }
                }
            }
            else if (op <= (int)Opcode.PushTrue) hasParam = false;
            else if (op <= (int)Opcode.At) hasParam = true;
            else if (op <= (int)Opcode.GE) hasParam = false;
            else if (op <= (int)Opcode.GoTo) hasParam = true;
            else if (op <= (int)Opcode.ArgNum) hasParam = false;
            else hasParam = true;
            if (op <= (int)Opcode.Return) sb.Append(Debug.BuiltinNames[op]);
            if (hasParam && i < p.Opcodes.Count)
            {
                sb.Append('(').Append(p.Opcodes[i]).Append(')');
                ++i;
            }
        }
        sb.Append(']');
        sb.Append(" vars=").Append(p.VariableNum);
        sb.Append(" stack=").Append(p.RequiredStackSize);
        sb.Append(" maxRet=").Append(p.MaxReturnNum);
        sb.Append(" ints=[");
        for (int k = 0; k < p.IntConsts.Count; ++k)
        {
            if (k > 0) sb.Append(',');
            sb.Append(p.IntConsts[k].ToString(CultureInfo.InvariantCulture));
        }
        sb.Append("] floats=[");
        for (int k = 0; k < p.FloatConsts.Count; ++k)
        {
            if (k > 0) sb.Append(',');
            // 用 %g 的忠实实现（Format.FmtG）；golden 里的浮点都在定点范围内，
            // 与 C++ 探针的 printf("%g") 逐字节相同。
            sb.Append(Format.FmtG(p.FloatConsts[k]));
        }
        sb.Append("] strs=[");
        for (int k = 0; k < p.StringConsts.Count; ++k)
        {
            if (k > 0) sb.Append(',');
            sb.Append(Esc(p.StringConsts[k]));
        }
        sb.Append("] binarrs=[");
        for (int k = 0; k < p.BinArrConsts.Count; ++k)
        {
            if (k > 0) sb.Append(' ');
            sb.Append('[').Append(Format.FmtBytes(p.BinArrConsts[k])).Append(']');
        }
        sb.Append("] exports=[");
        // C++ 的 exports 是 std::map：按名字字典序打印（不是插入序）
        var names = new List<string>(p.Exports.Keys);
        names.Sort(StringComparer.Ordinal);
        for (int k = 0; k < names.Count; ++k)
        {
            if (k > 0) sb.Append(',');
            sb.Append(Esc(names[k])).Append(':').Append(p.Exports[names[k]]);
        }
        sb.Append(']');
        return sb.ToString();
    }
}
