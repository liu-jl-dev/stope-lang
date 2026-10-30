using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

using Stope;

namespace Stope.Demo;

/// <summary>
/// Quick-start demo: compile a Stope program and run it.
/// <para>
/// Stope's standard covers three things only: the Stope language, STML, and the compiler's
/// output (<see cref="Program"/>). It does <b>NOT</b> define a virtual machine, so the steps
/// below have different stability guarantees:
/// </para>
/// <list type="bullet">
/// <item>step 1 (compile): Lexer / Parser / Compiler / Program —— 编译器接口，相对稳定。
/// <c>Program</c> 有明确的编码契约，宿主可以依赖这一段。</item>
/// <item>step 2-4 (run): <see cref="Api"/> / <see cref="State"/> —— <b>内置示例执行器</b>，
/// 不是标准。值的表示、栈布局、宿主函数绑定、错误上报全是实现细节，换一个执行器可以
/// 长得完全不一样。见 <c>docs/zh-cn/vm-guide.md</c>。</item>
/// </list>
/// <para>
/// 运行：<c>dotnet run --project csharp/demo/01-quick-start</c>
/// </para>
/// <para>
/// 输出与 <c>cpp/demo/01-quick-start.cpp</c>、<c>gdscript/demo/demo_01.gd</c>、
/// <c>nodejs/demo/01-quick-start.js</c> 逐字节相同 —— 四方对同一份源码产出同一份字节码。
/// </para>
/// </summary>
internal static class Demo01
{
    /// <summary>
    /// 宿主侧的参数表：源码里的 <c>args[i]</c> / <c>argc</c> 都落到它身上
    /// （对应 C++ demo 的 <c>MyArgs</c>）。与标准无关，纯属示例执行器的接口。
    /// </summary>
    private sealed class MyArgs : Arguments
    {
        private readonly object?[] _data;
        public MyArgs(object?[] values) => _data = values;

        /// <summary>取不到就<b>自己报错</b>：<c>state.Error(...)</c> + 返回 null，执行器立刻停在这里。</summary>
        public override object? At(State state, object? indexOrKey)
        {
            if (indexOrKey is not long k)
            {
                state.Error("index must be an integer. ");
                return null;
            }
            if (k < 0 || k >= _data.Length)
            {
                state.Error("index out of range. ");
                return null;
            }
            return _data[k];
        }

        public override int Num() => _data.Length;
    }

    /// <summary>
    /// 值的显示形式。C++ 的 <c>cout &lt;&lt; double</c> 会把 15.0 打成 <c>15</c>；
    /// 这里按同一口径处理（整数 / 浮点 / null / 其它分开）。
    /// </summary>
    private static string Fmt(object? v) => v switch
    {
        null => "null",
        long l => l.ToString(CultureInfo.InvariantCulture),
        double d => d.ToString(CultureInfo.InvariantCulture),
        string s => s,
        _ => v.ToString() ?? "null",
    };

    /// <summary>
    /// 宿主函数表（对应 C++ demo 里绑的那个 lambda）。签名统一是
    /// <c>Func&lt;object?[], object?&gt;</c> —— 参数<b>整包</b>进来，自己拆。
    /// </summary>
    private static object? Println(object?[] argv)
    {
        var sb = new StringBuilder("[Host] ");
        foreach (var a in argv) sb.Append(Fmt(a));
        Console.WriteLine(sb.ToString());
        return null;
    }

    private static int Main()
    {
        Console.OutputEncoding = Encoding.UTF8;

        // ---------------- step 1: 编译源码 ----------------
        //
        // 稳定性：编译器接口。Program 有明确的编码契约（指令编号、操作数、跳转目标是
        // opcodes 下标），宿主可以依赖这一段。
        const string src = """
// example: sum all arguments

let result = 0.0;
let i = 0;
while i < argc {
  result = result + args[i];
  i = i + 1;
}

fmt:println("结果为: ", result);
return result;
""";

        var lexer = new Lexer(src);
        var parser = new Parser(lexer); // 第二参是 CustomOpcodeConfig，可省
        var tree = new Prog();
        parser.ParseProgram(tree);
        foreach (var e in lexer.Errors) Console.Error.WriteLine("[lex] " + e);
        foreach (var e in parser.Errors) Console.Error.WriteLine("[parse] " + e);

        var compiler = new Compiler(); // 构造参同上，可省
        var program = new Program();
        var rc = compiler.Compile(tree, program); // AST 与 Program 都传引用
        foreach (var e in compiler.Errors) Console.Error.WriteLine("[compile] " + e);
        if (rc != Result.Success)
        {
            // 编译失败时 Compile() 已按约定把 program 清空，别拿它去反汇编或执行
            Console.Error.WriteLine("compile failed, nothing to run");
            return 1;
        }
        // Disasm 自己以 "\n" 结尾，WriteLine 再加一个 —— 与 C++ 的 `<< std::endl`、
        // JS 的 console.log 一致（产出末尾那个空行）。
        Console.WriteLine(Debug.DisasmNoCustom(program));

        // ---------------- step 2-4: 装配执行器 ----------------
        //
        // 稳定性：内置示例，不是标准。换一个执行器，这段可以整个换掉。
        var api = new Api();
        var args = new MyArgs(new object?[] { 1.0, 2.0, 3.0, 4.0, 5.0 });

        // Reset 一次做完：清 returns / stack / errors，并按 VariableNum 开好槽位。
        // （C++ 侧那句必写的 state.variables.resize(...) 在这里由 Reset 代做。）
        var state = new State();
        state.Reset(api, program, args);

        // 宿主函数就是「某个变量槽里的值」：编译器把未声明的 fmt:println 当外部变量，
        // 登记进了 exports；按名字取槽位，填上函数即可。
        state.Variables[program.Exports["fmt:println"]] = (Func<object?[], object?>)Println;

        // ---------------- step 4: 跑 ----------------
        if (state.Run() != Result.Success)
        {
            foreach (var e in state.Errors) Console.Error.WriteLine("[vm] " + e);
            return 1;
        }
        Console.WriteLine("result: " + Fmt(state.Returns[0]));
        return 0;
    }
}
