//! 词法单元类型与 `Token` —— 对齐 `python/stope/token.py`。
//!
//! 编号与 C++ 的 `stope::TokenType` 逐项相同（0..46），**不要重排**。

/// 词法单元类型（编号与 C++ 逐项相同）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum TokenType {
    Invalid = 0,
    Eof = 1,
    Ident = 2,
    Integer = 3,
    Float = 4,
    String = 5,
    BinArr = 6,
    Comma = 7,
    Semi = 8,
    LParen = 9,
    RParen = 10,
    LBrack = 11,
    RBrack = 12,
    LBrace = 13,
    RBrace = 14,
    Assign = 15,
    Add = 16,
    Sub = 17,
    Mul = 18,
    Div = 19,
    IDiv = 20,
    Mod = 21,
    Pow = 22,
    EQ = 23,
    NE = 24,
    LT = 25,
    LE = 26,
    GT = 27,
    GE = 28,
    Not = 29,
    And = 30,
    Or = 31,
    If = 32,
    Elif = 33,
    Else = 34,
    Let = 35,
    Return = 36,
    While = 37,
    Break = 38,
    Continue = 39,
    Null = 40,
    False = 41,
    True = 42,
    Args = 43,
    Argc = 44,
    Export = 45,
    Custom = 46,
}

/// 枚举 → golden 里用的名字。
pub fn type_name(t: TokenType) -> &'static str {
    const NAMES: [&str; 47] = [
        "Invalid", "Eof", "Ident", "Integer", "Float", "String", "BinArr", "Comma", "Semi",
        "LParen", "RParen", "LBrack", "RBrack", "LBrace", "RBrace", "Assign", "Add", "Sub",
        "Mul", "Div", "IDiv", "Mod", "Pow", "EQ", "NE", "LT", "LE", "GT", "GE", "Not", "And",
        "Or", "If", "Elif", "Else", "Let", "Return", "While", "Break", "Continue", "Null",
        "False", "True", "Args", "Argc", "Export", "Custom",
    ];
    NAMES[t as usize]
}

/// 字面量的语义值（整数或浮点）。
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Literal {
    Int(i64),
    Float(f64),
}

/// 一个词法单元。`lexeme` 是原文；`parsed` 是语义形态（数字去掉下划线、字符串
/// 反转义后、标识符拼好 `:`）。只有数字 / 字符串 / 二进制数组的 lexeme 参与
/// 跨实现比对。
#[derive(Debug, Clone)]
pub struct Token {
    pub line: i32,
    pub type_: TokenType,
    pub lexeme: String,
    pub parsed: String,
    pub value: Option<Literal>,
}

impl Default for Token {
    fn default() -> Self {
        Token { line: 0, type_: TokenType::Eof, lexeme: String::new(), parsed: String::new(), value: None }
    }
}

impl Token {
    pub fn new(line: i32, type_: TokenType) -> Self {
        Token { line, type_, lexeme: String::new(), parsed: String::new(), value: None }
    }

    pub fn int_value(&self) -> i64 {
        match self.value {
            Some(Literal::Int(v)) => v,
            _ => 0,
        }
    }

    pub fn float_value(&self) -> f64 {
        match self.value {
            Some(Literal::Float(v)) => v,
            _ => 0.0,
        }
    }
}
