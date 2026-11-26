package stope;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import stope.Ast.*;

/** 编译器：AST → Program（照搬 python/stope/compiler.py，对齐 cpp/src/compiler.cpp）。
 *  指令流中指令与操作数混排；If/GoTo 的操作数是 opcodes 下标。 */
public final class Compiler {
    private static final class Deferred {
        final Stmt stmt; final int line; final int orderBaseline;
        Deferred(Stmt s, int l, int o) { stmt = s; line = l; orderBaseline = o; }
    }
    private static final class BlockScope {
        final Map<String, Integer> idMap = new java.util.LinkedHashMap<>();
        final Map<String, Integer> idOrder = new java.util.LinkedHashMap<>();
        final List<Deferred> defers = new ArrayList<>();
        boolean isDeferPayload = false;
    }
    private static final class WhileScope {
        int startIndex = 0;
        final List<Integer> breakIndices = new ArrayList<>();
    }
    private static final class Scope {
        final boolean isWhile;
        final BlockScope block;
        final WhileScope whileScope;
        Scope(BlockScope b) { isWhile = false; block = b; whileScope = null; }
        Scope(WhileScope w) { isWhile = true; block = null; whileScope = w; }
    }
    private static final class StackMgr {
        int size = 0, maxSize = 0;
        void inc(int n) { size += n; if (size > maxSize) maxSize = size; }
        void dec(int n) { size -= n; }
        void converge(int depth) { size = depth; }
    }

    private final Program prog;
    private final Opcode.CustomOpcodeConfig custom;
    public final List<String> errors = new ArrayList<>();
    private final List<String> varNames = new ArrayList<>();
    private final List<Integer> recycled = new ArrayList<>();
    private final StackMgr stack = new StackMgr();
    private final List<Scope> scopes = new ArrayList<>();
    private int declCounter = 0;
    private int deferOrderFloor = -1;
    private int deferErrLine = -1;
    private boolean stmtTerminates = false;
    private boolean sawBreak = false;
    private int curLine = -1;

    public Compiler(Program out, Opcode.CustomOpcodeConfig cfg) {
        this.prog = out;
        this.custom = cfg;
        resetCompile();
    }

    private void resetCompile() {
        errors.clear(); varNames.clear(); recycled.clear(); scopes.clear();
        declCounter = 0; deferOrderFloor = -1; deferErrLine = -1;
        stmtTerminates = false; sawBreak = false; curLine = -1;
        prog.clear();
        scopes.add(new Scope(new BlockScope()));
    }

    public boolean compile(Prog tree, List<String> preExports) {
        resetCompile();
        for (String n : preExports) {
            if (n.isEmpty()) { addError(0, "empty name in pre-exports. "); continue; }
            BlockScope fs = fileScope();
            if (fs.idMap.containsKey(n)) { addError(0, "duplicate export of \"" + n + "\". "); continue; }
            int idx = newUniqueVar(n);
            declareExported(n, idx, false);
        }
        visitProg(tree);
        if (!stmtTerminates) spliceDefers(fileScope());
        fileScope().defers.clear();
        if (!errors.isEmpty()) { prog.clear(); return false; }
        prog.variableNum = varNames.size();
        prog.requiredStackSize = stack.maxSize;
        return true;
    }

    // ------------------------------------------------------------ 指令发射
    private int codeSize() { return prog.opcodes.size(); }
    private void emitOp(int o) { prog.opcodes.add(o); }
    private void emitRaw(int v) {
        if (v < -32768 || v > 32767) {
            addError(curLine, "compile output too large: index exceeds int16. ");
            prog.opcodes.add(0);
            return;
        }
        prog.opcodes.add(v);
    }
    private void emitIndex(int idx) { emitRaw(idx); }
    private int emitPlaceholder() { prog.opcodes.add(-1); return codeSize() - 1; }
    private void patchIndex(int pos, int target) {
        if (target > 32767) {
            addError(curLine, "compile output too large: jump target exceeds int16. ");
            prog.opcodes.set(pos, 0);
            return;
        }
        prog.opcodes.set(pos, target);
    }
    private void addError(int line, String msg) { errors.add("line " + line + ": " + msg); }

