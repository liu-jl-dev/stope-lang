package tests;

import java.util.List;
import stope.Lexer;
import stope.Opcode;
import stope.Token;
import stope.TokenType;

/** golden 测试跑器。从仓库根运行（数据真源 gdscript/test/data/）。 */
public final class TestMain {
    static int passed = 0;
    static int failed = 0;

    static void check(String cid, String field, String want, String got) {
        if (want.equals(got)) passed++;
        else {
            failed++;
            System.err.println("FAIL " + cid + " " + field + "\n  want=[" + want + "]\n  got =[" + got + "]");
        }
    }

    static Opcode.CustomOpcodeConfig makeCfg(String which) {
        Opcode.CustomOpcodeConfig cfg = new Opcode.CustomOpcodeConfig();
        if ("collide".equals(which)) cfg.add("my:steal", 20, 2);
        else if ("main".equals(which)) { cfg.add("myop", 100, 2); cfg.add("vop", 101, -1); }
        return cfg;
    }

    static stope.Stml.LexerState stateOf(String name) {
        return switch (name) {
            case "Text" -> stope.Stml.LexerState.Text;
            case "Nevext" -> stope.Stml.LexerState.Nevext;
            case "Stope" -> stope.Stml.LexerState.Stope;
            default -> stope.Stml.LexerState.Xml;
        };
    }

