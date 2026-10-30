using System.Collections.Generic;

namespace Stope;

/// <summary>
/// 程序 = 指令流 + 常量池 + 变量表 —— 对应 <c>cpp/include/stope/program.hpp</c>。
/// <para>
/// 字段名取 C++ 的 camelCase 形式，容器都给默认空值：<c>new Program()</c> 拿到的就是
/// 可直接编译 / 执行的空程序。
/// </para>
/// <para>
/// <b>指令流是扁平的</b>：指令与操作数混在同一个序列里（<see cref="Opcodes"/>）。
/// 带操作数的指令见 <see cref="Debug.OpcodeHasArg"/>；自定义指令只在变长参数时多写一个
/// 「本次实参个数」。跳转目标（<c>If</c> / <c>GoTo</c>）存的是 <b>Opcodes 的下标</b>。
/// </para>
/// </summary>
public sealed class Program
{
    /// <summary>指令与操作数混排；元素都在 int16 范围内。</summary>
    public List<int> Opcodes = new();

    /// <summary>变量数量（槽位个数）。</summary>
    public int VariableNum;

    /// <summary>导出变量名 → 槽位。只有 <c>export</c> 与「未声明就使用的标识符」会进这里。</summary>
    public Dictionary<string, int> Exports = new();

    public List<long> IntConsts = new();
    public List<double> FloatConsts = new();
    public List<string> StringConsts = new();
    public List<byte[]> BinArrConsts = new();

    /// <summary>return 语句最大返回值数量。</summary>
    public int MaxReturnNum;

    /// <summary>执行这段产物需要的最小栈容量（编译器线性记账算出来的）。</summary>
    public int RequiredStackSize;

    /// <summary>清空成「刚构造」的状态（编译器在每次 <c>Compile</c> 开头调用）。</summary>
    public void Clear()
    {
        Opcodes.Clear();
        IntConsts.Clear();
        FloatConsts.Clear();
        StringConsts.Clear();
        BinArrConsts.Clear();
        Exports.Clear();
        VariableNum = 0;
        MaxReturnNum = 0;
        RequiredStackSize = 0;
    }
}
