package stope;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** 反汇编（照搬 python/stope/debug.py）。输出与 C++/GD/Node/C# 逐字节一致。 */
public final class Debug {
    private static final String[] NAMES = {
        "Assign", "PushNull", "PushFalse", "PushTrue", "PushInt",
        "PushFloat", "PushString", "PushBinArr", "PushValue", "PushId",
        "Call", "At", "Pop", "Minus", "Not",
        "Pow", "Mul", "Div", "IDiv", "Mod",
        "Add", "Sub", "EQ", "NE", "LT",
        "LE", "GT", "GE", "If", "GoTo",
        "GetArg", "ArgNum", "Return"
    };
    private static final int MIN_NAME_WIDTH = 10;

    private static String padRight(String s, int width) {
        if (s.length() >= width) return s;
        return s + " ".repeat(width - s.length());
    }

    private static boolean opcodeHasArg(int raw) {
        if (raw >= Opcode.PushInt && raw <= Opcode.At) return true;
        return raw == Opcode.If || raw == Opcode.GoTo || raw == Opcode.Return;
    }

    private static final class ByOpcode {
        final String name; final Opcode.CustomOpcode info;
        ByOpcode(String n, Opcode.CustomOpcode i) { name = n; info = i; }
    }

    public static String disasm(Program prog, Opcode.CustomOpcodeConfig cfg) {
        StringBuilder out = new StringBuilder();
        Map<Integer, ByOpcode> byOpcode = new HashMap<>();
        List<String> warnings = new ArrayList<>();
        int nameWidth = MIN_NAME_WIDTH;

        if (cfg != null) {
            // 按名字字典序建表（撞号时"谁赢"与 C++ 一致）
            List<String> names = new ArrayList<>(cfg.opcodes.keySet());
            Collections.sort(names);
            for (String name : names) {
                Opcode.CustomOpcode info = cfg.opcodes.get(name);
                int raw = info.opcode;
                if (raw < Opcode.kFirstCustomOpcode) {
                    String what = (raw >= 0 && raw < NAMES.length) ? NAMES[raw] : "(not an opcode)";
                    warnings.add("custom opcode \"" + name + "\" uses #" + raw + ", which collides with " + what + "; builtin decoding wins.");
                    continue;
                }
                if (byOpcode.containsKey(raw)) {
                    warnings.add("custom opcodes \"" + byOpcode.get(raw).name + "\" and \"" + name + "\" share #" + raw + "; the former wins.");
                    continue;
                }
                byOpcode.put(raw, new ByOpcode(name, info));
                if (name.length() > nameWidth) nameWidth = name.length();
            }
        }

        Set<Integer> unknown = new HashSet<>();
        List<Integer> ops = prog.opcodes;
        int i = 0;
        while (i < ops.size()) {
            int raw = (short) (int) ops.get(i);
            boolean hasArg = false;
            String name;
            if (raw >= 0 && raw < NAMES.length) {
                name = NAMES[raw];
                hasArg = opcodeHasArg(raw);
            } else if (byOpcode.containsKey(raw)) {
                ByOpcode ent = byOpcode.get(raw);
                name = ent.name;
                hasArg = ent.info.varArg;
            } else {
                name = raw > Opcode.Return ? "Custom" + raw : "Op#" + raw;
                unknown.add(raw);
            }
            out.append(padRight("[" + i + "]", 8));
            out.append(padRight(name, nameWidth));
            out.append(' ');
            i++;
            if (hasArg) {
                if (i < ops.size()) {
                    out.append((short) (int) ops.get(i));
                    i++;
                } else {
                    out.append("<missing operand>");
                    warnings.add("opcode at [" + (i - 1) + "] expects an operand but the stream ends there.");
                }
            }
            out.append('\n');
        }

        if (!byOpcode.isEmpty()) {
            out.append("custom opcodes:\n");
            List<Integer> keys = new ArrayList<>(byOpcode.keySet());
            Collections.sort(keys);
            for (int k : keys) {
                ByOpcode ent = byOpcode.get(k);
                out.append("  ").append(padRight(ent.name, nameWidth)).append(" -> ").append(k);
                if (ent.info.varArg) out.append(" (vararg)\n");
                else out.append(" (").append(ent.info.argNum).append(" args)\n");
            }
        }

        out.append("variables:\n");
        String[] variables = new String[Math.max(prog.variableNum, 0)];
        java.util.Arrays.fill(variables, "");
        for (Map.Entry<String, Integer> ent : prog.exports.entrySet()) {
            int idx = ent.getValue();
            if (idx >= 0 && idx < variables.length) variables[idx] = ent.getKey();
        }
        out.append("  ");
        for (int k = 0; k < variables.length; k++) {
            if (k > 0) out.append(' ');
            out.append('"').append(variables[k]).append('"');
        }
        out.append('\n');

        out.append("int consts:\n");
        for (long v : prog.intConsts) out.append("  ").append(v);
        out.append("\nfloat consts:\n");
        for (double v : prog.floatConsts) out.append("  ").append(Format.fmtG(v));
        out.append("\nstring consts:\n");
        for (String v : prog.stringConsts) out.append("  \"").append(v).append("\"\n");
        out.append("binary array consts:\n");
        for (String v : prog.binarrConsts) out.append("  ").append(v.length()).append(" bytes\n");
        out.append("max return num: ").append(prog.maxReturnNum).append('\n');
        out.append("required stack size: ").append(prog.requiredStackSize).append('\n');

        for (int raw : unknown) {
            if (raw > Opcode.Return)
                warnings.add("opcode #" + raw + " is not a builtin; pass the CustomOpcodeConfig to Disasm() to decode it.");
            else
                warnings.add("opcode #" + raw + " is not a valid instruction (unpatched placeholder?).");
        }
        for (String w : warnings) out.append("warning: ").append(w).append('\n');
        return out.toString();
    }

    private Debug() {}
}
