package stope;

import java.util.HashMap;
import java.util.Map;

/** 33 条内置指令，编号与 C++ 逐项相同（0..32，按声明顺序）。 */
public final class Opcode {
    public static final int
        Assign = 0, PushNull = 1, PushFalse = 2, PushTrue = 3,
        PushInt = 4, PushFloat = 5, PushString = 6, PushBinArr = 7,
        PushValue = 8, PushId = 9, Call = 10, At = 11, Pop = 12,
        Minus = 13, Not = 14, Pow = 15, Mul = 16, Div = 17, IDiv = 18,
        Mod = 19, Add = 20, Sub = 21, EQ = 22, NE = 23, LT = 24, LE = 25,
        GT = 26, GE = 27, If = 28, GoTo = 29, GetArg = 30, ArgNum = 31,
        Return = 32;
    public static final int kFirstCustomOpcode = Return + 1;

    /** 带操作数的内置指令。自定义指令由登记表决定。 */
    public static boolean hasArg(int op) {
        if (op > Return) return false;
        return switch (op) {
            case PushInt, PushFloat, PushString, PushBinArr, PushValue, PushId,
                 Call, At, If, GoTo, Return -> true;
            default -> false;
        };
    }

    public static final class CustomOpcode {
        public final int opcode;
        public final int argNum;
        public final boolean varArg;
        public CustomOpcode(int opcode, int argNum) {
            this.opcode = opcode;
            this.argNum = argNum;
            this.varArg = argNum < 0;
        }
    }

    public static final class CustomOpcodeConfig {
        public final Map<String, CustomOpcode> opcodes = new HashMap<>();
        public void add(String name, int opcode, int argNum) {
            opcodes.put(name, new CustomOpcode(opcode, argNum));
        }
        public CustomOpcode find(String name) { return opcodes.get(name); }
        public boolean contains(String name) { return opcodes.containsKey(name); }
    }

    private Opcode() {}
}
