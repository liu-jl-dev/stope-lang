package stope;

import stope.Ast.*;

/** 常量折叠 —— 只做单节点变换，自底向上。数值 helper 折叠与 VM 共用。
 *  整数 64 位回绕、除法向零取整。 */
public final class ExprOptim {
    private ExprOptim() {}

    // ---------------------------------------------------------- 数值 helper（折叠与 VM 共用）
    public static long intAdd(long a, long b) { return a + b; }
    public static long intSub(long a, long b) { return a - b; }
    public static long intMul(long a, long b) { return a * b; }
    public static long intNeg(long a) { return -a; }
    public static long intDiv(long a, long b) {
        if (a == Long.MIN_VALUE && b == -1) return Long.MIN_VALUE;
        return a / b;
    }
    public static long intMod(long a, long b) {
        if (b == -1) return 0;
        return a % b;
    }
    public static long intPow(long base, long exp) {
        long result = 1, b = base, e = exp;
        while (e > 0) {
            if ((e & 1) != 0) result *= b;
            e >>= 1;
            if (e > 0) b *= b;
        }
        return result;
    }
    public static boolean isSpecial(double v) { return Double.isNaN(v) || Double.isInfinite(v); }
    public static double fmod(double a, double b) {
        if (b == 0.0 || Double.isNaN(a) || Double.isNaN(b)) return Double.NaN;
        return a % b; // Java % 是 fmod 语义（余数跟被除数）
    }
    public static double fpow(double a, double b) { return Math.pow(a, b); }

    // ---------------------------------------------------------- 折叠
    private enum Kind { NOT_CONST, NULL_, BOOL, INT, FLOAT, STRING, BINARR }

    private static Kind kindOf(Expr e) {
        if (e == null) return Kind.NOT_CONST;
        if (e instanceof NullExpr) return Kind.NULL_;
        if (e instanceof BoolExpr) return Kind.BOOL;
        if (e instanceof IntExpr) return Kind.INT;
        if (e instanceof FloatExpr) return Kind.FLOAT;
        if (e instanceof StringExpr) return Kind.STRING;
        if (e instanceof BinArrExpr) return Kind.BINARR;
        return Kind.NOT_CONST;
    }
    private static boolean isConst(Kind k) { return k != Kind.NOT_CONST; }
    private static boolean isNumeric(Kind k) { return k == Kind.INT || k == Kind.FLOAT; }
    private static boolean isSeq(Kind k) { return k == Kind.STRING || k == Kind.BINARR; }
    private static boolean isNumLike(Kind k) { return k == Kind.BOOL || isNumeric(k); }
    private static boolean bothNumInt(Kind l, Kind r) { return isNumLike(l) && isNumLike(r) && l != Kind.FLOAT && r != Kind.FLOAT; }
    private static long asInt(Expr e) { return e instanceof IntExpr x ? x.value : 0; }
    private static long numAsInt(Expr e) {
        if (e instanceof BoolExpr x) return x.value ? 1 : 0;
        if (e instanceof IntExpr x) return x.value;
        return 0;
    }
    private static double asDouble(Expr e) {
        if (e instanceof BoolExpr x) return x.value ? 1.0 : 0.0;
        if (e instanceof IntExpr x) return (double) x.value;
        if (e instanceof FloatExpr x) return x.value;
        return 0.0;
    }
    private static int seqSize(Expr e) {
        if (e instanceof StringExpr x) return x.value.length();
        if (e instanceof BinArrExpr x) return x.value.length();
        return 0;
    }
    private static String seqValue(Expr e) {
        if (e instanceof StringExpr x) return x.value;
        if (e instanceof BinArrExpr x) return x.value;
        return "";
    }
    private static boolean truthy(Expr e) {
        if (e instanceof NullExpr) return false;
        if (e instanceof BoolExpr x) return x.value;
        if (e instanceof IntExpr x) return x.value != 0;
        if (e instanceof FloatExpr x) return x.value != 0.0;
        if (e instanceof StringExpr x) return x.value.length() != 0;
        if (e instanceof BinArrExpr x) return x.value.length() != 0;
        return false;
    }
    private static boolean seqEqual(Expr a, Expr b) {
        if (a instanceof StringExpr && b instanceof StringExpr) return seqValue(a).equals(seqValue(b));
        if (a instanceof BinArrExpr && b instanceof BinArrExpr) return seqValue(a).equals(seqValue(b));
        return false;
    }
    private static boolean cmpOf(int op, long a, long b) {
        return switch (op) {
            case TokenType.LT -> a < b; case TokenType.LE -> a <= b; case TokenType.GT -> a > b;
            default -> a >= b;
        };
    }
    private static boolean cmpOfF(int op, double a, double b) {
        return switch (op) {
            case TokenType.LT -> a < b; case TokenType.LE -> a <= b; case TokenType.GT -> a > b;
            default -> a >= b;
        };
    }

    private static Expr repeatSeq(int line, Expr base, long times) {
        if (times < 0) return null;
        int unit = seqSize(base);
        Kind k = kindOf(base);
        if (unit == 0) return k == Kind.STRING ? new StringExpr(line, "") : new BinArrExpr(line, "");
        if (times > (1 << 20) / unit) return null;
        StringBuilder out = new StringBuilder();
        for (long i = 0; i < times; i++) out.append(seqValue(base));
        return k == Kind.STRING ? new StringExpr(line, out.toString()) : new BinArrExpr(line, out.toString());
    }

    /** 单节点折叠：返回新节点或入参本身。 */
    public static Expr optimize(Expr e) {
        if (e == null) return null;
        Expr r = null;
        if (e instanceof UnaryExpr u) r = foldUnary(e, u);
        else if (e instanceof BinaryExpr b) r = foldBinary(e, b);
        return r != null ? r : e;
    }

