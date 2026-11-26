package stope;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** 参考执行器（照搬 python/stope/basic_vm.py）—— 33 条内置指令，step/run 各写一遍。
 *  不是标准的一部分；值语义对齐 C++ 的 6 种可观测值（bool=整数 1/0）。
 *  Java String 天然是 UTF-16 码元，字符串下标直接 charAt。 */
public final class BasicVM {
    private BasicVM() {}

    /** 宿主函数接口。 */
    public interface HostFn { Value call(Object ctx, Value[] args); }
    /** 宿主句柄（VM 不解释）。 */
    public static final class Handle {
        public final Object data;
        public Handle(Object d) { data = d; }
    }

    /** 值：null / 整数 / 浮点 / 字符串 / 字节数组 / 宿主函数 / 槽位引用 / 句柄。 */
    public static final class Value {
        public enum Type { Null, Integer, Float, String, BinArr, HostFn, Identifier, Handle }
        public final Type type;
        public final long integer;
        public final double float_;
        public final String string;
        public final Object object; // HostFn 的 ctx / Handle 的 data
        public final HostFn func;
        private Value(Type t, long i, double f, String s, Object o, HostFn fn) {
            type = t; integer = i; float_ = f; string = s; object = o; func = fn;
        }
        public static final Value NULL = new Value(Type.Null, 0, 0, null, null, null);
        public static Value ofInt(long v) { return new Value(Type.Integer, v, 0, null, null, null); }
        public static Value ofFloat(double v) { return new Value(Type.Float, 0, v, null, null, null); }
        public static Value ofString(String v) { return new Value(Type.String, 0, 0, v, null, null); }
        public static Value ofBinArr(String v) { return new Value(Type.BinArr, 0, 0, v, null, null); }
        public static Value ofIdent(int idx) { return new Value(Type.Identifier, idx, 0, null, null, null); }
        public static Value ofHostFn(Object ctx, HostFn f) { return new Value(Type.HostFn, 0, 0, null, ctx, f); }
        public static Value ofHandle(Object data) { return new Value(Type.Handle, 0, 0, null, data, null); }

        public boolean isNumber() { return type == Type.Integer || type == Type.Float; }
        public boolean isSeq() { return type == Type.String || type == Type.BinArr; }
        public double asDouble() { return type == Type.Integer ? (double) integer : type == Type.Float ? float_ : 0.0; }
    }

    public static boolean truely(Value v) {
        return switch (v.type) {
            case Null -> false;
            case Integer -> v.integer != 0;
            case Float -> v.float_ != 0.0;
            case String, BinArr -> !v.string.isEmpty();
            default -> true;
        };
    }

    public static boolean equals(Value a, Value b) {
        if (a.type == Value.Type.Null || b.type == Value.Type.Null) return a.type == b.type;
        if (a.type == Value.Type.Integer && b.type == Value.Type.Integer) return a.integer == b.integer;
        if (a.type == Value.Type.Integer && b.type == Value.Type.Float) return (double) a.integer == b.float_;
        if (a.type == Value.Type.Float && b.type == Value.Type.Integer) return a.float_ == (double) b.integer;
        if (a.type == Value.Type.Float && b.type == Value.Type.Float) return a.float_ == b.float_;
        if (a.type == Value.Type.String && b.type == Value.Type.String) return a.string.equals(b.string);
        if (a.type == Value.Type.BinArr && b.type == Value.Type.BinArr) return a.string.equals(b.string);
        if (a.type == Value.Type.HostFn && b.type == Value.Type.HostFn) return a.func == b.func && a.object == b.object;
        if (a.type == Value.Type.Handle && b.type == Value.Type.Handle) return a.object == b.object;
        return false;
    }

    /** 实参表接口（宿主实现）。 */
    public interface Arguments {
        Value at(Object ctx, State s, Value key);
        int num(Object ctx);
    }

    public static final class State {
        public final Program prog;
        public Arguments args;
        public Object argsCtx;
        public final List<Value> returns = new ArrayList<>();
        public final Value[] variables;
        public final List<Value> stack = new ArrayList<>();
        public final List<String> errors = new ArrayList<>();
        public int i = 0;
        public final Map<Integer, java.util.function.Consumer<State>> customOps = new HashMap<>();

