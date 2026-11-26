package stope;

import java.util.ArrayList;
import java.util.List;
import java.util.function.Function;

/** AST 节点与测试用形状序列化（对齐 python/stope/ast.py 与 cpp/test/test_common.hpp）。 */
public final class Ast {
    private Ast() {}

    public static abstract class Expr {
        public final int line;
        protected Expr(int line) { this.line = line; }
    }
    public static abstract class Stmt {
        public final int line;
        protected Stmt(int line) { this.line = line; }
    }
    public static final class Prog {
        public int line = -1;
        public final List<Stmt> stmts = new ArrayList<>();
    }
    public static final class Elif {
        public Expr cond;
        public Prog prog;
        public Elif(Expr c, Prog p) { cond = c; prog = p; }
    }

    // ---------------------------------------------------------- Expr 子类
    public static final class ErrExpr extends Expr {
        public ErrExpr(int line) { super(line); }
    }
    public static final class NullExpr extends Expr {
        public NullExpr(int line) { super(line); }
    }
    public static final class BoolExpr extends Expr {
        public final boolean value;
        public BoolExpr(int line, boolean v) { super(line); value = v; }
    }
    public static final class IntExpr extends Expr {
        public final long value;
        public IntExpr(int line, long v) { super(line); value = v; }
    }
    public static final class FloatExpr extends Expr {
        public final double value;
        public FloatExpr(int line, double v) { super(line); value = v; }
    }
    public static final class StringExpr extends Expr {
        public final String value;
        public StringExpr(int line, String v) { super(line); value = v; }
    }
    public static final class BinArrExpr extends Expr {
        public final String value; // UTF-16 码元序列（字节值以 char 存）
        public BinArrExpr(int line, String v) { super(line); value = v; }
    }
    public static final class IdentExpr extends Expr {
        public final String name;
        public IdentExpr(int line, String n) { super(line); name = n; }
    }
    public static final class ArgcExpr extends Expr {
        public ArgcExpr(int line) { super(line); }
    }
    public static final class ArgsExpr extends Expr {
        public final Expr key; // null 表示无参
        public ArgsExpr(int line, Expr k) { super(line); key = k; }
    }
    public static final class UnaryExpr extends Expr {
        public final int op; public final Expr expr;
        public UnaryExpr(int line, int op, Expr e) { super(line); this.op = op; expr = e; }
    }
    public static final class BinaryExpr extends Expr {
        public final int op; public final Expr left, right;
        public BinaryExpr(int line, int op, Expr l, Expr r) { super(line); this.op = op; left = l; right = r; }
    }
    public static final class CallExpr extends Expr {
        public final Expr callee; public final List<Expr> args;
        public CallExpr(int line, Expr c, List<Expr> a) { super(line); callee = c; args = a; }
    }
    public static final class AtExpr extends Expr {
        public final Expr container; public final List<Expr> keys;
        public AtExpr(int line, Expr c, List<Expr> k) { super(line); container = c; keys = k; }
    }
    public static final class CustomExpr extends Expr {
        public final String name; public final List<Expr> args;
        public CustomExpr(int line, String n, List<Expr> a) { super(line); name = n; args = a; }
    }

    // ---------------------------------------------------------- Stmt 子类
    public static final class ExprStmt extends Stmt {
        public final Expr expr;
        public ExprStmt(int line, Expr e) { super(line); expr = e; }
    }
    public static final class LetStmt extends Stmt {
        public final List<String> idents; public final boolean hasAssign; public final Expr expr;
        public LetStmt(int line, List<String> ids, boolean ha, Expr e) { super(line); idents = ids; hasAssign = ha; expr = e; }
    }
    public static final class ReturnStmt extends Stmt {
        public final List<Expr> exprs;
        public ReturnStmt(int line, List<Expr> es) { super(line); exprs = es; }
    }
    public static final class ExportStmt extends Stmt {
        public final List<String> idents;
        public ExportStmt(int line, List<String> ids) { super(line); idents = ids; }
    }
    public static final class BlockStmt extends Stmt {
        public final Prog prog;
        public BlockStmt(int line, Prog p) { super(line); prog = p; }
    }
    public static final class IfStmt extends Stmt {
        public final Expr cond; public final Prog first;
        public final List<Elif> elifs; public final Prog elseProg;
        public IfStmt(int line, Expr c, Prog f, List<Elif> es, Prog ep) { super(line); cond = c; first = f; elifs = es; elseProg = ep; }
    }
    public static final class WhileStmt extends Stmt {
        public final Expr cond; public final Prog prog;
        public WhileStmt(int line, Expr c, Prog p) { super(line); cond = c; prog = p; }
    }
    public static final class AssignStmt extends Stmt {
        public final Expr left, right;
        public AssignStmt(int line, Expr l, Expr r) { super(line); left = l; right = r; }
    }
    public static final class BreakStmt extends Stmt { public BreakStmt(int line) { super(line); } }
    public static final class ContinueStmt extends Stmt { public ContinueStmt(int line) { super(line); } }
    public static final class DeferStmt extends Stmt {
        public final Stmt inner;
        public DeferStmt(int line, Stmt s) { super(line); inner = s; }
    }
    public static final class ErrStmt extends Stmt { public ErrStmt(int line) { super(line); } }