    private static Expr foldUnary(Expr e, UnaryExpr u) {
        Expr inner = u.expr;
        Kind ck = kindOf(inner);
        if (!isConst(ck)) return null;
        int op = u.op;
        int line = e.line;
        if (op == TokenType.Not) {
            if (ck == Kind.NULL_ || isNumLike(ck)) return new BoolExpr(line, !truthy(inner));
            return null;
        }
        if (op == TokenType.Sub) {
            if (inner instanceof BoolExpr x) return new IntExpr(line, x.value ? -1 : 0);
            if (inner instanceof IntExpr x) return new IntExpr(line, intNeg(x.value));
            if (inner instanceof FloatExpr x) return new FloatExpr(line, -x.value);
            return null;
        }
        return null;
    }

    private static Expr foldBinary(Expr e, BinaryExpr b) {
        Expr L = b.left, R = b.right;
        Kind lk = kindOf(L), rk = kindOf(R);
        if (!isConst(lk) || !isConst(rk)) return null;
        int op = b.op;
        int line = e.line;

        // L1 and/or
        if (op == TokenType.And) return new BoolExpr(line, truthy(L) && truthy(R));
        if (op == TokenType.Or) return new BoolExpr(line, truthy(L) || truthy(R));

        // L2 null
        if (lk == Kind.NULL_ || rk == Kind.NULL_) {
            boolean both = lk == Kind.NULL_ && rk == Kind.NULL_;
            if (op == TokenType.EQ) return new BoolExpr(line, both);
            if (op == TokenType.NE) return new BoolExpr(line, !both);
            return null;
        }

        // L3 比较
        if (op == TokenType.EQ || op == TokenType.NE) {
            boolean decided = false, eq = false;
            if (lk == Kind.BOOL && rk == Kind.BOOL) {
                decided = true;
                eq = ((BoolExpr) L).value == ((BoolExpr) R).value;
            } else if (isNumeric(lk) && isNumeric(rk)) {
                decided = true;
                eq = bothNumInt(lk, rk) ? asInt(L) == asInt(R) : asDouble(L) == asDouble(R);
            } else if (isSeq(lk) && lk == rk) {
                decided = true;
                eq = seqEqual(L, R);
            }
            if (decided) return new BoolExpr(line, op == TokenType.EQ ? eq : !eq);
            return null;
        }
        if (op == TokenType.LT || op == TokenType.LE || op == TokenType.GT || op == TokenType.GE) {
            if (isNumeric(lk) && isNumeric(rk)) {
                boolean v = bothNumInt(lk, rk) ? cmpOf(op, asInt(L), asInt(R)) : cmpOfF(op, asDouble(L), asDouble(R));
                return new BoolExpr(line, v);
            }
            return null;
        }

        // L4 算术
        if (isNumLike(lk)) {
            if (op == TokenType.Add || op == TokenType.Sub || op == TokenType.Mul) {
                if (isNumLike(rk)) {
                    if (bothNumInt(lk, rk)) {
                        long a = numAsInt(L), bb = numAsInt(R);
                        return new IntExpr(line, op == TokenType.Add ? intAdd(a, bb) : op == TokenType.Sub ? intSub(a, bb) : intMul(a, bb));
                    }
                    double x = asDouble(L), y = asDouble(R);
                    return new FloatExpr(line, op == TokenType.Add ? x + y : op == TokenType.Sub ? x - y : x * y);
                } else if (op == TokenType.Mul && isSeq(rk) && lk != Kind.FLOAT) {
                    return repeatSeq(line, R, numAsInt(L));
                }
            } else if (op == TokenType.Div) {
                if (isNumLike(rk)) {
                    if (bothNumInt(lk, rk)) {
                        long a = numAsInt(L), bb = numAsInt(R);
                        if (bb != 0) {
                            if (intMod(a, bb) == 0) return new IntExpr(line, intDiv(a, bb));
                            return new FloatExpr(line, (double) a / (double) bb);
                        }
                    } else {
                        double bb = asDouble(R);
                        if (bb != 0.0) return new FloatExpr(line, asDouble(L) / bb);
                    }
                }
            } else if (op == TokenType.IDiv) {
                if (bothNumInt(lk, rk)) {
                    long a = numAsInt(L), bb = numAsInt(R);
                    if (bb != 0) return new IntExpr(line, intDiv(a, bb));
                }
            } else if (op == TokenType.Mod) {
                if (isNumLike(rk)) {
                    if (bothNumInt(lk, rk)) {
                        long a = numAsInt(L), bb = numAsInt(R);
                        if (bb != 0) return new IntExpr(line, intMod(a, bb));
                    } else {
                        double bb = asDouble(R);
                        if (bb != 0.0) return new FloatExpr(line, fmod(asDouble(L), bb));
                    }
                }
            } else if (op == TokenType.Pow) {
                if (isNumLike(rk)) {
                    if (bothNumInt(lk, rk)) {
                        long ex = numAsInt(R);
                        if (ex >= 0) return new IntExpr(line, intPow(numAsInt(L), ex));
                    }
                    double rr = fpow(asDouble(L), asDouble(R));
                    if (!isSpecial(rr)) return new FloatExpr(line, rr);
                }
            }
        } else if (isSeq(lk)) {
            if (op == TokenType.Add && rk == lk) {
                return lk == Kind.STRING
                    ? new StringExpr(line, seqValue(L) + seqValue(R))
                    : new BinArrExpr(line, seqValue(L) + seqValue(R));
            } else if (op == TokenType.Mul && (rk == Kind.INT || rk == Kind.BOOL)) {
                return repeatSeq(line, L, numAsInt(R));
            }
        }
        return null;
    }
}
