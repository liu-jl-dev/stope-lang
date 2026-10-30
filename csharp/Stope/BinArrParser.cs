using System.Collections.Generic;

namespace Stope;

/// <summary>
/// 二进制数组字面量【内容】的解析 —— 端口 <c>cpp/src/parse_binarr.cpp</c>。
/// <para>
/// 规则见 <c>docs/zh-cn/syntax-reference.md</c> §2.6，与 C++ 逐条一致：
/// <list type="bullet">
/// <item><c>b/B o/O d/D x/X</c> 前缀选进制；<b>没有前缀按 16</b>（首字符就是数据本身，不能被吃掉）</item>
/// <item>每段数字产生一个字节；段内可含 <c>_</c>，段之间用空白分隔</item>
/// <item>超出一个字节的值<b>静默截断</b>到低 8 位且不报错：<c>'d 300'</c> → <c>0x2C</c></item>
/// <item>出现该进制不允许的字符（如 <c>'x zz'</c>）→ 返回 <see cref="Result.Error"/></item>
/// <item>空内容合法，得到零长数组；只有前缀没有数据（如 <c>'b'</c>）同样是零长数组</item>
/// </list>
/// </para>
/// <para>
/// ⚠ 注意岔路：<c>'b 0100 0001'</c> 是<b>两个字节</b> <c>04 01</c>，不是 <c>0x41</c> ——
/// 二进制前缀下要写满 8 位。
/// </para>
/// </summary>
public sealed class BinArrParser
{
    private const int IntMax = int.MaxValue;

    private string _input = "";
    private int _pos;

    /// <summary>
    /// 解析 <paramref name="input"/>（<b>不含单引号</b>），字节依次追加到
    /// <paramref name="output"/>。失败时 <paramref name="output"/> 可能已写入前半段，
    /// 调用方负责丢弃（parser 走「报错但继续」的路径）。
    /// </summary>
    public Result Parse(string input, List<byte> output)
    {
        _input = input;
        _pos = 0;
        SkipWs();
        if (Eof) return Result.Success;

        int radix = 16;
        char c = _input[_pos];
        if (c is 'b' or 'B')
        {
            _pos += 1;
            radix = 2;
        }
        else if (c is 'o' or 'O')
        {
            _pos += 1;
            radix = 8;
        }
        else if (c is 'd' or 'D')
        {
            _pos += 1;
            radix = 10;
        }
        else if (c is 'x' or 'X')
        {
            _pos += 1;
            radix = 16;
        }
        return ParseByBase(output, radix);
    }

    private Result ParseByBase(List<byte> output, int radix)
    {
        SkipWs();
        while (!Eof)
        {
            if (!ParseInteger(radix, out int value)) return Result.Error;
            output.Add((byte)(value & 0xff)); // 超 0xFF 静默截断，等价于 C++ 的 static_cast<char>
            SkipWs();
        }
        return Result.Success;
    }

    /// <summary>
    /// 空段（只有下划线）与超出 int 范围的段都判失败 —— 与 <c>std::stoi</c> 抛异常等价。
    /// </summary>
    private bool ParseInteger(int radix, out int result)
    {
        result = 0;
        int n = 0;
        bool any = false;
        while (!Eof)
        {
            char c = _input[_pos];
            if (IsWs(c)) break;
            int d = DigitOf(c, radix);
            if (d >= 0)
            {
                if (n > (IntMax - d) / radix) return false;
                n = n * radix + d;
                _pos += 1;
                any = true;
            }
            else if (c == '_')
            {
                _pos += 1;
            }
            else
            {
                _pos += 1;
                return false;
            }
        }
        if (!any) return false;
        result = n;
        return true;
    }

    private bool Eof => _pos >= _input.Length;

    private void SkipWs()
    {
        while (!Eof && IsWs(_input[_pos])) _pos += 1;
    }

    private static bool IsWs(char c) => c is ' ' or '\t' or '\n' or '\r' or '\v' or '\f';

    /// <summary>该进制下的数值；不是该进制的字符返回 -1。</summary>
    private static int DigitOf(char c, int radix)
    {
        int d = -1;
        if (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        return d >= 0 && d < radix ? d : -1;
    }
}
