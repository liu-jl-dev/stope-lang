//! 词法单元类型与 Token。编号与 C++ 的 stope::TokenType 逐项相同（0..47），不要重排。
//! 参照 go/token.go；对外打印一律走 typeName（True/False 去掉关键字冲突）。

pub const TokenType = enum(u8) {
    Invalid,
    Eof,
    Ident,
    Integer,
    Float,
    String,
    BinArr,
    Comma,
    Semi,
    LParen,
    RParen,
    LBrack,
    RBrack,
    LBrace,
    RBrace,
    Assign,
    Add,
    Sub,
    Mul,
    Div,
    IDiv,
    Mod,
    Pow,
    EQ,
    NE,
    LT,
    LE,
    GT,
    GE,
    Not,
    And,
    Or,
    If,
    Elif,
    Else,
    Let,
    Return,
    While,
    Break,
    Continue,
    Defer,
    Null,
    False_,
    True_,
    Args,
    Argc,
    Export,
    Custom,
};

const type_names = [_][]const u8{
    "Invalid", "Eof", "Ident", "Integer", "Float", "String", "BinArr",
    "Comma", "Semi", "LParen", "RParen", "LBrack", "RBrack", "LBrace",
    "RBrace", "Assign", "Add", "Sub", "Mul", "Div", "IDiv", "Mod", "Pow",
    "EQ", "NE", "LT", "LE", "GT", "GE", "Not", "And", "Or", "If", "Elif",
    "Else", "Let", "Return", "While", "Break", "Continue", "Defer", "Null",
    "False", "True", "Args", "Argc", "Export", "Custom",
};

pub fn typeName(t: TokenType) []const u8 {
    return type_names[@intFromEnum(t)];
}

pub const Value = union(enum) {
    none,
    integer: i64,
    float: f64,
};

/// Lexeme 是原文片段；parsed 是「语义形态」（数字去下划线、标识符拼好冒号、
/// 字符串反转义后）。value 只对整数 / 浮点有意义。
pub const Token = struct {
    line: i32 = 1,
    typ: TokenType = .Eof,
    lexeme: []const u8 = "",
    parsed: []const u8 = "",
    value: Value = .none,
};
