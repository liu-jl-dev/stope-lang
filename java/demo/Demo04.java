package demo;

import stope.*;
import java.util.List;

/** demo 04：预导出（preExports）+ 宿主读取导出值。 */
public final class Demo04 {
    public static void main(String[] args) {
        String src = "a = 1; return print(a);";
        Opcode.CustomOpcodeConfig cfg = new Opcode.CustomOpcodeConfig();
        Lexer lx = new Lexer(src);
        lx.custom = cfg;
        Parser ps = new Parser(lx);
        Ast.Prog tree = new Ast.Prog();
        ps.parseProgram(tree);
        Program prog = new Program();
        new Compiler(prog, cfg).compile(tree, List.of("a", "print"));
        System.out.println("exports: " + prog.exports);
        BasicVM.State s = new BasicVM.State(prog);
        // 宿主函数 print：把参数原样返回
        Integer printSlot = prog.exports.get("print");
        if (printSlot != null) {
            s.variables[printSlot] = BasicVM.Value.ofHostFn(null,
                (ctx, argv) -> argv.length > 0 ? argv[0] : BasicVM.Value.NULL);
        }
        s.run();
        System.out.println("returns: " + Demo01.fmtReturns(s));
    }
}
