using System.Collections.Generic;

namespace Stope;

/// <summary>
/// 指令集 —— 与 <c>cpp/include/stope/opcode.hpp</c> 同序同值。
/// <para>
/// ⚠ 加枚举项必须同步三张「按序号对应」的表：<see cref="Debug.BuiltinNames"/>、
/// <c>BasicVm.Api</c> 的默认指令表，以及反汇编器里的「是否带操作数」判断（<see cref="Debug.OpcodeHasArg"/>）。
/// 少一项就是运行期越界或者整段指令错位。
/// </para>
/// </summary>
public enum Opcode
{
    Assign = 0,
    PushNull = 1,
    PushFalse = 2,
    PushTrue = 3,
    PushInt = 4,
    PushFloat = 5,
    PushString = 6,
    PushBinArr = 7,
    PushValue = 8,
    PushId = 9,

    Call = 10,
    At = 11,
    Pop = 12,
    Minus = 13,
    Not = 14,
    Pow = 15,
    Mul = 16,
    Div = 17,
    IDiv = 18,
    Mod = 19,

    Add = 20,
    Sub = 21,
    EQ = 22,
    NE = 23,
    LT = 24,
    LE = 25,
    GT = 26,
    GE = 27,
    If = 28,
    GoTo = 29,

    GetArg = 30,
    ArgNum = 31,
    Return = 32,
}

/// <summary>自定义指令的起始编号（33）。产物里 ≥ 它的编号都不是内置指令。</summary>
public static class OpcodeLimits
{
    public const int FirstCustomOpcode = (int)Opcode.Return + 1;

    /// <summary>内置指令条数（33）。</summary>
    public const int BuiltinCount = (int)Opcode.Return + 1;
}

/// <summary>登记表里的一条自定义指令。</summary>
public sealed class CustomOpcode
{
    /// <summary>指令编号（产物里就写这个数）。</summary>
    public int Opcode;

    /// <summary>参数个数；负数表示变长（产物里会多写一个「本次实参个数」）。</summary>
    public int ArgNum;

    public CustomOpcode(int opcode, int argNum = -1)
    {
        Opcode = opcode;
        ArgNum = argNum;
    }

    public bool IsVarArg => ArgNum < 0;
}

/// <summary>
/// 名字 → <see cref="CustomOpcode"/> 的登记表。
/// <para>
/// <b>Lexer / Parser / Compiler / Disasm 必须共用同一份对象</b> —— 各建一份会出现
/// 「编译期找不到指令」或者「反汇编印不出名字」。名字是普通标识符或命名空间形式
/// <c>a:b</c>（词法器保证），且关键字优先：注册一个叫 <c>if</c> 的指令无效。
/// </para>
/// </summary>
public sealed class CustomOpcodeConfig
{
    public readonly Dictionary<string, CustomOpcode> Opcodes = new();

    /// <summary>
    /// 登记一条自定义指令。<paramref name="argNum"/> 默认 -1（变长）。
    /// 同名重复注册返回 <see cref="Result.DuplicateWithBuiltinOpcode"/> 且**不覆盖**已有项。
    /// 与 C++ 一样不校验编号范围，编号请从 <see cref="OpcodeLimits.FirstCustomOpcode"/> 起。
    /// </summary>
    public Result AddCustomOpcode(string name, int opcode, int argNum = -1)
    {
        if (Opcodes.ContainsKey(name)) return Result.DuplicateWithBuiltinOpcode;
        Opcodes[name] = new CustomOpcode(opcode, argNum);
        return Result.Success;
    }

    public bool Has(string name) => Opcodes.ContainsKey(name);
}
