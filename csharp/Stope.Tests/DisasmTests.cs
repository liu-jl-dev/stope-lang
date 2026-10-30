using System;
using System.Collections.Generic;

namespace Stope.Tests;

/// <summary>
/// 反汇编：<c>golden_disasm.txt</c>（12 条，<c>cpp/tools/golden_disasm.cpp</c> dump），
/// 逐字节比 <c>Disasm</c> 的完整输出（含 <c>variables:</c> / 常量池 / warning 段）。
/// <para>
/// 两种模式：<c>MODE=src</c> 走「源码 → 编译 → 反汇编」；<c>MODE=raw</c> 直接给指令流
/// （<c>OPS=200,1</c>），用来覆盖「产物里有不认识的编号」这类正常编译路径造不出来的情况。
/// </para>
/// <para>
/// 四份实现（C++ / GDScript / Node.js / C#）对同一份产物必须输出同一串文本 —— 这是
/// 唯一能逐字节比对的中介物。
/// </para>
/// </summary>
public static class DisasmTests
{
    public static void Run(Report rep)
    {
        var cases = Data.ReadGolden("golden_disasm.txt");
        if (cases.Count == 0)
        {
            rep.AddFail("反汇编", "golden_disasm.txt 一条都没读到");
            return;
        }

        // 两份配置与探针里的 g_* 一致
        var mainCfg = LexerTests.MakeConfig(); // myop #100 (2 args) / vop #101 (vararg)

        var collideCfg = new CustomOpcodeConfig();
        collideCfg.AddCustomOpcode("my:steal", (int)Opcode.Add, 2); // 故意撞内置 Add

        foreach (var rec in cases)
        {
            string id = rec.GetValueOrDefault("ID", "");
            string cfgName = rec.GetValueOrDefault("CFG", "none");
            var cfg = cfgName switch
            {
                "main" => mainCfg,
                "collide" => collideCfg,
                _ => null,
            };

            string got;
            if (rec.GetValueOrDefault("MODE", "") == "src")
            {
                // SRC 是 E_(escUtf8(源码))，要解两层（见 ParserTests.RunCase 的注释）
                string src = Data.Unescape(rec.GetValueOrDefault("SRC", ""));
                var tree = new Prog();
                new Parser(new Lexer(src), cfg).ParseProgram(tree);
                var prog = new Program();
                new Compiler(cfg).Compile(tree, prog);
                got = Debug.Disasm(prog, cfg);
            }
            else
            {
                // raw：直接给指令流，不经过前端
                var prog = new Program();
                foreach (var s in rec.GetValueOrDefault("OPS", "").Split(','))
                    if (s.Length > 0)
                        prog.Opcodes.Add(int.Parse(s));
                prog.VariableNum = int.TryParse(rec.GetValueOrDefault("VARS", "0"), out int vn) ? vn : 0;
                got = Debug.Disasm(prog, cfg);
            }
            rep.Check(id, "DIS", rec.GetValueOrDefault("DIS", ""), got);
        }
    }
}