    // ------------------------------------------------------------ 作用域/变量
    private BlockScope fileScope() { return scopes.get(0).block; }
    private BlockScope pushBlockScope() {
        BlockScope bs = new BlockScope();
        scopes.add(new Scope(bs));
        return bs;
    }
    private WhileScope pushWhileScope() {
        WhileScope ws = new WhileScope();
        scopes.add(new Scope(ws));
        return ws;
    }
    private void popScope() { scopes.remove(scopes.size() - 1); }
    private BlockScope topBlockScope() {
        for (int i = scopes.size() - 1; i >= 0; i--)
            if (!scopes.get(i).isWhile) return scopes.get(i).block;
        return null;
    }
    private int newVar() {
        if (!recycled.isEmpty()) {
            int idx = recycled.remove(recycled.size() - 1);
            varNames.set(idx, "");
            return idx;
        }
        int i = varNames.size();
        varNames.add("");
        return i;
    }
    private int newUniqueVar(String name) { int i = varNames.size(); varNames.add(name); return i; }
    private void freeVar(int idx) { if (!recycled.contains(idx)) recycled.add(idx); }
    private int nextDeclOrder() { int o = declCounter; declCounter++; return o; }
    private void declareLocal(BlockScope bs, String name, int idx) {
        bs.idMap.put(name, idx);
        bs.idOrder.put(name, nextDeclOrder());
    }
    private void declareExported(String name, int idx, boolean implicit) {
        BlockScope fs = fileScope();
        fs.idMap.put(name, idx);
        fs.idOrder.put(name, implicit ? -1 : nextDeclOrder());
        prog.exports.put(name, idx);
    }
    private BlockScope findIdentHost(String name) {
        for (int i = scopes.size() - 1; i >= 0; i--) {
            Scope sc = scopes.get(i);
            if (!sc.isWhile && sc.block.idMap.containsKey(name)) return sc.block;
        }
        return null;
    }
    private BlockScope findIdentHostFrozen(String name, int floor) {
        int payloadIdx = -1;
        for (int i = scopes.size() - 1; i >= 0; i--) {
            Scope sc = scopes.get(i);
            if (!sc.isWhile && sc.block.isDeferPayload) { payloadIdx = i; break; }
        }
        for (int i = scopes.size() - 1; i >= 0; i--) {
            Scope sc = scopes.get(i);
            if (sc.isWhile) continue;
            BlockScope bs = sc.block;
            if (!bs.idMap.containsKey(name)) continue;
            if (i < payloadIdx) {
                Integer order = bs.idOrder.get(name);
                if (order != null && order >= 0 && order >= floor) continue;
            }
            return bs;
        }
        return null;
    }
    private BlockScope resolveAtSplice(String name) {
        BlockScope f = findIdentHostFrozen(name, deferOrderFloor);
        if (f != null) return f;
        BlockScope fs = fileScope();
        if (fs.idMap.containsKey(name)) {
            addError(deferErrLine, "duplicate export of \"" + name + "\". ");
            return fs;
        }
        return null;
    }
    private int identSlot(String name) {
        BlockScope host = deferOrderFloor >= 0 ? resolveAtSplice(name) : findIdentHost(name);
        if (host != null) return host.idMap.get(name);
        int idx = newUniqueVar(name);
        declareExported(name, idx, true);
        return fileScope().idMap.get(name);
    }

    // ------------------------------------------------------------ defer
    private void spliceDefers(BlockScope bs) {
        if (bs.defers.isEmpty() || !errors.isEmpty()) return;
        for (int k = bs.defers.size() - 1; k >= 0; k--) {
            if (!errors.isEmpty()) return;
            Deferred d = bs.defers.get(k);
            int savedFloor = deferOrderFloor, savedLine = deferErrLine;
            deferOrderFloor = d.orderBaseline;
            deferErrLine = d.line;
            BlockScope ps = pushBlockScope();
            ps.isDeferPayload = true;
            if (d.stmt != null) visitStmt(d.stmt);
            spliceDefers(ps);
            popScope();
            for (int v : ps.idMap.values()) freeVar(v);
            deferOrderFloor = savedFloor;
            deferErrLine = savedLine;
        }
    }

