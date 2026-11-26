package stope;

/** 词法单元类型。编号与 C++ 的 stope::TokenType 逐项相同（0..47），不要重排。 */
public final class TokenType {
    public static final int
        Invalid = 0, Eof = 1, Ident = 2, Integer = 3, Float = 4, String = 5, BinArr = 6,
        Comma = 7, Semi = 8, LParen = 9, RParen = 10, LBrack = 11, RBrack = 12,
        LBrace = 13, RBrace = 14, Assign = 15, Add = 16, Sub = 17, Mul = 18,
        Div = 19, IDiv = 20, Mod = 21, Pow = 22, EQ = 23, NE = 24, LT = 25, LE = 26,
        GT = 27, GE = 28, Not = 29, And = 30, Or = 31, If = 32, Elif = 33,
        Else = 34, Let = 35, Return = 36, While = 37, Break = 38, Continue = 39,
        Defer = 40, Null = 41, False_ = 42, True_ = 43, Args = 44, Argc = 45,
        Export = 46, Custom = 47;

    private static final String[] NAMES = {
        "Invalid", "Eof", "Ident", "Integer", "Float", "String", "BinArr",
        "Comma", "Semi", "LParen", "RParen", "LBrack", "RBrack", "LBrace", "RBrace",
        "Assign", "Add", "Sub", "Mul", "Div", "IDiv", "Mod", "Pow", "EQ", "NE", "LT",
        "LE", "GT", "GE", "Not", "And", "Or", "If", "Elif", "Else", "Let", "Return",
        "While", "Break", "Continue", "Defer", "Null", "False", "True", "Args", "Argc",
        "Export", "Custom"
    };
    public static String name(int t) { return NAMES[t]; }

    private TokenType() {}
}

