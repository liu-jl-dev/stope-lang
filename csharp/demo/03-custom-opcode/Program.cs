using System;
using System.Collections.Generic;
using System.Text;

using Stope;

namespace Stope.Demo;

/// <summary>
/// Demo 03: 自定义指令 —— 给编译器加几条自己的指令，只编译 + 反汇编，不运行。
/// <para>对应 <c>cpp/demo/03-custom-opcode.cpp</c> 与 <c>gdscript/demo/demo_03.gd</c>。</para>
/// <para>运行：<c>dotnet run --project csharp/demo/03-custom-opcode</c></para>
/// <para>
/// 项目只规定 33 条内置指令（<see cref="Opcode"/>）与 <see cref="Program"/> 的编码契约；
/// 再往上加指令是宿主自己的事，三步：
/// </para>
/// <list type="number">
/// <item>用 <see cref="CustomOpcodeConfig"/> 登记「名字 -&gt; (编号, 参数个数)」；</item>
/// <item><b>同一份 config</b> 同时交给 <see cref="Parser"/> 和 <see cref="Compiler"/>：
/// Parser 靠它把名字识别成 <see cref="TokenType.Custom"/>（查不到就只是普通标识符），
/// Compiler 靠它查编号与参数个数；</item>
/// <item>产物里就只是一串整数 —— 编号什么含义、谁来执行，全由宿主决定。</item>
/// </list>
/// <para>
/// 本 demo 不运行程序：自定义指令在内置执行器里没有实现，也不该有 —— 它是内置的基础
/// 虚拟机（会一直维护，但不是标准的一部分），默认只装内置那 33 项。自定义指令的意义
/// 正在于此：宿主自己定义、自己执行。
/// </para>
/// <para>两条硬约束（见 <c>docs/zh-cn/compiler-test-plan.md</c> §4.4）：</para>
/// <list type="bullet">
/// <item>编号必须 ≥ <see cref="OpcodeLimits.FirstCustomOpcode"/>（= Return + 1）。opcodes 是
/// 混排序列，撞号以后与内置指令无法区分；Disasm 会把这种注册报成 warning（[5] 演示）。</item>
/// <item>定长指令的 ArgNum 必须与实际调用一致，否则编译期报错、不产出（[4] 演示）。</item>
/// </list>
/// </summary>
internal static class Demo03
{
    /// <summary>编译一份源码并打印错误。<paramref name="config"/> 为 null 时按「没有自定义指令」处理。</summary>
    private static bool CompileAndReport(string src, CustomOpcodeConfig? config, Program outProg)
    {
        var lexer = new Lexer(src);
        var parser = new Parser(lexer, config); // 第二参：可空的 config
        var tree = new Prog();
        parser.ParseProgram(tree);
        foreach (var e in lexer.Errors) Console.WriteLine("  lexer: " + e);
        foreach (var e in parser.Errors) Console.WriteLine("  parser: " + e);

        var compiler = new Compiler(config); // 配置只在构造时注入一次
        var rc = compiler.Compile(tree, outProg);
        foreach (var e in compiler.Errors) Console.WriteLine("  compiler: " + e);
        return rc == Result.Success && lexer.Errors.Count == 0 && parser.Errors.Count == 0;
    }

    private static int Main()
    {
        Console.OutputEncoding = Encoding.UTF8;

        // ---------- 1. 登记自定义指令 ----------
        //
        // ArgNum ≥ 0 定长；ArgNum < 0（默认值 -1）变长，编译产物里会多写一个「本次调用
        // 的参数个数」。名字里的 ':' 是词法器支持的命名空间写法，用来避开宿主函数名
        // （fmt:println 那种）。
        var config = new CustomOpcodeConfig();
        Console.WriteLine("[1] 登记自定义指令：");
        // 返回 Result：同名重复注册会拿到 DuplicateWithBuiltinOpcode。这里三条都新，
        // 不为返回值打断流程。
        config.AddCustomOpcode("my:add", OpcodeLimits.FirstCustomOpcode + 0, 2);
        config.AddCustomOpcode("my:log", OpcodeLimits.FirstCustomOpcode + 1, -1);
        config.AddCustomOpcode("my:halt", OpcodeLimits.FirstCustomOpcode + 2, 0);
        // 打印顺序就是登记顺序 —— 各实现按自己的容器顺序打印即可。
        foreach (var (name, info) in config.Opcodes)
        {
            string kind = info.IsVarArg ? "（变长）" : $"（定长 {info.ArgNum} 参）";
            Console.WriteLine($"  {name} -> #{info.Opcode}{kind}");
        }

        // ---------- 2. 编译并反汇编 ----------
        //
        // 注意 my:add 的参数照常先压栈，指令本身不再带操作数；只有 my:log 这种变长指令
        // 后面多一个整数。反汇编要认出这些，必须把同一份 config 交给 Disasm()。
        const string src = """
    let x = 3;

    my:add(x, 4);        // 定长 2 参
    my:log("x =", x);    // 变长 2 参
    my:log();            // 变长 0 参
    my:halt();           // 定长 0 参

    return x;
  """;
        var program = new Program();
        Console.WriteLine("\n[2] 编译结果：");
        if (!CompileAndReport(src, config, program)) return 1;
        Console.WriteLine(Debug.Disasm(program, config));

        // ---------- 3. 对照：名字没登记就只是普通调用 ----------
        //
        // 词法器只有在 config 里查得到名字时才吐 Custom token，否则 "my:add" 就是个普通
        // 标识符 —— 编译成 Call，即「调用一个名叫 my:add 的宿主函数」。
        var plain = new Program();
        Console.WriteLine("\n[3] 同样的调用，不传 config：");
        if (CompileAndReport("my:add(1, 2);", null, plain))
            Console.WriteLine(Debug.DisasmNoCustom(plain));

        // ---------- 4. 参数个数不符 ----------
        //
        // 定长指令的参数量在编译期校验；报错后 Compile() 会把 out 复原为空，免得一个
        // 半成品 Program 被当成能跑的东西。
        var bad = new Program();
        Console.WriteLine("\n[4] 定长 2 参却只给 1 个：");
        if (!CompileAndReport("my:add(1);", config, bad))
            Console.WriteLine($"  -> 编译失败，Program 已清空（opcodes 剩 {bad.Opcodes.Count} 个 number）");

        // ---------- 5. 陷阱：编号撞到内置指令 ----------
        //
        // 自定义编号必须 ≥ FirstCustomOpcode。这里故意用一个内置编号注册：编译器写出的仍是
        // 同一个整数，谁也分不清它到底是 Add 还是 my:steal —— Disasm 只能按内置指令解码，
        // 并把它报成 warning。
        var collide = new CustomOpcodeConfig();
        collide.AddCustomOpcode("my:steal", (int)Opcode.Add, 2);
        var stolen = new Program();
        Console.WriteLine("\n[5] 用内置 Add 的编号注册 my:steal：");
        if (CompileAndReport("my:steal(1, 2);", collide, stolen))
        {
            Console.WriteLine(Debug.Disasm(stolen, collide));
            Console.WriteLine("  -> 反汇编只认得出 Add：my:steal 这个名字已经丢了，编号千万别撞内置。");
        }
        return 0;
    }
}