    // ------------------------------------------------------------ 语句
    private void visitProg(Prog p) {
        boolean terminated = false;
        for (Stmt s : p.stmts) {
            if (terminated) break;
            stmtTerminates = false;
            curLine = s.line;
            visitStmt(s);
            terminated = stmtTerminates;
        }
    }

    private void visitBodyAsBlock(Prog p) {
        BlockScope bs = pushBlockScope();
        visitProg(p);
        if (!stmtTerminates) spliceDefers(bs);
        bs.defers.clear();
        popScope();
        for (int v : bs.idMap.values()) freeVar(v);
    }

    private void visitStmt(Stmt s) {
        curLine = s.line;
        if (s instanceof ExprStmt x) { visitExpr(x.expr); emitOp(Opcode.Pop); stack.dec(1); }
        else if (s instanceof LetStmt x) visitLet(x);
        else if (s instanceof ReturnStmt x) visitReturn(x.exprs);
        else if (s instanceof ExportStmt x) visitExport(x.idents);
        else if (s instanceof BlockStmt x) visitBodyAsBlock(x.prog);
        else if (s instanceof IfStmt x) visitIf(x);
        else if (s instanceof WhileStmt x) visitWhile(x);
        else if (s instanceof AssignStmt x) {
            if (x.left instanceof IdentExpr id) {
                int idx = identSlot(id.name);
                emitOp(Opcode.PushId); emitIndex(idx); stack.inc(1);
            } else visitExpr(x.left);
            visitExpr(x.right);
            emitOp(Opcode.Assign); stack.dec(2);
        } else if (s instanceof BreakStmt) visitBreak();
        else if (s instanceof ContinueStmt) visitContinue();
        else if (s instanceof DeferStmt x) {
            BlockScope bs = topBlockScope();
            if (bs != null) bs.defers.add(new Deferred(x.inner, s.line, declCounter));
        }
        // ErrStmt 什么都不发
    }

    private void visitLet(LetStmt l) {
        BlockScope bs = topBlockScope();
        if (bs == null) return;
        if (l.hasAssign) {
            if (l.idents.isEmpty()) return;
            String name = l.idents.get(0);
            if (bs.idMap.containsKey(name)) { addError(curLine, "duplicate declaration of '" + name + "'. "); return; }
            int idx = newVar();
            declareLocal(bs, name, idx);
            emitOp(Opcode.PushId); emitIndex(idx); stack.inc(1);
            if (l.expr != null) visitExpr(l.expr);
            emitOp(Opcode.Assign); stack.dec(2);
        } else {
            for (String name : l.idents) {
                if (bs.idMap.containsKey(name)) { addError(curLine, "duplicate declaration of '" + name + "'. "); continue; }
                int idx = newVar();
                declareLocal(bs, name, idx);
            }
        }
    }

    private void visitReturn(List<Expr> es) {
        for (Scope sc : scopes)
            if (!sc.isWhile && sc.block.isDeferPayload) {
                addError(curLine, "\"return\" cannot be used in a defer statement. ");
                return;
            }
        for (int i = scopes.size() - 1; i >= 0; i--)
            if (!scopes.get(i).isWhile) spliceDefers(scopes.get(i).block);
        for (Expr e : es) visitExpr(e);
        emitOp(Opcode.Return); emitIndex(es.size());
        if (es.size() > prog.maxReturnNum) prog.maxReturnNum = es.size();
        stmtTerminates = true;
    }

    private void visitExport(List<String> ids) {
        if (scopes.size() > 1) addError(curLine, "\"export\" can only be used at top scope. ");
        BlockScope fs = fileScope();
        for (String name : ids) {
            if (fs.idMap.containsKey(name)) { addError(curLine, "duplicate export of \"" + name + "\". "); continue; }
            int idx = newUniqueVar(name);
            declareExported(name, idx, false);
        }
    }