        public State(Program prog) {
            this.prog = prog;
            this.variables = new Value[Math.max(prog.variableNum, 0)];
            Arrays.fill(variables, Value.NULL);
            installBuiltins();
        }

        public void addError(String msg) { errors.add(i + ": " + msg); }
        private Value atTop(int k) { return stack.get(stack.size() - k); }
        private void storeBinary(Value v) { stack.remove(stack.size() - 1); stack.set(stack.size() - 1, v); }
        private int readOperand() { i++; return (short) (int) prog.opcodes.get(i); }
        private boolean checkArith(String name, Value l, Value r) {
            if (l.type == Value.Type.Null || r.type == Value.Type.Null) { addError("\"" + name + "\" cannot operate on null. "); return false; }
            if (!l.isNumber() || !r.isNumber()) { addError("\"" + name + "\" can only operate on integer or float. "); return false; }
            return true;
        }
        private boolean checkIntZero(String name, Value l, Value r) {
            if (l.type == Value.Type.Integer && r.type == Value.Type.Integer && r.integer == 0) {
                addError("\"" + name + "\" division by zero. "); return false;
            }
            return true;
        }
        private Boolean lessThan(Value l, Value r) {
            if (l.isNumber() && r.isNumber()) return l.asDouble() < r.asDouble();
            addError("only on integer or float can be compared. ");
            return null;
        }

        /** 执行一条指令。errors 非空或指令流走完时不做事。 */
        public boolean step() {
            if (!errors.isEmpty()) return false;
            if (i >= prog.opcodes.size()) return true;
            int op = (short) (int) prog.opcodes.get(i);
            java.util.function.Consumer<State> h = customOps.get(op);
            if (h != null) h.accept(this);
            else addError("no implement for opcode " + op + ". ");
            if (!errors.isEmpty()) return false;
            i++;
            return true;
        }

        /** 执行到结束（与 step 独立的两份实现）。 */
        public boolean run() {
            int n = prog.opcodes.size();
            while (i < n) {
                int op = (short) (int) prog.opcodes.get(i);
                java.util.function.Consumer<State> h = customOps.get(op);
                if (h != null) h.accept(this);
                else addError("no implement for opcode " + op + ". ");
                if (!errors.isEmpty()) return false;
                i++;
            }
            return true;
        }

        private void installBuiltins() {
            java.util.List<java.util.function.Consumer<State>> hs = java.util.List.of(
                BasicVM::opAssign, BasicVM::opPushNull, BasicVM::opPushFalse, BasicVM::opPushTrue,
                BasicVM::opPushInt, BasicVM::opPushFloat, BasicVM::opPushString, BasicVM::opPushBinArr,
                BasicVM::opPushValue, BasicVM::opPushId, BasicVM::opCall, BasicVM::opAt,
                BasicVM::opPop, BasicVM::opMinus, BasicVM::opNot, BasicVM::opPow, BasicVM::opMul,
                BasicVM::opDiv, BasicVM::opIDiv, BasicVM::opMod, BasicVM::opAdd, BasicVM::opSub,
                BasicVM::opEq, BasicVM::opNe, BasicVM::opLt, BasicVM::opLe, BasicVM::opGt,
                BasicVM::opGe, BasicVM::opIf, BasicVM::opGoTo, BasicVM::opGetArg,
                BasicVM::opArgNum, BasicVM::opReturn
            );
            for (int k = 0; k < hs.size(); k++) customOps.put(k, hs.get(k));
        }
    }

