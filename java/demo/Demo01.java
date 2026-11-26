package demo;

import stope.*;

/** demo 01：编译 + 运行一段 Stope 代码。 */
public final class Demo01 {
    public static void main(String[] args) {
        String src = """
            let a = 5;
            let b = 9;
            return a * b;
            """;
        Opcode.CustomOpcodeConfig cfg = new Opcode.CustomOpcodeConfig();
        Lexer lx = new Lexer(src);
        lx.custom = cfg;
        Parser ps = new Parser(lx);
        Ast.Prog tree = new Ast.Prog();
        ps.parseProgram(tree);
        Program prog = new Program();
        Compiler comp = new Compiler(prog, cfg);
        comp.compile(tree, java.util.List.of());
        BasicVM.State s = new BasicVM.State(prog);
        s.run();
        System.out.println("returns: " + fmtReturns(s));
    }

    static String fmtReturns(BasicVM.State s) {
        StringBuilder out = new StringBuilder("[");
        for (int i = 0; i < s.returns.size(); i++) {
            if (i > 0) out.append(',');
            out.append(BasicVM.fmtValue(s.returns.get(i)));
        }
        return out.append(']').toString();
    }
}