    // ------------------------------------------------------------ if / while
    private static Boolean constCondTruth(Expr e) {
        if (e == null) return null;
        if (e instanceof NullExpr || e instanceof BoolExpr || e instanceof IntExpr
            || e instanceof FloatExpr || e instanceof StringExpr || e instanceof BinArrExpr) {
            return truthyExpr(e);
        }
        return null;
    }
    private static boolean truthyExpr(Expr e) {
        if (e instanceof NullExpr) return false;
        if (e instanceof BoolExpr x) return x.value;
        if (e instanceof IntExpr x) return x.value != 0;
        if (e instanceof FloatExpr x) return x.value != 0.0;
        if (e instanceof StringExpr x) return !x.value.isEmpty();
        if (e instanceof BinArrExpr x) return !x.value.isEmpty();
        return false;
    }

    private void visitIf(IfStmt iv) {
        if (iv.cond == null) return;
        List<Integer> gotoEnd = new ArrayList<>();
        int pendingFalse = -1;
        boolean allTerminate = true, anyEmitted = false, fallthrough = false, chainEnded = false;

        Boolean truth = constCondTruth(iv.cond);
        if (truth != null) {
            if (truth) {
                visitBodyAsBlock(iv.first);
                allTerminate = allTerminate && stmtTerminates;
                anyEmitted = true; fallthrough = true; chainEnded = true;
            }
        } else {
            visitExpr(iv.cond);
            emitOp(Opcode.If); stack.dec(1);
            pendingFalse = emitPlaceholder();
            visitBodyAsBlock(iv.first);
            boolean term = stmtTerminates;
            allTerminate = allTerminate && term;
            anyEmitted = true;
            if (!term) { emitOp(Opcode.GoTo); gotoEnd.add(emitPlaceholder()); }
        }
        for (Elif ei : iv.elifs) {
            if (chainEnded || ei.cond == null) continue;
            Boolean et = constCondTruth(ei.cond);
            if (et != null) {
                if (et) {
                    if (pendingFalse >= 0) patchIndex(pendingFalse, codeSize());
                    pendingFalse = -1;
                    visitBodyAsBlock(ei.prog);
                    allTerminate = allTerminate && stmtTerminates;
                    anyEmitted = true; fallthrough = true; chainEnded = true;
                }
                continue;
            }
            if (pendingFalse >= 0) patchIndex(pendingFalse, codeSize());
            pendingFalse = -1;
            visitExpr(ei.cond);
            emitOp(Opcode.If); stack.dec(1);
            pendingFalse = emitPlaceholder();
            visitBodyAsBlock(ei.prog);
            boolean term = stmtTerminates;
            allTerminate = allTerminate && term;
            anyEmitted = true;
            if (!term) { emitOp(Opcode.GoTo); gotoEnd.add(emitPlaceholder()); }
        }
        if (!chainEnded && iv.elseProg != null) {
            if (pendingFalse >= 0) patchIndex(pendingFalse, codeSize());
            pendingFalse = -1;
            visitBodyAsBlock(iv.elseProg);
            allTerminate = allTerminate && stmtTerminates;
            anyEmitted = true; fallthrough = true;
        }
        if (pendingFalse >= 0) patchIndex(pendingFalse, codeSize());
        for (int pos : gotoEnd) patchIndex(pos, codeSize());
        stmtTerminates = anyEmitted && allTerminate && fallthrough;
    }