    // ============================== 33 条指令 ==============================
    private static void opAssign(State s) {
        if (s.stack.size() < 2) { s.addError("stack underflow. "); return; }
        Value target = s.atTop(2);
        Value val = s.stack.get(s.stack.size() - 1);
        if (target.type == Value.Type.Identifier) {
            s.variables[(int) target.integer] = val;
            s.stack.remove(s.stack.size() - 1); s.stack.remove(s.stack.size() - 1);
        } else s.addError("no implement for value type. ");
    }
    private static void opPushNull(State s) { s.stack.add(Value.NULL); }
    private static void opPushFalse(State s) { s.stack.add(Value.ofInt(0)); }
    private static void opPushTrue(State s) { s.stack.add(Value.ofInt(1)); }
    private static void opPushInt(State s) { int idx = s.readOperand(); s.stack.add(Value.ofInt(s.prog.intConsts.get(idx))); }
    private static void opPushFloat(State s) { int idx = s.readOperand(); s.stack.add(Value.ofFloat(s.prog.floatConsts.get(idx))); }
    private static void opPushString(State s) { int idx = s.readOperand(); s.stack.add(Value.ofString(s.prog.stringConsts.get(idx))); }
    private static void opPushBinArr(State s) { int idx = s.readOperand(); s.stack.add(Value.ofBinArr(s.prog.binarrConsts.get(idx))); }
    private static void opPushValue(State s) { int idx = s.readOperand(); s.stack.add(s.variables[idx]); }
    private static void opPushId(State s) { int idx = s.readOperand(); s.stack.add(Value.ofIdent(idx)); }
    private static void opCall(State s) {
        int argNum = s.readOperand();
        Value callee = s.atTop(argNum + 1);
        if (callee.type != Value.Type.HostFn) { s.addError("\"Call\" can only call a function. "); return; }
        Value[] argv = new Value[argNum];
        for (int k = argNum; k > 0; k--) argv[k - 1] = s.atTop(k);
        Value out = callee.func.call(callee.object, argv);
        for (int j = 0; j < argNum; j++) s.stack.remove(s.stack.size() - 1);
        s.stack.set(s.stack.size() - 1, out);
    }
    private static void opAt(State s) {
        int keyNum = s.readOperand();
        if (keyNum != 1) { s.addError("no implement for key num != 1. "); return; }
        Value container = s.atTop(2), key = s.atTop(1);
        if (key.type != Value.Type.Integer) { s.addError("index must be integer. "); return; }
        long index = key.integer;
        Value result = Value.NULL;
        if (container.type == Value.Type.BinArr) {
            if (index < 0 || index >= container.string.length()) { s.addError("index out of range. "); return; }
            result = Value.ofInt(container.string.charAt((int) index) & 0xff);
        } else if (container.type == Value.Type.String) {
            // Java String 按 UTF-16 码元，直接 charAt
            if (index < 0 || index >= container.string.length()) { s.addError("index out of range. "); return; }
            result = Value.ofInt(container.string.charAt((int) index));
        } else { s.addError("no implement for container type. "); return; }
        s.stack.remove(s.stack.size() - 1); s.stack.remove(s.stack.size() - 1);
        s.stack.add(result);
    }
    private static void opPop(State s) { s.stack.remove(s.stack.size() - 1); }
    private static void opMinus(State s) {
        Value v = s.stack.get(s.stack.size() - 1);
        if (v.type == Value.Type.Integer) s.stack.set(s.stack.size() - 1, Value.ofInt(-v.integer));
        else if (v.type == Value.Type.Float) s.stack.set(s.stack.size() - 1, Value.ofFloat(-v.float_));
        else s.addError("\"Minus\" can only operate on integer or float. ");
    }
    private static void opNot(State s) {
        Value v = s.stack.get(s.stack.size() - 1);
        if (v.type == Value.Type.Null) s.stack.set(s.stack.size() - 1, Value.ofInt(1));
        else if (v.type == Value.Type.Integer) s.stack.set(s.stack.size() - 1, Value.ofInt(v.integer == 0 ? 1 : 0));
        else if (v.type == Value.Type.Float) s.stack.set(s.stack.size() - 1, Value.ofInt(v.float_ == 0.0 ? 1 : 0));
        else s.addError("\"Not\" can only operate on integer or float. ");
    }
    private static void opPow(State s) {
        Value l = s.atTop(2), r = s.atTop(1);
        if (!s.checkArith("Pow", l, r)) return;
        if (l.type == Value.Type.Integer && r.type == Value.Type.Integer && r.integer >= 0)
            s.storeBinary(Value.ofInt(ExprOptim.intPow(l.integer, r.integer)));
        else s.storeBinary(Value.ofFloat(ExprOptim.fpow(l.asDouble(), r.asDouble())));
    }
    private static void opMul(State s) {
        Value l = s.atTop(2), r = s.atTop(1);
        if (l.type == Value.Type.Null || r.type == Value.Type.Null) { s.addError("\"Mul\" cannot operate on null. "); return; }
        if (l.isNumber() && r.isNumber()) {
            if (l.type == Value.Type.Integer && r.type == Value.Type.Integer)
                s.storeBinary(Value.ofInt(ExprOptim.intMul(l.integer, r.integer)));
            else s.storeBinary(Value.ofFloat(l.asDouble() * r.asDouble()));
            return;
        }
        if ((l.isSeq() && r.type == Value.Type.Integer) || (l.type == Value.Type.Integer && r.isSeq())) {
            Value seq = l.isSeq() ? l : r;
            long times = l.isSeq() ? r.integer : l.integer;
            if (times < 0) { s.addError("\"Mul\" cannot repeat a sequence by a negative number. "); return; }
            StringBuilder out = new StringBuilder();
            for (long t = 0; t < times; t++) out.append(seq.string);
            s.storeBinary(seq.type == Value.Type.String ? Value.ofString(out.toString()) : Value.ofBinArr(out.toString()));
            return;
        }
        s.addError("\"Mul\" can only operate on numbers, or repeat a string / bin array by an integer. ");
    }
    private static void opDiv(State s) {
        Value l = s.atTop(2), r = s.atTop(1);
        if (!s.checkArith("Div", l, r)) return;
        if (!s.checkIntZero("Div", l, r)) return;
        if (l.type == Value.Type.Integer && r.type == Value.Type.Integer) {
            if (ExprOptim.intMod(l.integer, r.integer) == 0) s.storeBinary(Value.ofInt(ExprOptim.intDiv(l.integer, r.integer)));
            else s.storeBinary(Value.ofFloat(fdiv(l.asDouble(), r.asDouble())));
        } else s.storeBinary(Value.ofFloat(fdiv(l.asDouble(), r.asDouble())));
    }
    private static void opIDiv(State s) {
        Value l = s.atTop(2), r = s.atTop(1);
        if (!s.checkArith("IDiv", l, r)) return;
        if (!s.checkIntZero("IDiv", l, r)) return;
        if (l.type == Value.Type.Integer && r.type == Value.Type.Integer)
            s.storeBinary(Value.ofInt(ExprOptim.intDiv(l.integer, r.integer)));
        else s.storeBinary(Value.ofFloat(trunc(fdiv(l.asDouble(), r.asDouble()))));
    }
    private static void opMod(State s) {
        Value l = s.atTop(2), r = s.atTop(1);
        if (!s.checkArith("Mod", l, r)) return;
        if (!s.checkIntZero("Mod", l, r)) return;
        if (l.type == Value.Type.Integer && r.type == Value.Type.Integer)
            s.storeBinary(Value.ofInt(ExprOptim.intMod(l.integer, r.integer)));
        else s.storeBinary(Value.ofFloat(ExprOptim.fmod(l.asDouble(), r.asDouble())));
    }
    private static void opAdd(State s) {
        Value l = s.atTop(2), r = s.atTop(1);
        if (l.type == Value.Type.Null || r.type == Value.Type.Null) { s.addError("\"Add\" cannot operate on null. "); return; }
        if (l.type == Value.Type.Integer) {
            if (r.type == Value.Type.Integer) s.storeBinary(Value.ofInt(ExprOptim.intAdd(l.integer, r.integer)));
            else if (r.type == Value.Type.Float) s.storeBinary(Value.ofFloat((double) l.integer + r.float_));
            else s.addError("integer can only add integer or float. ");
        } else if (l.type == Value.Type.Float) {
            if (r.isNumber()) s.storeBinary(Value.ofFloat(l.float_ + r.asDouble()));
            else s.addError("float can only add integer or float. ");
        } else if (l.type == Value.Type.String && r.type == Value.Type.String) {
            s.storeBinary(Value.ofString(l.string + r.string));
        } else if (l.type == Value.Type.BinArr && r.type == Value.Type.BinArr) {
            s.storeBinary(Value.ofBinArr(l.string + r.string));
        } else s.addError("\"Add\" can only operate on numbers, strings or bin arrays. ");
    }
    private static void opSub(State s) {
        Value l = s.atTop(2), r = s.atTop(1);
        if (!s.checkArith("Sub", l, r)) return;
        if (l.type == Value.Type.Integer) {
            if (r.type == Value.Type.Integer) s.storeBinary(Value.ofInt(ExprOptim.intSub(l.integer, r.integer)));
            else if (r.type == Value.Type.Float) s.storeBinary(Value.ofFloat((double) l.integer - r.float_));
            else s.addError("integer can only subtract integer or float. ");
        } else if (l.type == Value.Type.Float) {
            if (r.isNumber()) s.storeBinary(Value.ofFloat(l.float_ - r.asDouble()));
            else s.addError("float can only subtract integer or float. ");
        } else s.addError("\"Sub\" can only operate on integer or float. ");
    }
    private static void opEq(State s) { s.storeBinary(Value.ofInt(equals(s.atTop(2), s.atTop(1)) ? 1 : 0)); }
    private static void opNe(State s) { s.storeBinary(Value.ofInt(equals(s.atTop(2), s.atTop(1)) ? 0 : 1)); }
    private static void opLt(State s) { Boolean v = s.lessThan(s.atTop(2), s.atTop(1)); if (v != null) s.storeBinary(Value.ofInt(v ? 1 : 0)); }
    private static void opLe(State s) { Boolean v = s.lessThan(s.atTop(1), s.atTop(2)); if (v != null) s.storeBinary(Value.ofInt(v ? 0 : 1)); }
    private static void opGt(State s) { Boolean v = s.lessThan(s.atTop(1), s.atTop(2)); if (v != null) s.storeBinary(Value.ofInt(v ? 1 : 0)); }
    private static void opGe(State s) { Boolean v = s.lessThan(s.atTop(2), s.atTop(1)); if (v != null) s.storeBinary(Value.ofInt(v ? 0 : 1)); }
    private static void opIf(State s) {
        boolean yes = truely(s.stack.get(s.stack.size() - 1));
        s.stack.remove(s.stack.size() - 1);
        int target = s.readOperand();
        if (!yes) s.i = target - 1;
    }
    private static void opGoTo(State s) { int target = s.readOperand(); s.i = target - 1; }
    private static void opGetArg(State s) {
        if (s.args == null) { s.addError("no args. "); return; }
        Value key = s.stack.remove(s.stack.size() - 1);
        s.stack.add(s.args.at(s.argsCtx, s, key));
    }
    private static void opArgNum(State s) {
        if (s.args == null) { s.addError("no args. "); return; }
        s.stack.add(Value.ofInt(s.args.num(s.argsCtx)));
    }
    private static void opReturn(State s) {
        int num = s.readOperand();
        s.returns.clear();
        for (int k = num; k > 0; k--) s.returns.add(s.atTop(k));
        s.i = s.prog.opcodes.size();
    }