    static String joinEsc16(java.util.List<String> errs) {
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < errs.size(); i++) {
            if (i > 0) out.append('|');
            out.append(Golden.esc16(errs.get(i)));
        }
        return out.toString();
    }

    static void testStml() {
        java.util.List<Golden.StmlCase> cases = Golden.readStmlCases();
        java.util.List<Golden.Record> wants = Golden.readGolden("golden_stml.txt", false);
        java.util.Map<String, Golden.Record> byId = new java.util.HashMap<>();
        for (Golden.Record w : wants) byId.put(w.get("ID"), w);
        for (Golden.StmlCase c : cases) {
            String cid = c.get("ID");
            Golden.Record want = byId.get(cid);
            if (want == null) { check(cid, "缺golden", "有", "无"); continue; }
            String src = c.src.repeat(c.times);
            if ("parse".equals(c.get("KIND"))) {
                stope.StmlLexer lx = new stope.StmlLexer(src, stope.Stml.LexerState.Xml);
                stope.StmlParser ps = new stope.StmlParser(lx);
                String md = c.get("MD");
                if (!md.isEmpty()) ps.maxDepth = Integer.parseInt(md);
                stope.Stml.Element root = new stope.Stml.Element();
                String sfName = c.get("SF");
                stope.StmlParser.StateFunc sf = stope.StmlParser.defaultStateFunc();
                if ("null".equals(sfName)) sf = null;
                else if ("text".equals(sfName)) sf = tag -> stope.Stml.LexerState.Text;
                boolean ok = ps.parse(root, sf);
                check(cid, "SHAPE", want.get("SHAPE"), stope.StmlParser.shape(root, Golden::esc16));
                check(cid, "RESULT", want.get("RESULT"), ok ? "Success" : "Error");
                check(cid, "ERRN", want.get("ERRN"), String.valueOf(ps.errors.size()));
                check(cid, "ERRS", want.get("ERRS"), joinEsc16(ps.errors));
                check(cid, "LEXERRN", want.get("LEXERRN"), String.valueOf(lx.errors.size()));
                check(cid, "LEXERRS", want.get("LEXERRS"), joinEsc16(lx.errors));
            } else {
                stope.StmlLexer lx = new stope.StmlLexer(src, stateOf(c.get("ST")));
                StringBuilder toks = new StringBuilder(), lexs = new StringBuilder();
                for (int i = 0; i < 10000; i++) {
                    stope.Stml.Token t = lx.nextToken();
                    if (i > 0) toks.append(' ');
                    toks.append(stope.Stml.typeName(t.typ)).append('(').append(t.line).append(')');
                    if (stope.StmlLexer.hasLexeme(t.typ)) {
                        if (lexs.length() > 0) lexs.append(',');
                        lexs.append(i).append(':').append(Golden.esc16(t.lexeme));
                    }
                    if (t.typ == stope.Stml.Eof) break;
                }
                check(cid, "TOKS", want.get("TOKS"), toks.toString());
                check(cid, "LEXS", want.get("LEXS"), lexs.toString());
                check(cid, "ERRN", want.get("ERRN"), String.valueOf(lx.errors.size()));
                check(cid, "ERRS", want.get("ERRS"), joinEsc16(lx.errors));
            }
        }
    }

    static void testDisasm() {
        java.util.List<Golden.Record> cases = Golden.readGolden("golden_disasm.txt", true);
        if (cases.isEmpty()) { check("golden-disasm", "条数", "非0", "0"); return; }
        for (Golden.Record c : cases) {
            String cid = c.get("ID");
            Opcode.CustomOpcodeConfig cfg = makeCfg(c.get("CFG"));
            stope.Program prog = new stope.Program();
            if ("src".equals(c.get("MODE"))) {
                String src = Golden.unescape(c.get("SRC"));
                stope.Lexer lx = new stope.Lexer(src);
                lx.custom = cfg.opcodes.isEmpty() ? null : cfg;
                stope.Parser ps = new stope.Parser(lx);
                stope.Ast.Prog tree = new stope.Ast.Prog();
                ps.parseProgram(tree);
                new stope.Compiler(prog, lx.custom).compile(tree, java.util.List.of());
            } else {
                for (String s : c.get("OPS").split(",", -1)) {
                    if (s.isEmpty()) continue;
                    prog.opcodes.add(Integer.parseInt(s));
                }
                String vars = c.get("VARS");
                if (!vars.isEmpty()) prog.variableNum = Integer.parseInt(vars);
            }
            check(cid, "DIS", c.get("DIS"), stope.Debug.disasm(prog, cfg.opcodes.isEmpty() ? null : cfg));
        }
    }

    static boolean isLexemeType(int t) {
        return t == TokenType.Integer || t == TokenType.Float || t == TokenType.String || t == TokenType.BinArr;
    }

    static String[] one(String src, Opcode.CustomOpcodeConfig cfg) {
        Lexer lx = new Lexer(src);
        lx.custom = cfg;
        StringBuilder toks = new StringBuilder();
        StringBuilder lexemes = new StringBuilder();
        for (int i = 0; i < 10000; i++) {
            Token t = lx.nextToken();
            if (i > 0) toks.append(' ');
            toks.append(TokenType.name(t.typ)).append('(').append(t.line).append(')');
            if (t.parsed.length() > 0) toks.append('[').append(Golden.escLex(t.parsed)).append(']');
            if (t.value instanceof Long v) toks.append('=').append(v);
            else if (t.value instanceof Double v) toks.append('=').append(Golden.fmtG(v));
            if (isLexemeType(t.typ)) {
                if (lexemes.length() > 0) lexemes.append(',');
                lexemes.append(i).append(':').append(Golden.escLex(t.lexeme));
            }
            if (t.typ == TokenType.Eof) break;
        }
        return new String[] { toks.toString(), lexemes.toString(),
            String.valueOf(lx.errors.size()), Golden.joinEsc(lx.errors) };
    }

    static stope.BasicVM.State buildVm(String src) {
        Opcode.CustomOpcodeConfig cfg = makeCfg("main");
        stope.Lexer lx = new stope.Lexer(src);
        lx.custom = cfg;
        stope.Parser ps = new stope.Parser(lx);
        stope.Ast.Prog tree = new stope.Ast.Prog();
        ps.parseProgram(tree);
        stope.Program prog = new stope.Program();
        stope.Compiler comp = new stope.Compiler(prog, cfg);
        if (!comp.compile(tree, java.util.List.of())) return null;
        stope.BasicVM.State s = new stope.BasicVM.State(prog);
        s.run();
        return s;
    }

    static String fmtReturns(stope.BasicVM.State s) {
        StringBuilder out = new StringBuilder("[");
        for (int i = 0; i < s.returns.size(); i++) {
            if (i > 0) out.append(',');
            out.append(stope.BasicVM.fmtValue(s.returns.get(i)));
        }
        return out.append(']').toString();
    }

    static void vmReturns(String cid, String src, String want) {
        stope.BasicVM.State s = buildVm(src);
        if (s == null) { check(cid, "编译", "成功", "失败"); return; }
        check(cid, "returns", want, fmtReturns(s));
        check(cid, "errors", "", String.join("|", s.errors));
    }

    static void vmErrs(String cid, String src, String wantMsg) {
        stope.BasicVM.State s = buildVm(src);
        if (s == null) { check(cid, "编译", "成功", "失败"); return; }
        check(cid, "错误条数", "1", String.valueOf(s.errors.size()));
        String got = s.errors.isEmpty() ? "<无错误>" : s.errors.get(0);
        int pos = got.indexOf(": ");
        if (pos >= 0) got = got.substring(pos + 2);
        check(cid, "错误消息", wantMsg, got);
    }

    static void testVm() {
        // 布尔就是整数
        vmReturns("V-06", "return true;", "[1]");
        vmReturns("V-06b", "return false;", "[0]");
        vmReturns("V-06c", "let t = true; let f = false; return t + f + (1 == 1);", "[2]");
        vmReturns("V-06d", "let a = 1; let b = 2; return a < b;", "[1]");
        // 整数幂
        vmReturns("V-07", "let a = 2; let b = 64; return a ^ b;", "[0]");
        vmReturns("V-07b", "let a = 2; return a ^ -1;", "[0.5]");
        vmReturns("V-07c", "let a = -8.0; let b = 0.5; return a ^ b;", "[nan]");
        // 序列
        vmReturns("V-08", "let s = \"ab\"; return s * 2;", "[abab]");
        vmReturns("V-08b", "let s = \"ab\"; return 2 * s;", "[abab]");
        vmReturns("V-08c", "let b = 'd 1 2'; return b * 2;", "[[1,2,1,2]]");
        vmErrs("V-08d", "let s = \"ab\"; let n = -1; return s * n;", "\"Mul\" cannot repeat a sequence by a negative number. ");
        vmReturns("V-08e", "let a = \"x\"; let b = \"y\"; return a + b;", "[xy]");
        vmReturns("V-08f", "let a = 'd 1'; let b = 'd 2'; return a + b;", "[[1,2]]");
        vmErrs("V-08g", "let b = 'd 1'; let n = -2; return b * n;", "\"Mul\" cannot repeat a sequence by a negative number. ");
        // 真值
        vmReturns("V-09", "let s = \"\"; if s { return 1; } return 2;", "[2]");
        vmReturns("V-09b", "let s = \"x\"; if s { return 1; } return 2;", "[1]");
        vmReturns("V-09c", "let b = 'd'; if b { return 1; } return 2;", "[2]");
        // 除零
        vmErrs("V-10", "let a = 1; let b = 0; return a / b;", "\"Div\" division by zero. ");
        vmErrs("V-10b", "let a = 1; let b = 0; return a idiv b;", "\"IDiv\" division by zero. ");
        vmErrs("V-10c", "let a = 1; let b = 0; return a % b;", "\"Mod\" division by zero. ");
        vmReturns("V-10d", "let a = 1.0; let b = 0; return a / b;", "[inf]");
        vmReturns("V-10e", "let a = 0.0; let b = 0; return a / b;", "[nan]");
        vmReturns("V-10f", "let a = 1.5; let b = 0; return a % b;", "[nan]");
        vmReturns("V-10g", "let a = -7.0; let b = 2.0; return a % b;", "[-1.0]");
        // Not
        vmErrs("V-11", "let s = \"abc\"; return !s;", "\"Not\" can only operate on integer or float. ");
        // MIN 边界
        vmReturns("V-12", "let m = 0 - 9223372036854775807 - 1; return -m;", "[-9223372036854775808]");
        vmReturns("V-12b", "let m = 0 - 9223372036854775807 - 1; return m idiv -1;", "[-9223372036854775808]");
        vmReturns("V-12c", "let m = 0 - 9223372036854775807 - 1; return m % -1;", "[0]");
        // idiv
        vmReturns("V-13", "let a = 7; let b = 2; return a idiv b;", "[3]");
        vmReturns("V-13b", "let a = 7.5; let b = 2; return a idiv b;", "[3.0]");
        vmReturns("V-13c", "let a = 1.0; let b = 0; return a idiv b;", "[inf]");
        // 相等
        vmReturns("V-15", "let a = \"1\"; let b = 1; return a == b;", "[0]");
        vmReturns("V-15b", "let a = null; let b = 0; return a == b;", "[0]");
        vmReturns("V-15c", "let a = 'd 1 2'; let b = 'd 1 2'; return a == b;", "[1]");
        vmReturns("V-15d", "let a = 'd 1'; let b = 'd 2'; return a == b;", "[0]");
        vmReturns("V-15e", "let a = \"ab\"; let n = 0; return a * n;", "[]");
        // 下标（UTF-16 码元）
        vmReturns("V-15f", "let b = 'd 1 2'; return b[1];", "[2]");
        vmReturns("V-15g", "let s = \"😀\"; return s[0];", "[55357]");
        vmErrs("V-15h", "let b = 'd 1'; return b[5];", "index out of range. ");
    }

    static void testLexer() {
        List<Golden.Record> cases = Golden.readGolden("golden_lex.txt", false);
        if (cases.isEmpty()) { check("golden_lex", "条数", "非0", "0"); return; }
        for (Golden.Record c : cases) {
            String cid = c.get("ID");
            String src = Golden.unescapeLex(c.get("SRC"));
            String[] r = one(src, makeCfg("main"));
            check(cid, "TOKS", c.get("TOKS"), r[0]);
            check(cid, "LEXEMES", c.get("LEXEMES"), r[1]);
            check(cid, "ERRN", c.get("ERRN"), r[2]);
            check(cid, "ERRS", c.get("ERRS"), r[3]);
        }
    }

    static void testParser() {
        java.util.List<Golden.Record> cases = Golden.readGolden("golden.txt", true);
        if (cases.isEmpty()) { check("golden", "条数", "非0", "0"); return; }
        for (Golden.Record c : cases) {
            String cid = c.get("ID");
            String src = Golden.unescape(c.get("SRC")); // 读时解一层，这里再解一层
            Opcode.CustomOpcodeConfig cfg = makeCfg("main");
            stope.Lexer lx = new stope.Lexer(src);
            lx.custom = cfg;
            stope.Parser ps = new stope.Parser(lx);
            ps.constFolding = "1".equals(c.get("FOLD"));
            stope.Ast.Prog tree = new stope.Ast.Prog();
            ps.parseProgram(tree);
            stope.Ast.Shaper shaper = new stope.Ast.Shaper(Golden::esc16);
            check(cid, "SHAPE", c.get("SHAPE"), shaper.prog(tree));

            StringBuilder lines = new StringBuilder();
            for (int i = 0; i < tree.stmts.size(); i++) {
                if (i > 0) lines.append(',');
                lines.append(tree.stmts.get(i).line);
            }
            check(cid, "LINES", c.get("LINES"), lines.toString());

            check(cid, "PERR", c.get("PERR"), String.valueOf(ps.errors.size()));
            check(cid, "PERRS", c.get("PERRS"), Golden.joinEsc(ps.errors));
            check(cid, "LEXERR", c.get("LEXERR"), String.valueOf(lx.errors.size()));
            check(cid, "LEXERRS", c.get("LEXERRS"), Golden.joinEsc(lx.errors));
        }
    }

    static void testCompiler() {
        java.util.List<Golden.Record> cases = Golden.readGolden("golden.txt", true);
        if (cases.isEmpty()) { check("golden-compiler", "条数", "非0", "0"); return; }
        for (Golden.Record c : cases) {
            String cid = c.get("ID");
            String src = Golden.unescape(c.get("SRC"));
            Opcode.CustomOpcodeConfig cfg = makeCfg("main");
            stope.Lexer lx = new stope.Lexer(src);
            lx.custom = cfg;
            stope.Parser ps = new stope.Parser(lx);
            ps.constFolding = "1".equals(c.get("FOLD"));
            stope.Ast.Prog tree = new stope.Ast.Prog();
            ps.parseProgram(tree);

            java.util.List<String> pre = new java.util.ArrayList<>();
            String preField = c.get("PRE");
            if (!preField.isEmpty()) for (String name : preField.split(",", -1)) pre.add(name);

            stope.Program prog = new stope.Program();
            stope.Compiler comp = new stope.Compiler(prog, cfg);
            comp.compile(tree, pre);

            check(cid, "OUT", c.get("OUT"), Dump.dumpProgram(prog, cfg));
            check(cid, "CERRS", c.get("CERRS"), Golden.joinEsc(comp.errors));
        }
    }

    /** 深度上限：照搬 Zig 的 8 组用例（200 层不 abort / 300 层 abort，四种结构）。 */
    static String depthSource(String kind, int n) {
        StringBuilder src = new StringBuilder();
        switch (kind) {
            case "paren" -> {
                src.append("(".repeat(n)).append('a').append(")".repeat(n)).append(';');
            }
            case "block" -> {
                src.append("{".repeat(n)).append("a;").append("}".repeat(n));
            }
            case "unary" -> {
                src.append("-".repeat(n)).append("a;");
            }
            case "at" -> {
                src.append("a[".repeat(n)).append('0').append("]".repeat(n)).append(';');
            }
        }
        return src.toString();
    }

    static void testDepth() {
        String[][] cases = {
            { "paren", "200", "no" }, { "paren", "300", "yes" },
            { "block", "300", "yes" }, { "unary", "300", "yes" },
            { "at", "300", "yes" },
            { "block", "200", "no" }, { "unary", "200", "no" }, { "at", "200", "no" },
        };
        for (String[] c : cases) {
            String id = "PD-" + c[0] + "-" + c[1];
            stope.Lexer lx = new stope.Lexer(depthSource(c[0], Integer.parseInt(c[1])));
            stope.Parser ps = new stope.Parser(lx);
            stope.Ast.Prog tree = new stope.Ast.Prog();
            ps.parseProgram(tree);
            if ("yes".equals(c[2])) {
                check(id, "错误条数", "1", String.valueOf(ps.errors.size()));
                String got = ps.errors.isEmpty() ? "<无错误>" : ps.errors.get(0);
                check(id, "错误文案", "line 1: nesting too deep (max 256). ", got);
            } else {
                check(id, "错误条数", "0", String.valueOf(ps.errors.size()));
            }
        }
    }

    /** step 与 run 两条独立路径必须等价（V-21 硬契约）。 */
    static void testVmStepEquiv() {
        String[] cases = {
            "return 1;",
            "let a = 2; let b = 3; return a + b;",
            "let x = 0; if x { return 1; } else { return 2; }",
            "return !0;",
            "let a = 7; let b = 2; return a / b;",
            "let s = \"ab\"; return s + \"c\";",
            "return 1 == 1;",
            "let a = 0; while a < 3 { a = a + 1; } return a;",
        };
        for (int idx = 0; idx < cases.length; idx++) {
            String cid = "V-21-" + idx;
            Opcode.CustomOpcodeConfig cfg = makeCfg("main");
            stope.Lexer lx1 = new stope.Lexer(cases[idx]); lx1.custom = cfg;
            stope.Parser ps1 = new stope.Parser(lx1);
            stope.Ast.Prog tree1 = new stope.Ast.Prog(); ps1.parseProgram(tree1);
            stope.Program prog1 = new stope.Program();
            if (!new stope.Compiler(prog1, cfg).compile(tree1, java.util.List.of())) {
                check(cid, "编译", "成功", "失败"); continue;
            }
            stope.BasicVM.State s1 = new stope.BasicVM.State(prog1); s1.run();

            stope.Lexer lx2 = new stope.Lexer(cases[idx]); lx2.custom = cfg;
            stope.Parser ps2 = new stope.Parser(lx2);
            stope.Ast.Prog tree2 = new stope.Ast.Prog(); ps2.parseProgram(tree2);
            stope.Program prog2 = new stope.Program();
            new stope.Compiler(prog2, cfg).compile(tree2, java.util.List.of());
            stope.BasicVM.State s2 = new stope.BasicVM.State(prog2);
            int steps = 0;
            while (s2.i < prog2.opcodes.size() && s2.errors.isEmpty() && steps < 10000) {
                s2.step(); steps++;
            }
            check(cid, "returns", fmtReturns(s1), fmtReturns(s2));
            check(cid, "errors", String.join("|", s1.errors), String.join("|", s2.errors));
        }
    }

    /** 宿主函数与实参表。 */
    static void testVmHost() {
        // V-14：宿主函数注入变量
        {
            stope.Program prog = new stope.Program();
            prog.opcodes.add(Opcode.PushValue); prog.opcodes.add(0); // 压 callee
            prog.opcodes.add(Opcode.Call); prog.opcodes.add(0);
            prog.opcodes.add(Opcode.Return); prog.opcodes.add(1);
            prog.variableNum = 1;
            stope.BasicVM.State s = new stope.BasicVM.State(prog);
            s.variables[0] = stope.BasicVM.Value.ofHostFn(null, (ctx, args) -> stope.BasicVM.Value.ofInt(42));
            s.run();
            check("V-14", "returns", "[42]", fmtReturns(s));
        }
        // V-18：argc + args[0]
        {
            stope.Program prog = new stope.Program();
            prog.intConsts.add(0L); // PushInt 0 的常量
            prog.opcodes.add(Opcode.ArgNum);
            prog.opcodes.add(Opcode.PushInt); prog.opcodes.add(0);
            prog.opcodes.add(Opcode.GetArg);
            prog.opcodes.add(Opcode.Add);
            prog.opcodes.add(Opcode.Return); prog.opcodes.add(1);
            stope.BasicVM.State s = new stope.BasicVM.State(prog);
            s.args = new stope.BasicVM.Arguments() {
                public stope.BasicVM.Value at(Object ctx, stope.BasicVM.State st, stope.BasicVM.Value key) {
                    return stope.BasicVM.Value.ofInt(2);
                }
                public int num(Object ctx) { return 1; }
            };
            s.run();
            check("V-18", "returns", "[3]", fmtReturns(s));
        }
    }

    public static void main(String[] args) {
        testLexer();
        testParser();
        testCompiler();
        testDisasm();
        testStml();
        testVm();
        testVmStepEquiv();
        testVmHost();
        testDepth();
        System.out.println("断言 " + (passed + failed) + " 条，失败 " + failed + " 条");
        if (failed > 0) System.exit(1);
    }
}