    private void visitWhile(WhileStmt w) {
        Boolean truth = constCondTruth(w.cond);
        boolean condConst = truth != null;
        boolean eliminate = condConst && !truth;
        WhileScope ws = pushWhileScope();
        ws.startIndex = codeSize();
        int caseGotoEnd = -1;
        if (w.cond != null && !condConst) {
            visitExpr(w.cond);
            emitOp(Opcode.If); stack.dec(1);
            caseGotoEnd = emitPlaceholder();
        }
        if (eliminate) { stmtTerminates = false; popScope(); return; }
        boolean savedSawBreak = sawBreak;
        sawBreak = false;
        visitBodyAsBlock(w.prog);
        boolean bodyTerm = stmtTerminates;
        boolean bodySawBreak = sawBreak;
        sawBreak = savedSawBreak;
        if (!bodyTerm) { emitOp(Opcode.GoTo); emitIndex(ws.startIndex); }
        for (int pos : ws.breakIndices) patchIndex(pos, codeSize());
        if (caseGotoEnd >= 0) patchIndex(caseGotoEnd, codeSize());
        stmtTerminates = ((w.cond == null || (condConst && truth)) && !bodySawBreak);
        popScope();
    }

    private int findWhileIdx() {
        for (int i = scopes.size() - 1; i >= 0; i--) {
            Scope sc = scopes.get(i);
            if (sc.isWhile) return i;
            if (!sc.isWhile && sc.block.isDeferPayload) return -2; // 撞到 defer 载荷
        }
        return -1;
    }

    private void spliceDefersAbove(int whileIdx) {
        for (int i = scopes.size() - 1; i > whileIdx; i--)
            if (!scopes.get(i).isWhile) spliceDefers(scopes.get(i).block);
    }

    private void visitBreak() {
        int wi = findWhileIdx();
        if (wi == -2) { addError(curLine, "\"break\" cannot cross a defer statement. "); return; }
        if (wi < 0) { addError(curLine, "cannot use \"break\" outside of a loop. "); return; }
        spliceDefersAbove(wi);
        emitOp(Opcode.GoTo);
        scopes.get(wi).whileScope.breakIndices.add(emitPlaceholder());
        sawBreak = true;
        stmtTerminates = true;
    }

    private void visitContinue() {
        int wi = findWhileIdx();
        if (wi == -2) { addError(curLine, "\"continue\" cannot cross a defer statement. "); return; }
        if (wi < 0) { addError(curLine, "cannot use \"continue\" outside of a loop. "); return; }
        spliceDefersAbove(wi);
        emitOp(Opcode.GoTo);
        emitIndex(scopes.get(wi).whileScope.startIndex);
        stmtTerminates = true;
    }

    // ------------------------------------------------------------ 表达式
    private void visitExpr(Expr e) {
        if (e instanceof ErrExpr) return;
        else if (e instanceof NullExpr) { emitOp(Opcode.PushNull); stack.inc(1); }
        else if (e instanceof BoolExpr x) { emitOp(x.value ? Opcode.PushTrue : Opcode.PushFalse); stack.inc(1); }
        else if (e instanceof IntExpr x) { emitOp(Opcode.PushInt); emitIndex(constIndex(prog.intConsts, x.value)); stack.inc(1); }
        else if (e instanceof FloatExpr x) { emitOp(Opcode.PushFloat); emitIndex(constIndex(prog.floatConsts, x.value)); stack.inc(1); }
        else if (e instanceof StringExpr x) { emitOp(Opcode.PushString); emitIndex(constIndex(prog.stringConsts, x.value)); stack.inc(1); }
        else if (e instanceof BinArrExpr x) { emitOp(Opcode.PushBinArr); emitIndex(constIndex(prog.binarrConsts, x.value)); stack.inc(1); }
        else if (e instanceof IdentExpr x) { int idx = identSlot(x.name); emitOp(Opcode.PushValue); emitIndex(idx); stack.inc(1); }
        else if (e instanceof ArgcExpr) { emitOp(Opcode.ArgNum); stack.inc(1); }
        else if (e instanceof ArgsExpr x) { if (x.key != null) visitExpr(x.key); emitOp(Opcode.GetArg); }
        else if (e instanceof UnaryExpr x) {
            visitExpr(x.expr);
            if (x.op == TokenType.Not) emitOp(Opcode.Not);
            else if (x.op == TokenType.Sub) emitOp(Opcode.Minus);
        } else if (e instanceof BinaryExpr x) {
            if (x.op == TokenType.Or) { visitOr(x); return; }
            if (x.op == TokenType.And) { visitAnd(x); return; }
            visitExpr(x.left); visitExpr(x.right);
            emitOp(binaryOpcode(x.op));
            stack.dec(1);
        } else if (e instanceof CallExpr x) {
            visitExpr(x.callee);
            for (Expr a : x.args) visitExpr(a);
            emitOp(Opcode.Call); emitIndex(x.args.size());
            stack.dec(x.args.size());
        } else if (e instanceof AtExpr x) {
            visitExpr(x.container);
            for (Expr k : x.keys) visitExpr(k);
            emitOp(Opcode.At); emitIndex(x.keys.size());
            stack.dec(x.keys.size());
        } else if (e instanceof CustomExpr x) {
            Opcode.CustomOpcode info = custom != null ? custom.find(x.name) : null;
            if (info == null) { addError(curLine, "undefined custom opcode \"" + x.name + "\". "); return; }
            if (!info.varArg && info.argNum != x.args.size())
                addError(curLine, "custom opcode \"" + x.name + "\" expected " + info.argNum + " args, but got " + x.args.size() + ". ");
            for (Expr a : x.args) visitExpr(a);
            prog.opcodes.add(info.opcode);
            if (info.varArg) emitIndex(x.args.size());
            stack.dec(x.args.size() - 1);
        }
    }