    private static double fdiv(double a, double b) {
        if (b != 0.0) return a / b;
        if (a == 0.0 || Double.isNaN(a)) return Double.NaN;
        return Math.copySign(Double.POSITIVE_INFINITY, a) * Math.copySign(1.0, b);
    }
    private static double trunc(double v) {
        if (ExprOptim.isSpecial(v)) return v;
        return v < 0 ? Math.ceil(v) : Math.floor(v);
    }

    /** 紧凑值格式（测试用，对齐 python/tests/test_vm.py 的 _fmt）。 */
    public static String fmtValue(Value v) {
        return switch (v.type) {
            case Null -> "null";
            case Integer -> String.valueOf(v.integer);
            case Float -> {
                if (Double.isNaN(v.float_)) yield "nan";
                if (Double.isInfinite(v.float_)) yield v.float_ < 0 ? "-inf" : "inf";
                String t = Format.fmtG(v.float_);
                yield (t.indexOf('.') < 0 && t.indexOf('e') < 0) ? t + ".0" : t;
            }
            case String -> v.string;
            case BinArr -> {
                StringBuilder out = new StringBuilder("[");
                for (int k = 0; k < v.string.length(); k++) {
                    if (k > 0) out.append(',');
                    out.append((int) v.string.charAt(k) & 0xff);
                }
                out.append(']');
                yield out.toString();
            }
            default -> "<other>";
        };
    }
}