    // ---------------------------------------------------------- shape 序列化
    public static final class Shaper {
        private final StringBuilder out = new StringBuilder();
        private final Function<String, String> esc;

        /** esc 回调：对字符串内容转义（测试侧传 Golden.esc16）。 */
        public Shaper(Function<String, String> escFn) { this.esc = escFn; }

        public String prog(Prog p) {
            if (p == null) return "";
            for (int i = 0; i < p.stmts.size(); i++) {
                if (i > 0) out.append(" ; ");
                stmt(p.stmts.get(i));
            }
            return out.toString();
        }

        public void stmt(Stmt s) {
            if (s == null) { out.append("null"); return; }
            if (s instanceof ExprStmt x) { out.append("ExprStmt("); expr(x.expr); out.append(')'); }
            else if (s instanceof LetStmt x) {
                out.append("Let[");
                for (int i = 0; i < x.idents.size(); i++) { if (i > 0) out.append(','); out.append(x.idents.get(i)); }
                out.append(']');
                if (x.hasAssign) { out.append('='); expr(x.expr); }
            } else if (s instanceof ReturnStmt x) {
                out.append("Return(");
                for (int i = 0; i < x.exprs.size(); i++) { if (i > 0) out.append(", "); expr(x.exprs.get(i)); }
                out.append(')');
            } else if (s instanceof ExportStmt x) {
                out.append("Export[");
                for (int i = 0; i < x.idents.size(); i++) { if (i > 0) out.append(','); out.append(x.idents.get(i)); }
                out.append(']');
            } else if (s instanceof BlockStmt x) { out.append("Block{"); prog(x.prog); out.append('}'); }
            else if (s instanceof IfStmt x) {
                out.append("If("); expr(x.cond); out.append("){"); prog(x.first); out.append('}');
                for (Elif ei : x.elifs) { out.append("Elif("); expr(ei.cond); out.append("){"); prog(ei.prog); out.append('}'); }
                if (x.elseProg != null) { out.append("Else{"); prog(x.elseProg); out.append('}'); }
            } else if (s instanceof WhileStmt x) { out.append("While("); expr(x.cond); out.append("){"); prog(x.prog); out.append('}'); }
            else if (s instanceof AssignStmt x) { out.append("Assign("); expr(x.left); out.append(", "); expr(x.right); out.append(')'); }
            else if (s instanceof BreakStmt) out.append("Break");
            else if (s instanceof ContinueStmt) out.append("Continue");
            else if (s instanceof DeferStmt x) { out.append("Defer("); stmt(x.inner); out.append(')'); }
            else if (s instanceof ErrStmt) out.append('?');
        }

        public void expr(Expr e) {
            if (e == null) { out.append("null"); return; }
            if (e instanceof ErrExpr x) out.append("Err(L").append(x.line).append(')');
            else if (e instanceof NullExpr) out.append("Null");
            else if (e instanceof ArgcExpr) out.append("Argc");
            else if (e instanceof BoolExpr x) out.append(x.value ? "Bool(true)" : "Bool(false)");
            else if (e instanceof IntExpr x) out.append("Int(").append(x.value).append(')');
            else if (e instanceof FloatExpr x) out.append("Float(").append(GoldenFmt.shortG(x.value)).append(')');
            else if (e instanceof BinArrExpr x) {
                out.append("BinArr[");
                for (int i = 0; i < x.value.length(); i++) {
                    if (i > 0) out.append(',');
                    out.append(String.format("%02x", (int) x.value.charAt(i) & 0xff));
                }
                out.append(']');
            } else if (e instanceof StringExpr x) out.append("Str(\"").append(esc.apply(x.value)).append("\")");
            else if (e instanceof IdentExpr x) out.append("Ident(").append(x.name).append(')');
            else if (e instanceof ArgsExpr x) {
                if (x.key == null) out.append("Args(null)");
                else { out.append("Args("); expr(x.key); out.append(')'); }
            } else if (e instanceof UnaryExpr x) {
                out.append("Unary(").append(TokenType.name(x.op)).append(", "); expr(x.expr); out.append(')');
            } else if (e instanceof BinaryExpr x) {
                out.append("Bin(").append(TokenType.name(x.op)).append(", "); expr(x.left); out.append(", "); expr(x.right); out.append(')');
            } else if (e instanceof CallExpr x) {
                out.append("Call("); expr(x.callee);
                for (Expr a : x.args) { out.append("; "); expr(a); }
                out.append(')');
            } else if (e instanceof AtExpr x) {
                out.append("At("); expr(x.container);
                for (Expr k : x.keys) { out.append("; "); expr(k); }
                out.append(')');
            } else if (e instanceof CustomExpr x) {
                out.append("Custom(").append(x.name);
                for (Expr a : x.args) { out.append("; "); expr(a); }
                out.append(')');
            }
        }

        public String done() { return out.toString(); }
    }

    /** 库内不依赖 tests.Golden，放一个 fmt 的静态镜像。 */
    public static final class GoldenFmt {
        public static String shortG(double v) { return stope.Format.fmtG(v); }
    }
}
