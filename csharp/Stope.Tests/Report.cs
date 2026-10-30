using System;
using System.Collections.Generic;

namespace Stope.Tests;

/// <summary>
/// 极简断言与汇总。**不是测试框架**：没有测试发现、没有 fixture，只是一组「比一下、
/// 记一笔」的方法 —— 目标是让 <c>dotnet run</c> 的输出与 GDScript / nodejs 两侧的测试
/// 汇总格式一致，方便三条命令横向对照。
/// </summary>
public sealed class Report
{
    public int Pass;
    public int Fail;
    private readonly List<string> _messages = new();
    private const int MaxShown = 40;

    public void Check(string id, string field, string want, string got)
    {
        if (string.Equals(want, got, StringComparison.Ordinal))
        {
            ++Pass;
            return;
        }
        ++Fail;
        if (_messages.Count < MaxShown)
        {
            _messages.Add($"  FAIL {id} [{field}]\n        期望: {Show(want)}\n        实际: {Show(got)}");
        }
        else if (_messages.Count == MaxShown)
        {
            _messages.Add("  ... 更多失败已省略");
        }
    }

    public void CheckInt(string id, string field, long want, long got) =>
        Check(id, field, want.ToString(System.Globalization.CultureInfo.InvariantCulture),
            got.ToString(System.Globalization.CultureInfo.InvariantCulture));

    public void CheckTrue(string id, string what, bool ok)
    {
        if (ok)
        {
            ++Pass;
            return;
        }
        ++Fail;
        if (_messages.Count < MaxShown) _messages.Add($"  FAIL {id} {what}");
    }

    public void AddFail(string id, string why)
    {
        ++Fail;
        if (_messages.Count < MaxShown) _messages.Add($"  FAIL {id} {why}");
    }

    /// <summary>把一段失败详情打进输出（用于长串 diff 之前先打印上下文）。</summary>
    public void Dump()
    {
        foreach (var m in _messages) Console.WriteLine(m);
        _messages.Clear();
    }

    public static string Show(string s)
    {
        if (s.Length == 0) return "<空>";
        string t = s.Replace("\n", "\\n", StringComparison.Ordinal);
        return t.Length > 300 ? t[..300] + "…" : t;
    }
}
