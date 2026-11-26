package tests;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import stope.Opcode;
import stope.Program;

/** 单行产物格式（docs/zh-cn/compiler-test-plan.md §2.3）—— 测试侧私有，不进库。
 *  照抄 python/tests/golden.py 的 dump_program。 */
public final class Dump {
    private static final String[] BUILTIN_NAMES = {
        "Assign", "PushNull", "PushFalse", "PushTrue", "PushInt", "PushFloat",
        "PushString", "PushBinArr", "PushValue", "PushId", "Call", "At", "Pop",
        "Minus", "Not", "Pow", "Mul", "Div", "IDiv", "Mod", "Add", "Sub", "EQ",
        "NE", "LT", "LE", "GT", "GE", "If", "GoTo", "GetArg", "ArgNum", "Return"
    };

    private static boolean hasArg(int op, Opcode.CustomOpcodeConfig cfg) {
        if (op > Opcode.Return) {
            if (cfg == null) return false;
            for (Opcode.CustomOpcode info : cfg.opcodes.values())
                if (info.opcode == op) return info.varArg;
            return false;
        }
        return Opcode.hasArg(op);
    }

    private static String esc(String s) {
        StringBuilder out = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '\\' -> out.append("\\\\");
                case '"' -> out.append("\\\"");
                case '\n' -> out.append("\\n");
                case '\r' -> out.append("\\r");
                case '\t' -> out.append("\\t");
                default -> out.append(c < 128 ? c : '?');
            }
        }
        return out.toString();
    }

    private static String fmtBytes(String bytes) {
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < bytes.length(); i++) {
            if (i > 0) out.append(',');
            out.append(String.format("%02x", (int) bytes.charAt(i) & 0xff));
        }
        return out.toString();
    }

    public static String dumpProgram(Program prog, Opcode.CustomOpcodeConfig cfg) {
        StringBuilder out = new StringBuilder("code[");
        List<Integer> ops = prog.opcodes;
        int i = 0;
        while (i < ops.size()) {
            if (i > 0) out.append(' ');
            int o = ops.get(i) & 0xffff;
            i++;
            if (o > Opcode.Return) out.append("Opcode(").append(o).append(')');
            else out.append(BUILTIN_NAMES[o]);
            if (hasArg(o, cfg) && i < ops.size()) {
                int arg = (short) (int) ops.get(i);
                out.append('(').append(arg).append(')');
                i++;
            }
        }
        out.append("] vars=").append(prog.variableNum)
           .append(" stack=").append(prog.requiredStackSize)
           .append(" maxRet=").append(prog.maxReturnNum)
           .append(" ints=[");
        for (int k = 0; k < prog.intConsts.size(); k++) {
            if (k > 0) out.append(',');
            out.append(prog.intConsts.get(k));
        }
        out.append("] floats=[");
        for (int k = 0; k < prog.floatConsts.size(); k++) {
            if (k > 0) out.append(',');
            out.append(stope.Format.fmtG(prog.floatConsts.get(k)));
        }
        out.append("] strs=[");
        for (int k = 0; k < prog.stringConsts.size(); k++) {
            if (k > 0) out.append(',');
            out.append(esc(prog.stringConsts.get(k)));
        }
        out.append("] binarrs=[");
        for (int k = 0; k < prog.binarrConsts.size(); k++) {
            if (k > 0) out.append(' ');
            out.append('[').append(fmtBytes(prog.binarrConsts.get(k))).append(']');
        }
        out.append("] exports=[");
        List<String> names = new ArrayList<>(prog.exports.keySet());
        Collections.sort(names);
        for (int k = 0; k < names.size(); k++) {
            if (k > 0) out.append(',');
            out.append(esc(names.get(k))).append(':').append(prog.exports.get(names.get(k)));
        }
        out.append(']');
        return out.toString();
    }

    private Dump() {}
}