    private void visitOr(BinaryExpr b) {
        visitExpr(b.left); emitOp(Opcode.If); stack.dec(1);
        int firstIf = emitPlaceholder();
        int depth1 = stack.size;
        emitOp(Opcode.PushTrue); stack.inc(1);
        emitOp(Opcode.GoTo); int goto1 = emitPlaceholder();
        patchIndex(firstIf, codeSize()); stack.converge(depth1);
        visitExpr(b.right); emitOp(Opcode.If); stack.dec(1);
        int secondIf = emitPlaceholder();
        int depth2 = stack.size;
        emitOp(Opcode.PushTrue); stack.inc(1);
        emitOp(Opcode.GoTo); int goto2 = emitPlaceholder();
        patchIndex(secondIf, codeSize()); stack.converge(depth2);
        emitOp(Opcode.PushFalse); stack.inc(1);
        patchIndex(goto1, codeSize()); patchIndex(goto2, codeSize());
    }

    private void visitAnd(BinaryExpr b) {
        visitExpr(b.left); emitOp(Opcode.If); stack.dec(1);
        int firstIf = emitPlaceholder();
        visitExpr(b.right); emitOp(Opcode.If); stack.dec(1);
        int secondIf = emitPlaceholder();
        int depth = stack.size;
        emitOp(Opcode.PushTrue); stack.inc(1);
        emitOp(Opcode.GoTo); int gotoEnd = emitPlaceholder();
        patchIndex(firstIf, codeSize()); patchIndex(secondIf, codeSize());
        stack.converge(depth);
        emitOp(Opcode.PushFalse); stack.inc(1);
        patchIndex(gotoEnd, codeSize());
    }

    // ------------------------------------------------------------ 工具
    private static <T> int constIndex(List<T> pool, T v) {
        for (int i = 0; i < pool.size(); i++) {
            T cur = pool.get(i);
            if (cur.equals(v)) return i;
        }
        pool.add(v);
        return pool.size() - 1;
    }
    private static int binaryOpcode(int t) {
        return switch (t) {
            case TokenType.EQ -> Opcode.EQ; case TokenType.NE -> Opcode.NE;
            case TokenType.LT -> Opcode.LT; case TokenType.LE -> Opcode.LE;
            case TokenType.GT -> Opcode.GT; case TokenType.GE -> Opcode.GE;
            case TokenType.Add -> Opcode.Add; case TokenType.Sub -> Opcode.Sub;
            case TokenType.Mul -> Opcode.Mul; case TokenType.Div -> Opcode.Div;
            case TokenType.IDiv -> Opcode.IDiv; case TokenType.Mod -> Opcode.Mod;
            case TokenType.Pow -> Opcode.Pow;
            default -> Opcode.Pop;
        };
    }
}
