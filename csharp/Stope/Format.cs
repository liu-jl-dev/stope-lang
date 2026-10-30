using System;
using System.Globalization;
using System.Text;

namespace Stope;

/// <summary>
/// 跨实现共用的格式化工具。三个函数都必须与 C++ 侧逐字节一致 —— 期望值全部是
/// C++ 探针 dump 出来的字符串，差一个字符测试就红。
/// </summary>
public static class Format
{
    /// <summary>
    /// 与 C++ 的 <c>escUtf8</c> 一致：只转义 <c>\ " \n \r \t</c>，其余非 ASCII 打成 '?'。
    /// 按**码点**遍历（与 nodejs 的 <c>for...of</c> 一致），所以非 BMP 字符只出一个 '?'。
    /// </summary>
    public static string Esc(string s)
    {
        var sb = new StringBuilder(s.Length);
        for (int i = 0; i < s.Length; ++i)
        {
            char ch = s[i];
            if (ch == '\\') sb.Append("\\\\");
            else if (ch == '"') sb.Append("\\\"");
            else if (ch == '\n') sb.Append("\\n");
            else if (ch == '\r') sb.Append("\\r");
            else if (ch == '\t') sb.Append("\\t");
            else if (char.IsHighSurrogate(ch) && i + 1 < s.Length && char.IsLowSurrogate(s[i + 1]))
            {
                sb.Append('?'); // 非 BMP：整个码点只出一个 '?'
                ++i;
            }
            else if (ch < 128) sb.Append(ch);
            else sb.Append('?');
        }
        return sb.ToString();
    }

    /// <summary>
    /// 二进制数组的字节十六进制，小写两位，逗号分隔：<c>04,01</c>。
    /// </summary>
    public static string FmtBytes(byte[] bytes)
    {
        var sb = new StringBuilder(bytes.Length * 3);
        for (int i = 0; i < bytes.Length; ++i)
        {
            if (i > 0) sb.Append(',');
            sb.Append(bytes[i].ToString("x2", CultureInfo.InvariantCulture));
        }
        return sb.ToString();
    }

    /// <summary>
    /// 复刻 C 的 <c>printf("%g")</c>（精度 6）。.NET 没有等价物，所以照 nodejs / GDScript
    /// 侧的 <c>fmtG</c> 手工实现同一套决策：
    /// <list type="bullet">
    /// <item>先取十进制指数 X（10^X ≤ |v| &lt; 10^(X+1)）</item>
    /// <item>X &lt; -4 或 X ≥ 6 → 科学计数法，尾数 5 位小数</item>
    /// <item>否则 → 定点表示，5 - X 位小数</item>
    /// </list>
    /// 两种情形都去掉尾部 0 与孤立的小数点。舍入进位到 10 时 X 要 +1 再重新决策，
    /// 否则 999999.9 会打成 <c>1e+06</c> 而 glibc 打 <c>100000</c>。
    /// <para>
    /// 已知边界（与另外两份实现相同）：次正规数（|v| &lt; 2.2e-308）不保证 6 位有效数字，
    /// 所以用例里不要拿次正规数做跨实现比对。
    /// </para>
    /// </summary>
    public static string FmtG(double v)
    {
        if (double.IsNaN(v)) return "nan";
        if (double.IsInfinity(v)) return v > 0 ? "inf" : "-inf";
        if (v == 0.0) return double.IsNegative(v) ? "-0" : "0";

        const int precision = 6;
        string sign = v < 0 ? "-" : "";
        double a = Math.Abs(v);

        int x = (int)Math.Floor(Math.Log10(a));
        int guard = 40; // Math.Pow 的误差可能让初值差 1，最多校正这么多次
        while (guard-- > 0 && Math.Pow(10, x) > a) x -= 1;
        while (guard-- > 0 && Math.Pow(10, x + 1) <= a) x += 1;

        // 尾数：6 位有效数字 == 保留 5 位小数（尾数恒在 [1, 10)）
        double mant = Math.Round(a / Math.Pow(10, x), precision - 1, MidpointRounding.AwayFromZero);
        string mantStr = mant.ToString("F5", CultureInfo.InvariantCulture);
        if (mantStr.StartsWith("10", StringComparison.Ordinal))
        { // 舍入进位（9.999999 -> 10.00000）
            x += 1;
            mantStr = "1.00000";
        }

        if (x < -4 || x >= precision)
        {
            return sign + StripZeros(mantStr) + "e" + (x >= 0 ? "+" : "-")
                   + Math.Abs(x).ToString("D2", CultureInfo.InvariantCulture);
        }

        int digits = Math.Max(0, precision - 1 - x);
        double fixedVal = Math.Round(a, digits, MidpointRounding.AwayFromZero);
        return sign + StripZeros(fixedVal.ToString("F" + digits.ToString(CultureInfo.InvariantCulture),
            CultureInfo.InvariantCulture));
    }

    /// <summary>去掉小数尾部多余的 0，以及随之孤立的小数点：<c>1.50000</c> → <c>1.5</c>。</summary>
    private static string StripZeros(string s)
    {
        if (s.IndexOf('.') < 0) return s;
        s = s.TrimEnd('0');
        if (s.EndsWith(".", StringComparison.Ordinal)) s = s[..^1];
        return s;
    }
}
