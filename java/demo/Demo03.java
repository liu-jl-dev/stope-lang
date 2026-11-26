package demo;

import stope.*;

/** demo 03：自定义指令（登记 → 编译 → 反汇编）。 */
public final class Demo03 {
    public static void main(String[] args) {
        String src = "return myop(1, 2);";
        Opcode.CustomOpcodeConfig cfg = new Opcode.CustomOpcodeConfig();
        cfg.add("myop", 100, 2);
        Lexer lx = new Lexer(src);
        lx.custom = cfg;
        Parser ps = new Parser(lx);
        Ast.Prog tree = new Ast.Prog();
        ps.parseProgram(tree);
        Program prog = new Program();
        new Compiler(prog, cfg).compile(tree, java.util.List.of());
        System.out.print(Debug.disasm(prog, cfg));
    }
}
